import AudioCommon
import Foundation
import MLX
import MLXCommon
import MLXNN
import Qwen3ASR

/// Niveau d'alignement mot-à-mot (mode live) : Qwen3-ForcedAligner 0,6B 4-bit.
///
/// Au commit d'une phrase, aligne le texte japonais retenu sur l'audio et
/// donne la borne exacte de consommation audio (zéro dérive entre les
/// fenêtres successives ; timestamps 80 ms, inférence non-autorégressive).
///
/// Les poids sont réutilisés depuis le cache Hugging Face
/// (`mlx-community/Qwen3-ForcedAligner-0.6B-4bit`, ~935 Mo, déjà installé) ;
/// à défaut, téléchargement unique du bundle équivalent `aufklarer` dans le
/// cache `qwen3-speech`.
actor Qwen3AlignerRuntime {
    /// Réutilisation du cache HF (aucun téléchargement).
    static let hubModelID = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
    /// Fallback : téléchargement unique (même modèle, MLX 4-bit).
    static let downloadModelID = "aufklarer/Qwen3-ForcedAligner-0.6B-4bit"
    static let sampleRate = 16_000

    enum Qwen3AlignerError: LocalizedError, Equatable {
        case notPrepared

        var errorDescription: String? {
            switch self {
            case .notPrepared: "Qwen3-ForcedAligner n'est pas chargé."
            }
        }
    }

    private var aligner: Qwen3ForcedAligner?
    private let clearCache: @Sendable () -> Void

    init(clearCache: @escaping @Sendable () -> Void = { MLX.Memory.clearCache() }) {
        self.clearCache = clearCache
    }

    var isPrepared: Bool { aligner != nil }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard aligner == nil else { return }
        if let snapshot = Self.hubSnapshotDirectory() {
            do {
                progress(0, "Qwen3-ForcedAligner 0.6B : chargement depuis le cache HF…")
                aligner = try Self.load(from: snapshot)
                progress(1, "Qwen3-ForcedAligner 0.6B prêt")
                return
            } catch {
                // Bundle HF incomplet ou incompatible → fallback téléchargement.
                progress(0, "Qwen3-ForcedAligner 0.6B : cache HF inutilisable, téléchargement…")
            }
        }
        let loaded = try await Qwen3ForcedAligner.fromPretrained(
            modelId: Self.downloadModelID,
            progressHandler: { fraction, message in
                progress(min(fraction * 0.9 + 0.05, 0.95), "Qwen3-ForcedAligner 0.6B : \(message)")
            }
        )
        aligner = loaded
        progress(1, "Qwen3-ForcedAligner 0.6B prêt")
    }

    /// Alignement d'un texte retenu sur l'audio 16 kHz → timestamps (secondes)
    /// par mot (80 ms de résolution). Sérialisé par l'acteur.
    func align(audio: [Float], text: String) throws -> [AlignedWord] {
        guard let aligner else { throw Qwen3AlignerError.notPrepared }
        return aligner.align(
            audio: audio, text: text, sampleRate: Self.sampleRate, language: "Japanese"
        )
    }

    func unload() {
        aligner = nil
        clearCache()
    }

    /// Snapshot du cache HF contenant les poids de l'aligneur (nil sinon).
    /// Le hub stocke `models--<org>--<model>/snapshots/<révision>/`.
    static func hubSnapshotDirectory() -> URL? {
        let hubDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: ".cache/huggingface/hub")
            .appending(path: "models--\(Self.hubModelID.replacingOccurrences(of: "/", with: "--"))")
            .appending(path: "snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: hubDirectory, includingPropertiesForKeys: nil
        ) else { return nil }
        return entries
            .filter { entry in
                FileManager.default.fileExists(
                    atPath: entry.appendingPathComponent("model.safetensors").path
                )
            }
            .first
    }

    /// Chargement manuel d'un snapshot HF (layout mlx-community :
    /// `model.safetensors` quantisé MLX 4-bit group-64, sans quantize_config).
    /// Variante `.mlx4bit` — identique à `ForcedAlignerVariant.mlx4bit.textConfig`.
    static func load(from directory: URL) throws -> Qwen3ForcedAligner {
        var textConfig = TextDecoderConfig.small
        textConfig.bits = 4
        textConfig.groupSize = 64
        let model = Qwen3ForcedAligner(
            audioConfig: .forcedAligner,
            textConfig: textConfig,
            classifyNum: 5000,
            useFloatTextDecoder: false
        )
        let vocabPath = directory.appendingPathComponent("vocab.json")
        if FileManager.default.fileExists(atPath: vocabPath.path) {
            let tokenizer = Qwen3Tokenizer()
            try tokenizer.load(from: vocabPath)
            model.tokenizer = tokenizer
        }
        // Le snapshot mlx-community est en layout MLX natif ; `.auto` détecte
        // la convention (PyTorch pour le bundle aufklarker, MLX natif ici).
        try WeightLoader.loadForcedAlignerWeights(into: model, from: directory, convLayout: .auto)
        try Self.patchClassifyHead(into: model, textConfig: textConfig, in: directory)
        return model
    }

    /// Le `lm_head` du snapshot mlx-community est quantisé (U32 4-bit +
    /// scales/biases par groupe) alors que `classifyHead` est un `Linear`
    /// flottant : le loader y dépose donc des poids bruts inutilisables.
    /// On déquantise (op `MLX.dequantized`, sur GPU) et on re-patche le
    /// poids. Sans effet si le bundle est déjà flottant (layout aufklarker).
    private static func patchClassifyHead(
        into model: Qwen3ForcedAligner,
        textConfig: TextDecoderConfig,
        in directory: URL
    ) throws {
        let weightFile = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "safetensors" }
        guard let weightFile else { return }
        let raw = try CommonWeightLoader.loadSafetensors(url: weightFile)
        guard let packed = raw["lm_head.weight"], packed.dtype == .uint32,
              let scales = raw["lm_head.scales"],
              let biases = raw["lm_head.biases"] else { return }
        let dequantized = MLX.dequantized(
            packed,
            scales: scales,
            biases: biases,
            groupSize: textConfig.groupSize,
            bits: textConfig.bits,
            mode: .affine
        )
        model.classifyHead.update(parameters: ModuleParameters(values: ["weight": .value(dequantized)]))
        print("Aligner : lm_head 4-bit déquantisé (head \(packed.shape[0]) classes)")
    }
}
