import Foundation
import os

// Journal de debug du live (activé par `MLXTRANSLATE_DEBUG=1`) : horodaté (ISO8601 +
// t+ depuis le démarrage), écrit sur stderr et (optionnel) en append dans
// `MLXTRANSLATE_DEBUG_LOG` (sinon `~/.mlxtranslate/live-debug.log`). Sert à tracer
// l'enchaînement endpointing → ASR (Voxtral) → preview (Apple) → traduction EN
// (preview/final, MLX) → superposition, avec les timings.
public enum LiveDebug {
    public static let enabled = ProcessInfo.processInfo.environment["MLXTRANSLATE_DEBUG"] != nil
    private static let start = Date()
    private static let lock = NSLock()
    private static let wallClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static var logURL: URL {
        if let custom = ProcessInfo.processInfo.environment["MLXTRANSLATE_DEBUG_LOG"] {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mlxtranslate")
            .appendingPathComponent("live-debug.log")
    }

    /// Horodatage (heure murale + t+ depuis le début du live) + message, sur stderr
    /// et en append dans le fichier de debug (si activé).
    public static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let now = Date()
        let t = now.timeIntervalSince(start)
        let line = "[live-debug \(wallClock.string(from: now)) t+\(String(format: "%.2f", t)) s] \(message())\n"
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        let url = logURL
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            try? fh.close()
        } else {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data(line.utf8).write(to: url)
        }
    }
}

// ---------------------------------------------------------------------------
// Sortie live (lignes preview sur stderr, engagement final sur stdout + SRT)
// ---------------------------------------------------------------------------

actor LiveOutput {
    private let fileURL: URL
    private var cues: [Cue] = []
    private var cueIndex = 0
    private var sessionStart = Date()
    private var lastPreviewShow = Date.distantPast
    private var latestPreview = ""
    /// Délai minimal entre deux lignes preview (lissé anti-scintillement) :
    /// un seul affichage par fenêtre, le texte le plus récent gagne.
    private static let previewThrottle: TimeInterval = 0.2

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    // Ligne preview (provisoire) : surcouche la ligne de stderr. Throttlée
    // (≤ 1 affichage / 200 ms, le texte le plus récent gagne) pour éviter le
    // scintillement quand les chunks (streaming MLX, preview Apple) arrivent
    // plus vite que 200 ms.
    func showPreview(_ text: String) {
        guard !text.isEmpty else { return }
        latestPreview = text
        let now = Date()
        guard now.timeIntervalSince(lastPreviewShow) >= Self.previewThrottle else { return }
        lastPreviewShow = now
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + latestPreview).utf8))
    }

    // Efface la ligne preview + réinitialise le throttle pour que le prochain
    // énoncé s'affiche immédiatement (sans attendre la fenêtre de 200 ms).
    func clearPreview() {
        lastPreviewShow = Date.distantPast
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
    /// Début (échantillons 16 kHz) de l'énoncé en cours — mis à jour par le
    /// moteur live après chaque commit ; sert d'horodatage aux previews.
    var committedSampleOffset = 0
    /// Callback de la preview basse latence (JA→EN roulant) : alimente la
    /// superposition GUI (l'outil CLI passe nil → pas de superposition).
    var previewLine: (@Sendable (String, Bool) -> Void)?

    init(
        capture: AppCapture,
        speech: AppleSpeechService,
        translation: AppleTranslationService,
        output: LiveOutput,
        previewLine: (@Sendable (String, Bool) -> Void)? = nil
    ) {
        self.capture = capture
        self.speech = speech
        self.translation = translation
        self.output = output
        self.previewLine = previewLine
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
    // L'horodatage affiché est le DÉBUT de l'énoncé en cours (aligné sur le
    // final/SRT), pas la position courante : les previews et les cues SRT
    // utilisent alors la même base temporelle.
    private func renderPreview() async {
        let ja = jaLock.withLock { rollingJA }
        guard ja != lastTranslatedJA,
              Date().timeIntervalSince(lastTranslateTime) >= 0.7,
              !ja.isEmpty else { return }
        do {
            let started = Date()
            let en = try await translation.translate(ja)
            let now = Date()
            jaLock.withLock { lastTranslatedJA = ja }
            lastTranslateTime = now
            // Début de l'énoncé en cours ≈ dernier commit (0 sinon).
            let utteranceStart = Double(committedSampleOffset) / LiveEndpointing.sampleRate
            let timecode = LiveFormat.timecode(utteranceStart)
            LiveDebug.log(
                "PREVIEW(Apple) JA=\"\(ja)\" → EN=\"\(en)\" "
                + "(traduction \(String(format: "%.0f", now.timeIntervalSince(started) * 1000)) ms) "
                + "→ onLine preview"
            )
            // Superposition : preview basse latence (remplacée par le final MLX à la fin
            // de l'énoncé). L'outil CLI (pas de superposition) ne reçoit pas ce callback.
            previewLine?(en, false)
            await output.showPreview("\(timecode) ~ \(en)")
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
    // Callback de superposition : le texte EN courant (preview en streaming, puis final
    // engagé) + un flag « estFinal ». Sert à alimenter une barre de sous-titres GUI
    // (l'outil CLI renvoie nil → pas de superposition).
    var onLine: (@Sendable (String, Bool) -> Void)?
    // Callback de l'INSTANTANÉ (preview Apple basse latence, JA roulant → EN) — distinct
    // du final MLX (onLine). Alimente la ligne « instantané » de la superposition, qui
    // reste affichée en continu pendant la parole (le final s'empile au-dessus).
    // nil pour l'outil CLI (pas de superposition).
    var onApplePreview: (@Sendable (String, Bool) -> Void)?
    // Signal d'arrêt externe (GUI « Arrêter ») : la boucle s'arrête quand il renvoie true
    // (en plus de SIGINT / --max / échec du flux SCK).
    var stopRequested: @Sendable () -> Bool = { false }
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
            let started = Date()
            _ = try await helper.startSession()
            if !audio.isEmpty {
                try await helper.append(samples: audio, range: 0..<audio.count)
            }
            text = try await helper.stopAndFlush()
            LiveDebug.log(
                "ASR(Voxtral) JA=\"\(text)\" "
                + "(\(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms, "
                + "\(String(format: "%.1f", Double(audio.count) / 16000.0)) s d'audio)"
            )
        } catch {
            Pipeline.log("énoncé Voxtral en échec : \(error.localizedDescription)")
            LiveDebug.log("ASR(Voxtral) échec : \(error.localizedDescription)")
            await helper.cancel()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(macOS 26.4, *)
    func run() async throws {
        Pipeline.log("mode live : capture de « \(configuration.app) »")
        // Garanti le metallib MLX (kernels Metal) à côté de l'exécutable, même quand
        // on appelle LiveEngine directement (GUI) plutôt que via Live.run (CLI).
        try Pipeline.ensureMetalLibrary()
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
                capture: capture, speech: speech, translation: translation, output: output,
                // L'instantané (preview Apple) va sur son callback dédié (ligne « instantané »
                // de la superposition) ; repli sur onLine si non fourni (GUI ancienne version).
                previewLine: configuration.onApplePreview ?? configuration.onLine
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
            if stopLock.withLock({ $0 }) || configuration.stopRequested() { stopRequested = true; break }

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
            LiveDebug.log(
                "ENDPOINTING énoncé [\(String(format: "%.1f", startSeconds))–\(String(format: "%.1f", endSeconds)) s] "
                + "(durée \(String(format: "%.1f", endSeconds - startSeconds)) s) → ASR + traduction"
            )

            let jaText = await transcribeUtterance(helper: sidecar, audio: utteranceAudio)

            var enText: String?
            if !configuration.sansTraduction {
                do {
                    let translateStarted = Date()
                    let chunkCounter = OSAllocatedUnfairLock(initialState: 0)
                    enText = try await translator.translateLive(
                        japanese: jaText,
                        glossary: glossary,
                        sourceStart: startSeconds,
                        sourceEnd: endSeconds,
                        onChunk: { chunk in
                            if !chunk.isEmpty {
                                let n = chunkCounter.withLock { $0 += 1; return $0 }
                                LiveDebug.log("MLX chunk #\(n) (preview cumulée) = \"\(chunk)\"")
                                configuration.onLine?(chunk, false)
                                Task {
                                    await output.showPreview("\(LiveFormat.timecode(startSeconds)) ~ \(chunk)")
                                }
                            }
                        }
                    )
                    if enText?.isEmpty == true { enText = nil }
                    let chunkTotal = chunkCounter.withLock { $0 }
                    LiveDebug.log(
                        "TRAD(MLX) FINAL EN=\"\(enText ?? "")\" "
                        + "(\(String(format: "%.0f", Date().timeIntervalSince(translateStarted) * 1000)) ms, \(chunkTotal) chunks)"
                    )
                } catch {
                    Pipeline.log("traduction EN en échec : \(error.localizedDescription)")
                    LiveDebug.log("TRAD(MLX) échec : \(error.localizedDescription)")
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
            // Superposition : engagement du final EN (ou JA si sans-traduction).
            let finalEN = enText ?? (configuration.sansTraduction ? jaText : "")
            if !finalEN.isEmpty {
                LiveDebug.log("FINAL onLine isFinal=true EN=\"\(finalEN)\"")
                configuration.onLine?(finalEN, true)
            }

            lastCommit = cut
            previewTask?.committedSampleOffset = lastCommit
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
            let finalEN = enText ?? (configuration.sansTraduction ? jaText : "")
            if !finalEN.isEmpty { configuration.onLine?(finalEN, true) }
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
