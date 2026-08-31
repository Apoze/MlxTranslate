import Foundation

/// Cadence des snapshots Qwen « pseudo-live » (ré-transcription cumulative de
/// la clause en cours). Port de WhisperASR, adapté à MlxTranslate : la base
/// d'échantillons est `LiveEndpointing.sampleRate` (16 kHz) et il n'y a pas de
/// pré-repli (preRoll = 0) — la fenêtre démarre au début de la phrase.
enum QwenPseudoLiveCadence: Int, CaseIterable, Sendable {
    case seconds1 = 1
    case seconds2 = 2
    case seconds3 = 3

    /// Cadence par défaut (plan validé : 2 s).
    static let productDefault: QwenPseudoLiveCadence = .seconds2

    /// Échantillons 16 kHz par intervalle de cadence.
    var sampleCount: Int { rawValue * Int(LiveEndpointing.sampleRate) }
}

/// Travail de preview (snapshot Qwen à transcrire).
struct QwenPseudoLivePreviewWork: Equatable, Sendable {
    let generation: Int
    let range: Range<Int>
    /// Numéro de séquence de la phrase EN COURS au moment de l'observe
    /// (croissant ; le work coalescé garde le seq de SON observe — une
    /// chaîne de work ne traverse jamais un commit, le coordinateur
    /// bloque les previews sur `stageFinal`). `var` (défaut -1) pour que
    /// l'initialiseur memberwise le porte ; immuable après construction.
    var seq: Int = -1
}

/// Travail final (commit de la clause : le range est définitif, les previews
/// de ce range sont bloquées jusqu'au `completeFinal`).
struct QwenPseudoLiveFinalWork: Equatable, Sendable {
    let generation: Int
    let range: Range<Int>
    let stableThrough: Int
}

/// Résultat d'un preview accepté.
struct QwenPseudoLivePreviewResult: Equatable, Sendable {
    let work: QwenPseudoLivePreviewWork
    let source: String
}

/// Résultat de `completePreview` : le résultat accepté (si encore pertinent) +
/// l'éventuel travail coalescé à traiter ensuite.
struct QwenPseudoLivePreviewCompletion: Equatable, Sendable {
    let accepted: QwenPseudoLivePreviewResult?
    let next: QwenPseudoLivePreviewWork?
}

enum QwenPseudoLivePreviewStatus: Equatable, Sendable {
    case available
    case catchingUp
    case degraded
    case unavailable
}

/// Planifie des snapshots Qwen cumulatifs **sans** leur conférer l'autorité
/// PCM stable : le planificateur d'endpointing reste le seul propriétaire des
/// ranges finaux et de la réclamation. Port de WhisperASR (struct pur,
/// testable) : `LocalEndpointPlanner.sampleRate` → `LiveEndpointing.sampleRate`,
/// preRoll 0.
struct QwenPseudoLiveCoordinator: Sendable {
    let cadence: QwenPseudoLiveCadence
    let previewsEnabled: Bool

    private(set) var coalescedTickCount = 0
    private(set) var staleResultCount = 0
    private(set) var generation = 0
    private(set) var previewStatus: QwenPseudoLivePreviewStatus = .available

    private var phraseStart: Int?
    private var lastRequestedEnd: Int?
    private var latestRequestedRange: Range<Int>?
    private var inFlight: QwenPseudoLivePreviewWork?
    private var pending: QwenPseudoLivePreviewWork?
    private var pendingFinals: [QwenPseudoLiveFinalWork] = []
    private var previewNotBefore = 0
    private var isCancelled = false

    var isCatchingUp: Bool { pending != nil }

    init(cadence: QwenPseudoLiveCadence = .productDefault, previewsEnabled: Bool = true) {
        self.cadence = cadence
        self.previewsEnabled = previewsEnabled
    }

    /// Début d'une preview : le max de `notBefore` (borne stable après un
    /// commit) et du début de la parole (preRoll 0).
    static func previewStart(speechStart: Int, notBefore: Int) -> Int {
        max(notBefore, speechStart)
    }

    /// Observe l'état courant ; renvoie un travail de preview à transcrire
    /// si la cadence est atteinte et que la fenêtre n'est pas bloquée.
    /// - `seq` : numéro de la phrase en cours (compteur du moteur) — porté
    ///   par le work pour que la superposition distingue les previews de la
    ///   phrase engagée de ceux de la phrase suivante.
    mutating func observe(
        speechStart: Int,
        availableThrough: Int,
        seq: Int = -1
    ) -> QwenPseudoLivePreviewWork? {
        guard previewsEnabled,
              !isCancelled,
              speechStart >= previewNotBefore,
              availableThrough > speechStart else { return nil }
        if phraseStart == nil {
            phraseStart = speechStart
            lastRequestedEnd = speechStart
        }
        guard let phraseStart,
              availableThrough - (lastRequestedEnd ?? phraseStart) >= cadence.sampleCount else {
            return nil
        }

        lastRequestedEnd = availableThrough
        let work = QwenPseudoLivePreviewWork(
            generation: generation,
            range: phraseStart..<availableThrough,
            seq: seq
        )
        latestRequestedRange = work.range
        guard inFlight == nil, pendingFinals.isEmpty else {
            if pending != nil || inFlight != nil { coalescedTickCount += 1 }
            pending = work
            previewStatus = .catchingUp
            return nil
        }
        inFlight = work
        return work
    }

    /// Un snapshot s'est terminé : accepte le résultat s'il est encore
    /// pertinent (génération + range à jour), sinon compte un résultat obsolète.
    mutating func completePreview(
        _ work: QwenPseudoLivePreviewWork,
        source: String
    ) -> QwenPseudoLivePreviewCompletion {
        guard inFlight == work else {
            staleResultCount += 1
            return QwenPseudoLivePreviewCompletion(accepted: nil, next: nil)
        }
        inFlight = nil
        let accepted = !isCancelled
            && work.generation == generation
            && work.range == latestRequestedRange
            ? QwenPseudoLivePreviewResult(work: work, source: source)
            : nil
        if accepted == nil { staleResultCount += 1 }
        if accepted != nil { previewStatus = .available }
        return QwenPseudoLivePreviewCompletion(
            accepted: accepted,
            next: takePendingIfReady()
        )
    }

    /// Un snapshot a échoué : passe en « dégradé » et renvoie l'éventuel
    /// travail coalescé.
    mutating func failPreview(
        _ work: QwenPseudoLivePreviewWork
    ) -> QwenPseudoLivePreviewWork? {
        guard inFlight == work else {
            staleResultCount += 1
            return nil
        }
        inFlight = nil
        previewStatus = .degraded
        return takePendingIfReady()
    }

    /// Un final est engagé : le range est définitif, les previews le couvrant
    /// sont bloquées (previewNotBefore = stableThrough), la génération
    /// s'incrémente (les previews en vol deviennent obsolètes).
    @discardableResult
    mutating func stageFinal(
        range: Range<Int>,
        stableThrough: Int
    ) -> QwenPseudoLiveFinalWork {
        generation += 1
        phraseStart = nil
        lastRequestedEnd = nil
        latestRequestedRange = nil
        pending = nil
        if previewStatus == .catchingUp { previewStatus = .available }
        previewNotBefore = max(previewNotBefore, stableThrough)
        let work = QwenPseudoLiveFinalWork(
            generation: generation,
            range: range,
            stableThrough: stableThrough
        )
        pendingFinals.append(work)
        return work
    }

    /// Le final est traité : libère le slot et relance l'éventuel preview
    /// coalescé.
    mutating func completeFinal(
        _ work: QwenPseudoLiveFinalWork
    ) -> QwenPseudoLivePreviewWork? {
        guard pendingFinals.first == work else { return nil }
        pendingFinals.removeFirst()
        return takePendingIfReady()
    }

    /// Annule le coordinateur (fin du live).
    mutating func cancel() {
        isCancelled = true
        generation += 1
        phraseStart = nil
        lastRequestedEnd = nil
        latestRequestedRange = nil
        pending = nil
        pendingFinals.removeAll()
        previewStatus = .unavailable
    }

    private mutating func takePendingIfReady() -> QwenPseudoLivePreviewWork? {
        guard !isCancelled, pendingFinals.isEmpty, inFlight == nil, let pending else {
            return nil
        }
        self.pending = nil
        inFlight = pending
        return pending
    }
}
