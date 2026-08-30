import Foundation

/// Garde monotone de la ligne de preview roulante (live) : le texte affiché
/// ne fait que progresser en cours de clause — il ne rétrécit jamais entre
/// deux passes (ex. le début d'une nouvelle passe de re-traduction, « Hello,
/// », ne remplace pas « Hello, I'm doing well » ; la ligne tient l'ancien
/// texte jusqu'à ce que la nouvelle passe rattrape sa longueur, ou jusqu'au
/// commit qui remet la garde à zéro via `reset`).
///
/// Pur et testable (aucune dépendance UI) : utilisé par `LiveOverlayState`
/// (superposition GUI) et `LiveOutput` (ligne stderr CLI).
struct PreviewMonotone: Sendable {
    private var current = ""

    /// Texte actuellement retenu.
    var currentValue: String { current }

    /// Accepte le candidat s'il progresse ; renvoie le texte à afficher.
    /// - Vide candidat → conserve l'existant (jamais de blanchiment).
    /// - Vide actuel → prend le candidat.
    /// - Extension (l'actuel est un préfixe) → croissance, acceptée.
    /// - Texte différent d'au moins la même longueur → correction
    ///   (au moins aussi complète), acceptée.
    /// - Rétrécissement → retenu : la ligne garde l'ancien texte.
    @discardableResult
    mutating func accept(_ candidate: String) -> String {
        if candidate.isEmpty { return current }
        if current.isEmpty {
            current = candidate
            return candidate
        }
        if candidate.hasPrefix(current) {
            current = candidate
            return candidate
        }
        if candidate.count >= current.count {
            current = candidate
            return candidate
        }
        return current
    }

    /// Remet la garde à zéro (engagement d'un final : la clause suivante
    /// démarre une nouvelle ligne).
    mutating func reset() {
        current = ""
    }
}
