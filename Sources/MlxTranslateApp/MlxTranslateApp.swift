import SwiftUI
import AppKit

// App GUI de MlxTranslate : une fine couche sur la librairie `MlxTranslate`
// (pipeline offline + capture live). Fenêtre principale (onglets Offline / Live)
// + une superposition de sous-titres flottante et déplaçable (NSPanel) + une icône
// dans la barre des menus (NSStatusItem) pour piloter le live.

// Coordinateur : possède le modèle (fenêtre) et le contrôleur de la barre des menus.
@MainActor
final class AppCoordinator: ObservableObject {
    let model: AppModel
    let statusBar: StatusBarController

    init() {
        let model = AppModel()
        self.model = model
        self.statusBar = StatusBarController(model: model)
    }
}

@main
struct MlxTranslateApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(model: coordinator.model)
                .frame(minWidth: 540, minHeight: 400)
        }
        .commands {
            CommandMenu("Superposition") {
                Button(coordinator.model.overlayVisible ? "Masquer la superposition" : "Afficher la superposition") {
                    coordinator.model.toggleOverlay()
                }
            }
            CommandGroup(replacing: .help) {
                Button("À propos de MlxTranslate") { coordinator.model.showAbout() }
            }
        }
    }
}
