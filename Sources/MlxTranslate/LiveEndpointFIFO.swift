import Foundation

/// Handoff FIFO entre la boucle d'endpointing (producteur, non bloquant) et
/// le worker de commit final (ASR → aligneur → MLX, consommateur). Port du
/// `LocalEndpointFIFO` de WhisperASR, adapté :
/// - le producteur STAGE les fenêtres (aucune validation, aucun PCM libéré)
///   et continue immédiatement — la boucle ne bloque JAMAIS sur la passe de
///   qualité ;
/// - le consommateur traite les fenêtres dans l'ordre (les plus anciennes
///   d'abord) ; un échec reste en tête de file (« Audio retained — retrying
///   oldest phrase… ») et le PCM n'avance que sur fenêtre acceptée ;
/// - le spool garde le PCM des fenêtres en attente (trim borné par la plus
///   ancienne `windowStart`) — rien n'est perdu si le worker est en retard.
actor LiveEndpointFIFO {
    /// Fenêtre de commit stagée (indices absolus 16 kHz).
    struct Entry: Equatable, Sendable {
        let windowStart: Int
        let windowEnd: Int
        /// Décision forcée (filet 5 s) → la traduction marque un fragment
        /// (« ne pas compléter ni deviner »).
        let forced: Bool
        /// Contexte ASR (suffixe du JA committé) capturé AU STAGING —
        /// déterministe, quel que soit le retard du consommateur.
        let asrContext: String
        /// Horodatage du staging (uptime) — file d'attente journalisable.
        let stagedUptimeNanoseconds: UInt64
    }

    private var pending: [Entry] = []
    private var producerFinished = false

    /// Stage une fenêtre (producteur). Aucune validation, aucun PCM libéré.
    func stage(_ entry: Entry) {
        pending.append(entry)
    }

    /// Plus ancienne fenêtre en attente (nil si vide).
    func next() -> Entry? { pending.first }

    func pendingCount() -> Int { pending.count }

    /// `windowStart` de la plus ancienne fenêtre en attente — borne de trim
    /// du spool (le PCM avant cette borne n'est pas encore libérable : le
    /// consommateur lit `samples(from:upTo:)` au traitement, pas au staging).
    func oldestPendingWindowStart() -> Int? { pending.first?.windowStart }

    /// Accepte une fenêtre traitée (consommateur, tête de file uniquement).
    func accept(_ entry: Entry) {
        guard pending.first == entry else { return }
        pending.removeFirst()
    }

    /// Le producteur n'envoiera plus de fenêtres (fin de la boucle).
    func finishProducing() { producerFinished = true }

    /// File drainée : producteur terminé ET plus de fenêtre en attente.
    func isDrained() -> Bool { producerFinished && pending.isEmpty }
}
