import Foundation
import SwiftUI
import os
@testable import MlxTranslate

// Drapeau d'arrêt du live (thread-safe) : la boucle du moteur live le consulte à
// chaque tour ; le bouton/menu « Arrêter » le lève.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func request() { lock.lock(); flag = true; lock.unlock() }
    func requested() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}

/// Préchargement des modèles du live au lancement de l'app (GUI) :
/// ASR (Qwen3-ASR 1.7B), aligneur, traducteur EN (qwen3-4b — défaut du
/// live) et Apple Translation (réchauffée, ~250 ms) se chargent en arrière-
/// plan. `startLive` RÉUTILISE ces instances (les gardes d'idempotence de
/// `prepare`/`configure` évitent tout double chargement) — le live démarre
/// en quelques secondes au lieu de ~30–40 s de chargement. Les instances
/// sont exposées immédiatement (préparation en vol) : si le live démarre
/// pendant le chargement, le `prepare` du moteur s'empile derrière sur
/// l'actor et saute — jamais deux modèles chargés en mémoire.
@available(macOS 26.4, *)
@MainActor
final class LiveModelPreloader {
    static let shared = LiveModelPreloader()
    private init() {}

    private(set) var asr: Qwen3ASRFinalRuntime?
    private(set) var aligner: Qwen3AlignerRuntime?
    private(set) var translator: LocalMLXTranslator?
    private(set) var translation: AppleTranslationService?
    private var started = false

    /// Démarre le préchargement en arrière-plan (une seule fois).
    func start() {
        guard !started else { return }
        started = true
        // Instances créées maintenant (préparation en vol) — réutilisables
        // immédiatement par `startLive`, même avant la fin du chargement.
        let asr = Qwen3ASRFinalRuntime()
        let aligner = Qwen3AlignerRuntime()
        let translator = LocalMLXTranslator(candidate: .qwen3_4B)
        let translation = AppleTranslationService()
        self.asr = asr
        self.aligner = aligner
        self.translator = translator
        self.translation = translation
        Task { [weak self] in
            // Quatre chargements en parallèle (actors indépendants) — le plus
            // lent (ASR, ~20 s) fixe la durée ; UI non bloquée (MainActor en pause).
            async let asrLoad: Void = try asr.prepare(progress: { _, _ in })
            async let alignerLoad: Void = try aligner.prepare(progress: { _, _ in })
            async let translatorLoad: Void = try translator.prepare(progress: { _, _ in })
            async let translationLoad: Void = try translation.configure(sourceLocale: "ja")
            do {
                _ = try await (asrLoad, alignerLoad, translatorLoad, translationLoad)
            } catch {
                MlxTranslate.LiveDebug.log("Préchargement live : \(error.localizedDescription)")
            }
            await MainActor.run { self?.preloadFinished() }
        }
    }

    private func preloadFinished() {
        // Signal de journalisation (les instances sont déjà exposées).
        MlxTranslate.LiveDebug.log("Préchargement live terminé (ASR + aligneur + qwen3-4b + Apple Translation)")
    }
}

// Modèle partagé de l'app (fenêtre + barre des menus). Isolé au MainActor ; les
// mutations de @Published se font sur le thread principal.
@MainActor
final class AppModel: ObservableObject {
    // MARK: Offline
    @Published var offlineURL: URL?
    @Published var offlineDoTranslate = true
    @Published var offlineModel: LocalMLXTranslator.Candidate = .productDefault
    @Published var offlineRunning = false
    @Published var offlineLog = ""
    @Published var offlineResultURL: URL?

    // MARK: Live
    @Published var liveApp: String = ""
    @Published var liveApps: [CaptureApp] = []
    /// Modèle EN du live : qwen3-4b par défaut (testé : qualité supérieure
    /// au 1.7b, sans ralentissement ressenti ; adapté aux finaux live) ;
    /// 8b/1.7b/gemma restent disponibles (le défaut offline reste qwen3-8b).
    @Published var liveModel: LocalMLXTranslator.Candidate = .qwen3_4B
    /// Niveau final ASR (qwenja par défaut / voxtral legacy).
    @Published var liveASR: LiveFinalASR = .productDefault
    /// Pseudo-live Qwen (snapshots roulants de la clause en cours) —
    /// actif uniquement en mode qwenja.
    @Published var livePseudoLive = true
    /// Cadence des snapshots cumulatifs (1/2/3 s) — prise en compte au
    /// démarrage du live (redémarrage requis pour changer la valeur).
    /// Persistée (UserDefaults, comme la position de la superposition).
    @Published var liveCadence: QwenPseudoLiveCadence = .productDefault {
        didSet {
            UserDefaults.standard.set(liveCadence.rawValue, forKey: Self.cadenceDefaultsKey)
        }
    }
    private static let cadenceDefaultsKey = "mlxtranslate.live.cadence"
    /// Source de la ligne roulante (mode Qwen) : Apple basse latence (défaut,
    /// ~250 ms chaud) ou MLX streaming (lente, glossaire). Persistée.
    @Published var livePreviewMode: LivePreviewMode = .productDefault {
        didSet {
            UserDefaults.standard.set(livePreviewMode.rawValue, forKey: Self.previewModeDefaultsKey)
        }
    }
    private static let previewModeDefaultsKey = "mlxtranslate.live.previewMode"
    @Published var liveDelay: VoxtralTranscriptionDelay = .milliseconds960
    @Published var liveRunning = false
    @Published var liveStatus = ""

    // MARK: Superposition
    let overlay = OverlayController()
    @Published var overlayVisible = false

    private var liveTask: Task<Void, Never>?
    private var offlineTask: Task<Void, Never>?
    private let liveStop = StopFlag()

    init() {
        refreshApps()
        // Cadence des snapshots (persistance GUI, comme la position de la
        // superposition) — valeur par défaut : 2 s (productDefault).
        if let raw = UserDefaults.standard.object(forKey: Self.cadenceDefaultsKey) as? Int,
           let cadence = QwenPseudoLiveCadence(rawValue: raw) {
            liveCadence = cadence
        }
        // Source de la ligne roulante (persistance GUI) — défaut : Apple
        // basse latence (LivePreviewMode.productDefault).
        if let raw = UserDefaults.standard.object(forKey: Self.previewModeDefaultsKey) as? String,
           let mode = LivePreviewMode(rawValue: raw) {
            livePreviewMode = mode
        }
        // Préchargement des modèles du live (arrière-plan) : le premier
        // « Live » démarre sans attendre le chargement MLX/ASR.
        if #available(macOS 26.4, *) {
            LiveModelPreloader.shared.start()
        }
        let env = ProcessInfo.processInfo.environment
        // Pré-sélection de l'app live (test / script).
        if let app = env["MLXTRANSLATE_GUI_LIVE_APP"] {
            liveApp = app
        }
        // Test visuel de la barre de superposition (sans lancer de live) :
        // deux finaux — un court, un long (enveloppe + rétrécissement de
        // police + hauteur dynamique) — pour vérifier la fenêtre de 2 lignes.
        if env["MLXTRANSLATE_GUI_TEST_OVERLAY"] != nil {
            overlay.commitFinal("The team finished the last part of the quarterly report an hour ago, and the manager asked everyone to stay until the numbers have been double checked against the client spreadsheet before we can send the final version over tomorrow morning")
            overlay.commitFinal("I promised to pick up the kids from soccer practice at five, then drive home before it starts to rain, so I will be late to dinner unless someone can cover the first part of the evening cleanup for me this week")
        }
        // Auto-démarrage du live (test / script) : après un court délai pour laisser
        // l'app se poser.
        if env["MLXTRANSLATE_GUI_AUTO_START_LIVE"] != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run { self?.startLive() }
            }
        }
    }

    // MARK: - Offline --------------------------------------------------------

    /// Lance la chaîne offline sur le média déposé. « Traduire » actif → chaîne
    /// complète (ASR → alignement → parlants → traduction EN). Sinon → sans traduction.
    func runOffline() {
        guard let url = offlineURL, !offlineRunning else { return }
        let doTranslate = offlineDoTranslate
        let model = offlineModel
        offlineRunning = true
        offlineLog = "Lancement : \(url.lastPathComponent)\n"
        offlineTask = Task {
            do {
                let command = Command(verb: .finale, video: url, model: model)
                if doTranslate {
                    try await Pipeline.run(command)
                } else {
                    try await Pipeline.transcribe(command)
                    try await Pipeline.align(command)
                    try await Pipeline.diarize(command)
                }
                let base = url.deletingPathExtension().lastPathComponent
                let ext = doTranslate ? "EN" : "JA"
                await MainActor.run {
                    self.offlineLog += doTranslate
                        ? "Chaîne terminée (ASR → alignement → parlants → traduction EN).\n"
                        : "Chaîne terminée (ASR → alignement → parlants), sans traduction.\n"
                    self.offlineResultURL = url.deletingLastPathComponent()
                        .appendingPathComponent("\(base) (\(ext)).srt")
                }
            } catch {
                await MainActor.run {
                    self.offlineLog += "Erreur : \(error.localizedDescription)\n"
                }
            }
            await MainActor.run { self.offlineRunning = false }
        }
    }

    // MARK: - Live -----------------------------------------------------------

    /// Liste les applications capturables (ScreenCaptureKit) et pré-sélectionne la première.
    func refreshApps() {
        Task {
            guard #available(macOS 26.4, *) else { return }
            let apps = (try? await AppCapture.listApps()) ?? []
            await MainActor.run {
                self.liveApps = apps
                if self.liveApp.isEmpty, let first = apps.first {
                    self.liveApp = first.name
                }
            }
        }
    }

    /// Démarre le live : capture l'audio de `liveApp`, alimente la superposition
    /// (EN preview → final) et écrit le SRT live. La tâche se termine à l'arrêt
    /// (bouton/menu) ou à l'échec du flux SCK.
    func startLive() {
        guard !liveRunning, !liveApp.isEmpty else { return }
        let app = liveApp
        let model = liveModel
        let delay = liveDelay
        let asrMode = liveASR
        let pseudoLive = livePseudoLive
        let cadence = liveCadence
        let outURL = Pipeline.homeURL
            .appendingPathComponent("live-\(Int(Date().timeIntervalSince1970)).srt")
        liveRunning = true
        liveStatus = "Démarrage…"
        liveStop.reset()
        overlayVisible = true
        overlay.show()

        liveTask = Task {
            do {
                guard #available(macOS 26.4, *) else {
                    await self.setLiveStatus("Le mode live nécessite macOS 26.4 ou plus récent.")
                    return
                }
                var config = LiveEngineConfiguration(
                    app: app,
                    preview: true,
                    model: model,
                    glossaryURL: Pipeline.defaultGlossaryURL,
                    delay: delay,
                    outputURL: outURL
                )
                // Niveau final ASR + pseudo-live (snapshots roulants de la
                // clause en cours, cadence configurable 1/2/3 s — moteur
                // qwenja uniquement).
                config.liveASR = asrMode
                config.pseudoLive = pseudoLive
                config.pseudoLiveCadence = cadence
                // Source de la ligne roulante (Apple basse latence par défaut).
                config.previewMode = livePreviewMode
                // Modèles préchargés au lancement (idempotence des `prepare` :
                // pas de double chargement même si le préchargement est encore
                // en cours — le `prepare` du moteur s'empile et saute).
                let preloader = LiveModelPreloader.shared
                config.preloadedASR = preloader.asr
                config.preloadedAligner = preloader.aligner
                // Le traducteur préchargé est le défaut live (qwen3-4b) —
                // on ne le réutilise que si le modèle sélectionné est le même.
                config.preloadedTranslator = (model == .qwen3_4B) ? preloader.translator : nil
                MlxTranslate.LivePreloadedTranslation.service = preloader.translation
                // Lignes de la superposition (2 lignes, `LiveOverlayState`) :
                // l'APERÇU roulant (Apple basse latence + snapshots Qwen)
                // reste en bas (blanc) ; le FINAL EN stable s'engage et fait
                // défiler la fenêtre (2 finaux max, le plus ancien s'estompe).
                config.onApplePreview = { [weak weakModel = self] text, _ in
                    MlxTranslate.LiveDebug.log("onApplePreview text=\"\(text)\"")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            weakModel?.overlay.showPreview(text)
                        }
                    }
                }
                config.onLine = { [weak weakModel = self] text, isFinal in
                    MlxTranslate.LiveDebug.log("onLine isFinal=\(isFinal) text=\"\(text)\"")
                    // Les chunks MLX (isFinal=false) n'alimentent que stderr ; seul le
                    // final engagé (isFinal=true) s'empile dans les lignes stables.
                    guard isFinal else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            weakModel?.overlay.commitFinal(text)
                        }
                    }
                }
                // Arrêt externe (bouton / menu « Arrêter »).
                config.stopRequested = { [stop = self.liveStop] in stop.requested() }

                await self.setLiveStatus("Live en cours : « \(app) »")
                try await LiveEngine(configuration: config).run()
                await self.setLiveStatus("Terminé : \(outURL.lastPathComponent) (~/.mlxtranslate)")
            } catch {
                await self.setLiveStatus("Erreur : \(error.localizedDescription)")
            }
            await self.finishLive()
        }
    }

    /// Demande l'arrêt du live (la boucle s'arrête au tour suivant).
    func stopLive() {
        guard liveRunning else { return }
        liveStop.request()
        liveStatus = "Arrêt en cours…"
    }

    private func finishLive() {
        liveRunning = false
        liveStatus = "À l'arrêt"
        overlayVisible = false
        overlay.reset()
    }

    private func setLiveStatus(_ s: String) {
        liveStatus = s
    }

    // MARK: - Superposition --------------------------------------------------

    func toggleOverlay() {
        overlayVisible.toggle()
        if overlayVisible {
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
