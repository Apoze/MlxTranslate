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
    @Published var liveModel: LocalMLXTranslator.Candidate = .productDefault
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
        let env = ProcessInfo.processInfo.environment
        // Pré-sélection de l'app live (test / script).
        if let app = env["MLXTRANSLATE_GUI_LIVE_APP"] {
            liveApp = app
        }
        // Test visuel de la barre de superposition (sans lancer de live).
        if env["MLXTRANSLATE_GUI_TEST_OVERLAY"] != nil {
            overlay.set(text: "Bonjour, ceci est la barre de sous-titres.", isFinal: true)
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
                // Superposition : le texte EN courant (preview en streaming, final engagé).
                config.onLine = { [weak weakModel = self] text, isFinal in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            weakModel?.overlay.set(text: text, isFinal: isFinal)
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
        overlay.set(text: "", isFinal: true)
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
