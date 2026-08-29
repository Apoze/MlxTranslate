import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

private typealias PromptMessage = [String: any Sendable]

actor LocalMLXTranslator {
    typealias CueGeneration = (
        nativePrompt: String,
        nativeOutput: String,
        inputTokens: Int,
        outputTokens: Int?,
        finishReason: String?
    )
    typealias CueGenerator = @Sendable (
        HighQualityTranslationTurn,
        HighQualityTranslationBatch
    ) async throws -> CueGeneration

    enum Candidate: String, CaseIterable, Codable, Sendable {
        case translateGemma12B = "translategemma-12b-it-4bit"
        case translateGemma4B = "translategemma-4b-it-4bit"
        case qwen2_5_7B = "qwen2.5-7b-4bit"
        case qwen3_8B = "qwen3-8b-4bit"
        case qwen3_14B = "qwen3-14b-4bit"

        // Défaut : le vainqueur mesuré du pipeline python historique (Qwen2.5-7B-4bit).
        static let productDefault = Candidate.qwen2_5_7B

        var modelID: String {
            switch self {
            case .translateGemma12B: "mlx-community/translategemma-12b-it-4bit"
            case .translateGemma4B: "mlx-community/translategemma-4b-it-4bit"
            case .qwen2_5_7B: "mlx-community/Qwen2.5-7B-4bit"
            case .qwen3_8B: "mlx-community/Qwen3-8B-4bit"
            case .qwen3_14B: "mlx-community/Qwen3-14B-4bit"
            }
        }

        var revision: String {
            switch self {
            case .translateGemma12B: "f3dcfd54df14672fbcf0731086fb47a797a943ae"
            case .translateGemma4B: "5788ec08c047f3f2e17808101b8d9566ac930d58"
            case .qwen2_5_7B, .qwen3_8B: "main"
            case .qwen3_14B: "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4"
            }
        }

        var weightSHA256: [String] {
            switch self {
            case .translateGemma12B:
                [
                    "bd64914bb159830648d444dec435236c2690214124761e78ece98d1ef1ee75af",
                    "c3b207c1a3ebafc136664dba65b3f474f73191634428b8380204e647fc844b89",
                ]
            case .translateGemma4B:
                ["113acb0c29997a3015af84bec2c8f967cb7b15f8959d1c26b9628b921e324c40"]
            case .qwen2_5_7B, .qwen3_8B: []
            case .qwen3_14B:
                [
                    "5795efcfc7c96fd273e600562e8b111bfcc427415de9001d0a07e70cd99cff19",
                    "2814562d654fe2d541fd4682804a0ccaa400e79701872c8e9f5998cf9481fdf8",
                ]
            }
        }

        var weightFileNames: [String] {
            switch self {
            case .translateGemma4B, .qwen2_5_7B, .qwen3_8B:
                ["model.safetensors"]
            case .translateGemma12B, .qwen3_14B:
                ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
            }
        }

        var declaredPeakMemoryBytes: UInt64 {
            switch self {
            case .translateGemma12B: 8 * 1_024 * 1_024 * 1_024
            case .translateGemma4B: 4 * 1_024 * 1_024 * 1_024
            case .qwen2_5_7B, .qwen3_8B: 8 * 1_024 * 1_024 * 1_024
            case .qwen3_14B: 10 * 1_024 * 1_024 * 1_024
            }
        }

        var extraEOSTokens: Set<String> {
            switch self {
            case .translateGemma12B, .translateGemma4B: ["<end_of_turn>"]
            case .qwen2_5_7B, .qwen3_8B, .qwen3_14B: ["<|im_end|>"]
            }
        }

        var usesTranslateGemmaContract: Bool {
            self == .translateGemma12B || self == .translateGemma4B
        }
    }

    static let modelID = Candidate.productDefault.modelID
    static let revision = Candidate.productDefault.revision
    static let runtimeVersion = "3.31.4"
    static let declaredPeakMemoryBytes = Candidate.productDefault.declaredPeakMemoryBytes
    static let inputTokenLimit = 2_048
    static let generationParameters = GenerateParameters(maxTokens: 256, temperature: 0)
    static let retryGenerationParameters = GenerateParameters(
        maxTokens: 128,
        temperature: 0
    )

    let candidate: Candidate
    private var container: ModelContainer?
    private let clearCache: @Sendable () -> Void
    private let cueGenerator: CueGenerator?

    init(
        candidate: Candidate = .productDefault,
        clearCache: @escaping @Sendable () -> Void = { Memory.clearCache() },
        cueGenerator: CueGenerator? = nil
    ) {
        self.candidate = candidate
        self.clearCache = clearCache
        self.cueGenerator = cueGenerator
    }

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard container == nil else { return }
        let candidate = self.candidate
        progress(0, "\(candidate.rawValue): preparing download…")
        Memory.peakMemory = 0
        let loaded = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(
                id: candidate.modelID,
                revision: candidate.revision,
                extraEOSTokens: candidate.extraEOSTokens
            ),
            progressHandler: {
                progress($0.fractionCompleted * 0.9, "\(candidate.rawValue): downloading…")
            }
        )
        do {
            try Task.checkCancellation()
        } catch {
            clearCache()
            throw error
        }
        container = loaded
        progress(1, "\(candidate.rawValue) ready")
    }

    func translate(_ batch: HighQualityTranslationBatch) async throws -> HighQualityTranslationExchange {
        defer { clearCache() }
        let container = self.container
        guard container != nil || cueGenerator != nil else {
            throw HighQualityTranslationServiceError(
                model: candidate.modelID,
                attempts: [],
                response: nil,
                message: "\(candidate.rawValue) is not loaded."
            )
        }

        let started = Date()
        var translations: [Translation] = []
        var traces: [HighQualityLocalTranslationBatch] = []
        var inFlightTrace: HighQualityLocalTranslationBatch?
        do {
            for turn in batch.turns {
                defer { clearCache() }
                try Task.checkCancellation()
                let unitStarted = Date()
                let prompt = Self.frozenPrompt(for: turn)
                let messages = messages(for: turn, in: batch)
                let nativePrompt: String
                let tokenCount: Int
                var output: String
                var outputTokens: Int?
                var finishReason: String?
                if let cueGenerator {
                    let generated = try await cueGenerator(turn, batch)
                    nativePrompt = generated.nativePrompt
                    tokenCount = generated.inputTokens
                    output = generated.nativeOutput
                    outputTokens = generated.outputTokens
                    finishReason = generated.finishReason
                } else {
                    guard let container else { preconditionFailure() }
                    let parameters = batch.retryReasonCodes == nil
                        ? Self.generationParameters
                        : Self.retryGenerationParameters
                    nativePrompt = try batch.retryReasonCodes == nil
                        ? Self.nativePrompt(messages)
                        : Self.retryNativeInput(messages)
                    tokenCount = try await Self.tokenCount(messages, using: container)
                    guard tokenCount <= Self.inputTokenLimit else {
                        throw HighQualityTranslationServiceError(
                            model: candidate.modelID,
                            attempts: [],
                            response: nil,
                            message: "Cue \(turn.id) exceeds the frozen 2K input limit."
                        )
                    }
                    output = ""
                    inFlightTrace = .init(
                        cueIDs: [turn.id],
                        sanitizedPrompt: prompt,
                        nativePrompt: nativePrompt,
                        nativeOutput: "",
                        model: candidate.modelID,
                        revision: candidate.revision,
                        sanitizedOutput: "",
                        inputTokens: tokenCount,
                        duration: 0,
                        context: batch.context(for: turn)
                    )
                    let input = try await container.prepare(input: UserInput(
                        prompt: .messages(messages),
                        additionalContext: ["enable_thinking": false]
                    ))
                    let stream = try await container.generate(
                        input: input,
                        parameters: parameters
                    )
                    for await generation in stream {
                        try Task.checkCancellation()
                        output += generation.chunk ?? ""
                        if let info = generation.info {
                            outputTokens = info.generationTokenCount
                            finishReason = switch info.stopReason {
                            case .stop: "stop"
                            case .length: "length"
                            case .cancelled: "cancelled"
                            }
                        }
                        inFlightTrace = .init(
                            cueIDs: [turn.id],
                            sanitizedPrompt: prompt,
                            nativePrompt: nativePrompt,
                            nativeOutput: output,
                            model: candidate.modelID,
                            revision: candidate.revision,
                            sanitizedOutput: "",
                            inputTokens: tokenCount,
                            outputTokens: outputTokens,
                            finishReason: finishReason,
                            duration: Date().timeIntervalSince(unitStarted),
                            context: batch.context(for: turn)
                        )
                    }
                }
                try Task.checkCancellation()
                let nativeOutput = output
                guard let output = Self.translationText(
                    nativeOutput,
                    for: turn,
                    candidate: candidate
                ), !output.isEmpty else {
                    throw HighQualityTranslationServiceError(
                        model: candidate.modelID,
                        attempts: [],
                        response: nil,
                        message: "\(candidate.rawValue) returned an empty translation for \(turn.id)."
                    )
                }
                translations.append(.init(id: turn.id, source: turn.japanese, text: output))
                traces.append(.init(
                    cueIDs: [turn.id],
                    sanitizedPrompt: prompt,
                    nativePrompt: nativePrompt,
                    nativeOutput: nativeOutput,
                    model: candidate.modelID,
                    revision: candidate.revision,
                    sanitizedOutput: output,
                    inputTokens: tokenCount,
                    outputTokens: outputTokens,
                    finishReason: finishReason,
                    duration: Date().timeIntervalSince(unitStarted),
                    context: batch.context(for: turn)
                ))
                inFlightTrace = nil
            }

            let response = String(decoding: try JSONEncoder().encode(
                Envelope(translations: translations.map { .init(id: $0.id, text: $0.text) })
            ), as: UTF8.self)
            return .init(
                model: candidate.modelID,
                response: response,
                attempts: [.init(
                    number: 1,
                    duration: Date().timeIntervalSince(started),
                    outcome: "success"
                )],
                revision: candidate.revision,
                runtimeVersion: Self.runtimeVersion,
                batches: traces + [inFlightTrace].compactMap { $0 },
                peakMemoryBytes: UInt64(max(0, Memory.peakMemory))
            )
        } catch let error as HighQualityTranslationServiceError {
            throw HighQualityTranslationServiceError(
                model: error.model,
                attempts: error.attempts,
                response: error.response,
                revision: candidate.revision,
                runtimeVersion: Self.runtimeVersion,
                batches: traces + [inFlightTrace].compactMap { $0 },
                peakMemoryBytes: UInt64(max(0, Memory.peakMemory)),
                message: error.message
            )
        } catch {
            throw HighQualityTranslationServiceError(
                model: candidate.modelID,
                attempts: [.init(
                    number: 1,
                    duration: Date().timeIntervalSince(started),
                    outcome: error.localizedDescription
                )],
                response: nil,
                revision: candidate.revision,
                runtimeVersion: Self.runtimeVersion,
                batches: traces + [inFlightTrace].compactMap { $0 },
                peakMemoryBytes: UInt64(max(0, Memory.peakMemory)),
                message: error.localizedDescription
            )
        }
    }

    func unload() {
        container = nil
        clearCache()
    }

    func handleMemoryWarning() {
        clearCache()
    }

    static func frozenPrompt(for turn: HighQualityTranslationTurn) -> String {
        turn.japanese
    }

    private func messages(
        for turn: HighQualityTranslationTurn,
        in batch: HighQualityTranslationBatch
    ) -> [PromptMessage] {
        if candidate.usesTranslateGemmaContract {
            if batch.retryReasonCodes != nil {
                return [Self.retryUserMessage(for: turn, glossary: batch.glossary(for: turn))]
            }
            return batch.context(for: turn).map(Self.contextMessages)
                ?? [Self.directUserMessage(turn.japanese)]
        }
        var pairs: [(String, String)] = []
        for term in batch.glossary(for: turn) {
            for japanese in term.japanese {
                pairs.append((japanese, term.english))
            }
        }
        var messages = pairs.flatMap { source, target in
            [qwenUserMessage(source), ["role": "assistant", "content": target]]
        }
        messages.append(qwenUserMessage(Self.contextText(for: turn), currentCue: true))
        return messages
    }

    private func qwenUserMessage(_ text: String, currentCue: Bool = false) -> PromptMessage {
        [
            "role": "user",
            "content": currentCue
                ? "Use the surrounding Japanese only as context. Translate only the text between the CURRENT markers. Return those exact markers around the English translation, without explanations:\n\n\(text)"
                : text,
        ]
    }

    static func directNativePrompt(for japanese: String) throws -> String {
        try nativePrompt([directUserMessage(japanese)])
    }

    static func contextNativePrompt(_ context: HighQualityConversationContextEvidence) throws -> String {
        try nativePrompt(contextMessages(context))
    }

    static func retryNativePrompt(
        for turn: HighQualityTranslationTurn,
        glossary: [HighQualityGlossaryPromptTerm]
    ) throws -> String {
        try retryNativeInput([retryUserMessage(for: turn, glossary: glossary)])
    }

    private static func retryUserMessage(
        for turn: HighQualityTranslationTurn,
        glossary: [HighQualityGlossaryPromptTerm]
    ) -> PromptMessage {
        canonicalUserMessage(for: turn, glossary: glossary, sourceLanguage: "ja-JP")
    }

    private static func canonicalUserMessage(
        for turn: HighQualityTranslationTurn,
        glossary: [HighQualityGlossaryPromptTerm],
        sourceLanguage: String = "ja"
    ) -> PromptMessage {
        let canonicalTerms = glossary.compactMap { term -> String? in
            guard let matched = term.japanese.first(where: turn.japanese.contains),
                  let canonical = term.japanese.first else { return nil }
            return matched == canonical
                ? "\(canonical) = \(term.english)"
                : "\(matched) = \(canonical) = \(term.english)"
        }
        return directUserMessage(
            (canonicalTerms + [turn.japanese]).joined(separator: "\n"),
            sourceLanguage: sourceLanguage
        )
    }

    private static func directUserMessage(
        _ text: String,
        sourceLanguage: String = "ja"
    ) -> PromptMessage {
        [
            "role": "user",
            "content": [textBlock(text, sourceLanguage: sourceLanguage)],
        ]
    }

    private static func contextMessages(
        _ context: HighQualityConversationContextEvidence
    ) -> [PromptMessage] {
        context.acceptedHistory.flatMap { pair in
            [directUserMessage(pair.japanese), ["role": "assistant", "content": pair.english]]
        } + [directUserMessage(context.currentTarget)]
    }

    private static func textBlock(
        _ text: String,
        sourceLanguage: String = "ja"
    ) -> PromptMessage {
        [
            "type": "text",
            "source_lang_code": sourceLanguage,
            "target_lang_code": "en",
            "text": text,
        ]
    }

    private static func contextText(for turn: HighQualityTranslationTurn) -> String {
        let start = "<<<CURRENT:\(turn.id)>>>"
        let end = "<<<END_CURRENT:\(turn.id)>>>"
        return """
        SPEAKER_ID:
        \(turn.speakerLabel ?? "")
        CONTEXT_BEFORE:
        \(turn.precedingJapanese.joined(separator: "\n"))
        \(start)
        \(turn.japanese)
        \(end)
        CONTEXT_AFTER:
        \(turn.followingJapanese.joined(separator: "\n"))
        """
    }

    static func translationText(
        _ output: String,
        for turn: HighQualityTranslationTurn,
        candidate: Candidate
    ) -> String? {
        if candidate.usesTranslateGemmaContract {
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let start = "<<<CURRENT:\(turn.id)>>>"
        let end = "<<<END_CURRENT:\(turn.id)>>>"
        guard let startRange = output.range(of: start),
              let endRange = output.range(of: end, range: startRange.upperBound..<output.endIndex) else {
            return nil
        }
        return output[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nativePrompt(_ messages: [PromptMessage]) throws -> String {
        String(decoding: try JSONSerialization.data(
            withJSONObject: messages,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), as: UTF8.self)
    }

    private static func retryNativeInput(_ messages: [PromptMessage]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [
            "messages": messages,
            "generation": [
                "max_tokens": retryGenerationParameters.maxTokens ?? 0,
                "temperature": retryGenerationParameters.temperature,
            ] as [String: any Sendable],
        ] as [String: any Sendable], options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private static func tokenCount(
        _ messages: [PromptMessage],
        using container: ModelContainer
    ) async throws -> Int {
        try await container.perform(values: messages) { context, messages in
            try context.tokenizer.applyChatTemplate(
                messages: messages,
                tools: nil,
                additionalContext: ["add_generation_prompt": true, "enable_thinking": false]
            ).count
        }
    }

    private struct Translation: Sendable {
        let id: String
        let source: String
        let text: String
    }

    private struct Envelope: Encodable {
        struct Item: Encodable { let id: String; let text: String }
        let translations: [Item]
    }
}
