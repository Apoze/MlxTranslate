import Foundation

/// Repli des répétitions dégénérées de l'ASR (musique / silence) : sur un
/// audio non-parole, Qwen3-ASR émet parfois « はい、はい、はい、… » × 100 —
/// la traduction produit alors « yes, yeah, yeah × 40 » et le SRT se remplit
/// de lignes identiques. Appliqué AVANT traduction (MLX ou Apple) et avant
/// l'alignement/SRT ; le texte brut reste journalisé pour le debug.
enum LiveRepetition {
    /// Longueur minimale (caractères) de la séquence répétée pour replier.
    static let minRun = 40
    /// Nombre minimal de répétitions de l'unité.
    static let minCount = 4
    /// Taille maximale (caractères) de l'unité testée.
    static let maxUnit = 24
    /// Nombre d'unités conservées après repli (« はい、はい、はい … »).
    static let keptUnits = 3

    /// Replie la séquence répétée en fin de texte :
    /// « はい、 » × 100 → « はい、はい、はい、… ».
    /// Le texte normal est renvoyé inchangé.
    ///
    /// Algorithme : pour chaque taille d'unité L (1…24) et chaque alignement
    /// (offset mod L), on cherche la plus longue séquence de blocs consécutifs
    /// ÉGAL (bloc = L caractères) ; la séquence gagnante (plus longue, à égalité
    /// la plus petite unité = période réelle, puis la plus précoce) est repliée
    /// en `keptUnits` unités + « … » ; le préfixe et le suffixe non périodique
    /// (sortie ASR tronquée en pleine unité) sont conservés.
    static func collapse(_ text: String) -> String {
        let chars = Array(text)
        let n = chars.count
        guard n >= minRun else { return text }

        var bestFull = 0
        var bestStart = 0
        var bestL = 0

        for L in 1...maxUnit where 2 * L <= n {
            for offset in 0..<L {
                let m = (n - offset) / L   // blocs complets
                guard m >= minCount else { continue }
                // Plus longue séquence de blocs consécutifs égaux (égalité
                // transitive : on compare chaque bloc au précédent).
                var i = 0
                while i < m {
                    var j = i + 1
                    while j < m, blocksEqual(chars, offset + j * L, offset + (j - 1) * L, L) {
                        j += 1
                    }
                    let blocks = j - i
                    let full = blocks * L
                    if full >= minRun, blocks >= minCount {
                        let start = offset + i * L
                        if full > bestFull
                            || (full == bestFull && L < bestL)
                            || (full == bestFull && L == bestL && start < bestStart) {
                            bestFull = full
                            bestStart = start
                            bestL = L
                        }
                    }
                    i = j
                }
            }
        }
        guard bestFull > 0 else { return text }
        // L'unité est le premier bloc de la séquence gagnante.
        let s = bestStart
        let unit = String(chars[s..<s + bestL])
        var result = String(chars[0..<s])
        result += String(repeating: unit, count: keptUnits)
        // Morceau final non périodique (entre la fin des blocs égaux et `n`).
        result += String(chars[(s + bestFull)..<n])
        if bestFull > keptUnits * bestL {
            result += "…"
        }
        return result
    }

    /// Deux blocs de longueur L (début `a` et `b`, indices caractères) égaux ?
    private static func blocksEqual(_ chars: [Character], _ a: Int, _ b: Int, _ L: Int) -> Bool {
        for k in 0..<L where chars[a + k] != chars[b + k] {
            return false
        }
        return true
    }
}
