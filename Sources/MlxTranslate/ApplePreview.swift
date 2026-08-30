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
    case prepareFailed(underlying: String)
    case formatUnavailable
    case emptyTranslation
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupported(let language): "Apple Speech ne supporte pas \(language)."
        case .assetsMissing: "Les ressources Speech/Translation ne sont pas installées."
        case .prepareFailed(let detail): "La préparation de la session de traduction a échoué : \(detail)"
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
    /// Échantillon 16 kHz jusqu'où le transcribeur a FINALISÉ des résultats
    /// (`resultsFinalizationTime`) : borne dure du texte définitif — signal
    /// complémentaire de l'endpointing (le texte avant cette borne ne
    /// changera plus).
    var finalizedThroughSample: Int

    init(
        segment: TranscriptionSegment,
        isFinal: Bool,
        finalizedThroughSample: Int = 0
    ) {
        self.segment = segment
        self.isFinal = isFinal
        self.finalizedThroughSample = finalizedThroughSample
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
        contextualStrings: [String] = [],
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
        // Bias lexical : le glossaire (formes JA) est injecté comme « context
        // strings » AVANT la préparation, pour que le transcribeur Apple
        // privilégie ces termes propres (plafonné à 100 par le framework).
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(100))
            try await analyzer.setContext(context)
        }
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
                    let finalizedSeconds = max(0, CMTimeGetSeconds(result.resultsFinalizationTime))
                    await onUpdate(
                        LiveSourceUpdate(
                            segment: TranscriptionSegment(
                                start: start,
                                end: start + duration,
                                text: text
                            ),
                            isFinal: result.isFinal,
                            finalizedThroughSample: Int((finalizedSeconds * 16_000).rounded())
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
        // Préchauffage : la création du transcriber charge les assets Speech
        // (état système, persistant) ; l'objet lui-même est jeté, start()
        // en crée un autre.
        _ = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        return true
    }
}

// Traduction Translation (JA→EN, faible latence), sur appareil.
@available(macOS 26.4, *)
actor AppleTranslationService {
    private var session: TranslationSession?

    func configure(sourceLocale: String) async throws {
        // Idempotence : une session déjà prête (préchargement au lancement
        // de l'app, ou deuxième appel du moteur) → rien à faire.
        guard session == nil else { return }
        let source = Locale.Language(identifier: sourceLocale)
        let candidate = TranslationSession(
            installedSource: source,
            target: Locale.Language(identifier: "en"),
            preferredStrategy: .lowLatency
        )
        // 26.4+ : prépare la session avant de vérifier isReady — la session
        // fraîchement créée n'est pas « ready » tant que prepareTranslation()
        // n'a pas chargé ses assets (et télécharge le paquet si
        // canRequestDownloads est vrai).
        // prepareTranslation() est la porte fiable (isReady est optimiste).
        // Délai 30 s : instantané si les assets sont installés, temps de
        // téléchargement court sinon.
        //
        // notInstalled est une course avec translationd : après un démarrage ou
        // un re-sync d'assets du daemon, prepareTranslation() peut jeter
        // .notInstalled pendant que la synchronisation est en cours → 3
        // essais, 3 s d'attente entre eux.
        var prepareError: Error?
        for attempt in 1...3 {
            do {
                try await withAsyncDeadline(
                    .seconds(30),
                    operationName: "préparation Apple Translation"
                ) {
                    try await candidate.prepareTranslation()
                }
                prepareError = nil
                break
            } catch let e as TranslationError where TranslationError.notInstalled ~= e {
                prepareError = e
                if attempt < 3 {
                    LiveDebug.log(
                        "[APPLE-TRANSLATION] notInstalled (essai \(attempt)/3) — translationd en cours de synchronisation, nouvel essai dans 3 s"
                    )
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            } catch {
                prepareError = error
                break
            }
        }
        if let prepareError {
            // On ne gomme pas l'erreur sous-jacente : elle dit si c'est les
            // assets, le réseau, ou un état de framework inattendu.
            let detail = "\(prepareError) — \(prepareError.localizedDescription)"
            LiveDebug.log("[APPLE-TRANSLATION] prepareTranslation() échec : \(detail)")
            throw ApplePreviewError.prepareFailed(underlying: detail)
        }
        // isReady peut HANGER (canal d'observation du framework bloqué) →
        // délai 10 s. Si prepareTranslation() a réussi, on accepte la session.
        do {
            let ready = try await withAsyncDeadline(
                .seconds(10),
                operationName: "isReady Apple Translation"
            ) {
                await candidate.isReady
            }
            if !ready {
                LiveDebug.log(
                    "[APPLE-TRANSLATION] isReady=false après prepareTranslation() réussi — session acceptée"
                )
            }
        } catch {
            LiveDebug.log(
                "[APPLE-TRANSLATION] isReady en échec/délai (10 s) — session acceptée (prepareTranslation() OK)"
            )
        }
        session = candidate
        // Préchauffage : le premier translate() froid dépasse la deadline de
        // 2 s (démarrage du moteur dans translationd). Un petit appel ici
        // rend les traductions chaudes ≈ 250 ms. Non bloquant : l'échec
        // laisse la session utilisable, la première ligne sera juste lente.
        do {
            _ = try await withAsyncDeadline(
                .seconds(15),
                operationName: "préchauffage Apple Translation"
            ) {
                try await candidate.translate("a").targetText
            }
            LiveDebug.log("[APPLE-TRANSLATION] préchauffage OK — traductions chaudes ≈ 250 ms")
        } catch {
            LiveDebug.log(
                "[APPLE-TRANSLATION] préchauffage : \(error.localizedDescription)"
            )
        }
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
