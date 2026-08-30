import AudioCommon
import CryptoKit
import Foundation
import MLX
import Qwen3ASR

/// Niveau final de précision ASR (mode live) : Qwen3-ASR 1,7B japonais 8-bit (MLX).
///
/// Le runtime est vendu dans le repo (`Vendor/SpeechSwiftPrototype`, issu de
/// WhisperASR, mêmes pins MLX que le reste du repo). Les poids vivent dans le
/// cache custom de WhisperASR (`~/Library/Caches/qwen3-speech/...`) : si le
/// bundle est présent, le chargement est offline avec gating révision/SHA256 ;
/// sinon un téléchargement unique est autorisé.
actor Qwen3ASRFinalRuntime {
    /// Le modèle 1,7B mesuré (p95 0,64 s, CER ~26 %, 0 vide sur le clip 60 s).
    static let modelID = "ph0ryn/Qwen3-ASR-1.7B-JA-MLX-8bit"
    static let expectedRevision = "7c70d18cb650655d32eafb952a74a49c6a3caad0"
    static let expectedArtifactSHA256: [String: String] = [
        "model.safetensors": "bdef075a5044d0befcf18541e97c8d3dadc273bf00857bbf4d1601bd11480954",
        "model.safetensors.index.json": "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5",
    ]
    static let modelLanguage = "Japanese"
    static let sampleRate = 16_000
    /// Plafond de tokens par transcription (mêmes options que WhisperASR).
    static let maxTokens = 448

    enum Qwen3ASRFinalError: LocalizedError, Equatable {
        case modelNotCached
        case invalidModelRevision(expected: String, actual: String)
        case invalidModelChecksum(artifact: String, expected: String, actual: String)
        case notPrepared

        var errorDescription: String? {
            switch self {
            case .modelNotCached:
                "Qwen3-ASR 1.7B JA n'est pas installé (\(Qwen3ASRFinalRuntime.modelID))."
            case .invalidModelRevision(let expected, let actual):
                "Qwen3-ASR 1.7B JA : révision inattendue (\(actual), attendu \(expected))."
            case .invalidModelChecksum(let artifact, let expected, let actual):
                "Qwen3-ASR 1.7B JA : empreinte SHA256 inattendue pour \(artifact)."
            case .notPrepared:
                "Qwen3-ASR 1.7B JA n'est pas chargé."
            }
        }
    }

    private var model: Qwen3ASRModel?
    private let clearCache: @Sendable () -> Void

    init(clearCache: @escaping @Sendable () -> Void = { MLX.Memory.clearCache() }) {
        self.clearCache = clearCache
    }

    var isPrepared: Bool { model != nil }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard model == nil else { return }
        let cache = try HuggingFaceDownloader.getCacheDirectory(for: Self.modelID)
        let offline = HuggingFaceDownloader.weightsExist(in: cache)
        if offline {
            // Un bundle local complet ne doit jamais déclencher de requête réseau.
            try Self.verifyArtifacts(in: cache)
        }
        progress(0, "Qwen3-ASR 1.7B JA : chargement…")
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: Self.modelID,
            cacheDir: cache,
            offlineMode: offline,
            progressHandler: { fraction, message in
                progress(min(fraction * 0.9 + 0.05, 0.95), "Qwen3-ASR 1.7B JA : \(message)")
            }
        )
        // Warmup (pattern WhisperASR QwenRuntime.prepare) : transcrire 1 s de
        // zéros pour chauffer les kernels Metal et le décodeur avant le
        // premier appel réel (évite la latence de premier passage).
        _ = loaded.transcribe(
            audio: [Float](repeating: 0, count: Self.sampleRate),
            sampleRate: Self.sampleRate,
            language: Self.modelLanguage,
            maxTokens: 16
        )
        model = loaded
        progress(1, "Qwen3-ASR 1.7B JA prêt")
    }

    /// Transcription d'audio 16 kHz en japonais, avec contexte glissant
    /// optionnel (carryover : dernières transcriptions, améliore les noms).
    /// Sérialisée par l'acteur ; le modèle s'exécute sur le GPU (MLX).
    func transcribe(audio: [Float], context: String? = nil) throws -> String {
        guard let model else { throw Qwen3ASRFinalError.notPrepared }
        var options = Qwen3DecodingOptions(maxTokens: Self.maxTokens, language: Self.modelLanguage)
        options.context = context
        return model.transcribe(audio: audio, sampleRate: Self.sampleRate, options: options)
    }

    func unload() {
        model = nil
        clearCache()
    }

    /// Gating révision + SHA256 (port simplifié de WhisperASR
    /// `requireQualifiedQwenArtifacts`). Les métadonnées de révision sont
    /// écrites par le téléchargeur custom dans `.cache/huggingface/download/`.
    static func verifyArtifacts(in directory: URL) throws {
        for name in expectedArtifactSHA256.keys.sorted() {
            let artifact = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: artifact.path) else {
                throw Qwen3ASRFinalError.modelNotCached
            }
            let metadata = directory.appendingPathComponent(
                ".cache/huggingface/download/\(name).metadata"
            )
            let revision = (try? String(contentsOf: metadata, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? "missing"
            guard revision == expectedRevision else {
                throw Qwen3ASRFinalError.invalidModelRevision(
                    expected: expectedRevision, actual: revision
                )
            }
            let data = try Data(contentsOf: artifact)
            let digest = SHA256.hash(data: data)
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard let expected = expectedArtifactSHA256[name] else { continue }
            guard actual == expected else {
                throw Qwen3ASRFinalError.invalidModelChecksum(
                    artifact: name, expected: expected, actual: actual
                )
            }
        }
    }
}
