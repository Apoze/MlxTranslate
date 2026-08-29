import AVFoundation
import CoreMedia
import Foundation
import os
@preconcurrency import Speech
@preconcurrency import Translation

// Aperçu temps réel (sur appareil, faible latence) :
//  - Speech (JA, faible latence) : audio 16 kHz → texte JA progressif.
//  - Translation (JA→EN, faible latence) : texte → EN rapide.
// Port dissocié de whisperASR/Sources/AppleLiveServices.swift (sans les vues
// SwiftUI, sans le download d'actifs, réduit au chemin japonais→anglais).

enum ApplePreviewError: LocalizedError {
    case unsupported(String)
    case assetsMissing
    case formatUnavailable
    case emptyTranslation
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported(let language): "Apple Speech ne supporte pas \(language)."
        case .assetsMissing: "Les ressources Speech/Translation ne sont pas installées."
        case .formatUnavailable: "Le format audio Speech est introuvable."
        case .emptyTranslation: "Traduction Apple vide."
        case .timedOut: "La traduction Apple n'a pas terminé avant l'échéance."
        }
    }
}

// Segment de transcription (texte source + bornes).
struct TranscriptionSegment: Sendable {
    var start: Double
    var end: Double?
    var text: String
}

// Mise à jour de la source en direct (texte progressif).
struct LiveSourceUpdate: Sendable {
    var segment: TranscriptionSegment
    var isFinal: Bool

    init(segment: TranscriptionSegment, isFinal: Bool) {
        self.segment = segment
        self.isFinal = isFinal
    }
}

// Aliments de l'analyseur Speech : le type du framework `Speech.AnalyzerInput`.

// Transcription Speech (JA, faible latence) : audio 16 kHz → texte progressif.
@available(macOS 26.0, *)
actor AppleSpeechService {
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<Speech.AnalyzerInput>.Continuation?
    private var analysisTask: Task<CMTime?, Error>?
    private var resultTask: Task<Void, Error>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var nextAnalyzerInputTime: CMTime?

    func prepare(localeIdentifier: String) async throws {
        _ = await Self.prepareTranscriber(localeIdentifier: localeIdentifier)
    }

    func start(
        localeIdentifier: String,
        onUpdate: @escaping @MainActor @Sendable (LiveSourceUpdate) -> Void
    ) async throws {
        await cancel()
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            throw ApplePreviewError.unsupported(localeIdentifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: Self.inputFormat
        ) else {
            throw ApplePreviewError.formatUnavailable
        }
        try await analyzer.prepareToAnalyze(in: format)

        var continuation: AsyncStream<Speech.AnalyzerInput>.Continuation?
        let stream = AsyncStream<Speech.AnalyzerInput>(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        guard let continuation else { throw ApplePreviewError.formatUnavailable }

        self.analyzer = analyzer
        self.analyzerFormat = format
        self.converter = Self.formatsMatch(Self.inputFormat, format)
            ? nil : AVAudioConverter(from: Self.inputFormat, to: format)
        self.inputContinuation = continuation
        self.resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = max(0, CMTimeGetSeconds(result.range.start))
                    let duration = max(0, CMTimeGetSeconds(result.range.duration))
                    await onUpdate(
                        LiveSourceUpdate(
                            segment: TranscriptionSegment(
                                start: start,
                                end: start + duration,
                                text: text
                            ),
                            isFinal: result.isFinal
                        )
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                throw error
            }
        }
        self.analysisTask = Task { try await analyzer.analyzeSequence(stream) }
    }

    func send(samples: [Float], startSample: Int) throws {
        guard !samples.isEmpty, let format = analyzerFormat else { return }
        let input = Self.makeBuffer(samples: samples, format: Self.inputFormat)
        let output: AVAudioPCMBuffer
        if let converter {
            let ratio = format.sampleRate / Self.inputFormat.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                throw ApplePreviewError.formatUnavailable
            }
            var supplied = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                guard !supplied else {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            output = converted
        } else {
            output = input
        }
        let requestedStart = CMTime(value: Int64(startSample), timescale: 16_000)
        let bufferStart = nextAnalyzerInputTime ?? requestedStart
        inputContinuation?.yield(Speech.AnalyzerInput(buffer: output, bufferStartTime: bufferStart))
        nextAnalyzerInputTime = CMTimeAdd(
            bufferStart,
            CMTime(
                value: Int64(output.frameLength),
                timescale: CMTimeScale(format.sampleRate.rounded())
            )
        )
    }

    func finish() async {
        inputContinuation?.finish()
        let lastTime = try? await analysisTask?.value
        if let analyzer, let lastTime {
            try? await analyzer.finalizeAndFinish(through: lastTime)
        } else if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        _ = try? await resultTask?.value
        clear()
    }

    func cancel() async {
        inputContinuation?.finish()
        analysisTask?.cancel()
        resultTask?.cancel()
        if let analyzer { await analyzer.cancelAndFinishNow() }
        clear()
    }

    private func clear() {
        analyzer = nil
        inputContinuation = nil
        analysisTask = nil
        resultTask = nil
        analyzerFormat = nil
        converter = nil
        nextAnalyzerInputTime = nil
    }

    private static func makeBuffer(samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            buffer.floatChannelData![0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func prepareTranscriber(localeIdentifier: String) async -> Bool {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else { return false }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        return true
    }
}

// Traduction Translation (JA→EN, faible latence), sur appareil.
@available(macOS 26.4, *)
actor AppleTranslationService {
    private var session: TranslationSession?

    func configure(sourceLocale: String) async throws {
        let source = Locale.Language(identifier: sourceLocale)
        let candidate = TranslationSession(
            installedSource: source,
            target: Locale.Language(identifier: "en"),
            preferredStrategy: .lowLatency
        )
        guard await candidate.isReady else {
            throw ApplePreviewError.assetsMissing
        }
        session = candidate
    }

    func translate(_ text: String) async throws -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw ApplePreviewError.emptyTranslation }
        guard let session else { throw ApplePreviewError.assetsMissing }
        let translated = try await withAsyncDeadline(
            .seconds(2),
            operationName: "Apple low-latency translation",
            operation: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await session.translate(source).targetText
            }
        )
        let normalized = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ApplePreviewError.emptyTranslation }
        return normalized
    }
}
