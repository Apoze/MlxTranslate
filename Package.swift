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
        .executable(name: "mlxtranslate", targets: ["MlxTranslateCLI"]),
        .executable(name: "mlxtranslatetests", targets: ["MlxTranslateTests"]),
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
        // Bibliothèque : pipeline (SRT, CLIParser, Live, ASR, ...) — pas de point
        // d'entrée (`@main`), pour pouvoir être dépendante sans double `__main`.
        .target(
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
            // Permet `@testable import MlxTranslate` (le CLI + le test runner
            // accèdent aux types internes SRT / CLIParser / LiveEndpointing / Command).
            swiftSettings: [.unsafeFlags(["-enable-testing"])],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++"),
                .linkedFramework("Foundation"),
            ]
        ),
        // Point d'entrée du CLI (`@main`) : une fine couche sur la bibliothèque.
        .executableTarget(
            name: "MlxTranslateCLI",
            dependencies: ["MlxTranslate"],
            path: "Sources/MlxTranslateCLI"
        ),
        // Suite de tests autoportante (rapides : SRT, CLI, endpointing) — une cible
        // exécutable, pas de framework XCTest / swift-testing (absent du toolchain CLT).
        // Lancement : `swift run mlxtranslatetests` (sort 0 si vert, 1 sinon).
        .executableTarget(
            name: "MlxTranslateTests",
            dependencies: ["MlxTranslate"],
            path: "Tests/MlxTranslateTests"
        ),
    ],
    swiftLanguageModes: [.v5],
)
