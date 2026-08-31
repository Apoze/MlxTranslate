import Foundation

/// Endpointing sémantique des clauses live : le silence ne fait que
/// DÉCLENCHER une évaluation ; le verdict vient de la sortie du modèle
/// (ponctuation de fin de phrase / fin japonaise conservatrice) et de la
/// stabilité du texte, pas d'une fenêtre temporelle fixe (pas de « cut doux
/// 5 s / forcé 10 s »).
///
/// Règles (plan validé) :
/// - fenêtre ≥ 12 s → `forceCut` (filet de sécurité) ;
/// - phrase terminale + (stable || appleFinalized || silence ≥ 2 s) → `commitFinal` ;
/// - non terminale et silence ≥ 2 s → `commitFragment` ;
/// - sinon → `hold`.
enum LiveSemanticEndpointer {
    /// Verdict sur la clause en cours.
    enum Decision: Equatable, Sendable {
        /// Continuer d'accumuler : pas encore de point de commit fiable.
        case hold
        /// Clause complète (fin de phrase) → commit final.
        case commitFinal
        /// Clause incomplète, silence ≥ 2 s → commit fragmentaire.
        case commitFragment
        /// Fenêtre ≥ 12 s → commit de sécurité.
        case forceCut
    }

    // Constantes de conception (plan validé).
    /// Silence minimal (s) pour déclencher une évaluation.
    static let triggerSilenceSeconds = 0.3
    /// Silence (s) au-delà duquel une clause incomplète est commitée fragment.
    static let fragmentHoldSeconds = 2.0
    /// Filet de sécurité : durée max d'une fenêtre sans commit (s).
    static let forceCutSeconds = 12.0
    /// Fenêtre de stabilité : le snapshot doit rester inchangé ce temps (s).
    static let stabilityGuardSeconds = 1.12
    /// Historique LLM roulant : nombre de paires JA→EN commises conservées.
    static let historyLimit = 4
    /// Contexte ASR roulant : nombre de caractères JA récents passés au
    /// transcribeur (continuité lexicale).
    static let asrContextCharacters = 200
    /// Contexte ASR roulant ACTIVÉ : les derniers `asrContextCharacters` du
    /// JA committé sont injectés au transcribeur (prompt système). Désactivé
    /// par défaut en live : le modèle RÉ-ÉMET le prompt système dans sa
    /// sortie (écho) → répétitions de lignes SRT + hallucinations sur les
    /// fenêtres courtes. WhisperASR n'utilise pas ce contexte en live
    /// (option offline / bench).
    static var asrContextEnabled = false
    /// Cadence de référence de ré-transcription cumulative (s) — défaut
    /// produit. La cadence effective est `QwenPseudoLiveCadence` (configurable
    /// 1/2/3 s, GUI + CLI `--cadence`), consommée par
    /// `QwenPseudoLiveCoordinator`.
    static let snapshotCadenceSeconds = 2.0

    /// Décision pure (tests table-driven).
    /// - Parameters:
    ///   - silenceSeconds: silence de fin courant (s).
    ///   - isTerminal: le snapshot se termine par une ponctuation terminale
    ///     ou une fin japonaise conservatrice.
    ///   - isStable: snapshot inchangé depuis ≥ `stabilityGuardSeconds`.
    ///   - windowSeconds: durée de la fenêtre depuis le dernier commit (s).
    ///   - appleFinalized: signal complémentaire (financement Apple).
    static func evaluate(
        silenceSeconds: Double,
        isTerminal: Bool,
        isStable: Bool,
        windowSeconds: Double,
        appleFinalized: Bool = false
    ) -> Decision {
        if windowSeconds >= forceCutSeconds { return .forceCut }
        if isTerminal && (isStable || appleFinalized || silenceSeconds >= fragmentHoldSeconds) {
            return .commitFinal
        }
        if !isTerminal && silenceSeconds >= fragmentHoldSeconds {
            return .commitFragment
        }
        return .hold
    }

    /// Détection de fin de phrase : ponctuation terminale OU fin japonaise
    /// conservatrice (même liste que le planificateur de clauses WhisperASR —
    /// on ne commit jamais sur une forme ambiguë).
    static func isTerminalJapanese(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }
        if ["。", "！", "？", "!", "?"].contains(last) { return true }
        return terminalEndings.contains(where: trimmed.hasSuffix)
    }

    /// Fins de phrase japonaises conservatrices (réutilisées de WhisperASR).
    static let terminalEndings = [
        "じゃなかった", "じゃない", "でしょう", "でした", "ました", "ません",
        "でしょうか", "ですよね", "ますよね", "ですか", "ますか", "ですよ",
        "ますよ", "ですね", "ますね", "だよね", "だった", "だよ", "だね",
        "です", "ます",
    ]

    /// Durée en secondes du silence de fin d'un tampon 16 kHz : nombre de
    /// frames silencieuses consécutives (100 ms, seuil RMS
    /// `LiveEndpointing.silenceThreshold`) × 0,1. Fonction pure testable.
    static func trailingSilenceSeconds(_ samples: [Float]) -> Double {
        let frame = LiveEndpointing.frameSamples
        let threshold = LiveEndpointing.silenceThreshold
        let frameCount = samples.count / frame
        guard frameCount > 0 else { return 0 }
        var silentFrames = 0
        var i = frameCount - 1
        while i >= 0 {
            var quiet = true
            let start = i * frame
            for j in start..<(start + frame) where samples[j].magnitude >= threshold {
                quiet = false
                break
            }
            if quiet { silentFrames += 1 } else { break }
            i -= 1
        }
        return Double(silentFrames) * Double(frame) / LiveEndpointing.sampleRate
    }
}

/// Stabilité du snapshot : le texte est « stable » s'il est observé sans
/// changement pendant ≥ `stabilityGuardSeconds` (observations périodiques,
/// poll endpointing 0,4 s — ≈ 3 observations consécutives).
struct SnapshotStabilityTracker: Sendable {
    private var lastText: String?
    private var firstObserved: Date?
    private let stability: TimeInterval

    init(stability: TimeInterval = LiveSemanticEndpointer.stabilityGuardSeconds) {
        self.stability = stability
    }

    /// Observe un snapshot ; renvoie `true` si le texte est stable
    /// (inchangé depuis ≥ `stability`).
    mutating func observe(_ text: String, now: Date = Date()) -> Bool {
        if text == lastText, let first = firstObserved {
            return now.timeIntervalSince(first) >= stability
        }
        lastText = text
        firstObserved = now
        return false
    }

    /// Réinitialise le suivi (après un commit).
    mutating func reset() {
        lastText = nil
        firstObserved = nil
    }
}
