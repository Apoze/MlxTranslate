// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SpeechSwiftPrototype",
    platforms: [
        .macOS("15.0"),
        .iOS("18.0"),
    ],
    products: [
        .library(name: "Qwen3ASR", targets: ["Qwen3ASR"]),
        .library(name: "SpeechVAD", targets: ["SpeechVAD"]),
        // Utilitaires partagés (téléchargeur HF, AlignedWord, tokenizer) —
        // exposés pour les consommateurs externes du repo MlxTranslate.
        .library(name: "AudioCommon", targets: ["AudioCommon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
    ],
    targets: [
        .target(
            name: "AudioCommon",
            dependencies: [
                .product(name: "Hub", package: "swift-transformers"),
            ]
        ),
        .target(
            name: "MLXCommon",
            dependencies: [
                "AudioCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXFFT", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "SpeechVAD",
            dependencies: ["AudioCommon"]
        ),
        .target(
            name: "Qwen3ASR",
            dependencies: [
                "AudioCommon",
                "MLXCommon",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
    ]
)
