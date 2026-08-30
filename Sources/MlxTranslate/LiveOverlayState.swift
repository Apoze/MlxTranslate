import Foundation

/// Mise en page de la superposition live (texte tronqué, taille de police,
/// nombre de lignes enveloppées, hauteur du panneau) — pure et testable
/// sans AppKit.
struct LiveOverlayLayout: Equatable {
    var topText = ""
    var bottomText = ""
    var topFont: CGFloat = 20
    var bottomFont: CGFloat = 20
    /// Lignes enveloppées par label (1…3 ; un texte vide occupe 1 ligne
    /// de réserve, la hauteur minimale du panneau en est 2 × 32 = 64).
    var topLines = 1
    var bottomLines = 1
    /// Hauteur du panneau (64…192 px), arrimée en bas (le bas du panneau
    /// reste fixe, le contenu pousse vers le haut).
    var panelHeight: CGFloat = 64

    static let empty = LiveOverlayLayout()
}

/// Machine d'état pure de la superposition de sous-titres live (2 lignes) :
///
/// - **Bas (blanc)** : la ligne courante — l'aperçu roulant de la clause en
///   formation (pseudo-live), ou le final EN le plus récent après commit.
/// - **Haut (atténué, alpha 0,6)** : le final stable précédent (fenêtre
///   roulante de 2 finaux ; l'ancien défile hors de la fenêtre).
///
/// Mise en page : chaque ligne enveloppe jusqu'à 3 lignes, la police
/// rétrécit automatiquement 20 → 14 pt pour tenir, troncature dure à
/// 250 caractères, hauteur du panneau 64…192 px (2…6 lignes de 32 pt).
///
/// Hystérésis : PENDANT le live (aperçus) la hauteur ne fait que croître
/// (pas de ressaut à mesure que le texte roulant varie) ; à chaque
/// **commit final**, recomputation complète (la hauteur peut rétrécir).
struct LiveOverlayState {
    // MARK: - Paramètres (bornes approuvées du plan)

    /// Largeur de contenu disponible pour l'enveloppement (pt).
    var width: CGFloat = 920
    /// Hauteur d'une ligne (pt).
    let lineHeight: CGFloat = 32
    /// Plage de police (pt) : rétrécissement automatique 20 → 14.
    let fontMax: CGFloat = 20
    let fontMin: CGFloat = 14
    /// Nombre maximal de lignes enveloppées par label.
    let maxLines = 3
    /// Troncature dure (caractères) par ligne (au-delà : « … »).
    let maxChars = 250
    /// Facteur de largeur de caractère moyen (× taille de police).
    /// Sur-estimation volontaire (conservative) : on réserve toujours
    /// assez de hauteur — le texte ne doit JAMAIS être perdu.
    let charWidthFactor: CGFloat = 0.58
    /// Bornes de hauteur du panneau (px).
    let minPanelHeight: CGFloat = 64
    let maxPanelHeight: CGFloat = 192

    // MARK: - Contenu

    /// Finaux EN commités (fenêtre roulante : le plus récent en dernier,
    /// plafond 2).
    private var finals: [String] = []
    /// Aperçu roulant de la clause en formation (texte JA ou EN courant).
    private var preview = ""
    /// Vrai tant qu'un aperçu est affiché (ligne bas = aperçu).
    private var previewActive = false

    /// Hauteur affichée courante (hystérésis : ne fait que croître entre
    /// aperçus ; recomputée à chaque commit final).
    private var currentHeight: CGFloat = 64

    /// Dernière mise en page calculée (à appliquer par le rendu AppKit).
    private(set) var layout = LiveOverlayLayout.empty

    init(width: CGFloat = 920) {
        self.width = width
    }

    // MARK: - Lecture du contenu

    /// Ligne haute (atténuée) : le final stable précédent.
    var topText: String {
        if previewActive { return finals.last ?? "" }
        return finals.count >= 2 ? finals[0] : ""
    }

    /// Ligne basse (blanche) : l'aperçu roulant, ou le final le plus récent.
    var bottomText: String {
        previewActive ? preview : (finals.last ?? "")
    }

    var hasContent: Bool {
        !topText.isEmpty || !bottomText.isEmpty
    }

    // MARK: - Transitions

    /// Aperçu roulant (clause en cours). La hauteur ne fait que croître
    /// (hystérésis live — pas de ressaut pendant la parole).
    mutating func showPreview(_ text: String) {
        preview = text
        previewActive = !text.isEmpty
        var candidate = layoutFor(top: topText, bottom: bottomText)
        currentHeight = max(currentHeight, candidate.panelHeight)
        candidate.panelHeight = currentHeight
        layout = candidate
    }

    /// Final EN commité : fait défiler la fenêtre (2 finaux max), vide
    /// l'aperçu, et **recompute la mise en page en totalité** (la hauteur
    /// peut rétrécir — moment « stable »).
    mutating func commitFinal(_ text: String) {
        guard !text.isEmpty else { return }
        finals.append(text)
        if finals.count > 2 { finals.removeFirst() }
        preview = ""
        previewActive = false
        layout = layoutFor(top: topText, bottom: bottomText)
        currentHeight = layout.panelHeight
    }

    /// Vide la fenêtre (finaux + aperçu) et remet la hauteur au minimum.
    mutating func reset() {
        finals.removeAll()
        preview = ""
        previewActive = false
        currentHeight = minPanelHeight
        layout = .empty
    }

    // MARK: - Résolveur de mise en page (pur)

    /// Nombre de lignes enveloppées estimé de `text` à `font` pt.
    /// Sur-estime volontairement (facteur large) : on réserve toujours
    /// assez de hauteur — jamais de texte perdu.
    func estimatedLines(_ text: String, font: CGFloat) -> Int {
        guard !text.isEmpty else { return 1 }
        let charsPerLine = max(1, Int((width / (font * charWidthFactor)).rounded(.down)))
        return max(1, Int(ceil(Double(text.count) / Double(charsPerLine))))
    }

    /// Plus grande police de [14…20] pt dans laquelle `text` tient sur
    /// `maxLines` lignes au plus.
    func fittedFont(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return fontMax }
        var font = fontMax
        while font > fontMin && estimatedLines(text, font: font) > maxLines {
            font -= 1
        }
        return font
    }

    /// Troncature dure : au-delà de `maxChars`, coupe + « … ».
    func truncated(_ s: String) -> String {
        guard s.count > maxChars else { return s }
        return String(s.prefix(maxChars)) + "…"
    }

    private func layoutFor(top: String, bottom: String) -> LiveOverlayLayout {
        var l = LiveOverlayLayout()
        l.topText = truncated(top)
        l.bottomText = truncated(bottom)
        l.topFont = fittedFont(l.topText)
        l.bottomFont = fittedFont(l.bottomText)
        l.topLines = min(maxLines, estimatedLines(l.topText, font: l.topFont))
        l.bottomLines = min(maxLines, estimatedLines(l.bottomText, font: l.bottomFont))
        l.panelHeight = min(
            maxPanelHeight,
            max(minPanelHeight, CGFloat(l.topLines + l.bottomLines) * lineHeight)
        )
        return l
    }
}
