import AppKit
import SwiftUI

// Icône dans la barre des menus (NSStatusItem) pour piloter le live sans ouvrir la
// fenêtre : démarrer/arrêter le live, afficher la superposition, ouvrir la fenêtre.
@MainActor
final class StatusBarController: NSObject {
    private var item: NSStatusItem?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init()
        setup()
    }

    private func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "captions.bubble",
            accessibilityDescription: "MlxTranslate — live"
        )
        item.button?.toolTip = "MlxTranslate — sous-titres live"

        let menu = NSMenu()
        menu.addItem(makeItem("Démarrer le live") { [weak self] in
            self?.model?.startLive()
        })
        menu.addItem(makeItem("Arrêter le live") { [weak self] in
            self?.model?.stopLive()
        })
        menu.addItem(.separator())
        menu.addItem(makeItem("Afficher la superposition") { [weak self] in
            self?.model?.toggleOverlay()
        })
        menu.addItem(makeItem("Ouvrir la fenêtre") { [weak self] in
            self?.model?.openMainWindow()
        })
        menu.addItem(.separator())
        menu.addItem(makeItem("Quitter") {
            NSApp.terminate(nil)
        })
        item.menu = menu
        self.item = item
    }

    // Item de menu qui exécute une action MainActor (la fermeture de menu est sur le
    // thread principal).
    private func makeItem(_ title: String, _ action: @MainActor @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? (@MainActor () -> Void) else { return }
        MainActor.assumeIsolated { action() }
    }
}
