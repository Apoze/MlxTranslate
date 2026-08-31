import AppKit
@testable import MlxTranslate

/// Superposition de sous-titres live : une NSPanel sans bordure,
/// transparente, flottante (au-dessus des autres fenêtres) et
/// non-activante (ne vole pas le focus), **déplaçable**
/// (isMovableByWindowBackground) — style « barre YouTube ». Détachée de
/// la fenêtre principale ; sa position est mémorisée (UserDefaults).
///
/// Contenu (barre de 3 lignes, pilotée par la machine d'état pure
/// `LiveOverlayState`) :
/// - **bas (ligne live)** : la ligne en cours — l'aperçu roulant de la
///   clause en formation, puis le stream du final MLX (les chunks
///   cumulatifs la remplacent sur place : la ligne s'améliore au fur et
///   à mesure, sans saut de source) ;
/// - **haut (2 lignes finalisées)** : les finaux stables les plus
///   récents ; à chaque engagement, le plus ancien défile hors de la
///   barre (défilement automatique vers le haut).
///
/// Chaque ligne : UNE ligne visuelle (sans enveloppement), police
/// rétrécie automatiquement 20 → 14 pt pour tenir, troncature dure avec
/// « … ». Hauteur du panneau CONSTANTE (96 px = 3 × 32 pt), arrimée en
/// bas (le bas du panneau ne bouge jamais).
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var state = LiveOverlayState()
    private var topLabel: NSTextField!     // finalisé le plus ancien
    private var midLabel: NSTextField!     // finalisé le plus récent
    private var bottomLabel: NSTextField!  // ligne live
    // Par défaut, la superposition est centrée horizontalement (barre de
    // sous-titres classique). Le fond est déplaçable (clic + glisser) : la
    // position complète choisie est mémorisée ; l'inset vertical l'est aussi,
    // pour le chemin « par défaut ».
    private static let positionKey = "mlxtranslate.overlay.position"
    private static let bottomInsetKey = "mlxtranslate.overlay.bottomInset"
    private static let panelWidth: CGFloat = 960
    private static let contentWidth: CGFloat = 920
    private static let lineHeight: CGFloat = 32

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
        (l.cell as? NSTextFieldCell)?.wraps = false
        (l.cell as? NSTextFieldCell)?.isScrollable = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func build() {
        topLabel = makeLabel()
        midLabel = makeLabel()
        bottomLabel = makeLabel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: LiveOverlayState.barHeight),
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
        // Largeur verrouillée : sans cette contrainte, une fenêtre borderless
        // redimensionnée à la taille « fitting » du contenu (≈ 0 avec des
        // labels vides) s'effondrerait à quelques points de large.
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: Self.panelWidth).isActive = true
        content.addSubview(topLabel)
        content.addSubview(midLabel)
        content.addSubview(bottomLabel)
        // Les 3 labels empilés, arrimés EN BAS : le label live au bord
        // inférieur du panneau, les finalisés au-dessus — la hauteur de la
        // barre est constante, la géométrie est fixée une fois pour toutes.
        NSLayoutConstraint.activate([
            bottomLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            midLabel.bottomAnchor.constraint(equalTo: bottomLabel.topAnchor),
            midLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            topLabel.bottomAnchor.constraint(equalTo: midLabel.topAnchor),
            topLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bottomLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            midLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            topLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            bottomLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            midLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            topLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight),
        ])

        panel.contentView = content
        panel.delegate = self
        self.panel = panel
    }

    // MARK: - Contenu

    /// Aperçu roulant (clause en cours) : ligne live (sur place) ; pendant
    /// le stream d'un final, l'aperçu est stagé (il prend la ligne live au
    /// prochain engagement).
    func showPreview(_ text: String) {
        LiveDebug.log("SUPERPOSITION aperçu text=\"\(text)\"")
        state.showPreview(text)
        applyLayout()
        if state.hasContent { show() }
    }

    /// Chunk du stream de final MLX (cumulatif) : remplace la ligne live
    /// sur place — la ligne « en cours » s'améliore chunk par chunk.
    func streamingChunk(_ text: String) {
        LiveDebug.log("SUPERPOSITION stream final text=\"\(text)\"")
        state.streamingChunk(text)
        applyLayout()
        show()
    }

    /// Un final EN stable s'engage : prend le slot du haut, le plus ancien
    /// défile hors de la barre, la ligne live est vidée (ou reprise par la
    /// preview stagée de la phrase suivante).
    func commitFinal(_ text: String) {
        LiveDebug.log("SUPERPOSITION final engagé text=\"\(text)\"")
        state.commitFinal(text)
        applyLayout()
        show()
    }

    /// Vide la barre (finalisés + ligne live + stagé) et masque la superposition.
    func reset() {
        state.reset()
        applyLayout()
        hide()
    }

    // MARK: - Compat (pré-remplissage de test, effacement)

    /// Point d'entrée unifié.
    /// - `isFinal == false` : l'aperçu roulant (ligne live) ;
    /// - `isFinal == true` : un final s'engage ; `text` vide → réinitialise
    ///   la barre et masque la superposition.
    func set(text: String, isFinal: Bool) {
        if isFinal {
            if text.isEmpty { reset() } else { commitFinal(text) }
        } else {
            showPreview(text)
        }
    }

    /// Convenience : engage un final.
    func update(_ text: String) {
        commitFinal(text)
    }

    // MARK: - Affichage

    func show() {
        guard let panel else { return }
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
        LiveDebug.log("SUPERPOSITION affiché frame=\(panel.frame)")
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Applique la mise en page calculée par `LiveOverlayState` : textes et
    /// polices des 3 slots (la hauteur du panneau est constante).
    private func applyLayout() {
        let l = state.layout
        topLabel.stringValue = l.lines[0]
        midLabel.stringValue = l.lines[1]
        bottomLabel.stringValue = l.lines[2]
        topLabel.font = NSFont.systemFont(ofSize: l.fonts[0], weight: .semibold)
        midLabel.font = NSFont.systemFont(ofSize: l.fonts[1], weight: .semibold)
        bottomLabel.font = NSFont.systemFont(ofSize: l.fonts[2], weight: .semibold)
        LiveDebug.log(
            "SUPERPOSITION layout [\"\(l.lines[0].prefix(24))\" \(l.fonts[0])pt | "
            + "\"\(l.lines[1].prefix(24))\" \(l.fonts[1])pt | "
            + "\"\(l.lines[2].prefix(24))\" \(l.fonts[2])pt]"
        )
    }

    // Position du panneau :
    // - Si l'utilisateur l'a déplacé (position complète mémorisée), on la
    //   respecte — le fond est déplaçable (isMovableByWindowBackground).
    // - Sinon, par défaut : centré horizontalement sur l'écran principal, avec
    //   un inset vertical (mémorisé, sinon 40 pt). La hauteur étant
    //   constante, le bas du panneau est arrimé à l'inset.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey),
           let (x, y) = Self.parse(saved) {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            let sf = screen.frame
            let x = sf.minX + (sf.width - size.width) / 2
            let y = sf.minY + Self.bottomInset()
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    /// Inset vertical (distance bas du panneau → bas de l'écran) pour le
    /// chemin « par défaut ». Défaut 40 pt.
    private static func bottomInset() -> CGFloat {
        if let v = UserDefaults.standard.object(forKey: bottomInsetKey) as? Double {
            return max(0, CGFloat(v))
        }
        return 40
    }

    /// Position complète « x,y » (mémorisée quand l'utilisateur déplace le
    /// panneau).
    private static func parse(_ s: String) -> (CGFloat, CGFloat)? {
        let p = s.components(separatedBy: ",")
        guard p.count == 2, let x = Double(p[0]), let y = Double(p[1]) else { return nil }
        return (CGFloat(x), CGFloat(y))
    }

    // Mémorise la position complète quand l'utilisateur déplace le panneau
    // (fond déplaçable). On met aussi l'inset vertical à jour, pour le chemin
    // « par défaut » (centré).
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        let o = panel.frame.origin
        UserDefaults.standard.set("\(Int(o.x)),\(Int(o.y))", forKey: Self.positionKey)
        if let screen = screenContaining(panel) {
            UserDefaults.standard.set(Double(max(0, o.y - screen.frame.minY)), forKey: Self.bottomInsetKey)
        }
    }

    /// L'écran contenant le centre du panneau.
    private func screenContaining(_ panel: NSPanel) -> NSScreen? {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.main ?? NSScreen.screens.first
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
