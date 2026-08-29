import Foundation
import MLX
import MLXAudioSTT
import HuggingFace

// Backends ASR :
//   voxtral   — Voxtral Mini 4B Realtime via sidecar python (uv, audité,
//               par-fenêtre avec deltas) ;
//   voxtral4b — même modèle, natif Swift (fp16), sans python ;
//   qwen3asr  — Qwen3-ASR 0,6B 4-bit (mlx-community), test qualité.

enum ASRBackend: String, CaseIterable, Sendable {
    case voxtral = "voxtral"
    case voxtral4b = "voxtral4b"
    case qwen3asr = "qwen3asr"

    static let `default` = ASRBackend.voxtral

    var displayName: String {
        switch self {
        case .voxtral: "Voxtral 4B Realtime (sidecar)"
        case .voxtral4b: "Voxtral 4B Realtime fp16 (Swift)"
        case .qwen3asr: "Qwen3-ASR 0,6B (Swift)"
        }
    }

    func parse(_ raw: String) -> ASRBackend? {
        ASRBackend(rawValue: raw.lowercased())
    }
}

struct ASRResult: Sendable {
    let backend: ASRBackend
    let chunkTexts: [String]
    let fullText: String
    let windowSeconds: Int
}

enum ASR {
    static let sidecarRoot: URL = Pipeline.homeURL.appendingPathComponent("sidecar", isDirectory: true)

    /// Transcrit l'audio fenêtre par fenêtre (30 s) et retourne le texte
    /// par fenêtre + le texte complet (contrôle de cohérence).
    /// `language` : langue forcée ("ja" par défaut, "auto" = pas de forçage).
    static func transcribe(
        windows: [Audio.Window],
        samples: [Float],
        backend: ASRBackend,
        language: String = "ja",
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ASRResult {
        switch backend {
        case .voxtral:
            return try await transcribeVoxtralSidecar(
                windows: windows, samples: samples, language: language, progress: progress
            )
        case .voxtral4b:
            return try await transcribeNative(
                windows: windows,
                modelID: "mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16",
                language: language,
                progress: progress
            )
        case .qwen3asr:
            return try await transcribeQwen3ASR(windows: windows, language: language, progress: progress)
        }
    }

    /// Proportion de caractères « étrangers » (latins + hangul) pour une
    /// transcription censée être en `language` (ici ja). Un ratio élevé
    /// signale une dérive linguistique (hallucination multilingue sur
    /// l'audio incertain).
    static func foreignRatio(_ text: String, expected: String) -> Double {
        let chars = Array(text)
        guard !chars.isEmpty else { return 1 }
        var foreign = 0
        for ch in chars {
            guard let v = ch.unicodeScalars.first?.value else { continue }
            switch v {
            case 0x41...0x5A, 0x61...0x7A: foreign += 1   // latins
            case 0xAC00...0xD7A3: foreign += 1            // hangul
            default: break
            }
        }
        return Double(foreign) / Double(chars.count)
    }

    // ------------------------------------------------------------------
    // Sidecar python (uv) — défaut, audité dans WhisperASR.
    // ------------------------------------------------------------------

    private static func transcribeVoxtralSidecar(
        windows: [Audio.Window],
        samples: [Float],
        language: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ASRResult {
        let helper = VoxtralHelperRuntime(rootDirectory: sidecarRoot)
        try await helper.prepare { fraction, message in
            progress(fraction * 0.3, "Voxtral sidecar — \(message)")
        }
        let windowCount = windows.count
        var chunkTexts: [String] = []
        // Offline par fenêtre : chaque fenêtre est transcrite dans une session
        // dédiée puis mise à jour (commit/flush). Le commit résout le décalage
        // du modèle streaming : le texte de la fenêtre K est la transcription
        // complète de son propre audio (et non un fragment décalé).
        for (index, window) in windows.enumerated() {
            let windowSamples = Array(window.samples)
            var chunkText = ""
            do {
                _ = try await helper.startSession()
                try await helper.append(
                    samples: windowSamples,
                    range: 0..<windowSamples.count
                )
                chunkText = try await helper.stopAndFlush()
            } catch {
                Pipeline.log("fenêtre Voxtral \(index + 1) en échec : \(error.localizedDescription)")
                await helper.cancel()
            }
            chunkTexts.append(chunkText.trimmingCharacters(in: .whitespacesAndNewlines))
            progress(
                0.3 + Double(index + 1) / Double(max(windowCount, 1)) * 0.55,
                "fenêtre \(index + 1)/\(windowCount)"
            )
        }
        await helper.shutdown()

        // Forçage de langue : si une fenêtre a dérivé (texte non-japonais sur
        // de l'audio japonais), on la retraduit avec le modèle natif (fp16)
        // qui force la langue. On ne remplace que si la retraduction est plus
        // propre (ratio d'étrangers inférieur).
        if language != "auto" {
            let drifted = chunkTexts.indices.filter {
                !chunkTexts[$0].isEmpty && foreignRatio(chunkTexts[$0], expected: language) > 0.10
            }
            if !drifted.isEmpty {
                progress(0.85, "forçage \(language) : \(drifted.count) fenêtre(s) à retraduire")
                Pipeline.log("forçage \(language) : \(drifted.count) fenêtre(s) dérivée(s) (index \(drifted.map { $0 + 1 }))")
                let model = try await VoxtralRealtimeModel.fromPretrained("mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16")
                var fixed = 0
                for i in drifted {
                    let retext = await transcribeWindow(windows[i], language: language, model: model)
                    if foreignRatio(retext, expected: language) < foreignRatio(chunkTexts[i], expected: language) {
                        chunkTexts[i] = retext
                        fixed += 1
                    }
                }
                Pipeline.log("forçage \(language) : \(fixed)/\(drifted.count) fenêtre(s) retraduite(s)")
            }
        }

        let fullText = chunkTexts.joined(separator: " ")
        return ASRResult(
            backend: .voxtral,
            chunkTexts: chunkTexts,
            fullText: fullText,
            windowSeconds: 20
        )
    }

    /// Retraduit une fenêtre avec le modèle natif (forçage de langue).
    private static func transcribeWindow(
        _ window: Audio.Window,
        language: String,
        model: VoxtralRealtimeModel
    ) async -> String {
        let parameters = STTGenerateParameters(
            maxTokens: 2048,
            temperature: 0,
            topP: 1,
            topK: 0,
            verbose: false,
            language: language,
            chunkDuration: 20,
            minChunkDuration: 1
        )
        let output = await Task.detached(priority: .userInitiated) {
            model.generate(audio: MLXArray(Array(window.samples)), generationParameters: parameters)
        }.value
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // ------------------------------------------------------------------
    // Natif Swift : Voxtral 4B Realtime fp16 (mlx-audio-swift).
    // ------------------------------------------------------------------

    private static func transcribeNative(
        windows: [Audio.Window],
        modelID: String,
        language: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ASRResult {
        progress(0.05, "Chargement \(modelID)…")
        let model = try await VoxtralRealtimeModel.fromPretrained(modelID)
        progress(0.3, "Modèle Voxtral 4B prêt")
        var chunkTexts: [String] = []
        for (index, window) in windows.enumerated() {
            let parameters = STTGenerateParameters(
                maxTokens: 2048,
                temperature: 0,
                topP: 1,
                topK: 0,
                verbose: false,
                language: language,
                chunkDuration: 20,
                minChunkDuration: 1
            )
            let output = await Task.detached(priority: .userInitiated) {
                model.generate(audio: MLXArray(Array(window.samples)), generationParameters: parameters)
            }.value
            chunkTexts.append(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
            progress(
                0.3 + Double(index + 1) / Double(max(windows.count, 1)) * 0.65,
                "fenêtre \(index + 1)/\(windows.count)"
            )
        }
        let fullText = chunkTexts.joined(separator: " ")
        return ASRResult(
            backend: .voxtral4b,
            chunkTexts: chunkTexts,
            fullText: fullText,
            windowSeconds: 20
        )
    }

    // ------------------------------------------------------------------
    // Qwen3-ASR (test qualité).
    // ------------------------------------------------------------------

    private static func transcribeQwen3ASR(
        windows: [Audio.Window],
        language: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ASRResult {
        progress(0.05, "Chargement Qwen3-ASR…")
        let model = try await Qwen3ASRModel.fromPretrained("mlx-community/Qwen3-ASR-0.6B-4bit")
        progress(0.3, "Modèle Qwen3-ASR prêt")
        var chunkTexts: [String] = []
        for (index, window) in windows.enumerated() {
            let parameters = STTGenerateParameters(
                maxTokens: 2048,
                temperature: 0,
                topP: 1,
                topK: 0,
                verbose: false,
                language: language,
                chunkDuration: 20,
                minChunkDuration: 1
            )
            let output = await Task.detached(priority: .userInitiated) {
                model.generate(audio: MLXArray(Array(window.samples)), generationParameters: parameters)
            }.value
            chunkTexts.append(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
            progress(
                0.3 + Double(index + 1) / Double(max(windows.count, 1)) * 0.65,
                "fenêtre \(index + 1)/\(windows.count)"
            )
        }
        return ASRResult(
            backend: .qwen3asr,
            chunkTexts: chunkTexts,
            fullText: chunkTexts.joined(separator: " "),
            windowSeconds: 20
        )
    }
}
