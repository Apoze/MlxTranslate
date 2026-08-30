# speech-swift prototype snapshot

This directory contains only the source files needed by WhisperASR's remaining
local comparison prototypes. The retained upstream files are copied without
modification from:

- repository: `https://github.com/soniqo/speech-swift`
- commit: `9c4bff5a8f0287a179b9a039da25ff9fa02553a3`
- license: Apache-2.0 (see `LICENSE`)

The offline Qwen decoder is byte-identical at the E34-qualified upstream
revision `2723d1c2754fae2921fd4c475eb2594e88f7de39`:
`Sources/Qwen3ASR/Qwen3ASR.swift` SHA-256
`5d17f3f5465f4d548530e16c1007b34b02a823fecf1e53c3352e7ecb790e8fc1`.
No downloader, network helper or unrelated upstream source from that revision
is vendored.

The reduced package manifest intentionally excludes unrelated TTS, server,
benchmark, WhisperKit and `SpeechCore.xcframework` targets. MLX Swift 0.31.6
and Swift Transformers 1.3.3 remain exact external dependencies.

The root `Scripts/build_mlx_metallib.sh` is derived from the same pinned
upstream build script; it only adapts output discovery to WhisperASR's app and
test bundle names.

## Local modifications (MlxTranslate)

The upstream sources are otherwise untouched, except:

1. `Package.swift` — exposes the `AudioCommon` library product
   (upstream kept it internal-only). Needed by MlxTranslate for
   `HuggingFaceDownloader` and `AlignedWord`.
2. `Sources/Qwen3ASR/WeightLoading.swift` — `loadForcedAlignerWeights` gained
   a `convLayout: Conv2dWeightLayout` parameter (default `.pyTorch`, so the
   existing `fromPretrained` path is unchanged). The upstream loader
   unconditionally transposes the audio-encoder conv2d weights from the
   PyTorch `[outC, inC, kH, kW]` layout, which is correct for the
   `aufklarer/Qwen3-ForcedAligner-*` bundles but wrong for mlx-community HF
   snapshots, which are stored in MLX-native `[outC, kH, kW, inC]` layout
   (transposing them again corrupts conv1 into an `in_channels=3` weight and
   crashes the first forward pass). `.auto` detects the actual layout from the
   shape of `conv2d1.weight`; `.mlxNative` forces the no-transpose path.
   The mlx-community aligner snapshot also ships a quantized `lm_head`
   (4-bit U32 + per-group scales/biases) while `Qwen3ForcedAligner` keeps a
   float `classifyHead`; MlxTranslate's `Qwen3AlignerRuntime` dequantizes it
   with `MLX.dequantized` after weight loading, so no upstream model change.
