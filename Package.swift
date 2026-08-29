// swift-tools-version: 6.2
import PackageDescription

// MlxTranslate — pipeline local de sous-titrage :
//   Voxtral (ASR) -> Qwen3-ForcedAligner (horodatage) -> SpeakerKit (locuteurs)
//   -> traduction MLX -> SRT.
//
// Les runtimes de la cible `MlxTranslate/Runtime` sont issus du dépôt
// whisperASR (commit 3a76d8f, projet du même auteur) : HighQualityForcedAlignerRuntime,
// HighQualitySpeakerKitRuntime, LocalMLXTranslator, VoxtralHelperRuntime.

let package = Package(
    name: "MlxTranslate",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "mlxtranslate", targets: ["MlxTranslate"]),
    ],
    traits: [
        // Génère le bundle de ressources (Bundle.module) pour la cible.
        .init(name: "SwiftModuleResourceBundle"),
    ],
    dependencies: [
        // MLX (piles pinnées identiques à whisperASR).
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", exact: "0.1.3"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
    ],
    targets: [
        .executableTarget(
            name: "MlxTranslate",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/MlxTranslate",
            exclude: ["Runtime/VoxtralHelper"],
            resources: [
                .copy("Runtime/VoxtralHelper"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5],
)
