import Foundation

/// Mise en page de la superposition live (textes tronqués, tailles de
/// police, hauteur du panneau) — pure et testable sans AppKit.
///
/// Barre de 3 lignes : 2 lignes finalisées + 1 ligne live (en bas).
/// Chaque ligne est UNE ligne visuelle (police rétrécie automatiquement
/// 20 → 14 pt, troncature dure avec « … ») ; la hauteur du panneau est
/// constante (3 × 32 pt = 96 pt) — plus de jumps de hauteur.
struct LiveOverlayLayout: Equatable {
    var lines: [String] = ["", "", ""]   // 3 slots, haut → bas
    var fonts: [CGFloat] = [20, 20, 20]
    /// Hauteur du panneau (96 px = 3 × 32, constante).
    var panelHeight: CGFloat = LiveOverlayState.barHeight
    static let empty = LiveOverlayLayout()
}

/// Machine d'état pure de la superposition de sous-titres live (barre
/// 3 lignes, arrimée en bas) :
///
/// - **Bas (ligne live)** : la ligne en cours — l'aperçu roulant de la
///   clause en formation (Apple ou snapshots Qwen) ET le stream du final
///   MLX (les chunks cumulatifs la remplacent sur place). Plus de
///   dualité preview/final : la ligne EST le final en cours, qui
///   s'améliore au fur et à mesure.
/// - **Haut (2 lignes finalisées)** : les finaux stables les plus
///   récents ; à chaque engagement, le plus ancien défile hors de la
///   barre (défilement automatique vers le haut).
///
/// Streaming : pendant qu'une passe de final MLX est en cours
/// (`streamingChunk`), les previews Apple arrivant entre-temps sont
/// *stagées* (latest-wins) et prennent la ligne live dès que le final
/// s'engage — pas de scintillement entre les deux sources.
///
/// Mise en page : chaque ligne tient sur UNE ligne visuelle (sans
/// enveloppement) — rétrécissement automatique de police 20 → 14 pt
/// pour tenir, troncature dure avec « … » ; hauteur du panneau
/// constante (96 pt).
struct LiveOverlayState {
    // MARK: - Paramètres

    /// Largeur de contenu disponible pour le fitting des lignes (pt).
    var width: CGFloat = 920
    /// Hauteur d'une ligne (pt).
    let lineHeight: CGFloat = 32
    /// Plage de police (pt) : rétrécissement automatique 20 → 14.
    let fontMax: CGFloat = 20
    let fontMin: CGFloat = 14
    /// Facteur de largeur de caractère moyen (× taille de police).
    /// Sur-estimation volontaire (conservative) : on réserve toujours
    /// assez de largeur — le texte ne doit JAMAIS être coupé avant
    /// l'épuisement de la police minimale.
    let charWidthFactor: CGFloat = 0.58
    /// Nombre de lignes finalisées conservées dans la barre (la ligne
    /// live est la 3ᵉ).
    let finalizedCap = 2

    /// Hauteur constante de la barre (3 lignes de 32 pt).
    static var barHeight: CGFloat { 3 * 32 }

    // MARK: - Contenu

    /// Finaux engagés (le plus ancien en premier, plafond
    /// `finalizedCap` ; le surplus défile hors de la barre).
    private var finals: [String] = []
    /// Ligne live (slot bas) : l'aperçu roulant, ou le final en cours
    /// (stream MLX).
    private var live = ""
    /// Preview Apple stagée pendant le stream d'un final MLX (latest
    /// wins ; prend la ligne live quand le final s'engage).
    private var stagedPreview = ""
    /// Vrai tant que les chunks d'une passe de final MLX arrivent.
    private var streaming = false

    // MARK: - Séquences de phrase (gardes anti-retour)

    /// Séquence du dernier final engagé (la barre n'affiche plus que des
    /// contenus d'une phrase SUIVANTE — les previews/finaux en retard de
    /// la phrase engagée sont jetés, le texte ne « revient » pas).
    private var lastCommittedSeq = -1
    /// Séquence du contenu actuellement sur la ligne live (une preview de
    /// la même phrase peut la réécrire sur place — reformulation d'une
    /// même clause — mais pas une preview d'une phrase antérieure).
    private var liveSeq = -1
    /// Séquence de la preview stagée (le commit ne la promeut que si elle
    /// appartient à une phrase STRICTEMENT postérieure à la phrase
    /// engagée).
    private var stagedSeq = -1

    /// Dernière mise en page calculée (à appliquer par le rendu AppKit).
    private(set) var layout = LiveOverlayLayout.empty

    // MARK: - Lecture du contenu

    /// Les 3 slots de la barre (haut → bas) : 2 finalisées + live.
    var lines: [String] {
        let settled: [String]
        switch finals.count {
        case 0: settled = ["", ""]
        case 1: settled = ["", finals[0]]
        default: settled = [finals[0], finals[1]]
        }
        return [settled[0], settled[1], live]
    }

    var hasContent: Bool { lines.contains { !$0.isEmpty } }

    // MARK: - Transitions

    /// Aperçu roulant (Apple, ou snapshots Qwen hors stream de final) :
    /// prend la ligne live **sur place** (remplacement direct — les
    /// états d'une même clause peuvent se reformuler, pas de garde
    /// monotone sur le TEXTE). Pendant le stream d'un final MLX, l'aperçu
    /// est stagé : il prend la ligne live dès que le final s'engage.
    ///
    /// Garde de SÉQUENCE : une preview de la phrase déjà ENGAGÉE (séquence
    /// ≤ `lastCommittedSeq`) ne réécrirait pas la ligne — c'est le cas du
    /// « texte d'avant qui revient et grossit » : la preview Apple roulante
    /// porte la séquence de la phrase EN COURS, pas celle de la phrase
    /// engagée (le moteur ré-aiguille la séquence à chaque commit).
    mutating func showPreview(_ text: String, seq: Int) {
        if streaming {
            stagedPreview = text
            stagedSeq = seq
        } else if seq > lastCommittedSeq, seq >= liveSeq {
            live = text
            liveSeq = seq
        }
        recompute()
    }

    /// Chunk du stream de final MLX (cumulatif) : prend la ligne live
    /// sur place — la ligne « en cours » s'améliore chunk par chunk,
    /// sans saut de source. Le seq de la phrase (celle du FINAL, portée
    /// par les chunks) est mémorisé : la preview stagée ne sera promue
    /// qu'avec une séquence strictement postérieure.
    mutating func streamingChunk(_ text: String, seq: Int) {
        streaming = true
        live = text
        liveSeq = seq
        recompute()
    }

    /// Final EN engagé : prend le slot du haut (le plus ancien défile
    /// hors de la barre), la ligne live est vidée — sauf si une
    /// preview Apple a été stagée pendant le stream ET qu'elle appartient
    /// à une phrase STRICTEMENT postérieure à la phrase engagée : elle
    /// prend la ligne live (la phrase suivante est déjà en formation).
    /// Sinon la ligne repart vide (pas de « retour » de l'ancienne
    /// phrase).
    mutating func commitFinal(_ text: String, seq: Int) {
        lastCommittedSeq = max(lastCommittedSeq, seq)
        if !text.isEmpty {
            finals.append(text)
            if finals.count > finalizedCap { finals.removeFirst() }
            if !stagedPreview.isEmpty, stagedSeq > lastCommittedSeq {
                live = stagedPreview
                liveSeq = stagedSeq
                stagedPreview = ""
                stagedSeq = -1
            } else {
                live = ""
                liveSeq = -1
                stagedPreview = ""
                stagedSeq = -1
            }
        } else {
            // Final vide (énoncé sans contenu) : la ligne live est
            // vidée, rien ne s'engage.
            live = ""
            liveSeq = -1
            stagedPreview = ""
            stagedSeq = -1
        }
        streaming = false
        recompute()
    }

    /// Vide la barre (finalisés + live + stagé) et remet le drapeau de
    /// stream + les séquences.
    mutating func reset() {
        finals.removeAll()
        live = ""
        liveSeq = -1
        stagedPreview = ""
        stagedSeq = -1
        lastCommittedSeq = -1
        streaming = false
        layout = .empty
    }

    // MARK: - Résolveur de mise en page (pur)

    /// Nombre de caractères tenant sur UNE ligne visuelle à `font` pt.
    func charsPerLine(font: CGFloat) -> Int {
        max(1, Int((width / (font * charWidthFactor)).rounded(.down)))
    }

    /// Nombre de lignes enveloppées estimé de `text` à `font` pt.
    func estimatedLines(_ text: String, font: CGFloat) -> Int {
        guard !text.isEmpty else { return 1 }
        return max(1, Int(ceil(Double(text.count) / Double(charsPerLine(font: font)))))
    }

    /// Plus grande police de [14…20] pt dans laquelle `text` tient sur
    /// UNE ligne visuelle.
    func fittedFont(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return fontMax }
        var font = fontMax
        while font > fontMin && estimatedLines(text, font: font) > 1 {
            font -= 1
        }
        return font
    }

    /// Fitting d'un slot de la barre en UNE ligne visuelle :
    /// rétrécissement automatique de police, puis troncature dure avec
    /// « … » si le texte ne tient pas même à 14 pt.
    func fittedLine(_ s: String) -> (text: String, font: CGFloat) {
        guard !s.isEmpty else { return ("", fontMax) }
        let font = fittedFont(s)
        let cap = charsPerLine(font: font)
        guard s.count > cap else { return (s, font) }
        return (String(s.prefix(cap)) + "…", font)
    }

    private mutating func recompute() {
        var l = LiveOverlayLayout()
        for i in 0..<l.lines.count {
            let f = fittedLine(lines[i])
            l.lines[i] = f.text
            l.fonts[i] = f.font
        }
        l.panelHeight = Self.barHeight
        layout = l
    }
}
