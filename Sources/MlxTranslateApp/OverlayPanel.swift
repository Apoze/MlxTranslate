import AppKit
import MlxTranslate

/// Superposition de sous-titres live : une NSPanel sans bordure, transparente,
/// flottante (au-dessus des autres fenêtres) et non-activante (ne vole pas la focus),
/// **déplaçable** (isMovableByWindowBackground) — style « barre YouTube ». Détachée de
/// la fenêtre principale ; sa position est mémorisée (UserDefaults).
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    // Fenêtre défilante : les 2 derniers FINAUX (stables, blanc) en haut, l'INSTANTANÉ
    // (preview basse latence, atténué) toujours en bas. Quand un final s'engage, il
    // s'empile en haut et la plus ancienne ligne défile hors de la fenêtre.
    private let stableTopLabel = NSTextField(labelWithString: "")   // final le plus ancien (atténué, « défile »)
    private let stableMidLabel = NSTextField(labelWithString: "")   // final le plus récent (blanc plein)
    private let previewLabel = NSTextField(labelWithString: "")     // instantané (atténué)
    private var stableLines: [String] = []   // borné à 2, plus récent en dernier
    private var previewText = ""
    private let positionKey = "mlxtranslate.overlay.position"
    private static let stableMax = 2

    override init() {
        super.init()
        build()
    }

    private func makeLabel() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        l.textColor = .white
        l.alignment = .center
        l.maximumNumberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 96),
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
        // 3 lignes de 32 px (96 au total) : stables en haut, instantané en bas.
        for l in [stableTopLabel, stableMidLabel, previewLabel] {
            content.addSubview(l)
        }
        stableTopLabel.textColor = .white.withAlphaComponent(0.6)   // le plus ancien : s'estompe
        previewLabel.textColor = .white.withAlphaComponent(0.65)    // instantané : atténué
        NSLayoutConstraint.activate([
            stableTopLabel.topAnchor.constraint(equalTo: content.topAnchor),
            stableTopLabel.heightAnchor.constraint(equalToConstant: 32),
            stableMidLabel.topAnchor.constraint(equalTo: stableTopLabel.bottomAnchor),
            stableMidLabel.heightAnchor.constraint(equalToConstant: 32),
            previewLabel.topAnchor.constraint(equalTo: stableMidLabel.bottomAnchor),
            previewLabel.heightAnchor.constraint(equalToConstant: 32),
            stableTopLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stableMidLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            previewLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stableTopLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 920),
            stableMidLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 920),
            previewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 920),
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

    /// Ligne INSTANTANÉ (bas, atténué) : la preview Apple basse latence, toujours
    /// affichée pendant la parole. N'affecte pas les lignes stables.
    func showInstant(text: String) {
        LiveDebug.log("SUPERPOSITION instantané text=\"\(text)\"")
        previewText = text
        previewLabel.stringValue = text
        if !text.isEmpty { show() }
    }

    /// Un FINAL stable (MLX) s'engage : il s'empile en haut (blanc), la plus ancienne
    /// ligne défile hors de la fenêtre (2 stables max). L'instantané (bas) continue.
    func commitStable(text: String) {
        LiveDebug.log("SUPERPOSITION final engagé text=\"\(text)\"")
        guard !text.isEmpty else { return }
        stableLines.append(text)
        if stableLines.count > Self.stableMax { stableLines.removeFirst() }
        updateStableLabels()
        show()
    }

    /// Alimente la fenêtre défilante (point d'entrée unifié, utilisé par le pré-remplissage
    /// de test et l'effacement).
    /// - `isFinal == false` : l'INSTANTANÉ (bas, atténué).
    /// - `isFinal == true` : un FINAL stable s'engage (haut) ; `text` vide → réinitialise
    ///   la fenêtre et masque la barre.
    func set(text: String, isFinal: Bool) {
        if isFinal {
            if text.isEmpty { reset() } else { commitStable(text: text) }
        } else {
            showInstant(text: text)
        }
    }

    /// Convenience : engage un final.
    func update(_ text: String) {
        commitStable(text: text)
    }

    /// Vide la fenêtre (stables + instantané) et masque la barre.
    func reset() {
        stableLines.removeAll()
        previewText = ""
        stableTopLabel.stringValue = ""
        stableMidLabel.stringValue = ""
        previewLabel.stringValue = ""
        hide()
    }

    // Réaffiche les 2 lignes stables : top = le plus ancien (s'estompe),
    // middle = le plus récent (blanc plein).
    private func updateStableLabels() {
        stableTopLabel.stringValue = stableLines.count >= 2 ? stableLines[0] : ""
        stableMidLabel.stringValue = stableLines.last ?? ""
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
