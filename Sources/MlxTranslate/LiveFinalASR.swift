import Foundation

/// Niveau final de précision ASR du mode live.
///
/// - `qwenJA` (défaut) : Qwen3-ASR 1,7B japonais 8-bit — mesuré p95 0,64 s,
///   CER ~26 %, 0 sortie vide sur le clip de test.
/// - `voxtralQ4` : pipeline Voxtral 4-bit sidecar (légacy — régression et
///   comparaison).
enum LiveFinalASR: String, CaseIterable, Codable, Sendable {
    case qwenJA = "qwenja"
    case voxtralQ4 = "voxtral"

    static let productDefault = LiveFinalASR.qwenJA

    static func cliValue(_ raw: String) -> Self? {
        Self(rawValue: raw.lowercased())
    }
}

/// Garde des vides de la finale live : choisit le texte japonais à nourrir au
/// LLM pour une clause committée. Ne renvoie jamais un texte vide (un LLM
/// alimenté avec une entrée vide hallucine une complétion) ; renvoie `nil` si
/// les deux sources sont vides (la clause reste en JA seul, comme le pipeline
/// offline pour les cues vides).
enum LiveClauseSelection {
    /// - Parameters:
    ///   - qwenJapanese: texte final du niveau Qwen3-ASR (peut être vide).
    ///   - appleJapanese: meilleur texte Apple disponible sur la même plage
    ///     (fallback si Qwen est vide).
    static func select(qwenJapanese: String?, appleJapanese: String?) -> String? {
        let qwen = qwenJapanese?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let qwen, !qwen.isEmpty else {
            let apple = appleJapanese?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (apple?.isEmpty == false) ? apple : nil
        }
        return qwen
    }
}
