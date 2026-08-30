import AppKit
import MlxTranslate

/// Superposition de sous-titres live : une NSPanel sans bordure, transparente,
/// flottante (au-dessus des autres fenêtres) et non-activante (ne vole pas la focus),
/// **déplaçable** (isMovableByWindowBackground) — style « barre YouTube ». Détachée de
/// la fenêtre principale ; sa position est mémorisée (UserDefaults).
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let positionKey = "mlxtranslate.overlay.position"

    override init() {
        super.init()
        build()
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let content = RoundedBackgroundView()
        content.wantsLayer = true

        label.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
        ])

        panel.contentView = content
        panel.delegate = self
        self.panel = panel
    }

    func show() {
        guard let panel else { return }
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Met à jour la barre avec le texte EN courant. La preview (EN en cours de
    /// traduction) s'affiche en atténué ; le final s'affiche en blanc plein.
    func set(text: String, isFinal: Bool) {
        LiveDebug.log("SUPERPOSITION set isFinal=\(isFinal) text=\"\(text)\"")
        label.stringValue = text
        label.textColor = isFinal ? .white : NSColor.white.withAlphaComponent(0.65)
        if text.isEmpty {
            hide()
        } else {
            show()
        }
    }

    /// Convenience : affiche un final.
    func update(_ text: String) {
        set(text: text, isFinal: true)
    }

    // Position mémorisée ; sinon bas-centre de l'écran principal.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let size = panel.frame.size
        if let saved = UserDefaults.standard.string(forKey: positionKey),
           let (x, y) = Self.parse(saved) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let vis = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 40))
        }
    }

    private static func parse(_ s: String) -> (CGFloat, CGFloat)? {
        let p = s.components(separatedBy: ",")
        guard p.count == 2, let x = Double(p[0]), let y = Double(p[1]) else { return nil }
        return (CGFloat(x), CGFloat(y))
    }

    // Mémorise la position quand l'utilisateur déplace le panel.
    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.frame.origin != .zero else { return }
        let o = panel.frame.origin
        UserDefaults.standard.set("\(Int(o.x)),\(Int(o.y))", forKey: positionKey)
    }
}

/// Fond arrondi semi-transparent (couche, pas de masque).
final class RoundedBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
    }
}
