import AppKit
@testable import MlxTranslate

/// Superposition de sous-titres live : une NSPanel sans bordure, transparente,
/// flottante (au-dessus des autres fenêtres) et non-activante (ne vole pas la
/// focus), **déplaçable** (isMovableByWindowBackground) — style « barre YouTube ».
/// Détachée de la fenêtre principale ; sa position est mémorisée (UserDefaults).
///
/// Contenu (2 lignes, pilotées par la machine d'état pure `LiveOverlayState`) :
/// - **haut (atténué, alpha 0,6)** : le final stable précédent ;
/// - **bas (blanc)** : l'aperçu roulant de la clause en cours, ou le final
///   le plus récent après commit.
///
/// Chaque ligne enveloppe jusqu'à 3 lignes, la police rétrécit 20 → 14 pt
/// pour tenir, troncature à 250 caractères. Hauteur dynamique 64…192 px,
/// **arrimée en bas** : le bas du panneau reste fixe, le contenu pousse vers
/// le haut (hystérésis : la hauteur ne fait que croître entre aperçus,
/// recomputation complète à chaque commit final).
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var state = LiveOverlayState()
    private var topLabel: NSTextField!    // final précédent (atténué)
    private var bottomLabel: NSTextField! // courant (blanc)
    private var topHeight: NSLayoutConstraint!
    private var bottomHeight: NSLayoutConstraint!
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
        l.maximumNumberOfLines = 3
        l.lineBreakMode = .byWordWrapping
        (l.cell as? NSTextFieldCell)?.wraps = true
        (l.cell as? NSTextFieldCell)?.isScrollable = false
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func build() {
        topLabel = makeLabel()
        bottomLabel = makeLabel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 64),
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
        // labels vides) s'effondrait à quelques points de large.
        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: Self.panelWidth).isActive = true
        content.addSubview(topLabel)
        content.addSubview(bottomLabel)
        topLabel.textColor = .white.withAlphaComponent(0.6)   // final précédent : s'estompe
        // Bloc arrimé EN BAS : le label bas au bord inférieur du panneau, le
        // haut au-dessus — quand la hauteur croît, le bas reste fixe.
        NSLayoutConstraint.activate([
            bottomLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            topLabel.bottomAnchor.constraint(equalTo: bottomLabel.topAnchor),
            topLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            bottomLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            topLabel.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        topHeight = topLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        bottomHeight = bottomLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight)
        NSLayoutConstraint.activate([topHeight, bottomHeight])

        panel.contentView = content
        panel.delegate = self
        self.panel = panel
    }

    // MARK: - Contenu

    /// Aperçu roulant (clause en cours) : ligne basse ; la hauteur ne fait
    /// que croître (hystérésis live).
    func showPreview(_ text: String) {
        LiveDebug.log("SUPERPOSITION aperçu text=\"\(text)\"")
        state.showPreview(text)
        applyLayout()
        if state.hasContent { show() }
    }

    /// Un final EN stable s'engage : défile la fenêtre de 2 lignes et
    /// recompute la mise en page en totalité (la hauteur peut rétrécir).
    func commitFinal(_ text: String) {
        LiveDebug.log("SUPERPOSITION final engagé text=\"\(text)\"")
        state.commitFinal(text)
        applyLayout()
        show()
    }

    /// Vide la fenêtre (finaux + aperçu), remet la hauteur au minimum et
    /// masque la barre.
    func reset() {
        state.reset()
        topLabel.stringValue = ""
        bottomLabel.stringValue = ""
        topLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        bottomLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        topLabel.maximumNumberOfLines = 1
        bottomLabel.maximumNumberOfLines = 1
        topHeight.constant = Self.lineHeight
        bottomHeight.constant = Self.lineHeight
        setPanelHeight(64)
        hide()
    }

    // MARK: - Compat (pré-remplissage de test, effacement)

    /// Point d'entrée unifié.
    /// - `isFinal == false` : l'aperçu roulant (bas).
    /// - `isFinal == true` : un final s'engage (haut) ; `text` vide → réinitialise
    ///   la fenêtre et masque la barre.
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
        // Log fiable : après orderFront + résolution du graphe, le frame des
        // labels est celui réellement rendu à l'écran.
        panel.contentView?.layoutSubtreeIfNeeded()
        LiveDebug.log("SUPERPOSITION affiché frame=\(panel.frame) topLabel=\(topLabel.frame) bottomLabel=\(bottomLabel.frame)")
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Applique la mise en page calculée par `LiveOverlayState` : polices,
    /// lignes, hauteurs des labels et hauteur du panneau (bas fixe).
    private func applyLayout() {
        let l = state.layout
        topLabel.stringValue = l.topText
        bottomLabel.stringValue = l.bottomText
        topLabel.font = NSFont.systemFont(ofSize: l.topFont, weight: .semibold)
        bottomLabel.font = NSFont.systemFont(ofSize: l.bottomFont, weight: .semibold)
        topLabel.maximumNumberOfLines = max(1, l.topLines)
        bottomLabel.maximumNumberOfLines = max(1, l.bottomLines)
        topHeight.constant = CGFloat(l.topLines) * Self.lineHeight
        bottomHeight.constant = CGFloat(l.bottomLines) * Self.lineHeight
        // Résout le sous-arbre AVANT de redimensionner le panneau : la
        // fenêtre borderless suit la taille fitting du contenu, il faut que
        // celle-ci soit déjà la bonne pour que le repositionnement bas fixe
        // parte de la bonne géométrie.
        panel?.contentView?.layoutSubtreeIfNeeded()
        setPanelHeight(l.panelHeight)
        panel?.contentView?.layoutSubtreeIfNeeded()
        LiveDebug.log("SUPERPOSITION layout top[\"\(l.topText.prefix(20))\" \(l.topFont)pt \(l.topLines)L] bottom[\"\(l.bottomText.prefix(20))\" \(l.bottomFont)pt \(l.bottomLines)L] topLabel=\(topLabel.frame) bottomLabel=\(bottomLabel.frame) content=\(String(describing: panel?.contentView?.frame))")
    }

    /// Change la hauteur du panneau en gardant le BAS fixe (arrimage bas :
    /// l'origine — bas-gauche en coordonnées AppKit — ne bouge pas).
    private func setPanelHeight(_ height: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        let newBottom = frame.origin.y
        frame.size.height = height
        frame.origin.y = newBottom
        panel.setFrame(frame, display: true)
    }

    // Position du panneau :
    // - Si l'utilisateur l'a déplacé (position complète mémorisée), on la
    //   respecte — le fond est déplaçable (isMovableByWindowBackground).
    // - Sinon, par défaut : centré horizontalement sur l'écran principal, avec
    //   un inset vertical (mémorisé, sinon 40 pt).
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
