import Foundation
import os

// Moteur du mode temps réel (live) : audio d'une application (JA) → sous-titres EN.
//
// Trois composants parallèles :
//   1. Source JA finale   = Voxtral 4B (sidecar, par énoncé) sur l'audio tamponné.
//   2. Preview (bas, synchro) = Speech Apple (JA progressif) + Translation EN.
//   3. Traduction EN finale = LocalMLXTranslator (par énoncé, streaming) qui
//      remplace la preview à la fin de l'énoncé et s'engage dans le SRT live.
//
// Endpointing : pause silencieuse ≥ 300 ms (RMS) ou forçage à 12 s.

// ---------------------------------------------------------------------------
// Sortie live (lignes preview sur stderr, engagement final sur stdout + SRT)
// ---------------------------------------------------------------------------

actor LiveOutput {
    private let fileURL: URL
    private var cues: [Cue] = []
    private var cueIndex = 0
    private var sessionStart = Date()

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    // Ligne preview (provisoire) : surcouche la ligne de stderr.
    func showPreview(_ text: String) {
        guard !text.isEmpty else { return }
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + text).utf8))
    }

    // Efface la ligne preview.
    func clearPreview() {
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }

    // Engagement d'un énoncé final : l'EN (ou JA si --sans-traduction).
    @discardableResult
    func commit(start: Double, end: Double, japanese: String, english: String?, show: Bool) -> Int {
        cueIndex += 1
        let text: String
        if let english, !english.isEmpty {
            text = english
        } else {
            text = japanese.isEmpty ? "" : "(JA) \(japanese)"
        }
        let cue = Cue(index: cueIndex, start: start, end: end, text: text)
        cues.append(cue)
        flush()
        if show {
            print(LiveFormat.finalLine(LiveCue(
                index: cueIndex,
                start: start,
                end: end,
                japanese: japanese,
                previewEnglish: nil,
                finalEnglish: english
            )))
        }
        return cueIndex
    }

    func flush() {
        try? SRT.write(cues, to: fileURL)
    }

    var committedCount: Int { cues.count }
}

// ---------------------------------------------------------------------------
// Preview temps réel (Speech Apple JA + Translation EN, sur appareil)
// ---------------------------------------------------------------------------

@available(macOS 26.4, *)
final class LivePreviewTask: @unchecked Sendable {
    private let capture: AppCapture
    private let speech: AppleSpeechService
    private let translation: AppleTranslationService
    private let output: LiveOutput
    private var fedUpTo = 0
    private var lastTranslatedJA = ""
    private var lastTranslateTime = Date.distantPast
    private var task: Task<Void, Never>?
    private let stopLock = OSAllocatedUnfairLock(initialState: false)
    private let jaLock = NSLock()
    private var rollingJA = ""

    init(capture: AppCapture, speech: AppleSpeechService, translation: AppleTranslationService, output: LiveOutput) {
        self.capture = capture
        self.speech = speech
        self.translation = translation
        self.output = output
    }

    @MainActor
    func start() async throws {
        try await speech.prepare(localeIdentifier: "ja")
        try await speech.start(localeIdentifier: "ja") { [weak self] update in
            self?.handleUpdate(update)
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.stopLock.withLock({ $0 }) {
                await self.feedAudio()
                await self.renderPreview()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    // Aliments l'audio tamponné au Speech (tranches de 1600 échantillons, 100 ms).
    private func feedAudio() async {
        guard fedUpTo < capture.sampleCount() else { return }
        let chunk = capture.samples(from: fedUpTo, upTo: min(fedUpTo + 1_600, capture.sampleCount()))
        guard !chunk.isEmpty else { return }
        do {
            try await speech.send(samples: chunk, startSample: fedUpTo)
            fedUpTo += chunk.count
        } catch { /* best-effort */ }
    }

    // Traduction throttlée (≥ 0,7 s et texte changé) du texte roulant → EN bas.
    private func renderPreview() async {
        let ja = jaLock.withLock { rollingJA }
        guard ja != lastTranslatedJA,
              Date().timeIntervalSince(lastTranslateTime) >= 0.7,
              !ja.isEmpty else { return }
        do {
            let en = try await translation.translate(ja)
            let now = Date()
            jaLock.withLock { lastTranslatedJA = ja }
            lastTranslateTime = now
            let clock = LiveFormat.clock(Double(capture.sampleCount()) / LiveEndpointing.sampleRate)
            await output.showPreview("\(clock) ~ \(en)")
        } catch { /* best-effort */ }
    }

    private func handleUpdate(_ update: LiveSourceUpdate) {
        let text = update.segment.text
        jaLock.lock()
        if !text.isEmpty { rollingJA = text }
        jaLock.unlock()
    }

    func finish() async {
        stopLock.withLock { $0 = true }
        task?.cancel()
        await task?.value
        task = nil
        await speech.cancel()
    }
}

// ---------------------------------------------------------------------------
// Moteur live
// ---------------------------------------------------------------------------

struct LiveEngineConfiguration: Sendable {
    var app: String
    var preview: Bool = true
    var model: LocalMLXTranslator.Candidate = .productDefault
    var glossaryURL: URL?
    var delay: VoxtralTranscriptionDelay = .milliseconds960
    var sansTraduction: Bool = false
    var outputURL: URL
    var maxSeconds: Double?
    var show: Bool = true
}

enum LiveError: LocalizedError {
    case appNotFound(String)
    case sidecar(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let detail): "application introuvable : \(detail) (utilisez `live --list`)"
        case .sidecar(let detail): "Voxtral sidecar : \(detail)"
        }
    }
}

// ---------------------------------------------------------------------------
// Point d'entrée du mode live (CLI)
// ---------------------------------------------------------------------------

enum Live {
    static func listApps() async throws {
        let apps = try await AppCapture.listApps()
        if apps.isEmpty {
            print("Aucune application capturable (vérifiez les permissions de capture d'écran).")
            return
        }
        print("Applications capturables :")
        for app in apps {
            print("  \(app.id)   (\(app.name))")
        }
    }

    @available(macOS 26.4, *)
    static func run(_ command: Command) async throws {
        guard let app = command.app else {
            throw LiveError.appNotFound("(vide) — utilisez `--app`")
        }
        try Pipeline.ensureMetalLibrary()
        let outputURL = command.liveOutput ?? Pipeline.homeURL.appendingPathComponent(
            "live-\(Int(Date().timeIntervalSince1970)).srt"
        )
        let config = LiveEngineConfiguration(
            app: app,
            preview: command.livePreview && !command.sansTraduction,
            model: command.model,
            glossaryURL: command.glossary ?? Pipeline.defaultGlossaryURL,
            delay: command.liveDelay,
            sansTraduction: command.sansTraduction,
            outputURL: outputURL,
            maxSeconds: command.maxSeconds
        )
        try await LiveEngine(configuration: config).run()
    }
}

struct LiveEngine: Sendable {
    let configuration: LiveEngineConfiguration

    // Transcription d'un énoncé JA (Voxtral 4B, session dédiée).
    private func transcribeUtterance(helper: VoxtralHelperRuntime, audio: [Float]) async -> String {
        var text = ""
        do {
            _ = try await helper.startSession()
            if !audio.isEmpty {
                try await helper.append(samples: audio, range: 0..<audio.count)
            }
            text = try await helper.stopAndFlush()
        } catch {
            Pipeline.log("énoncé Voxtral en échec : \(error.localizedDescription)")
            await helper.cancel()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(macOS 26.4, *)
    func run() async throws {
        Pipeline.log("mode live : capture de « \(configuration.app) »")
        let apps = try await AppCapture.listApps()
        guard let match = apps.first(where: {
            $0.id.caseInsensitiveCompare(configuration.app) == .orderedSame
                || $0.name.caseInsensitiveCompare(configuration.app) == .orderedSame
        }) else {
            throw LiveError.appNotFound(configuration.app)
        }

        // Lock d'arrêt partagé (SIGINT, --max, échec du flux SCK) — créé AVANT la
        // capture pour que le callback d'échec couvre aussi la fenêtre de setup.
        let stopLock = OSAllocatedUnfairLock(initialState: false)

        let capture = AppCapture()
        // Si le flux SCK échoue en cours (app fermée, TCC révoquée, écran déconnecté),
        // on arrête la boucle pour finaliser ce qui reste au lieu de poller dans le vide.
        capture.onStreamFailure = { _ in
            stopLock.withLock { $0 = true }
        }
        try await capture.start(app: match.running)
        Pipeline.log("capture démarrée : \(match.name)")

        let output = LiveOutput(fileURL: configuration.outputURL)

        // Timer d'arrêt (--max), compté depuis le début de la capture.
        var maxTask: Task<Void, Never>?
        if let maxSeconds = configuration.maxSeconds {
            maxTask = Task {
                try? await Task.sleep(for: .seconds(maxSeconds))
                stopLock.withLock { $0 = true }
            }
        }

        var previewTask: LivePreviewTask?
        let speech = AppleSpeechService()
        let translation = AppleTranslationService()
        if configuration.preview {
            do {
                try await translation.configure(sourceLocale: "ja")
            } catch {
                Pipeline.log("preview : \(error.localizedDescription)")
            }
            previewTask = LivePreviewTask(
                capture: capture, speech: speech, translation: translation, output: output
            )
            if let task = previewTask {
                do {
                    try await task.start()
                    Pipeline.log("preview Apple démarrée (JA progressif → EN bas)")
                } catch {
                    Pipeline.log("preview indisponible : \(error.localizedDescription)")
                }
            }
        }

        let sidecar = VoxtralHelperRuntime(rootDirectory: ASR.sidecarRoot)
        let sidecarConfig = VoxtralContinuousConfiguration(model: .q4, delay: configuration.delay)
        do {
            try await sidecar.prepare(configuration: sidecarConfig)
        } catch {
            await capture.stop()
            await previewTask?.finish()
            throw LiveError.sidecar(error.localizedDescription)
        }

        let translator = LocalMLXTranslator(candidate: configuration.model)
        try await translator.prepare { _, _ in }
        var glossary: [HighQualityGlossaryPromptTerm] = []
        if let glossaryURL = configuration.glossaryURL {
            glossary = (try? Glossaire.terms(from: glossaryURL)) ?? []
        }
        if !glossary.isEmpty { Pipeline.log("glossaire : \(glossary.count) terme(s)") }

        // --- Boucle d'endpointing + finalisation ---------------------------
        var lastCommit = 0
        var stopRequested = false

        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            stopLock.withLock { $0 = true }
        }
        source.resume()

        while !stopRequested {
            try? await Task.sleep(for: .seconds(LiveEndpointing.pollSeconds))
            if stopLock.withLock({ $0 }) { stopRequested = true; break }

            let available = capture.sampleCount()
            guard available >= LiveEndpointing.minSilenceFrames * LiveEndpointing.frameSamples else { continue }

            // Trouve la pause (début de silence ≥ minSilenceFrames) après lastCommit.
            var cut = capture.lastSilenceCut(
                from: lastCommit + LiveEndpointing.minSilenceFrames * LiveEndpointing.frameSamples,
                upTo: available
            )
            // Forçage : si 12 s s'accumulent sans pause, on coupe à 12 s ; sinon on
            // coupe à la pause (silence) si elle tombe avant 12 s.
            let maxEnd = lastCommit + Int(LiveEndpointing.forceCutSeconds * LiveEndpointing.sampleRate)
            if let s = cut {
                cut = min(s, maxEnd)
            } else if available >= maxEnd {
                cut = maxEnd
            }
            guard let cut = cut, cut - lastCommit >= Int(0.5 * LiveEndpointing.sampleRate) else { continue }

            let utteranceAudio = capture.samples(from: lastCommit, upTo: cut)
            let startSeconds = Double(lastCommit) / LiveEndpointing.sampleRate
            let endSeconds = Double(cut) / LiveEndpointing.sampleRate

            let jaText = await transcribeUtterance(helper: sidecar, audio: utteranceAudio)

            var enText: String?
            if !configuration.sansTraduction {
                do {
                    enText = try await translator.translateLive(
                        japanese: jaText,
                        glossary: glossary,
                        sourceStart: startSeconds,
                        sourceEnd: endSeconds,
                        onChunk: { chunk in
                            if !chunk.isEmpty {
                                Task {
                                    await output.showPreview("\(LiveFormat.timecode(startSeconds)) ~ \(chunk)")
                                }
                            }
                        }
                    )
                    if enText?.isEmpty == true { enText = nil }
                } catch {
                    Pipeline.log("traduction EN en échec : \(error.localizedDescription)")
                }
            }

            await output.clearPreview()
            await output.commit(
                start: startSeconds,
                end: endSeconds,
                japanese: jaText,
                english: enText,
                show: configuration.show
            )

            lastCommit = cut
            if lastCommit >= Int(120 * LiveEndpointing.sampleRate) {
                capture.trim(upTo: lastCommit)
            }
        }

        // --- Finalisation de l'audio restant --------------------------------
        let remaining = capture.sampleCount()
        if remaining - lastCommit >= Int(0.5 * LiveEndpointing.sampleRate) {
            let utteranceAudio = capture.samples(from: lastCommit, upTo: remaining)
            let startSeconds = Double(lastCommit) / LiveEndpointing.sampleRate
            let endSeconds = Double(remaining) / LiveEndpointing.sampleRate
            let jaText = await transcribeUtterance(helper: sidecar, audio: utteranceAudio)
            var enText: String?
            if !configuration.sansTraduction {
                enText = try? await translator.translateLive(
                    japanese: jaText,
                    glossary: glossary,
                    sourceStart: startSeconds,
                    sourceEnd: endSeconds
                )
            }
            await output.commit(
                start: startSeconds,
                end: endSeconds,
                japanese: jaText,
                english: enText,
                show: configuration.show
            )
        }

        // --- Arrêt propre ----------------------------------------------------
        source.cancel()
        maxTask?.cancel()
        await previewTask?.finish()
        await capture.stop()
        await sidecar.shutdown()
        await output.flush()
        let count = await output.committedCount
        Pipeline.log("live terminé : \(count) énoncé(s) → \(configuration.outputURL.path)")
    }
}
