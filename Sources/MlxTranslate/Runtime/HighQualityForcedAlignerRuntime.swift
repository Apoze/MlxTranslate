import Foundation
import HuggingFace
import MLX
import MLXAudioSTT

actor HighQualityForcedAlignerRuntime {
    static let modelID = "mlx-community/Qwen3-ForcedAligner-0.6B-4bit"
    static let revision = "2f652af86ae0c73fe189b9429225c908ce4bf020"
    static let declaredPeakMemoryBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024
    static let maximumWindowSeconds = 20
    static let maximumFallbackCharacters = 84
    static let maximumFallbackCharactersPerSecond = 20.0
    static let maximumCoarseAnchorCharacters = 48
    private static let sampleRate = 16_000

    private var model: Qwen3ForcedAlignerModel?

    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        guard model == nil else { return }
        progress(0, "Downloading Qwen3 ForcedAligner…")
        guard let repository = Repo.ID(rawValue: Self.modelID) else {
            throw jobError("Invalid forced-alignment model identifier.")
        }
        let directory = try await HubClient.default.downloadSnapshot(
            of: repository,
            revision: Self.revision
        ) { download in
            progress(download.fractionCompleted, "Downloading Qwen3 ForcedAligner…")
        }
        try Task.checkCancellation()
        progress(0.95, "Loading Qwen3 ForcedAligner…")
        Memory.peakMemory = 0
        model = try await Qwen3ForcedAlignerModel.fromModelDirectory(directory)
        progress(1, "Qwen3 ForcedAligner ready")
    }

    func align(
        samples: [Float],
        turns: [HighQualityTranslationTurn]
    ) async throws -> HighQualityAlignmentExchange {
        guard let model else { throw jobError("Forced-alignment model is not loaded.") }

        var chunks: [HighQualityAlignmentChunk] = []
        var previousCueEnd = 0.0
        var retryAttemptedGroupCount = 0
        var retryAcceptedGroupCount = 0
        var fallbackMerges: [HighQualityAlignmentFallbackMerge] = []
        let groups = Self.groups(turns)
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            let sourceStart = group.first?.sourceStart ?? 0
            let sourceEnd = group.first?.sourceEnd ?? (Double(samples.count) / Double(Self.sampleRate))
            let startSample = max(0, Int((sourceStart * Double(Self.sampleRate)).rounded()))
            let endSample = min(
                samples.count,
                Int((sourceEnd * Double(Self.sampleRate)).rounded())
            )
            guard startSample < endSample else { throw jobError("ASR timing anchor is empty.") }
            guard endSample - startSample <= Self.maximumWindowSeconds * Self.sampleRate else {
                throw jobError(
                    "ASR timing anchor exceeds the forced aligner's "
                        + "\(Self.maximumWindowSeconds)-second limit."
                )
            }
            let audio = MLXArray(Array(samples[startSample..<endSample]))
            func aligned(
                _ candidateTurns: [HighQualityTranslationTurn]
            ) throws -> (cues: [HighQualityAlignedCue], items: [HighQualityAlignmentItem]) {
                let tokenGroups = candidateTurns.map { Self.alignmentTokens($0.japanese) }
                guard tokenGroups.allSatisfy({ !$0.isEmpty }) else {
                    throw jobError("A Japanese cue has no alignable text.")
                }
                let output = model.generate(
                    audio: audio,
                    text: tokenGroups.flatMap { $0 }.joined(separator: " "),
                    language: "Japanese"
                )
                guard output.items.count == tokenGroups.reduce(0, { $0 + $1.count }) else {
                    throw jobError("Qwen3 ForcedAligner returned incomplete character timing.")
                }
                var cursor = 0
                var cues: [HighQualityAlignedCue] = []
                var rawItems: [HighQualityAlignmentItem] = []
                for (turn, tokens) in zip(candidateTurns, tokenGroups) {
                    let items = output.items[cursor..<(cursor + tokens.count)]
                    cursor += tokens.count
                    let boundedItems = items.map {
                        let interval = Self.boundedInterval(
                            start: sourceStart + $0.startTime,
                            end: sourceStart + $0.endTime,
                            sourceStart: sourceStart,
                            sourceEnd: sourceEnd
                        )
                        return HighQualityAlignmentItem(
                            cueID: turn.id,
                            text: $0.text,
                            start: interval.start,
                            end: interval.end
                        )
                    }
                    guard let first = boundedItems.first, let last = boundedItems.last else {
                        throw jobError(
                            "Qwen3 ForcedAligner returned no timing for cue \(turn.id)."
                        )
                    }
                    rawItems += boundedItems
                    cues.append(.init(
                        id: turn.id,
                        text: turn.japanese,
                        start: first.start,
                        end: last.end
                    ))
                }
                return (cues, rawItems)
            }

            var result = try aligned(group)
            if !Self.hasValidCueTimeline(
                result.cues,
                after: previousCueEnd,
                before: sourceEnd
            ) {
                retryAttemptedGroupCount += 1
                let retried = try group.map { try aligned([$0]) }
                let retryCues = retried.flatMap(\.cues)
                if Self.hasValidCueTimeline(
                    retryCues,
                    after: previousCueEnd,
                    before: sourceEnd
                ) {
                    result = (retryCues, retried.flatMap(\.items))
                    retryAcceptedGroupCount += 1
                } else if let fallback = Self.contentPreservingFallback(
                    cues: result.cues,
                    rawItems: result.items,
                    after: max(previousCueEnd, sourceStart),
                    before: min(
                        sourceEnd,
                        groups.indices.contains(index + 1)
                            ? groups[index + 1].first?.sourceStart ?? sourceEnd
                            : sourceEnd
                    ),
                    chunkIndex: index
                ) {
                    result.cues = fallback.cues
                    fallbackMerges += fallback.merges
                }
            }
            previousCueEnd = result.cues.last?.end ?? previousCueEnd
            chunks.append(.init(
                index: index,
                sourceStart: sourceStart,
                sourceEnd: sourceEnd,
                cues: result.cues,
                rawItems: result.items
            ))
        }
        return .init(
            chunks: chunks,
            modelID: Self.modelID,
            revision: Self.revision,
            peakMemoryBytes: UInt64(max(0, Memory.peakMemory)),
            configuration: [
                "language": "Japanese",
                "sampleRate": String(Self.sampleRate),
                "zeroDurationFallback": "per-cue-realignment-same-asr-window",
                "retryAttemptedGroupCount": String(retryAttemptedGroupCount),
                "retryAcceptedGroupCount": String(retryAcceptedGroupCount),
                "fallbackMergeCount": String(fallbackMerges.count),
                "coarseFallbackCount": String(fallbackMerges.count {
                    $0.timingPolicy == "coarse-fallback-free-window-gap"
                }),
                "coarseTimingPolicy": "single-zero-cue-asr-anchor-20cps",
                "coarseTimingCueIDs": chunks.flatMap(\.cues).compactMap {
                    $0.timingQuality == "coarse" ? $0.id : nil
                }.joined(separator: ","),
            ],
            fallbackMerges: fallbackMerges
        )
    }

    static func contentPreservingFallback(
        cues: [HighQualityAlignedCue],
        rawItems: [HighQualityAlignmentItem] = [],
        after lowerBound: TimeInterval,
        before upperBound: TimeInterval,
        chunkIndex: Int = 0
    ) -> (
        cues: [HighQualityAlignedCue],
        merges: [HighQualityAlignmentFallbackMerge]
    )? {
        let zeroCueIDs = cues.filter { $0.end <= $0.start }.map(\.id)
        guard !zeroCueIDs.isEmpty else { return nil }
        if let cue = cues.first,
           cues.count == 1,
           cue.end == cue.start,
           !rawItems.isEmpty,
           rawItems.allSatisfy({
               $0.cueID == cue.id && $0.start == cue.start && $0.end == $0.start
           }),
           cue.text.count <= maximumCoarseAnchorCharacters,
           lowerBound < upperBound,
           cue.start >= lowerBound,
           cue.start <= upperBound {
            let duration = Double(cue.text.count) / maximumFallbackCharactersPerSecond
            guard duration > 0, duration <= upperBound - lowerBound else { return nil }
            let start = min(max(cue.start - duration, lowerBound), upperBound - duration)
            let end = start + duration
            guard cue.start >= start, cue.start <= end else { return nil }
            return ([HighQualityAlignedCue(
                id: cue.id,
                text: cue.text,
                start: start,
                end: end,
                timingOrigin: "asr-window-anchor",
                timingPolicy: "single-zero-cue-asr-anchor-20cps",
                timingQuality: "coarse"
            )], [])
        }
        var result = cues
        var merges: [HighQualityAlignmentFallbackMerge] = []
        let lastCueID = cues.last?.id

        for cueID in zeroCueIDs {
            guard let sourceIndex = result.firstIndex(where: { $0.id == cueID }) else {
                return nil
            }
            let source = result[sourceIndex]
            guard source.end == source.start else { return nil }
            let previousIndex = result[..<sourceIndex].lastIndex { $0.end > $0.start }
            let followingIndex = result.index(after: sourceIndex) < result.endIndex
                ? result[result.index(after: sourceIndex)...].firstIndex { $0.end > $0.start }
                : nil
            let previousDistance = previousIndex.map {
                abs(source.start - result[$0].end)
            } ?? .infinity
            let followingDistance = followingIndex.map {
                abs(result[$0].start - source.end)
            } ?? .infinity
            guard let targetIndex = previousDistance <= followingDistance
                ? previousIndex : followingIndex else { return nil }
            let direction = targetIndex == previousIndex ? "previous" : "following"
            let target = result[targetIndex]
            let mergedText = direction == "previous"
                ? target.text + source.text : source.text + target.text
            guard mergedText.count <= maximumFallbackCharacters else { return nil }

            var finalEnd = target.end
            var timingPolicy = "merge-adjacent-valid-cue"
            let requiredDuration = Double(mergedText.count)
                / maximumFallbackCharactersPerSecond
            if target.end - target.start < requiredDuration {
                let requiredEnd = target.start + requiredDuration
                guard cueID == lastCueID,
                      direction == "previous",
                      requiredEnd <= upperBound else { return nil }
                finalEnd = requiredEnd
                timingPolicy = "coarse-fallback-free-window-gap"
            }
            let mergedCue = HighQualityAlignedCue(
                id: target.id,
                text: mergedText,
                start: target.start,
                end: finalEnd
            )
            result[targetIndex] = mergedCue
            result.remove(at: sourceIndex)
            merges.append(.init(
                chunkIndex: chunkIndex,
                sourceCueID: source.id,
                targetCueID: target.id,
                direction: direction,
                sourceText: source.text,
                targetOriginalText: target.text,
                mergedText: mergedText,
                sourceOriginalStart: source.start,
                sourceOriginalEnd: source.end,
                targetOriginalStart: target.start,
                targetOriginalEnd: target.end,
                finalStart: target.start,
                finalEnd: finalEnd,
                freeGapEnd: upperBound,
                timingPolicy: timingPolicy
            ))
        }
        guard Self.hasValidCueTimeline(result, after: lowerBound, before: upperBound)
        else { return nil }
        return (result, merges)
    }

    static func hasValidCueTimeline(
        _ cues: [HighQualityAlignedCue],
        after lowerBound: TimeInterval,
        before upperBound: TimeInterval
    ) -> Bool {
        var previousEnd = lowerBound
        return cues.allSatisfy { cue in
            guard cue.start >= previousEnd, cue.end > cue.start, cue.end <= upperBound else {
                return false
            }
            previousEnd = cue.end
            return true
        }
    }

    static func boundedInterval(
        start: TimeInterval,
        end: TimeInterval,
        sourceStart: TimeInterval,
        sourceEnd: TimeInterval
    ) -> (start: TimeInterval, end: TimeInterval) {
        (
            min(max(start, sourceStart), sourceEnd),
            min(max(end, sourceStart), sourceEnd)
        )
    }

    func unload() {
        model = nil
        Memory.clearCache()
    }

    private static func groups(
        _ turns: [HighQualityTranslationTurn]
    ) -> [[HighQualityTranslationTurn]] {
        var result: [[HighQualityTranslationTurn]] = []
        var group: [HighQualityTranslationTurn] = []
        for turn in turns {
            if let first = group.first,
               first.sourceStart != turn.sourceStart || first.sourceEnd != turn.sourceEnd {
                result.append(group)
                group = []
            }
            group.append(turn)
        }
        if !group.isEmpty { result.append(group) }
        return result
    }

    private static func alignmentTokens(_ text: String) -> [String] {
        text.filter { $0.isLetter || $0.isNumber || $0 == "'" }.map(String.init)
    }

    private func jobError(_ message: String) -> HighQualityJobError {
        .init(stage: .alignment, message: message, resultDirectory: nil)
    }
}
