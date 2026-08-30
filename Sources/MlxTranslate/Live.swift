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
    /// Garde monotone : la ligne ne rétrécit jamais entre deux passes
    /// (remise à zéro par `clearPreview`, avant chaque commit).
    private var previewMonotone = PreviewMonotone()
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
    // (≤ 1 affichage / 200 ms) + garde monotone (le plus complet gagne) pour
    // éviter le scintillement quand les chunks (streaming MLX, preview Apple)
    // arrivent plus vite que 200 ms.
    func showPreview(_ text: String) {
        guard !text.isEmpty else { return }
        latestPreview = previewMonotone.accept(text)
        let now = Date()
        guard now.timeIntervalSince(lastPreviewShow) >= Self.previewThrottle else { return }
        lastPreviewShow = now
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + latestPreview).utf8))
    }

    // Efface la ligne preview + réinitialise la garde monotone et le throttle
    // pour que le prochain énoncé s'affiche immédiatement (sans attendre la
    // fenêtre de 200 ms, sans hériter du texte de la clause précédente).
    func clearPreview() {
        previewMonotone.reset()
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
    /// Borne (échantillons 16 kHz, index absolu) jusqu'où le transcribeur Apple
    /// a FINALISÉ des résultats (`resultsFinalizationTime`) : le texte avant
    /// cette borne ne changera plus. Signal d'endpointing complémentaire
    /// (stabilité dure) — lu depuis le moteur via `finalizedThroughSample`.
    private var finalizedThroughSampleLocked = 0
    /// Formes JA du glossaire, injectées comme « context strings » du
    /// transcribeur Apple (bias lexical des termes propres).
    private let contextualStrings: [String]
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
        contextualStrings: [String] = [],
        previewLine: (@Sendable (String, Bool) -> Void)? = nil
    ) {
        self.capture = capture
        self.speech = speech
        self.translation = translation
        self.output = output
        self.contextualStrings = contextualStrings
        self.previewLine = previewLine
    }

    @MainActor
    func start() async throws {
        try await speech.prepare(localeIdentifier: "ja")
        try await speech.start(localeIdentifier: "ja", contextualStrings: contextualStrings) { [weak self] update in
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
        if update.finalizedThroughSample > finalizedThroughSampleLocked {
            finalizedThroughSampleLocked = update.finalizedThroughSample
        }
        jaLock.unlock()
    }

    /// Borne de finalisation Apple (échantillons 16 kHz, index absolu) — le
    /// texte avant cette borne est définitif (signal d'endpointing).
    var finalizedThroughSample: Int {
        jaLock.withLock { finalizedThroughSampleLocked }
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
    /// Niveau final ASR : `qwenJA` (défaut produit, endpointing sémantique
    /// Qwen3-ASR + aligneur) ou `voxtralQ4` (legacy).
    var liveASR: LiveFinalASR = LiveFinalASR.productDefault
    /// Pseudo-live Qwen : snapshots cumulatifs de la clause en cours (cadence
    /// 2 s) pilotés par `QwenPseudoLiveCoordinator` — ligne roulante de la
    /// sortie du modèle final + aliment de l'endpointing sémantique. ON par
    /// défaut en mode qwenja ; `MLXTRANSLATE_PSEUDO_LIVE=0` le désactive.
    var pseudoLive: Bool = true
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
    /// Préparation du niveau final Qwen3-ASR (ASR finale + aligneur) en échec.
    case finalASR(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let detail): "application introuvable : \(detail) (utilisez `live --list`)"
        case .sidecar(let detail): "Voxtral sidecar : \(detail)"
        case .finalASR(let detail): "niveau final Qwen3-ASR : \(detail)"
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
            maxSeconds: command.maxSeconds,
            liveASR: command.liveASR,
            pseudoLive: ProcessInfo.processInfo.environment["MLXTRANSLATE_PSEUDO_LIVE"] != "0"
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
        // Glossaire : chargé AVANT le preview pour injecter les formes JA comme
        // « context strings » du transcribeur Apple (bias lexical des termes
        // propres) ; il alimente aussi la traduction (prompt + contexte roulant).
        var glossary: [HighQualityGlossaryPromptTerm] = []
        if let glossaryURL = configuration.glossaryURL {
            glossary = (try? Glossaire.terms(from: glossaryURL)) ?? []
        }
        if !glossary.isEmpty { Pipeline.log("glossaire : \(glossary.count) terme(s)") }
        let contextualStrings = Glossaire.contextualStrings(terms: glossary)
        if !contextualStrings.isEmpty {
            Pipeline.log("context strings : \(contextualStrings.count) forme(s) JA")
        }
        if configuration.preview {
            do {
                try await translation.configure(sourceLocale: "ja")
            } catch {
                Pipeline.log("preview : \(error.localizedDescription)")
            }
            previewTask = LivePreviewTask(
                capture: capture, speech: speech, translation: translation, output: output,
                contextualStrings: contextualStrings,
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

        let useQwenFinal = configuration.liveASR == .qwenJA
        // Legacy Voxtral : sidecar Python (seulement en mode voxtralQ4 — le
        // mode produit (qwenJA) charge Qwen3-ASR + aligneur en MLX, ~12 GB
        // résidents au lieu de Voxtral + Qwen).
        let sidecar: VoxtralHelperRuntime?
        if useQwenFinal {
            sidecar = nil
        } else {
            let helper = VoxtralHelperRuntime(rootDirectory: ASR.sidecarRoot)
            let sidecarConfig = VoxtralContinuousConfiguration(model: .q4, delay: configuration.delay)
            do {
                try await helper.prepare(configuration: sidecarConfig)
            } catch {
                await capture.stop()
                await previewTask?.finish()
                throw LiveError.sidecar(error.localizedDescription)
            }
            sidecar = helper
        }

        // Niveau final Qwen3-ASR (défaut produit) : transcribeur 1.7B JA
        // (snapshot) + aligneur de mots (borne exacte de chaque clause,
        // zéro dérive).
        var asrFinal: Qwen3ASRFinalRuntime?
        var alignerRT: Qwen3AlignerRuntime?
        if useQwenFinal {
            let final = Qwen3ASRFinalRuntime()
            do {
                try await final.prepare(progress: { _, message in Pipeline.log(message) })
            } catch {
                await capture.stop()
                await previewTask?.finish()
                throw LiveError.finalASR(error.localizedDescription)
            }
            let aligner = Qwen3AlignerRuntime()
            do {
                try await aligner.prepare(progress: { _, message in Pipeline.log(message) })
            } catch {
                await final.unload()
                await capture.stop()
                await previewTask?.finish()
                throw LiveError.finalASR(error.localizedDescription)
            }
            asrFinal = final
            alignerRT = aligner
        }

        let translator = LocalMLXTranslator(candidate: configuration.model)
        try await translator.prepare { _, _ in }

        // --- Boucle d'endpointing + finalisation ---------------------------
        var lastCommit = 0
        var stopRequested = false
        // État roulant de l'endpointing sémantique (mode Qwen3-ASR) :
        // snapshot cumulé (piloté par le coordinateur pseudo-live), suivi de
        // stabilité, historique LLM roulant (paires JA→EN, K=4) et contexte
        // ASR roulant (JA récent).
        var snapshot = ""
        var lastSnapshotThrough = 0
        var stabilityTracker = SnapshotStabilityTracker()
        var history: [HighQualityAcceptedTranslationPair] = []
        var committedJA = ""
        // Pseudo-live : coordinateur des snapshots cumulatifs Qwen (cadence
        // 2 s, coalescing, générations). `stageFinal` bloque les previews du
        // range commité ; `previewsEnabled` = false quand MLXTRANSLATE_PSEUDO_LIVE=0
        // (l'endpointing s'appuie alors sur le snapshot forcé au déclenchement).
        var pseudoLiveCoordinator = QwenPseudoLiveCoordinator(
            cadence: .productDefault,
            previewsEnabled: useQwenFinal && configuration.pseudoLive
        )

        /// Transcription d'un snapshot pseudo-live (travail planifié par le
        /// coordinateur) + enchaînement du travail coalescé (latest-wins).
        /// Met à jour la sortie du modèle (`snapshot`) consommée par
        /// l'endpointing sémantique, puis alimente la ligne roulante :
        /// - `--sans-traduction` : texte JA du snapshot (statu quo) ;
        /// - sinon : preview EN progressive — traduction streaming (MT,
        ///   `isFragment: true`) du snapshot cumulé, historique roulant borné.
        func runPendingPreview(_ work: QwenPseudoLivePreviewWork) async {
            guard let asrFinal else { return }
            do {
                let windowAudio = capture.samples(
                    from: work.range.lowerBound, upTo: work.range.upperBound
                )
                let asrContext = String(committedJA.suffix(LiveSemanticEndpointer.asrContextCharacters))
                let source = try await asrFinal.transcribe(
                    audio: windowAudio,
                    context: asrContext.isEmpty ? nil : asrContext
                )
                lastSnapshotThrough = work.range.upperBound
                let completion = pseudoLiveCoordinator.completePreview(work, source: source)
                if let accepted = completion.accepted {
                    // L'endpointing sémantique consomme le snapshot JA AVANT la
                    // passe de traduction : même si la MT échoue, le verdict
                    // porte sur le bon texte.
                    snapshot = accepted.source
                    LiveDebug.log("PSEUDO-LIVE(Qwen) roulant \"\(accepted.source)\"")
                    let rollingTimecode = LiveFormat.timecode(
                        Double(work.range.lowerBound) / LiveEndpointing.sampleRate
                    )
                    let channel = configuration.onApplePreview ?? configuration.onLine
                    if configuration.sansTraduction {
                        // Mode JA seul : la ligne roulante reste en JA (pas de MT).
                        channel?(accepted.source, false)
                        Task {
                            await output.showPreview("\(rollingTimecode) ~ \(accepted.source)")
                        }
                    } else {
                        // Preview EN progressive : traduction streaming du
                        // snapshot cumulé (« fragment incomplet — ne pas
                        // compléter ni deviner »), historique roulant borné
                        // (K=4, même contrat que le chemin de commit). La
                        // ligne ne rétrécit jamais entre les passes (garde
                        // monotone dans LiveOverlayState / LiveOutput).
                        let sourceStart = Double(work.range.lowerBound) / LiveEndpointing.sampleRate
                        let sourceEnd = Double(work.range.upperBound) / LiveEndpointing.sampleRate
                        let previewHistory = Array(history.suffix(LiveSemanticEndpointer.historyLimit))
                        let glossaryTerms = glossary
                        do {
                            let passStarted = Date()
                            let finalChunk = try await translator.translateLive(
                                japanese: accepted.source,
                                glossary: glossaryTerms,
                                history: previewHistory,
                                isFragment: true,
                                sourceStart: sourceStart,
                                sourceEnd: sourceEnd,
                                onChunk: { chunk in
                                    guard !chunk.isEmpty else { return }
                                    LiveDebug.log("PSEUDO-LIVE(MT) chunk = \"\(chunk)\"")
                                    channel?(chunk, false)
                                    let line = "\(rollingTimecode) ~ \(chunk)"
                                    Task { await output.showPreview(line) }
                                }
                            )
                            LiveDebug.log(
                                "PSEUDO-LIVE(MT) EN=\"\(finalChunk)\" "
                                + "(\(String(format: "%.0f", Date().timeIntervalSince(passStarted) * 1000)) ms)"
                            )
                            if !finalChunk.isEmpty {
                                channel?(finalChunk, false)
                                let line = "\(rollingTimecode) ~ \(finalChunk)"
                                Task { await output.showPreview(line) }
                            }
                        } catch {
                            // Échec de la passe : on garde la dernière preview
                            // affichée (le snapshot JA a déjà alimenté l'endpointing).
                            LiveDebug.log("PSEUDO-LIVE(MT) en échec : \(error.localizedDescription)")
                        }
                    }
                }
                if let next = completion.next {
                    await runPendingPreview(next)
                }
            } catch {
                LiveDebug.log("PSEUDO-LIVE(Qwen) en échec : \(error.localizedDescription)")
                if let next = pseudoLiveCoordinator.failPreview(work) {
                    await runPendingPreview(next)
                }
            }
        }

        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            stopLock.withLock { $0 = true }
        }
        source.resume()

        while !stopRequested {
            try? await Task.sleep(for: .seconds(LiveEndpointing.pollSeconds))
            if stopLock.withLock({ $0 }) || configuration.stopRequested() { stopRequested = true; break }

            let available = capture.sampleCount()

            if useQwenFinal, let asrFinal, let alignerRT {
                // --- Endpointing sémantique (Qwen3-ASR final + aligneur) ---
                guard available - lastCommit >= Int(0.5 * LiveEndpointing.sampleRate) else { continue }

                // 1) Silence de fin (mesure sur la fenêtre) + snapshot du
                //    modèle final (sortie consommée par l'endpointing) —
                //    deux sources de snapshot, plus récent gagne :
                //    - pseudo-live (coordinateur) : ré-transcription
                //      cumulative de la clause en cours, cadence 2 s
                //      (coalescing + générations ; bloqué sur les ranges
                //      commités via stageFinal) ;
                //    - forçage au déclenchement : si le dernier snapshot est
                //      périmé (nouvelle audio depuis), la fenêtre est calme et
                //      l'endpointing a besoin du texte complet — transcribe
                //      hors cadence.
                let tail = capture.samples(
                    from: max(lastCommit, available - Int(LiveSemanticEndpointer.forceCutSeconds * LiveEndpointing.sampleRate)),
                    upTo: available
                )
                let silenceSeconds = LiveSemanticEndpointer.trailingSilenceSeconds(tail)
                let windowSeconds = Double(available - lastCommit) / LiveEndpointing.sampleRate
                let triggerDue = silenceSeconds >= LiveSemanticEndpointer.triggerSilenceSeconds
                // Filet de sécurité : la fenêtre est bornée même sans pause
                // (parole continue) — le déclenchement passe aussi à 12 s.
                let safetyDue = windowSeconds >= LiveSemanticEndpointer.forceCutSeconds
                let staleAtTrigger =
                    (triggerDue || safetyDue)
                        && available - lastSnapshotThrough >= Int(0.5 * LiveEndpointing.sampleRate)
                if staleAtTrigger {
                    lastSnapshotThrough = available
                    let windowAudio = capture.samples(from: lastCommit, upTo: available)
                    let asrContext = String(committedJA.suffix(LiveSemanticEndpointer.asrContextCharacters))
                    do {
                        let asrStarted = Date()
                        snapshot = try await asrFinal.transcribe(
                            audio: windowAudio,
                            context: asrContext.isEmpty ? nil : asrContext
                        )
                        LiveDebug.log(
                            "ASR(Qwen3) snapshot (forcé au déclenchement) \"\(snapshot)\" "
                            + "(\(String(format: "%.0f", Date().timeIntervalSince(asrStarted) * 1000)) ms, "
                            + "\(String(format: "%.1f", Double(windowAudio.count) / 16000.0)) s d'audio)"
                        )
                    } catch {
                        Pipeline.log("snapshot Qwen3-ASR en échec : \(error.localizedDescription)")
                        LiveDebug.log("ASR(Qwen3) snapshot en échec : \(error.localizedDescription)")
                    }
                } else if !safetyDue, let work = pseudoLiveCoordinator.observe(
                    speechStart: lastCommit,
                    availableThrough: available
                ) {
                    // Preview de cadence uniquement hors filet : le filet (≥ 12 s)
                    // force la coupe, inutile de bloquer la boucle sur un snapshot.
                    await runPendingPreview(work)
                }

                // 2) Déclenchement : silence de fin ≥ 0,3 s — ou filet de
                //    sécurité à 12 s (borne la fenêtre même sans pause).
                guard triggerDue || safetyDue else { continue }

                // 3) Verdict sémantique : fin de phrase + stabilité (pas de
                //    fenêtre temporelle fixe) ; 2 s de silence sur clause
                //    incomplète → fragment ; 12 s → filet de sécurité.
                let stable = stabilityTracker.observe(snapshot)
                let terminal = LiveSemanticEndpointer.isTerminalJapanese(snapshot)
                // Signal complémentaire Apple : le transcribeur a FINALISÉ son
                // texte jusqu'à la fin de la fenêtre disponible (marge 1 s) →
                // le texte roulant est stable (substitut de `isStable`).
                let appleFinalizedThrough = previewTask?.finalizedThroughSample ?? 0
                let appleFinalized =
                    appleFinalizedThrough > lastCommit
                        && appleFinalizedThrough >= available - Int(1.0 * LiveEndpointing.sampleRate)
                let decision = LiveSemanticEndpointer.evaluate(
                    silenceSeconds: silenceSeconds,
                    isTerminal: terminal,
                    isStable: stable,
                    windowSeconds: windowSeconds,
                    appleFinalized: appleFinalized
                )
                guard decision != .hold else { continue }

                // Garde des vides : jamais de clause vide au LLM.
                guard let jaText = LiveClauseSelection.select(qwenJapanese: snapshot, appleJapanese: nil) else {
                    continue
                }

                // 4) Alignement : borne exacte de consommation (zéro dérive) —
                //    la fenêtre suivante démarre à la fin du dernier mot.
                //    Repli : fedThrough − garde de stabilité (1,12 s).
                let windowAudio = capture.samples(from: lastCommit, upTo: available)
                var nextCommit = max(
                    lastCommit,
                    available - Int(LiveSemanticEndpointer.stabilityGuardSeconds * LiveEndpointing.sampleRate)
                )
                if let aligned = try? await alignerRT.align(audio: windowAudio, text: jaText),
                   let lastWord = aligned.last, lastWord.startTime > 0 {
                    nextCommit = min(
                        max(lastCommit + Int(lastWord.endTime * Float(LiveEndpointing.sampleRate)), lastCommit),
                        available
                    )
                }
                if nextCommit <= lastCommit { nextCommit = available }
                LiveDebug.log(
                    "ENDPOINTING(qwen) \(decision) silence=\(String(format: "%.1f", silenceSeconds)) s "
                    + "terminal=\(terminal) stable=\(stable) "
                    + "→ commit [\(String(format: "%.1f", Double(lastCommit) / LiveEndpointing.sampleRate))"
                    + "–\(String(format: "%.1f", Double(nextCommit) / LiveEndpointing.sampleRate)) s] "
                    + "JA=\"\(jaText)\""
                )

                // 5) Traduction (historique roulant + glossaire, streaming).
                var enText: String?
                let windowStartSeconds = Double(lastCommit) / LiveEndpointing.sampleRate
                if !configuration.sansTraduction {
                    do {
                        let translateStarted = Date()
                        let chunkCounter = OSAllocatedUnfairLock(initialState: 0)
                        enText = try await translator.translateLive(
                            japanese: jaText,
                            glossary: glossary,
                            history: Array(history.suffix(LiveSemanticEndpointer.historyLimit)),
                            // Fragment OU forceCut (12 s) : clause incomplète
                            // → « ne pas compléter ni deviner ».
                            isFragment: decision == .commitFragment || decision == .forceCut,
                            sourceStart: windowStartSeconds,
                            sourceEnd: Double(nextCommit) / LiveEndpointing.sampleRate,
                            onChunk: { chunk in
                                if !chunk.isEmpty {
                                    let n = chunkCounter.withLock { $0 += 1; return $0 }
                                    LiveDebug.log("MLX chunk #\(n) (preview cumulée) = \"\(chunk)\"")
                                    configuration.onLine?(chunk, false)
                                    Task {
                                        await output.showPreview(
                                            "\(LiveFormat.timecode(windowStartSeconds)) ~ \(chunk)"
                                        )
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

                // 6) Engagement + état roulant (historique LLM, contexte ASR,
                //    stabilité réinitialisée, fenêtre avancée à la borne alignée).
                let finalEN = enText ?? (configuration.sansTraduction ? jaText : "")
                await output.clearPreview()
                await output.commit(
                    start: Double(lastCommit) / LiveEndpointing.sampleRate,
                    end: Double(nextCommit) / LiveEndpointing.sampleRate,
                    japanese: jaText,
                    english: enText,
                    show: configuration.show
                )
                if !finalEN.isEmpty {
                    LiveDebug.log("FINAL onLine isFinal=true EN=\"\(finalEN)\"")
                    configuration.onLine?(finalEN, true)
                }
                history.append(HighQualityAcceptedTranslationPair(
                    cueID: "live-\(history.count)",
                    japanese: jaText,
                    english: finalEN.isEmpty ? jaText : finalEN
                ))
                history = Array(history.suffix(LiveSemanticEndpointer.historyLimit))
                committedJA += " \(jaText)"
                // Pseudo-live : le range est définitif — le coordinateur
                // bloque les previews le couvrant (previewNotBefore = borne
                // alignée) et incrémente la génération (les snapshots en vol
                // deviennent obsolètes).
                let finalWork = pseudoLiveCoordinator.stageFinal(
                    range: lastCommit..<nextCommit,
                    stableThrough: nextCommit
                )
                lastCommit = nextCommit
                stabilityTracker.reset()
                snapshot = ""
                lastSnapshotThrough = 0
                // Libère le slot final et relance l'éventuel preview coalescé
                // (la clause suivante reprend la roulante immédiatement).
                if let pending = pseudoLiveCoordinator.completeFinal(finalWork) {
                    await runPendingPreview(pending)
                }
                previewTask?.committedSampleOffset = lastCommit
                if lastCommit >= Int(120 * LiveEndpointing.sampleRate) {
                    capture.trim(upTo: lastCommit)
                }
                continue
            }

            // --- Legacy Voxtral : coupe au silence + forçage 12 s ---
            guard let sidecar,
                  available >= LiveEndpointing.minSilenceFrames * LiveEndpointing.frameSamples else { continue }

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
        if useQwenFinal, let asrFinal {
            if remaining - lastCommit >= Int(0.5 * LiveEndpointing.sampleRate) {
                let windowAudio = capture.samples(from: lastCommit, upTo: remaining)
                let context = String(committedJA.suffix(LiveSemanticEndpointer.asrContextCharacters))
                let rawJA = (try? await asrFinal.transcribe(
                    audio: windowAudio,
                    context: context.isEmpty ? nil : context
                )) ?? ""
                if let jaText = LiveClauseSelection.select(
                    qwenJapanese: rawJA.trimmingCharacters(in: .whitespacesAndNewlines),
                    appleJapanese: nil
                ) {
                    var enText: String?
                    if !configuration.sansTraduction {
                        enText = try? await translator.translateLive(
                            japanese: jaText,
                            glossary: glossary,
                            history: Array(history.suffix(LiveSemanticEndpointer.historyLimit)),
                            isFragment: false,
                            sourceStart: Double(lastCommit) / LiveEndpointing.sampleRate,
                            sourceEnd: Double(remaining) / LiveEndpointing.sampleRate
                        )
                    }
                    let finalEN = enText ?? (configuration.sansTraduction ? jaText : "")
                    await output.commit(
                        start: Double(lastCommit) / LiveEndpointing.sampleRate,
                        end: Double(remaining) / LiveEndpointing.sampleRate,
                        japanese: jaText,
                        english: enText,
                        show: configuration.show
                    )
                    if !finalEN.isEmpty { configuration.onLine?(finalEN, true) }
                }
            }
        } else if let sidecar, remaining - lastCommit >= Int(0.5 * LiveEndpointing.sampleRate) {
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
        pseudoLiveCoordinator.cancel()
        await previewTask?.finish()
        await capture.stop()
        await sidecar?.shutdown()
        await asrFinal?.unload()
        await alignerRT?.unload()
        await output.flush()
        let count = await output.committedCount
        Pipeline.log("live terminé : \(count) énoncé(s) → \(configuration.outputURL.path)")
    }
}
