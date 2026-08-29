// Types de support extraits de whisperASR (commit 3a76d8f) :
// HighQualityJob.swift, HighQualityGlossary.swift, HighQualityConversationContext.swift,
// HighQualityTranslationIntegrity.swift. Seules les définitions nécessaires aux
// runtimes copiés (aligneur, diarisation, traduction) sont portées ici, sans le
// cadre de qualité japonais du dépôt d'origine.
import Foundation

// MARK: - Étapes et erreurs

enum HighQualityJobStage: String, Codable, Sendable {
    case validating
    case preparingASR = "preparing-asr"
    case transcribing
    case preparingAlignment = "preparing-alignment"
    case aligning
    case preparingDiarization = "preparing-diarization"
    case diarizing
    case translating
    case exporting
    case completed
    case cancelled
    case failed
}

enum HighQualityJobFailureStage: String, Codable, Sendable {
    case source
    case application
    case modelPreparation = "model-preparation"
    case asr
    case alignment
    case diarization
    case translation
    case export
    case cancelled
}

struct HighQualityJobError: LocalizedError, Equatable, Sendable {
    let stage: HighQualityJobFailureStage
    let message: String
    let resultDirectory: URL?

    var errorDescription: String? { message }
}

// MARK: - Cues / alignment

struct HighQualityTranslationTurn: Codable, Equatable, Sendable {
    let id: String
    let japanese: String
    let precedingJapanese: [String]
    let followingJapanese: [String]
    let speakerLabel: String?
    let sourceStart: TimeInterval?
    let sourceEnd: TimeInterval?

    init(
        id: String,
        japanese: String,
        precedingJapanese: [String] = [],
        followingJapanese: [String] = [],
        speakerLabel: String? = nil,
        sourceStart: TimeInterval? = nil,
        sourceEnd: TimeInterval? = nil
    ) {
        self.id = id
        self.japanese = japanese
        self.precedingJapanese = precedingJapanese
        self.followingJapanese = followingJapanese
        self.speakerLabel = speakerLabel
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
    }
}

struct HighQualityAlignedCue: Codable, Equatable, Sendable {
    let id: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let timingOrigin: String?
    let timingPolicy: String?
    let timingQuality: String?

    init(
        id: String,
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        timingOrigin: String? = nil,
        timingPolicy: String? = nil,
        timingQuality: String? = nil
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.timingOrigin = timingOrigin
        self.timingPolicy = timingPolicy
        self.timingQuality = timingQuality
    }
}

struct HighQualityAlignmentItem: Codable, Equatable, Sendable {
    let cueID: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

struct HighQualityAlignmentFallbackMerge: Codable, Equatable, Sendable {
    let chunkIndex: Int
    let sourceCueID: String
    let targetCueID: String
    let direction: String
    let sourceText: String
    let targetOriginalText: String
    let mergedText: String
    let sourceOriginalStart: TimeInterval
    let sourceOriginalEnd: TimeInterval
    let targetOriginalStart: TimeInterval
    let targetOriginalEnd: TimeInterval
    let finalStart: TimeInterval
    let finalEnd: TimeInterval
    let freeGapEnd: TimeInterval
    let timingPolicy: String
}

struct HighQualityAlignmentChunk: Codable, Equatable, Sendable {
    let index: Int
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let cues: [HighQualityAlignedCue]
    let rawItems: [HighQualityAlignmentItem]

    init(
        index: Int,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval,
        cues: [HighQualityAlignedCue],
        rawItems: [HighQualityAlignmentItem] = []
    ) {
        self.index = index
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.cues = cues
        self.rawItems = rawItems
    }
}

struct HighQualityAlignmentExchange: Codable, Equatable, Sendable {
    let chunks: [HighQualityAlignmentChunk]
    let modelID: String
    let revision: String
    let peakMemoryBytes: UInt64
    let configuration: [String: String]?
    let fallbackMerges: [HighQualityAlignmentFallbackMerge]?

    init(
        chunks: [HighQualityAlignmentChunk],
        modelID: String,
        revision: String,
        peakMemoryBytes: UInt64,
        configuration: [String: String]? = nil,
        fallbackMerges: [HighQualityAlignmentFallbackMerge]? = nil
    ) {
        self.chunks = chunks
        self.modelID = modelID
        self.revision = revision
        self.peakMemoryBytes = peakMemoryBytes
        self.configuration = configuration
        self.fallbackMerges = fallbackMerges
    }
}

// MARK: - Diarisation

struct HighQualitySpeakerCountPolicy: Codable, Equatable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable {
        case automatic
        case expected
    }

    static let validExpectedCounts = 1...20
    static let automatic = Self(mode: .automatic, expectedCount: nil)

    let mode: Mode
    let expectedCount: Int?

    static func expected(_ count: Int) -> Self {
        Self(mode: .expected, expectedCount: count)
    }

    var isValid: Bool {
        mode == .automatic
            || (expectedCount != nil && Self.validExpectedCounts.contains(expectedCount!))
    }
}

struct HighQualitySpeakerConfiguration: Codable, Equatable, Sendable {
    static let standard = Self(
        enhancedPrecision: false,
        sensitiveDetection: false,
        countPolicy: .automatic
    )
    static let sensitiveClusteringThreshold: Float = 0.55

    let enhancedPrecision: Bool
    let sensitiveDetection: Bool
    let countPolicy: HighQualitySpeakerCountPolicy

    var isValid: Bool { countPolicy.isValid }
}

struct HighQualityDiarizationSpan: Codable, Equatable, Sendable {
    let speakerID: Int
    let start: TimeInterval
    let end: TimeInterval
}

struct HighQualityDiarizationExchange: Codable, Equatable, Sendable {
    let spans: [HighQualityDiarizationSpan]
    let modelID: String
    let revision: String
    let peakMemoryBytes: UInt64
    let useExclusiveReconciliation: Bool
    let speakerCountPolicy: HighQualitySpeakerCountPolicy
    let configuration: [String: String]?
    let speakerCentroids: [Int: [Float]]?

    init(
        spans: [HighQualityDiarizationSpan],
        modelID: String,
        revision: String,
        peakMemoryBytes: UInt64,
        useExclusiveReconciliation: Bool = false,
        speakerCountPolicy: HighQualitySpeakerCountPolicy = .automatic,
        configuration: [String: String]? = nil,
        speakerCentroids: [Int: [Float]]? = nil
    ) {
        self.spans = spans
        self.modelID = modelID
        self.revision = revision
        self.peakMemoryBytes = peakMemoryBytes
        self.useExclusiveReconciliation = useExclusiveReconciliation
        self.speakerCountPolicy = speakerCountPolicy
        self.configuration = configuration
        self.speakerCentroids = speakerCentroids
    }
}

// MARK: - Glossaire / traduction

struct HighQualitySourceProvenance: Codable, Equatable, Sendable {
    let path: String
    let fileName: String

    init(path: String, fileName: String) {
        self.path = path
        self.fileName = fileName
    }
}

struct HighQualityGlossaryPromptTerm: Codable, Equatable, Sendable {
    let id: String
    let japanese: [String]
    let english: String
    let englishAliases: [String]
}

enum HighQualityGlossarySelector {
    static func matchedForm(in text: String, forms: [String]) -> String? {
        let normalizedText = normalized(text)
        return forms.sorted(by: { $0.utf8.count > $1.utf8.count }).first {
            contains(normalized($0), in: normalizedText)
        }
    }

    private static func contains(_ form: String, in text: String) -> Bool {
        guard form.unicodeScalars.allSatisfy(\.isASCII) else {
            return text.contains(form)
        }
        var searchStart = text.startIndex
        while let range = text.range(of: form, range: searchStart..<text.endIndex) {
            let beforeIsWord = range.lowerBound > text.startIndex
                && text[text.index(before: range.lowerBound)].isWholeNumberOrLetter
            let afterIsWord = range.upperBound < text.endIndex
                && text[range.upperBound].isWholeNumberOrLetter
            if !beforeIsWord && !afterIsWord { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

private extension Character {
    var isWholeNumberOrLetter: Bool { isLetter || isNumber }
}

enum HighQualityTranslationIntegrityReasonCode: String, Codable, CaseIterable, Sendable {
    case emptyOutput = "empty-output"
    case residualJapanese = "residual-japanese"
    case controlScaffolding = "control-scaffolding"
    case criticalGlossaryViolation = "critical-glossary-violation"
    case truncatedOutput = "truncated-output"
    case degenerateRepetition = "degenerate-repetition"
    case pathologicalLength = "pathological-length"
    case copiedNeighbour = "copied-neighbour"
}

enum HighQualityConversationContextResetReason: String, Codable, Sendable {
    case jobStart = "job-start"
    case largePause = "large-pause"
    case chapter
    case sceneBoundary = "scene-boundary"
}

struct HighQualityAcceptedTranslationPair: Codable, Equatable, Sendable {
    let cueID: String
    let japanese: String
    let english: String
}

struct HighQualityConversationContextEvidence: Codable, Equatable, Sendable {
    let policyVersion: String
    let acceptedHistory: [HighQualityAcceptedTranslationPair]
    let resetReason: HighQualityConversationContextResetReason?
    let currentTarget: String
    let encodedHistoryBytes: Int
}

struct HighQualityTranslationBatch: Codable, Equatable, Sendable {
    let source: HighQualitySourceProvenance
    let turns: [HighQualityTranslationTurn]
    let glossary: [HighQualityGlossaryPromptTerm]
    let glossaryByCueID: [String: [HighQualityGlossaryPromptTerm]]
    let conversationContextByCueID: [String: HighQualityConversationContextEvidence]
    let retryReasonCodes: [String: [HighQualityTranslationIntegrityReasonCode]]?

    init(
        source: HighQualitySourceProvenance,
        turns: [HighQualityTranslationTurn],
        glossary: [HighQualityGlossaryPromptTerm],
        glossaryByCueID: [String: [HighQualityGlossaryPromptTerm]]? = nil,
        conversationContextByCueID: [String: HighQualityConversationContextEvidence] = [:],
        retryReasonCodes: [String: [HighQualityTranslationIntegrityReasonCode]]? = nil
    ) {
        self.source = source
        self.turns = turns
        self.glossary = glossary
        self.glossaryByCueID = glossaryByCueID ?? Self.cueLocalGlossary(
            turns: turns,
            glossary: glossary
        )
        self.conversationContextByCueID = conversationContextByCueID
        self.retryReasonCodes = retryReasonCodes
    }

    private enum CodingKeys: String, CodingKey {
        case source, turns, glossary, glossaryByCueID, conversationContextByCueID
        case retryReasonCodes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        source = try values.decode(HighQualitySourceProvenance.self, forKey: .source)
        turns = try values.decode([HighQualityTranslationTurn].self, forKey: .turns)
        glossary = try values.decode([HighQualityGlossaryPromptTerm].self, forKey: .glossary)
        glossaryByCueID = values.decodeIfPresent(
            [String: [HighQualityGlossaryPromptTerm]].self,
            forKey: .glossaryByCueID
        ) ?? Self.cueLocalGlossary(turns: turns, glossary: glossary)
        conversationContextByCueID = values.decodeIfPresent(
            [String: HighQualityConversationContextEvidence].self,
            forKey: .conversationContextByCueID
        ) ?? [:]
        retryReasonCodes = values.decodeIfPresent(
            [String: [HighQualityTranslationIntegrityReasonCode]].self,
            forKey: .retryReasonCodes
        )
    }

    func glossary(for turn: HighQualityTranslationTurn) -> [HighQualityGlossaryPromptTerm] {
        glossaryByCueID[turn.id] ?? []
    }

    func context(for turn: HighQualityTranslationTurn) -> HighQualityConversationContextEvidence? {
        conversationContextByCueID[turn.id]
    }

    private static func cueLocalGlossary(
        turns: [HighQualityTranslationTurn],
        glossary: [HighQualityGlossaryPromptTerm]
    ) -> [String: [HighQualityGlossaryPromptTerm]] {
        Dictionary(uniqueKeysWithValues: turns.map { turn in
            (turn.id, glossary.filter { term in
                HighQualityGlossarySelector.matchedForm(
                    in: turn.japanese,
                    forms: term.japanese
                ) != nil
            })
        })
    }
}

struct HighQualityTranslationAttempt: Codable, Equatable, Sendable {
    let number: Int
    let duration: TimeInterval
    let outcome: String
}

struct HighQualityTranslationExchange: Codable, Equatable, Sendable {
    let model: String
    let response: String
    let attempts: [HighQualityTranslationAttempt]
    let revision: String?
    let runtimeVersion: String?
    let batches: [HighQualityLocalTranslationBatch]
    let peakMemoryBytes: UInt64

    init(
        model: String,
        response: String,
        attempts: [HighQualityTranslationAttempt],
        revision: String? = nil,
        runtimeVersion: String? = nil,
        batches: [HighQualityLocalTranslationBatch] = [],
        peakMemoryBytes: UInt64 = 0
    ) {
        self.model = model
        self.response = response
        self.attempts = attempts
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.batches = batches
        self.peakMemoryBytes = peakMemoryBytes
    }
}

struct HighQualityLocalTranslationBatch: Codable, Equatable, Sendable {
    let cueIDs: [String]
    let sanitizedPrompt: String
    let nativePrompt: String?
    let nativeOutput: String?
    let model: String?
    let revision: String?
    let sanitizedOutput: String
    let inputTokens: Int
    let outputTokens: Int?
    let finishReason: String?
    let duration: TimeInterval?
    let attemptNumber: Int?
    let validationReasonCodes: [HighQualityTranslationIntegrityReasonCode]?
    let selected: Bool?
    let terminalOutcome: String?
    let context: HighQualityConversationContextEvidence?

    init(
        cueIDs: [String],
        sanitizedPrompt: String,
        nativePrompt: String? = nil,
        nativeOutput: String? = nil,
        model: String? = nil,
        revision: String? = nil,
        sanitizedOutput: String,
        inputTokens: Int,
        outputTokens: Int? = nil,
        finishReason: String? = nil,
        duration: TimeInterval? = nil,
        attemptNumber: Int? = nil,
        validationReasonCodes: [HighQualityTranslationIntegrityReasonCode]? = nil,
        selected: Bool? = nil,
        terminalOutcome: String? = nil,
        context: HighQualityConversationContextEvidence? = nil
    ) {
        self.cueIDs = cueIDs
        self.sanitizedPrompt = sanitizedPrompt
        self.nativePrompt = nativePrompt
        self.nativeOutput = nativeOutput
        self.model = model
        self.revision = revision
        self.sanitizedOutput = sanitizedOutput
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
        self.duration = duration
        self.attemptNumber = attemptNumber
        self.validationReasonCodes = validationReasonCodes
        self.selected = selected
        self.terminalOutcome = terminalOutcome
        self.context = context
    }
}

struct HighQualityTranslationServiceError: Codable, LocalizedError, Sendable {
    let model: String
    let attempts: [HighQualityTranslationAttempt]
    let response: String?
    let revision: String?
    let runtimeVersion: String?
    let batches: [HighQualityLocalTranslationBatch]
    let peakMemoryBytes: UInt64
    let message: String

    init(
        model: String,
        attempts: [HighQualityTranslationAttempt],
        response: String?,
        revision: String? = nil,
        runtimeVersion: String? = nil,
        batches: [HighQualityLocalTranslationBatch] = [],
        peakMemoryBytes: UInt64 = 0,
        message: String
    ) {
        self.model = model
        self.attempts = attempts
        self.response = response
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.batches = batches
        self.peakMemoryBytes = peakMemoryBytes
        self.message = message
    }

    var errorDescription: String? { message }
}
