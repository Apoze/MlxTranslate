import Foundation
import os

// Journal de debug du live (activé par `MLXTRANSLATE_DEBUG=1`) : horodaté (ISO8601 +
// t+ depuis le démarrage), écrit sur stderr et (optionnel) en append dans
// `MLXTRANSLATE_DEBUG_LOG` (sinon `~/.mlxtranslate/live-debug.log`). Sert à tracer
// l'enchaînement endpointing → ASR (Voxtral) → preview (Apple) → traduction EN
// (preview/final, MLX) → superposition, avec les timings.
public enum LiveDebug {
    public static let enabled = ProcessInfo.processInfo.environment["MLXTRANSLATE_DEBUG"] != nil
    /// Activation forcée (app GUI) : le log s'écrit même sans l'env variable
    /// `MLXTRANSLATE_DEBUG` (le CLI reste sur l'env) — diagnostic des
    /// sessions réelles (`~/.mlxtranslate/live-debug.log`, append, horodaté).
    public static var forceEnabled = false
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
        guard enabled || forceEnabled else { return }
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
    // Dédoublonnage SRT : un cue au texte IDENTIQUE au précédent (répétition
    // ASR repliée, doublon de forçage) étend le dernier cue au lieu
    // d'ajouter une ligne identique — l'audio couvert reste continu.
    @discardableResult
    func commit(start: Double, end: Double, japanese: String, english: String?, show: Bool) -> Int {
        let text: String
        if let english, !english.isEmpty {
            text = english
        } else {
            text = japanese.isEmpty ? "" : "(JA) \(japanese)"
        }
        if !text.isEmpty, let last = cues.last, last.text == text {
            cues[cues.count - 1].end = end
            flush()
            return cueIndex
        }
        cueIndex += 1
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

/// État partagé de la roulante Qwen (boucle d'endpointing + tâche de preview
/// non bloquante). Le preview task enchaîne les travaux coalescés (latest-wins)
/// PENDANT que la boucle décide/commit — le lock unique protège le snapshot
/// cumulé, l'historique LLM roulant (K=4), le contexte ASR roulant et le
/// coordinateur pseudo-live (les deux tâches y touchent en parallèle).
final class LiveRollingState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    fileprivate var snapshot = ""
    fileprivate var lastSnapshotThrough = 0
    fileprivate var lastPreviewSource: String?
    fileprivate var history: [HighQualityAcceptedTranslationPair] = []
    fileprivate var committedJA = ""
    fileprivate var coordinator: QwenPseudoLiveCoordinator
    /// Tâche de preview Qwen en cours (nil = aucune — la tâche se nettoie
    /// elle-même en fin d'enchaînement).
    fileprivate var previewTask: Task<Void, Never>?

    init(coordinator: QwenPseudoLiveCoordinator) {
        self.coordinator = coordinator
    }

    func with<R>(_ body: (LiveRollingState) throws -> R) rethrows -> R {
        try lock.withLock { try body(self) }
    }
}

/// Instance de traduction Apple préchargée (GUI : session préparée au
/// lancement de l'app, ~250 ms de réchauffement déjà payés). Dispo macOS
/// 26.4+ (dispo du framework Translation) — d'où le conteneur annoté
/// (la config LiveEngineConfiguration n'est pas annotée). L'app le fixe
/// avant `startLive` ; le CLI garde son instance propre (nil).
@available(macOS 26.4, *)
enum LivePreloadedTranslation {
    static var service: AppleTranslationService?
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
    /// Paires (échantillon finalisé 16 kHz, longueur du texte cumulé à ce
    /// moment) — permettent de borner la roulante au dernier commit : le
    /// suffixe affiché/traduit est le contenu NOUVEAU depuis le dernier
    /// commit, pas l'historique cumulé de la session (d'où les « sous-titres
    /// qui reviennent » et les traductions sur tout le contenu ancien).
    private var finalizedTextLengths: [(sample: Int, length: Int)] = []
    /// Longueur (caractères) du texte roulant consommée par le dernier
    /// commit : `previewText` = suffixe après cette borne.
    private var committedTextLength = 0
    /// Formes JA du glossaire, injectées comme « context strings » du
    /// transcribeur Apple (bias lexical des termes propres).
    private let contextualStrings: [String]
    /// Début (échantillons 16 kHz) de l'énoncé en cours — mis à jour par le
    /// moteur live après chaque commit ; sert d'horodatage aux previews.
    var committedSampleOffset = 0
    /// Séquence de la phrase EN COURS (compteur du moteur, croissant) —
    /// portée par chaque preview : la superposition ignore les previews de
    /// la phrase déjà engagée (texte en retard qui « revient »).
    private let seqLock = OSAllocatedUnfairLock(initialState: 0)
    /// Borne du dernier commit (échantillons 16 kHz) : le suffixe de la
    /// preview doit SAUTER à la longueur de texte du premier résultat
    /// FINALISÉ qui franchit cette borne — la queue de la phrase engagée
    /// (déjà remplacée par son final MLX) ne pollue plus la preview de la
    /// phrase suivante (l'ASR Apple finalise en retard sur la coupe).
    private var pendingCutSample = 0
    /// Le saut de suffixe du commit en attente a-t-il déjà eu lieu (borne
    /// franchie par une finalisation) : un seul saut par commit.
    private var cutTrimDone = false
    /// Callback de la preview basse latence (JA→EN roulant) : alimente la
    /// superposition GUI (l'outil CLI passe nil → pas de superposition).
    var previewLine: (@Sendable (String, Bool, Int) -> Void)?

    init(
        capture: AppCapture,
        speech: AppleSpeechService,
        translation: AppleTranslationService,
        output: LiveOutput,
        contextualStrings: [String] = [],
        previewLine: (@Sendable (String, Bool, Int) -> Void)? = nil
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
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // Aliments l'audio tamponné au Speech (catch-up, port WhisperASR
    // `takeNewSamples`) : TOUS les nouveaux échantillons en UN envoi — pas de
    // tranches de 100 ms espacées de 300 ms qui alimenaient à ~0,3× la
    // vitesse réelle (dérive sans borne du texte roulant sur la réalité).
    private func feedAudio() async {
        guard fedUpTo < capture.sampleCount() else { return }
        let chunk = capture.samples(from: fedUpTo, upTo: capture.sampleCount())
        guard !chunk.isEmpty else { return }
        do {
            try await speech.send(samples: chunk, startSample: fedUpTo)
            fedUpTo += chunk.count
        } catch { /* best-effort */ }
    }

    // Traduction throttlée (≥ 0,25 s et texte changé) du SUFFIXE de la
    // roulante (contenu nouveau depuis le dernier commit) → EN bas :
    // cadence 250 ms (plan produit) — la ligne se met à jour à chaque
    // rafraîchissement, s'améliore à chaque résultat progressif du
    // transcribeur (cumulatif dans la phrase), et le final MLX (glossaire)
    // la remplace au commit. L'horodatage affiché est le DÉBUT de l'énoncé
    // en cours (dernier commit), pas la position courante : les previews
    // et les cues SRT utilisent alors la même base temporelle.
    private func renderPreview() async {
        let ja = previewText
        // Fragment trop court ET phrase non terminale → on attend (pas de
        // traduction de 1–2 caractères) ; fin terminale → traduction
        // immédiate (la phrase est complète).
        guard ja != lastTranslatedJA,
              Date().timeIntervalSince(lastTranslateTime) >= 0.25,
              !ja.isEmpty,
              (ja.count >= 4 || LiveSemanticEndpointer.isTerminalJapanese(ja)) else { return }
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
            // La séquence de phrase (croissante) permet à la barre d'ignorer cette
            // preview si la phrase a déjà été engagée pendant son vol (texte en
            // retard — plus de « retour » de l'ancienne ligne).
            previewLine?(en, false, seqLock.withLock { $0 })
            await output.showPreview("\(timecode) ~ \(en)")
        } catch { /* best-effort */ }
    }

    // Interne (pas private) : alimenté par le callback du transcribeur ;
    // testable directement (suite de tests).
    func handleUpdate(_ update: LiveSourceUpdate) {
        let text = update.segment.text
        jaLock.lock()
        if !text.isEmpty { rollingJA = text }
        if update.finalizedThroughSample > finalizedThroughSampleLocked {
            finalizedThroughSampleLocked = update.finalizedThroughSample
            // Borne de finalisation → longueur du texte cumulé au même
            // instant (le texte avant cet échantillon ne changera plus).
            let length = rollingJA.count
            finalizedTextLengths.append((update.finalizedThroughSample, length))
            if finalizedTextLengths.count > 512 {
                finalizedTextLengths.removeFirst(finalizedTextLengths.count - 512)
            }
            // Saut du suffixe : la finalisation vient de FRANCHIR la borne du
            // dernier commit → la preview saute à la longueur de texte de
            // CETTE finalisation (la queue de la phrase engagée disparaît de
            // la preview de la phrase suivante). Un seul saut par commit.
            if !cutTrimDone,
                pendingCutSample > 0,
                update.finalizedThroughSample >= pendingCutSample,
                length > committedTextLength {
                committedTextLength = length
                cutTrimDone = true
            }
        }
        jaLock.unlock()
    }

    /// Texte roulant japonais (segment courant, cumulatif dans la phrase) —
    /// lu par le moteur pour le planificateur d'endpointing (fin de phrase
    /// par ponctuation → commit immédiat, sans attendre le silence).
    var rollingText: String {
        jaLock.withLock { rollingJA }
    }

    /// Borne de finalisation Apple (échantillons 16 kHz, index absolu) — le
    /// texte avant cette borne est définitif (signal d'endpointing).
    var finalizedThroughSample: Int {
        jaLock.withLock { finalizedThroughSampleLocked }
    }

    /// Suffixe de la roulante DEPUIS LE DERNIER COMMIT (contenu nouveau
    /// seulement, pas l'historique cumulé de la session) — alimente la
    /// preview (traduction + affichage) et la détection de fin de phrase
    /// (planner d'endpointing). Avant le premier commit : texte complet.
    var previewText: String {
        jaLock.withLock {
            String(rollingJA.dropFirst(min(committedTextLength, rollingJA.count)))
        }
    }

    /// Borner la roulante au dernier commit (échantillon absolu 16 kHz) :
    /// l'affichage, la traduction et l'endpointing n'utilisent que le
    /// contenu NOUVEAU depuis cette borne — après un commit, la ligne
    /// repart vide jusqu'au nouveau contenu (pas de « retour » des
    /// sous-titres déjà committés).
    /// - Sans paire de finalisation avant la borne (début de session) :
    ///   rebond sur le texte courant (la roulante repart vide de suite).
    /// - `seq` : numéro de la phrase EN COURS après le commit — porté par
    ///   toutes les previews à venir (la superposition jette les previews
    ///   de la phrase engagée, dont la séquence est inférieure).
    /// - Suffixe contaminé : l'ASR Apple finalise EN RETARD sur la coupe —
    ///   entre le commit et la finalisation qui franchit la borne, le
    ///   suffixe contient la queue de la phrase engagée (texte « d'avant »
    ///   qui grossissait sur la preview). Quand cette finalisation arrive,
    ///   `handleUpdate` fait sauter le suffixe à sa longueur (plus de queue
    ///   ancienne dans la preview de la phrase suivante).
    func markCommitted(throughSample: Int, seq: Int) {
        committedSampleOffset = throughSample
        seqLock.withLock { $0 = seq }
        jaLock.lock()
        // Suffixe contaminé : l'ASR Apple finalise EN RETARD sur la coupe
        // (le filet 5 s coupe la phrase, mais la finalisation Apple de la
        // queue reste en attente). Deux cas :
        //
        // (a) Une finalisation a déjà FRANCHI la coupe (Apple est en avance)
        //     → sauter IMMÉDIATEMENT à la longueur de CETTE finalisation :
        //     la queue de la phrase engagée disparaît de la preview, et le
        //     saut n'aura pas lieu « plus tard » dans handleUpdate
        //     (cutTrimDone posé).
        // (b) Apple est en retard (aucune finalisation ≥ coupe) → borner à
        //     la dernière finalisation AVANT la coupe ; le saut aura lieu
        //     dans handleUpdate dès qu'une finalisation franchit la coupe
        //     (un seul saut par commit, cutTrimDone).
        var jumped = false
        for pair in finalizedTextLengths where pair.sample >= throughSample {
            committedTextLength = pair.length
            jumped = true
            break
        }
        if jumped {
            cutTrimDone = true
        } else {
            var length = 0
            for pair in finalizedTextLengths.reversed() where pair.sample <= throughSample {
                length = pair.length
                break
            }
            if length == 0 {
                // Sans paire finalisée (début de session) : rebond sur le
                // texte courant (la roulante repart vide de suite).
                length = rollingJA.count
            }
            committedTextLength = min(length, rollingJA.count)
            cutTrimDone = false
        }
        committedTextLength = min(committedTextLength, rollingJA.count)
        pendingCutSample = throughSample
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
    /// Niveau final ASR : `qwenJA` (défaut produit, endpointing sémantique
    /// Qwen3-ASR + aligneur) ou `voxtralQ4` (legacy).
    var liveASR: LiveFinalASR = LiveFinalASR.productDefault
    /// Pseudo-live Qwen : snapshots cumulatifs de la clause en cours pilotés
    /// par `QwenPseudoLiveCoordinator` — ligne roulante EN (preview MT
    /// progressive) + aliment de l'endpointing sémantique. ON par défaut en
    /// mode qwenja ; `MLXTRANSLATE_PSEUDO_LIVE=0` le désactive.
    var pseudoLive: Bool = true
    /// Cadence des snapshots cumulatifs (1 / 2 / 3 s) — prise en compte au
    /// démarrage du live (redémarrage requis pour changer la valeur).
    var pseudoLiveCadence: QwenPseudoLiveCadence = .productDefault
    /// Source de la ligne roulante EN (mode Qwen) : Apple `Speech` en
    /// streaming (défaut produit, ASR cumulé + traduction 250 ms) ou MLX
    /// streaming (option lente, glossaire, snapshots cumulatifs 1/2/3 s).
    var previewMode: LivePreviewMode = .productDefault
    // Instances préchargées (GUI : modèles chargés au lancement de l'app) —
    // les `prepare` sont idempotents : déjà préparées, le live démarre sans
    // attente ; nil pour le CLI (chargement classique au démarrage du live).
    var preloadedASR: Qwen3ASRFinalRuntime?
    var preloadedAligner: Qwen3AlignerRuntime?
    var preloadedTranslator: LocalMLXTranslator?
    // Callback de superposition : le texte EN courant (preview en streaming, puis final
    // engagé) + un flag « estFinal » + la SÉQUENCE de phrase (croissante, phrase en
    // cours au moment de l'émission) — sert à alimenter une barre de sous-titres GUI
    // (l'outil CLI renvoie nil → pas de superposition). La séquence permet à la barre
    // d'ignorer les previews en retard de la phrase déjà ENGAGÉE (le texte ne
    // « revient » pas).
    var onLine: (@Sendable (String, Bool, Int) -> Void)?
    // Callback de l'INSTANTANÉ (preview Apple basse latence, JA roulant → EN) — distinct
    // du final MLX (onLine). Alimente la ligne « instantané » de la superposition, qui
    // reste affichée en continu pendant la parole (le final s'empile au-dessus).
    // Mêmes arguments que `onLine` (texte, estFinal, séquence de phrase).
    // nil pour l'outil CLI (pas de superposition).
    var onApplePreview: (@Sendable (String, Bool, Int) -> Void)?
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
            model: command.liveModel,
            glossaryURL: command.glossary ?? Pipeline.defaultGlossaryURL,
            delay: command.liveDelay,
            sansTraduction: command.sansTraduction,
            outputURL: outputURL,
            maxSeconds: command.maxSeconds,
            liveASR: command.liveASR,
            pseudoLive: ProcessInfo.processInfo.environment["MLXTRANSLATE_PSEUDO_LIVE"] != "0",
            pseudoLiveCadence: command.liveCadence,
            previewMode: command.livePreviewSource
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
        let translation: AppleTranslationService
        if let preloaded = LivePreloadedTranslation.service {
            translation = preloaded   // session déjà chaude (chargement au lancement de l'app)
        } else {
            translation = AppleTranslationService()
        }
        // Ligne roulante Apple (Speech JA streaming, cumulatif, → traduction
        // Apple 250 ms) : active en mode legacy (Voxtral) et en mode Qwen
        // avec `previewMode == .apple` (DÉFAUT PRODUIT) — l'ASR Apple
        // alimente la ligne live (rapide, cumulative) et la détection de fin
        // de phrase (ponctuation) ; le final (Qwen3-ASR + MLX glossaire) la
        // remplace au commit. En mode Qwen `.mlx` (option lente), la roulante
        // est la tâche Qwen (snapshots cumulatifs + streaming MLX).
        let appleRollingPreview = configuration.preview
            && (configuration.liveASR == .qwenJA ? configuration.previewMode == .apple : true)
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
        }
        if appleRollingPreview {
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
            // Instances préchargées (app) : `prepare` idempotent — déjà
            // chargées au lancement, démarrage sans attente.
            let final = configuration.preloadedASR ?? Qwen3ASRFinalRuntime()
            do {
                try await final.prepare(progress: { _, message in Pipeline.log(message) })
            } catch {
                await capture.stop()
                await previewTask?.finish()
                throw LiveError.finalASR(error.localizedDescription)
            }
            let aligner = configuration.preloadedAligner ?? Qwen3AlignerRuntime()
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

        let translator: LocalMLXTranslator
        if let preloaded = configuration.preloadedTranslator {
            translator = preloaded
        } else {
            translator = LocalMLXTranslator(candidate: configuration.model)
        }
        try await translator.prepare { _, _ in }

        // --- Boucle d'endpointing + finalisation ---------------------------
        let sr = LiveEndpointing.sampleRate
        var lastCommit = 0
        // Séquence de phrase (croissante, par session live) : la clause EN
        // COURS porte la séquence courante ; chaque coupe (staging FIFO ou
        // avancement sans cue) incrémente — les previews/finaux de la phrase
        // ENGAGÉE (séquence inférieure) sont jetés par la superposition,
        // seuls ceux de la phrase SUIVANTE s'affichent.
        var phraseSeq = 0
        var stopRequested = false
        // Endpointing « lâche » (règles WhisperASR) : commit au silence de
        // 0,5 s après une phrase ≥ 1,5 s, à la FIN DE PHRASE (silence OU
        // ponctuation dans le texte roulant), filet dur à 5 s — la fenêtre
        // reste courte et la preview bouge à chaque cycle.
        var pausePlanner = LivePausePlanner()
        // État partagé avec la tâche de preview Qwen (non bloquante) :
        // snapshot cumulé, dédup des passes MLX, historique LLM roulant (K=4),
        // contexte ASR roulant (JA récent) et coordinateur pseudo-live
        // (coalescing des previews, générations).
        let rolling = LiveRollingState(
            coordinator: QwenPseudoLiveCoordinator(
                cadence: configuration.pseudoLiveCadence,
                previewsEnabled: useQwenFinal
                    && configuration.pseudoLive
                    && configuration.previewMode == .mlx
            )
        )
        // Début de la phrase EN COURS (première parole après le dernier
        // commit, échantillon absolu) : les snapshots de preview ré-écrivent
        // la phrase entière depuis ce début (snapshot cumulé WhisperASR) —
        // pas depuis le dernier commit (fenêtres courtes → ASR qui
        // « complète » la phrase au lieu de la transcrire). Réinitialisé à
        // chaque commit (le coordinateur bloque les ranges déjà engagés via
        // `previewNotBefore`, donc seule la nouvelle parole est transcrible).
        var utteranceStart: Int?

        /// Passe de preview EN progressive : traduction streaming du
        /// snapshot cumulé JA (`isFragment: true`, historique roulant borné
        /// K=4, même contrat que le chemin de commit). Affichage SEUL —
        /// l'endpointing sémantique a déjà consommé le texte JA ; la passe
        /// n'affecte pas l'endpointing. Utilisée par les previews de
        /// cadence (coordinateur) ET par le snapshot forcé au déclenchement
        /// — la ligne roulante EN se met à jour en continu, y compris au
        /// milieu d'une clause longue (la ligne ne rétrécit jamais : garde
        /// monotone dans LiveOverlayState / LiveOutput).
        func runEnglishPreviewPass(source: String, range: Range<Int>, seq: Int) async {
            let rollingTimecode = LiveFormat.timecode(
                Double(range.lowerBound) / LiveEndpointing.sampleRate
            )
            let channel = configuration.onApplePreview ?? configuration.onLine
            let sourceStart = Double(range.lowerBound) / LiveEndpointing.sampleRate
            let sourceEnd = Double(range.upperBound) / LiveEndpointing.sampleRate
            let previewHistory = rolling.with {
                Array($0.history.suffix(LiveSemanticEndpointer.historyLimit))
            }
            let glossaryTerms = glossary
            do {
                let passStarted = Date()
                let finalChunk = try await translator.translateLive(
                    japanese: source,
                    glossary: glossaryTerms,
                    history: previewHistory,
                    isFragment: true,
                    sourceStart: sourceStart,
                    sourceEnd: sourceEnd,
                    onChunk: { chunk in
                        guard !chunk.isEmpty else { return }
                        LiveDebug.log("PSEUDO-LIVE(MT) chunk = \"\(chunk)\"")
                        channel?(chunk, false, seq)
                        let line = "\(rollingTimecode) ~ \(chunk)"
                        Task { await output.showPreview(line) }
                    }
                )
                LiveDebug.log(
                    "PSEUDO-LIVE(MT) EN=\"\(finalChunk)\" "
                    + "(\(String(format: "%.0f", Date().timeIntervalSince(passStarted) * 1000)) ms)"
                )
                if !finalChunk.isEmpty {
                    channel?(finalChunk, false, seq)
                    let line = "\(rollingTimecode) ~ \(finalChunk)"
                    Task { await output.showPreview(line) }
                }
            } catch {
                // Échec de la passe : on garde la dernière preview affichée
                // (le snapshot JA a déjà alimenté l'endpointing).
                LiveDebug.log("PSEUDO-LIVE(MT) en échec : \(error.localizedDescription)")
            }
        }

        /// Démarre la tâche de preview Qwen (snapshot cumulé + ligne roulante)
        /// si aucune n'est en cours : le coordinateur a coalescé le travail
        /// (latest-wins) — la tâche l'exécute, alimente la roulante puis
        /// enchaîne la suite. La boucle d'endpointing ne bloque JAMAIS dessus.
        func startQwenPreviewTask(_ work: QwenPseudoLivePreviewWork) {
            guard rolling.with({ $0.previewTask == nil }) else { return }
            rolling.with {
                $0.previewTask = Task { await runQwenPreviewWork(work) }
            }
        }

        /// Exécute un snapshot pseudo-live (travail planifié par le
        /// coordinateur) + alimente la ligne roulante, puis enchaîne le
        /// travail coalescé (latest-wins) :
        /// - `--sans-traduction` : texte JA du snapshot ;
        /// - `.apple` (défaut) : traduction Apple basse latence (~250 ms,
        ///   session chaude) — la ligne bouge à chaque cycle ; le final MLX
        ///   (glossaire + historique) la remplace au commit ;
        /// - `.mlx` : passe MLX progressive (`runEnglishPreviewPass`),
        ///   dédupliquée par source JA.
        func runQwenPreviewWork(_ work: QwenPseudoLivePreviewWork) async {
            guard let asrFinal else {
                rolling.with { $0.previewTask = nil }
                return
            }
            do {
                let windowAudio = capture.samples(
                    from: work.range.lowerBound, upTo: work.range.upperBound
                )
                let asrContext = rolling.with {
                    LiveSemanticEndpointer.asrContextEnabled
                        ? String($0.committedJA.suffix(LiveSemanticEndpointer.asrContextCharacters))
                        : ""
                }
                let started = Date()
                let raw = try await asrFinal.transcribe(
                    audio: windowAudio,
                    context: asrContext.isEmpty ? nil : asrContext
                )
                // Repli des répétitions dégénérées (musique/silence) AVANT
                // traduction/affichage — le texte brut reste journalisé.
                let source = LiveRepetition.collapse(
                    raw.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                LiveDebug.log(
                    "PSEUDO-LIVE(Qwen) roulant \"\(source)\" "
                    + "(\(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms, "
                    + "\(String(format: "%.1f", Double(work.range.count) / 16000.0)) s d'audio)"
                )
                let completion = rolling.with {
                    $0.coordinator.completePreview(work, source: source)
                }
                if let accepted = completion.accepted {
                    // La roulante consomme le snapshot JA AVANT la traduction :
                    // même si la MT échoue, la ligne affiche le bon texte.
                    rolling.with {
                        $0.snapshot = accepted.source
                        $0.lastSnapshotThrough = work.range.upperBound
                    }
                    let rollingTimecode = LiveFormat.timecode(
                        Double(work.range.lowerBound) / LiveEndpointing.sampleRate
                    )
                    let channel = configuration.onApplePreview ?? configuration.onLine
                    if configuration.sansTraduction {
                        // Mode JA seul : la ligne roulante reste en JA (pas de MT).
                        channel?(accepted.source, false, work.seq)
                        await output.showPreview("\(rollingTimecode) ~ \(accepted.source)")
                    } else if configuration.previewMode == .apple {
                        do {
                            let enStarted = Date()
                            let en = try await translation.translate(accepted.source)
                            LiveDebug.log(
                                "PREVIEW(Apple→EN) JA=\"\(accepted.source)\" → EN=\"\(en)\" "
                                + "(\(String(format: "%.0f", Date().timeIntervalSince(enStarted) * 1000)) ms)"
                            )
                            channel?(en, false, work.seq)
                            await output.showPreview("\(rollingTimecode) ~ \(en)")
                        } catch {
                            LiveDebug.log("PREVIEW(Apple→EN) échec : \(error.localizedDescription)")
                        }
                    } else {
                        // Option lente : passe MLX progressive (glossaire) —
                        // dédupliquée par source JA (pas de passe répétée sur
                        // un texte inchangé — queue silencieuse, même ASR).
                        let isNew = rolling.with {
                            let changed = $0.lastPreviewSource != accepted.source
                            $0.lastPreviewSource = accepted.source
                            return changed
                        }
                        if isNew {
                            await runEnglishPreviewPass(
                                source: accepted.source,
                                range: work.range,
                                seq: work.seq
                            )
                        }
                    }
                }
                if let next = completion.next {
                    await runQwenPreviewWork(next)
                } else {
                    rolling.with { $0.previewTask = nil }
                }
            } catch {
                LiveDebug.log("PSEUDO-LIVE(Qwen) en échec : \(error.localizedDescription)")
                let next = rolling.with { $0.coordinator.failPreview(work) }
                if let next {
                    await runQwenPreviewWork(next)
                } else {
                    rolling.with { $0.previewTask = nil }
                }
            }
        }

        /// Avance l'état partagé sans cue (fenêtre vide ou ASR vide) : le
        /// coordinateur bloque le range définitif, la roulante repart sur la
        /// clause suivante immédiatement.
        func advanceRollingState(past range: Range<Int>) {
            let finalWork = rolling.with {
                $0.coordinator.stageFinal(range: range, stableThrough: range.upperBound)
            }
            rolling.with {
                $0.snapshot = ""
                $0.lastSnapshotThrough = 0
                $0.lastPreviewSource = nil
            }
            let pendingWork = rolling.with { $0.coordinator.completeFinal(finalWork) }
            if let pending = pendingWork {
                startQwenPreviewTask(pending)
            }
        }

        /// Trim borné du spool : ne libère JAMAIS le PCM d'une fenêtre FIFO
        /// encore en attente (le consommateur lit `samples(from:upTo:)` au
        /// traitement, pas au staging) — sinon trim normal à `commit`.
        func trimCapture(upTo commit: Int, fifo: LiveEndpointFIFO) async {
            guard commit >= Int(120 * sr) else { return }
            let oldest = await fifo.oldestPendingWindowStart()
            capture.trim(upTo: min(commit, oldest ?? commit))
        }

        /// Passe de qualité d'une fenêtre FIFO (ASR → aligneur → MLX →
        /// commit) — exécutée par le worker de commit (dans l'ordre, les
        /// plus anciennes d'abord) ; la boucle d'endpointing ne bloque
        /// JAMAIS dessus (port WhisperASR : le producteur stage, le
        /// consommateur commit).
        func processFIFOCommit(_ entry: LiveEndpointFIFO.Entry) async throws {
            guard let asrFinal, let alignerRT else {
                throw LiveError.finalASR("FIFO : ASR final / aligneur non prêts")
            }
            let windowAudio = capture.samples(from: entry.windowStart, upTo: entry.windowEnd)
            guard !windowAudio.isEmpty else {
                throw LiveError.finalASR("FIFO : fenêtre vide (PCM libéré ?)")
            }
            let asrStarted = Date()
            let rawJA = try await asrFinal.transcribe(
                audio: windowAudio,
                context: entry.asrContext.isEmpty ? nil : entry.asrContext
            )
            LiveDebug.log(
                "ASR(Qwen3) commit \"\(rawJA)\" "
                + "(\(String(format: "%.0f", Date().timeIntervalSince(asrStarted) * 1000)) ms, "
                + "\(String(format: "%.1f", Double(windowAudio.count) / sr)) s d'audio)"
            )
            // Repli des répétitions dégénérées (musique/silence) avant
            // alignement/traduction — le texte brut reste journalisé.
            let collapsedJA = LiveRepetition.collapse(
                rawJA.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard let jaText = LiveClauseSelection.select(
                qwenJapanese: collapsedJA, appleJapanese: nil
            ) else {
                // ASR vide (bruit) : avancement sans cue (le spool avance,
                // la phrase suivante repart proprement).
                LiveDebug.log("ENDPOINTING(fifo) ASR vide — avancement sans cue")
                return
            }

            // Alignement : borne exacte de consommation (zéro dérive) — le
            // cue se termine à la fin du dernier mot. Repli : fin de fenêtre
            // − garde de stabilité (1,12 s).
            var cueEnd = max(
                entry.windowStart,
                entry.windowEnd - Int(LiveSemanticEndpointer.stabilityGuardSeconds * sr)
            )
            if let aligned = try? await alignerRT.align(audio: windowAudio, text: jaText),
               let lastWord = aligned.last, lastWord.startTime > 0 {
                cueEnd = min(
                    max(entry.windowStart + Int(lastWord.endTime * Float(sr)), entry.windowStart),
                    entry.windowEnd
                )
            }
            if cueEnd <= entry.windowStart { cueEnd = entry.windowEnd }
            LiveDebug.log(
                "ENDPOINTING(fifo) commit [\(String(format: "%.1f", Double(entry.windowStart) / sr))"
                + "–\(String(format: "%.1f", Double(cueEnd) / sr)) s] "
                + "JA=\"\(jaText)\""
            )

            // Traduction finale (MLX, glossaire + historique roulant K=4,
            // streaming) — la passe de qualité : la ligne était « en cours »
            // (preview) jusqu'ici ; le final la remplace.
            let isFragment = entry.forced || !LiveSemanticEndpointer.isTerminalJapanese(jaText)
            var enText: String?
            let windowStartSeconds = Double(entry.windowStart) / sr
            if !configuration.sansTraduction {
                do {
                    let translateStarted = Date()
                    let chunkCounter = OSAllocatedUnfairLock(initialState: 0)
                    let finalHistory = rolling.with {
                        Array($0.history.suffix(LiveSemanticEndpointer.historyLimit))
                    }
                    enText = try await translator.translateLive(
                        japanese: jaText,
                        glossary: glossary,
                        history: finalHistory,
                        // Filet 5 s OU clause incomplète → « ne pas compléter
                        // ni deviner ».
                        isFragment: isFragment,
                        sourceStart: windowStartSeconds,
                        sourceEnd: Double(cueEnd) / sr,
                        onChunk: { chunk in
                            if !chunk.isEmpty {
                                let n = chunkCounter.withLock { $0 += 1; return $0 }
                                LiveDebug.log("MLX chunk #\(n) (preview cumulée) = \"\(chunk)\"")
                                configuration.onLine?(chunk, false, entry.seq)
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

            // Engagement + état roulant (historique LLM, contexte ASR) — le
            // worker commit dans l'ordre (les plus anciennes d'abord), la
            // cohérence SRT et historique est préservée.
            let finalEN = enText ?? (configuration.sansTraduction ? jaText : "")
            await output.clearPreview()
            await output.commit(
                start: windowStartSeconds,
                end: Double(cueEnd) / sr,
                japanese: jaText,
                english: enText,
                show: configuration.show
            )
            if !finalEN.isEmpty {
                LiveDebug.log("FINAL onLine isFinal=true seq=\(entry.seq) EN=\"\(finalEN)\"")
                configuration.onLine?(finalEN, true, entry.seq)
            }
            rolling.with {
                $0.history.append(HighQualityAcceptedTranslationPair(
                    cueID: "live-\($0.history.count)",
                    japanese: jaText,
                    english: finalEN.isEmpty ? jaText : finalEN
                ))
                $0.history = Array($0.history.suffix(LiveSemanticEndpointer.historyLimit))
                $0.committedJA += " \(jaText)"
            }
        }

        // --- Worker de commit (consommateur de la FIFO) -------------------
        // Port WhisperASR (`consumePrototypeEndpoints`) : la boucle d'endpointing
        // STAGE les fenêtres (non bloquant), le worker les traite dans l'ordre
        // (les plus anciennes d'abord) — la passe de qualité (ASR → aligneur →
        // MLX, ~1,5–2,6 s) ne bloque jamais l'endpointing ni les previews.
        // Un échec reste en tête de file (« Audio retained — retrying oldest
        // phrase… », 2 tentatives) ; le spool n'avance que sur fenêtre
        // acceptée.
        let fifo = LiveEndpointFIFO()
        let commitWorker = Task {
            var attempts = 0
            while true {
                guard let entry = await fifo.next() else {
                    let stopping = stopLock.withLock({ $0 }) || configuration.stopRequested()
                    // Arrêt + file vide → drain terminé. Arrêt + file non vide
                    // → on draine le reste (les cues stagées ne sont pas perdus).
                    let drained = await fifo.isDrained()
                    if stopping && drained { return }
                    try? await Task.sleep(for: .milliseconds(40))
                    continue
                }
                do {
                    try await processFIFOCommit(entry)
                    await fifo.accept(entry)
                    attempts = 0
                } catch {
                    attempts += 1
                    LiveDebug.log(
                        "ENDPOINTING(fifo) Audio retained — retrying oldest phrase… "
                        + "(tentative \(attempts)) : \(error.localizedDescription)"
                    )
                    // Deux échecs sur la même fenêtre : on la libère pour
                    // débloquer la file (le PCM reste en spool, la suite suit
                    // — sémantique « retained » de WhisperASR, adaptée au live).
                    if attempts >= 2 {
                        await fifo.accept(entry)
                        attempts = 0
                    }
                    try? await Task.sleep(for: .milliseconds(250))
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
                // --- Endpointing « lâche » (WhisperASR) + commit non
                //     bloquant (FIFO) : la boucle décide et STAGE, le worker
                //     de commit exécute la passe de qualité -----------------
                guard available - lastCommit >= Int(0.5 * sr) else { continue }

                // VAD de la fenêtre (RMS, seuil partagé) : silence de fin +
                // première parole (échantillon absolu).
                let scanStart = max(lastCommit, available - Int(LivePausePlanner.maxPhraseSeconds * sr))
                let tail = capture.samples(from: scanStart, upTo: available)
                let silenceSeconds = LiveSemanticEndpointer.trailingSilenceSeconds(tail)
                let speechStart = LivePausePlanner.firstSpeechSample(samples: tail, windowStart: scanStart)

                // Fin de phrase par PONCTUATION dans le texte roulant (segment
                // Apple en mode `.apple` — défaut — ou snapshot Qwen en
                // `.mlx`) : le commit ne attend pas le silence, l'accumulation
                // s'arrête à la fin de la phrase.
                let latestText = previewTask?.previewText ?? rolling.with { $0.snapshot }
                let decision = pausePlanner.observe(
                    windowStart: lastCommit,
                    available: available,
                    trailingSilenceSeconds: silenceSeconds,
                    speechStart: speechStart,
                    latestText: latestText
                )

                // Preview roulante (non bloquante) : tant que le planner
                // n'a rien à commiter, la tâche Qwen (snapshot cumulé →
                // ligne EN Apple/MLX) travaille en parallèle — la boucle ne
                // dort jamais dessus (plus de previews affamées).
                //
                // Le snapshot démarre au début de la phrase en cours (première
                // parole après le dernier commit), PAS au dernier commit :
                // la fenêtre pousse avec la phrase (snapshot cumulé WhisperASR)
                // — l'ASR transcrit la phrase entière, pas un tronçon qu'il
                // « compléterait » par hallucination. Pas de preview sans
                // parole (l'ASR sur du silence produit du bruit).
                if decision == nil {
                    if utteranceStart == nil, let s = speechStart {
                        utteranceStart = s
                    }
                    if let s = utteranceStart {
                        let previewWork = rolling.with {
                            $0.coordinator.observe(speechStart: s, availableThrough: available, seq: phraseSeq)
                        }
                        if let work = previewWork {
                            startQwenPreviewTask(work)
                        }
                    }
                    continue
                }

                // --- Commit : STAGE dans la FIFO (non bloquant) -------------------
                // Port WhisperASR (LocalEndpointFIFO) : la boucle ne fait que
                // STAGER la fenêtre — la passe de qualité (ASR → aligneur →
                // MLX) s'exécute dans le worker de commit, dans l'ordre (les
                // plus anciennes d'abord). Le PCM reste en spool (trim borné
                // par la plus ancienne fenêtre en attente) — rien n'est perdu
                // si le worker est en retard.
                LiveDebug.log(
                    "ENDPOINTING(planner) \(decision == .forced ? "forceCut" : "pause") "
                    + "silence=\(String(format: "%.1f", silenceSeconds)) s "
                    + "(\(String(format: "%.1f", Double(available - lastCommit) / sr)) s de fenêtre) → FIFO"
                )
                let windowAudio = capture.samples(from: lastCommit, upTo: available)
                // Garde des vides : fenêtre sans parole (musique/silence) →
                // avancer sans cue — pas d'accumulation sans borne, pas de
                // texte vide au LLM.
                if LivePausePlanner.firstSpeechSample(samples: windowAudio, windowStart: lastCommit) == nil {
                    LiveDebug.log("ENDPOINTING(planner) fenêtre vide — avancement sans cue")
                    pausePlanner.reset()
                    utteranceStart = nil
                    advanceRollingState(past: lastCommit..<available)
                    lastCommit = available
                    // La phrase en cours (séquence courante) est consommée :
                    // la phrase SUIVANTE démarre à la séquence courante + 1.
                    phraseSeq += 1
                    previewTask?.markCommitted(throughSample: lastCommit, seq: phraseSeq)
                    await trimCapture(upTo: lastCommit, fifo: fifo)
                    continue
                }

                let asrContext = rolling.with {
                    LiveSemanticEndpointer.asrContextEnabled
                        ? String($0.committedJA.suffix(LiveSemanticEndpointer.asrContextCharacters))
                        : ""
                }
                let entry = LiveEndpointFIFO.Entry(
                    windowStart: lastCommit,
                    windowEnd: available,
                    forced: decision == .forced,
                    asrContext: asrContext,
                    stagedUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    seq: phraseSeq
                )
                await fifo.stage(entry)
                let stagedCount = await fifo.pendingCount()
                LiveDebug.log(
                    "ENDPOINTING(fifo) fenêtre stagée "
                    + "[\(String(format: "%.1f", Double(lastCommit) / sr))"
                    + "–\(String(format: "%.1f", Double(available) / sr)) s] "
                    + "(seq \(phraseSeq), \(stagedCount) en attente)"
                )
                // La passe de qualité (ASR → aligneur → MLX) s'exécute dans le
                // worker de commit (dans l'ordre) — la boucle et les previews
                // continuent immédiatement.
                pausePlanner.reset()
                utteranceStart = nil
                advanceRollingState(past: lastCommit..<available)
                lastCommit = available
                // La phrase ENGAGÉE porte la séquence courante ; la phrase
                // SUIVANTE démarre à la suite (les previews en retard de la
                // phrase engagée — séquence inférieure — seront jetées par la
                // superposition).
                phraseSeq += 1
                previewTask?.markCommitted(throughSample: lastCommit, seq: phraseSeq)
                await trimCapture(upTo: lastCommit, fifo: fifo)
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
                    // Capture locale (le closure @Sendable ne capture pas
                    // le `var phraseSeq` de la boucle — avertissement Swift 6).
                    let commitSeq = phraseSeq
                    enText = try await translator.translateLive(
                        japanese: jaText,
                        glossary: glossary,
                        sourceStart: startSeconds,
                        sourceEnd: endSeconds,
                        onChunk: { chunk in
                            if !chunk.isEmpty {
                                let n = chunkCounter.withLock { $0 += 1; return $0 }
                                LiveDebug.log("MLX chunk #\(n) (preview cumulée) = \"\(chunk)\"")
                                configuration.onLine?(chunk, false, commitSeq)
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
                LiveDebug.log("FINAL onLine isFinal=true seq=\(phraseSeq) EN=\"\(finalEN)\"")
                configuration.onLine?(finalEN, true, phraseSeq)
            }

            lastCommit = cut
            // L'énoncé engagé porte la séquence courante ; le suivant démarre
            // à la suite (les previews en retard de l'engagé sont jetées).
            phraseSeq += 1
            previewTask?.markCommitted(throughSample: lastCommit, seq: phraseSeq)
            if lastCommit >= Int(120 * LiveEndpointing.sampleRate) {
                capture.trim(upTo: lastCommit)
            }
        }

        // --- Drain de la FIFO (fenêtres stagées avant l'arrêt) ----------------
        // Le worker traite le reste dans l'ordre (rien n'est perdu), puis
        // termine (`isDrained`).
        //
        // Borne d'arrêt : le nombre de PCM à l'instant de l'arrêt. La
        // capture continue de tamponner pendant le drain (2,5–3 s par
        // fenêtre) — la finalisation ne couvre QUE l'audio jusqu'à cette
        // borne : pas de cue de 46 s d'audio « post-arrêt », et le
        // signalement « Terminé » est rapide.
        let stopBoundary = capture.sampleCount()
        await fifo.finishProducing()
        await commitWorker.value

        // --- Finalisation de l'audio restant (bornée à l'arrêt) ---------------
        let remaining = stopBoundary
        if useQwenFinal, let asrFinal {
            if remaining - lastCommit >= Int(0.5 * LiveEndpointing.sampleRate) {
                // Morçelage : chaque morceau (≤ 6 s) est une passe complète
                // (ASR → traduction → commit) — un cue par morceau
                // (affichage progressif de la fin), l'état roulant
                // (historique LLM + contexte ASR) est mis à jour entre les
                // morceaux.
                let chunkSize = Int(6.0 * LiveEndpointing.sampleRate)
                var cursor = lastCommit
                // Chaque morceau est une « phrase » à part : séquences
                // croissantes (la phrase en cours au moment de l'arrêt porte
                // la séquence courante).
                var drainSeq = phraseSeq
                while remaining - cursor >= Int(0.5 * LiveEndpointing.sampleRate) {
                    let end = min(cursor + chunkSize, remaining)
                    let windowAudio = capture.samples(from: cursor, upTo: end)
                    let context = rolling.with {
                        LiveSemanticEndpointer.asrContextEnabled
                            ? String($0.committedJA.suffix(LiveSemanticEndpointer.asrContextCharacters))
                            : ""
                    }
                    let rawJA = (try? await asrFinal.transcribe(
                        audio: windowAudio,
                        context: context.isEmpty ? nil : context
                    )) ?? ""
                    let collapsedJA = LiveRepetition.collapse(
                        rawJA.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    if let jaText = LiveClauseSelection.select(
                        qwenJapanese: collapsedJA,
                        appleJapanese: nil
                    ) {
                        var enText: String?
                        if !configuration.sansTraduction {
                            let finalHistory = rolling.with {
                                Array($0.history.suffix(LiveSemanticEndpointer.historyLimit))
                            }
                            enText = try? await translator.translateLive(
                                japanese: jaText,
                                glossary: glossary,
                                history: finalHistory,
                                isFragment: false,
                                sourceStart: Double(cursor) / LiveEndpointing.sampleRate,
                                sourceEnd: Double(end) / LiveEndpointing.sampleRate
                            )
                        }
                        let finalEN = enText ?? (configuration.sansTraduction ? jaText : "")
                        await output.commit(
                            start: Double(cursor) / LiveEndpointing.sampleRate,
                            end: Double(end) / LiveEndpointing.sampleRate,
                            japanese: jaText,
                            english: enText,
                            show: configuration.show
                        )
                        if !finalEN.isEmpty {
                            configuration.onLine?(finalEN, true, drainSeq)
                            drainSeq += 1
                        }
                        // État roulant entre morceaux (contexte du morceau
                        // suivant + historique LLM).
                        rolling.with {
                            $0.history.append(HighQualityAcceptedTranslationPair(
                                cueID: "live-\($0.history.count)",
                                japanese: jaText,
                                english: finalEN.isEmpty ? jaText : finalEN
                            ))
                            $0.history = Array($0.history.suffix(LiveSemanticEndpointer.historyLimit))
                            $0.committedJA += " \(jaText)"
                        }
                    }
                    cursor = end
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
            if !finalEN.isEmpty {
                configuration.onLine?(finalEN, true, phraseSeq)
            }
        }

        // --- Arrêt propre ----------------------------------------------------
        source.cancel()
        maxTask?.cancel()
        rolling.with { $0.coordinator.cancel() }
        // Attendre la fin de la tâche de preview Qwen (si en cours) — sinon
        // elle écrirait dans le coordinateur annulé / le spool en arrêt.
        await rolling.with { $0.previewTask }?.value
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
