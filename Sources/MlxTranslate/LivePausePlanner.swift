import Foundation

/// Endpointing live « lâche » (port 1:1 des règles de WhisperASR
/// `LocalEndpointPlanner`) : on commit dès qu'un silence de
/// `pauseSilenceSeconds` suit la phrase (≥ `minimumBatchSeconds`), dès la fin
/// de phrase détectée dans le texte roulant (ponctuation terminale / fin
/// japonaise conservatrice), avec un filet dur à 5 s. La fenêtre reste
/// courte, la preview bouge à chaque cycle et le final arrive dès que le
/// locuteur s'arrête — pas d'attente de 2 s, pas de forçage à 12 s sur audio
/// silencieux.
///
/// Structure pure (testable table-driven), espace échantillons 16 kHz
/// (indices absolus). Port de WhisperASR adapté à MlxTranslate :
/// - détection de silence = `LiveSemanticEndpointer.trailingSilenceSeconds`
///   (RMS, seuil partagé) — fournie par le moteur à chaque observation ;
/// - fin de phrase = `LiveSemanticEndpointer.isTerminalJapanese` sur le texte
///   roulant (Apple par défaut, snapshot Qwen en mode `.mlx`) ;
/// - pas de `preRoll` (la fenêtre démarre au dernier commit).
struct LivePausePlanner: Sendable {
    /// Silence (s) après la dernière parole → commit de la phrase
    /// (WhisperASR : 350 ms de silence de fin + 500 ms de post-roll).
    static let pauseSilenceSeconds = 0.5
    /// Durée minimale (s) de la fenêtre avant qu'un silence ne puisse commiter
    /// (regroupe les phrases courtes).
    static let minimumBatchSeconds = 1.5
    /// Filet dur (s) de la fenêtre, quel que soit le silence : purge des
    /// lots anciens (le spool avance, la détection continue — rien n'est
    /// perdu).
    static let maxPhraseSeconds = 5.0

    /// Verdict sur la fenêtre courante.
    enum Decision: Equatable, Sendable {
        /// Silence de 0,5 s après une phrase ≥ 1,5 s, OU fin de phrase
        /// détectée dans le texte roulant (ponctuation terminale / fin
        /// japonaise conservatrice) → commit.
        case pause
        /// Fenêtre ≥ 5 s → coupure de sécurité (filet).
        case forced
    }

    /// Début de la phrase courante (échantillon absolu 16 kHz, premier
    /// échantillon de parole observé).
    private var phraseSpeechStart: Int?

    /// Observe l'état courant ; renvoie le verdict (nil = continuer à
    /// accumuler).
    /// - Parameters:
    ///   - windowStart: index du dernier commit (début de la fenêtre).
    ///   - available: taille courante du spool (échantillons absolus).
    ///   - trailingSilenceSeconds: secondes de silence de fin de la fenêtre
    ///     (0 = la parole est encore en cours).
    ///   - speechStart: début (échantillon absolu) de la PREMIÈRE parole dans
    ///     la fenêtre courante (nil = aucune parole dans la fenêtre).
    ///   - latestText: texte roulant courant (segment Apple / snapshot Qwen) —
    ///     une fin terminale (ponctuation) commite immédiatement, sans
    ///     attendre le silence ni la durée minimale de lot.
    mutating func observe(
        windowStart: Int,
        available: Int,
        trailingSilenceSeconds: Double,
        speechStart: Int?,
        latestText: String? = nil
    ) -> Decision? {
        if let start = speechStart {
            phraseSpeechStart = min(phraseSpeechStart ?? start, start)
        }
        // Filet : fenêtre ≥ 5 s → coupure de sécurité (même à vide — la coupe
        /// vide fait avancer `lastCommit`, pas d'accumulation sans borne).
        if Double(available - windowStart) / LiveEndpointing.sampleRate >= Self.maxPhraseSeconds {
            return .forced
        }
        guard let start = phraseSpeechStart else { return nil }
        // Phrase elle-même ≥ 5 s (parole continue) → coupure de sécurité.
        if Double(available - start) / LiveEndpointing.sampleRate >= Self.maxPhraseSeconds {
            return .forced
        }
        // Fin de phrase dans le texte roulant (ponctuation terminale ou fin
        // japonaise conservatrice) → commit immédiat — l'accumulation s'arrête
        // à la fin de la phrase, pas seulement au silence.
        if let latestText, LiveSemanticEndpointer.isTerminalJapanese(latestText) {
            return .pause
        }
        // Silence de 0,5 s après une phrase ≥ 1,5 s → commit.
        if trailingSilenceSeconds >= Self.pauseSilenceSeconds,
           Double(available - start) / LiveEndpointing.sampleRate >= Self.minimumBatchSeconds {
            return .pause
        }
        return nil
    }

    /// Réinitialise l'état après un commit (nouvelle fenêtre).
    mutating func reset() {
        phraseSpeechStart = nil
    }

    // MARK: - Scan de parole de la fenêtre (pur, testable)

    /// Index absolu du premier échantillon de parole dans la fenêtre (RMS,
    /// même seuil que l'endpointing live : une frame de 100 ms est « parole »
    /// si elle contient un échantillon ≥ `silenceThreshold`).
    /// `nil` si aucune frame ne contient de parole.
    static func firstSpeechSample(samples: [Float], windowStart: Int) -> Int? {
        let frame = LiveEndpointing.frameSamples
        let threshold = LiveEndpointing.silenceThreshold
        let frameCount = samples.count / frame
        for i in 0..<frameCount {
            let start = i * frame
            for j in start..<(start + frame) where abs(samples[j]) >= threshold {
                return windowStart + start
            }
        }
        return nil
    }
}
