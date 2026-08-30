import Foundation

// Orchestration : ~/.mlxtranslate (runs, glossaire), SRT (JA)/(EN)
// côte à côte de la vidéo, RTTM des parlants, traduction locale.

enum Pipeline {
    /// Fenêtres d'ASR : l'aligneur Qwen3 impose 20 s maximum par ancre.
    static let windowSeconds = 20

    enum PipelineError: LocalizedError {
        case mediaNotFound(String)
        case audioMissing(String)
        case chunksMissing(String)
        case jaSRTMissing(String)
        case rttmMissing(String)
        case transcriptionFailed(String)
        case alignmentFailed(String)
        case diarizationFailed(String)
        case translationFailed(String)
        case emptyTranscription
        case metalLibraryMissing

        var errorDescription: String? {
            switch self {
            case .mediaNotFound(let detail): "média introuvable : \(detail)"
            case .audioMissing(let detail): "audio introuvable dans le run : \(detail)"
            case .chunksMissing(let detail): "chunks.json introuvable : \(detail)"
            case .jaSRTMissing(let detail): "« \(detail) » absent — lancez d'abord `aligner`."
            case .rttmMissing(let detail): "RTTM introuvable : \(detail)"
            case .transcriptionFailed(let detail): "transcription en échec : \(detail)"
            case .alignmentFailed(let detail): "alignement en échec : \(detail)"
            case .diarizationFailed(let detail): "diarisation en échec : \(detail)"
            case .translationFailed(let detail): "traduction en échec : \(detail)"
            case .emptyTranscription: "transcription vide (audio muet ?)"
            case .metalLibraryMissing:
                "la bibliothèque Metal MLX (mlx.metallib) est introuvable.\n"
                + "  → Lancez d'abord une transcription (ex. `mlxtranslate transcrire <média>`) "
                + "pour la télécharger dans ~/.mlxtranslate, puis relancez."
            }
        }
    }

    // ------------------------------------------------------------------
    // Arborescence
    // ------------------------------------------------------------------

    static var homeURL: URL {
        if let override = ProcessInfo.processInfo.environment["MLXTRANSLATE_HOME"] {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath as String)
        }
        return URL(fileURLWithPath: NSString(string: "~/.mlxtranslate").expandingTildeInPath)
    }

    static var runsDirectory: URL { homeURL.appendingPathComponent("runs", isDirectory: true) }

    static var defaultGlossaryURL: URL {
        homeURL.appendingPathComponent("glossaire.txt")
    }

    static func makeRunDirectory() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let run = runsDirectory.appendingPathComponent(
            "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4).lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        return run
    }

    /// `nettoyer` : retire les sessions (runs/ et live-*.srt) mais garde les
    /// modèles (mlx.metallib, speakerkit, sidecar) et le glossaire.
    static func nettoyer() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: runsDirectory.path) {
            try fm.removeItem(at: runsDirectory)
            Pipeline.log("nettoyer : sessions (runs/) supprimées")
        } else {
            Pipeline.log("nettoyer : rien à supprimer dans runs/")
        }
        if let files = try? fm.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: nil) {
            let liveSRTs = files.filter { $0.lastPathComponent.hasPrefix("live-") && $0.lastPathComponent.hasSuffix(".srt") }
            for file in liveSRTs {
                try? fm.removeItem(at: file)
            }
            Pipeline.log("nettoyer : \(liveSRTs.count) SRT live supprimé(s)")
        }
        Pipeline.log("nettoyer : terminé (modèles et glossaire conservés)")
    }

    /// Plus récent run contenant un chunks.json pour ce média.
    static func findLatestRun(for video: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        var best: URL?
        var bestDate = Date.distantPast
        for entry in entries {
            let chunks = entry.appendingPathComponent("chunks.json")
            guard let data = try? Data(contentsOf: chunks),
                  let record = try? JSONDecoder().decode(ChunksRecord.self, from: data),
                  URL(fileURLWithPath: record.video) == video else { continue }
            let values = try? entry.resourceValues(forKeys: Set([URLResourceKey.contentModificationDateKey]))
            if let modification = values?.contentModificationDate, modification > bestDate {
                bestDate = modification
                best = entry
            }
        }
        return best
    }

    static func findRTTM(for video: URL) -> URL? {
        findLatestRun(for: video)?.appendingPathComponent("parlants.rttm")
    }

    // ------------------------------------------------------------------
    // SRT attendus côte à côte de la vidéo
    // ------------------------------------------------------------------

    static func jaSRTURL(for video: URL) -> URL {
        video.deletingLastPathComponent()
            .appendingPathComponent("\(video.deletingPathExtension().lastPathComponent) (JA).srt")
    }

    static func enSRTURL(for video: URL) -> URL {
        video.deletingLastPathComponent()
            .appendingPathComponent("\(video.deletingPathExtension().lastPathComponent) (EN).srt")
    }

    // ------------------------------------------------------------------
    // Enregistrement JSON des fenêtres
    // ------------------------------------------------------------------

    struct ChunksRecord: Codable, Sendable {
        struct ChunkRecord: Codable, Sendable {
            var index: Int
            var start: Double
            var end: Double
            var text: String
        }

        var video: String
        var asr: String
        var windowSeconds: Int
        var chunks: [ChunkRecord]
        var fullText: String
    }

    static func writeChunks(_ record: ChunksRecord, to run: URL) throws {
        let data = try JSONEncoder().encode(record)
        try data.write(to: run.appendingPathComponent("chunks.json"), options: .atomic)
    }

    static func readChunks(_ run: URL) throws -> ChunksRecord {
        let data = try Data(contentsOf: run.appendingPathComponent("chunks.json"))
        return try JSONDecoder().decode(ChunksRecord.self, from: data)
    }

    static func ensureAudio(video: URL, run: URL) throws -> [Float] {
        let wav = run.appendingPathComponent("audio.wav")
        if !FileManager.default.fileExists(atPath: wav.path) {
            log("extraction audio 16 kHz mono…")
            try Audio.extractWav(video: video, to: wav)
        }
        return try Audio.loadWAV(wav)
    }

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Le metallib MLX (kernels Metal précompilés) n'est pas embarqué par
    /// Cmlx en SwiftPM : il doit exister à côté de l'exécutable. On le copie
    /// depuis le cache local (`~/.mlxtranslate/mlx.metallib`) s'il manque.
    static func ensureMetalLibrary() throws {
        guard let executableURL = Bundle.main.executableURL else { return }
        let target = executableURL.deletingLastPathComponent()
            .appendingPathComponent("mlx.metallib")
        if FileManager.default.fileExists(atPath: target.path) { return }
        let source = homeURL.appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: source.path) else {
            log("metallib : \(source.lastPathComponent) absent du cache (\(source.path))")
            throw PipelineError.metalLibraryMissing
        }
        do {
            try FileManager.default.copyItem(at: source, to: target)
            log("metallib : copié à côté de l'exécutable")
        } catch {
            log("metallib : copie ignorée (\(error.localizedDescription))")
        }
    }

    // ------------------------------------------------------------------
    // Progression
    // ------------------------------------------------------------------

    final class ProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -1

        func report(_ stage: String, _ fraction: Double, _ message: String) {
            let percent = Int((fraction * 100).rounded())
            lock.lock()
            defer { lock.unlock() }
            guard percent > lastPercent else { return }
            lastPercent = percent
            FileHandle.standardError.write(Data("[\(stage)] \(percent)% — \(message)\n".utf8))
        }
    }

    // ------------------------------------------------------------------
    // Commandes
    // ------------------------------------------------------------------

    static func run(_ command: Command) async throws {
        if command.verb == .live {
            // Le mode live est normalement routé dans MlxTranslateMain ; repli ici.
            if #available(macOS 26.4, *) {
                try await Live.run(command)
            } else {
                throw PipelineError.mediaNotFound("le mode live nécessite macOS 26.4")
            }
            return
        }
        if command.verb == .nettoyer {
            try nettoyer()
            return
        }
        guard FileManager.default.fileExists(atPath: command.video.path) else {
            throw PipelineError.mediaNotFound(command.video.path)
        }
        // S'assurer que le metallib MLX est à côté de l'exécutable (nécessaire
        // à l'aligner et au traducteur, qui chargent MLX Metal).
        try ensureMetalLibrary()
        switch command.verb {
        case .transcrire:
            try await transcribe(command)
        case .aligner:
            try await align(command)
        case .parlants:
            try await diarize(command)
        case .traduire:
            try await translate(command)
        case .finale:
            try await finale(command)
        case .live:
            // Inatteignable (géré ci-dessus) ; exhaustivité du switch.
            break
        case .nettoyer:
            // Inatteignable (géré ci-dessus) ; exhaustivité du switch.
            break
        }
    }

    // ------------------------------------------------------------------
    // transcrire
    // ------------------------------------------------------------------

    static func transcribe(_ command: Command) async throws {
        let run = try makeRunDirectory()
        let samples = try ensureAudio(video: command.video, run: run)
        let windows = Audio.windows(samples, seconds: windowSeconds)
        let gate = ProgressGate()
        let result = try await ASR.transcribe(
            windows: windows,
            samples: samples,
            backend: command.asr,
            language: command.language,
            videoPath: command.video.path,
            progress: { fraction, message in gate.report("asr", fraction, message) }
        )
        var records: [ChunksRecord.ChunkRecord] = []
        for (index, window) in windows.enumerated() {
            records.append(.init(
                index: index,
                start: window.start,
                end: window.end,
                text: index < result.chunkTexts.count ? result.chunkTexts[index] : ""
            ))
        }
        try writeChunks(
            ChunksRecord(
                video: command.video.path,
                asr: command.asr.rawValue,
                windowSeconds: windowSeconds,
                chunks: records,
                fullText: result.fullText
            ),
            to: run
        )
        let totalCharacters = records.reduce(0) { $0 + $1.text.count }
        print("transcription : \(records.count) fenêtres, \(totalCharacters) caractères")
        print("run : \(run.path)")
    }

    // ------------------------------------------------------------------
    // aligner
    // ------------------------------------------------------------------

    static func align(_ command: Command) async throws {
        func usableRun() -> URL? {
            guard let candidate = findLatestRun(for: command.video) else { return nil }
            if let record = try? readChunks(candidate), record.chunks.count > 0 {
                return candidate
            }
            return nil
        }
        var run = usableRun()
        if run == nil {
            try await transcribe(command)
            run = usableRun()
        }
        guard let resolvedRun = run else { throw PipelineError.chunksMissing(command.video.path) }
        let samples = try ensureAudio(video: command.video, run: resolvedRun)
        let record = try readChunks(resolvedRun)

        var turns: [HighQualityTranslationTurn] = []
        for chunk in record.chunks where !chunk.text.trimmingCharacters(in: .whitespaces).isEmpty {
            for sentence in SRT.sentences(chunk.text) where SRT.containsJapanese(sentence) {
                turns.append(HighQualityTranslationTurn(
                    id: "c\(turns.count + 1)",
                    japanese: sentence,
                    sourceStart: chunk.start,
                    sourceEnd: chunk.end
                ))
            }
        }
        guard !turns.isEmpty else { throw PipelineError.emptyTranscription }

        let aligner = HighQualityForcedAlignerRuntime()
        let gate = ProgressGate()
        try await aligner.prepare { fraction, message in
            gate.report("aligner", fraction, message)
        }
        let exchange = try await aligner.align(samples: samples, turns: turns)

        var rawCues: [(start: Double, end: Double, text: String)] = []
        for chunk in exchange.chunks {
            let itemsByCue = Dictionary(grouping: chunk.rawItems, by: \.cueID)
            for cue in chunk.cues where !cue.text.trimmingCharacters(in: .whitespaces).isEmpty {
                let items = (itemsByCue[cue.id] ?? []).sorted { $0.start < $1.start }
                let text = SRT.punctuatedText(items: items, fallback: cue.text)
                rawCues.append((cue.start, cue.end, text))
            }
        }
        let finalCues = SRT.postProcess(rawCues)
        let srtURL = jaSRTURL(for: command.video)
        try SRT.write(finalCues, to: srtURL)
        print("alignement : \(finalCues.count) cues → \(srtURL.lastPathComponent)")
    }

    // ------------------------------------------------------------------
    // parlants
    // ------------------------------------------------------------------

    @discardableResult
    static func diarize(_ command: Command) async throws -> URL {
        let existing = findLatestRun(for: command.video)
        let run = try existing ?? makeRunDirectory()
        let samples = try ensureAudio(video: command.video, run: run)
        let policy = command.speakerCount
            .map(HighQualitySpeakerCountPolicy.expected)
            ?? .automatic
        let gate = ProgressGate()
        let speakerKit = HighQualitySpeakerKitRuntime(
            precision: .quantized,
            downloadBase: homeURL.appendingPathComponent("speakerkit", isDirectory: true).path
        )
        try await speakerKit.prepare { fraction, message in
            gate.report("parlants", fraction, message)
        }
        let exchange = try await speakerKit.diarize(
            samples: samples,
            speakerCountPolicy: policy
        )
        let rttmURL = run.appendingPathComponent("parlants.rttm")
        try Speakers.writeRTTM(exchange.spans, to: rttmURL, fileName: command.video.lastPathComponent)
        let ordered = Speakers.speakerOrder(
            segments: exchange.spans.map {
                RTTMSegment(speakerID: String($0.speakerID), label: nil, start: $0.start, duration: $0.end - $0.start)
            }
        )
        let totalDuration = ordered.reduce(0) { $0 + $1.total }
        print("parlants détectés : \(ordered.count)")
        for entry in ordered {
            let share = totalDuration > 0 ? Int((entry.total / totalDuration * 100).rounded()) : 0
            print("  \(entry.label ?? "\(entry.speakerID)") — \(Int(entry.total)) s (\(share)%)")
        }
        if let requested = command.speakerCount, requested != ordered.count {
            print("  (demandés : \(requested) — le modèle a produit \(ordered.count))")
        }
        return rttmURL
    }

    // ------------------------------------------------------------------
    // traduire
    // ------------------------------------------------------------------

    static func translate(_ command: Command) async throws {
        let jaURL = jaSRTURL(for: command.video)
        if !FileManager.default.fileExists(atPath: jaURL.path) {
            try await align(command)
        }
        let cues = try SRT.read(jaURL)
        guard !cues.isEmpty else { throw PipelineError.jaSRTMissing(jaURL.lastPathComponent) }

        // Parlants (si noms demandés, ou si un RTTM est attendu pour la finale).
        var rttmURL: URL?
        if command.names != nil || (command.verb == .finale && !command.sansParlants) {
            rttmURL = findRTTM(for: command.video)
            if rttmURL == nil {
                rttmURL = try await diarize(command)
            }
        }
        var speakerSegments: [RTTMSegment] = []
        var names: [String: String]?
        if let rttm = rttmURL {
            speakerSegments = try Speakers.parseRTTM(rttm)
            if let rawNames = command.names {
                names = try Speakers.parseNameMapping(
                    rawNames,
                    speakerOrder: Speakers.speakerOrder(segments: speakerSegments)
                )
            }
        }

        // Glossaire
        let glossaryURL = command.glossary ?? defaultGlossaryURL
        let terms = try Glossaire.terms(from: glossaryURL)

        // Tournées de traduction (contexte ± 2 cues).
        let turns = cues.enumerated().map { position, cue in
            let preceding = cues[max(0, position - 2)..<position].map(\.text)
            let following = cues[(position + 1)..<min(cues.count, position + 3)].map(\.text)
            return HighQualityTranslationTurn(
                id: "t\(cue.index)",
                japanese: cue.text,
                precedingJapanese: preceding,
                followingJapanese: following,
                speakerLabel: speakerLabel(for: cue, segments: speakerSegments, names: names, useLetters: command.verb == .finale)
            )
        }

        let gate = ProgressGate()
        let translator = LocalMLXTranslator(candidate: command.model)
        try await translator.prepare { fraction, message in
            gate.report("traduction", fraction, message)
        }
        let source = HighQualitySourceProvenance(
            path: command.video.path,
            fileName: command.video.lastPathComponent
        )
        let batch = HighQualityTranslationBatch(source: source, turns: turns, glossary: terms)
        let exchange = try await translator.translate(batch)
        var byID: [String: String] = [:]
        let envelopeData = Data(exchange.response.utf8)
        struct Envelope: Decodable {
            struct Item: Decodable {
                let id: String
                let text: String
            }
            let translations: [Item]
        }
        for item in (try JSONDecoder().decode(Envelope.self, from: envelopeData)).translations {
            byID[item.id] = item.text
        }

        // Résidus CJK → nouvelle tentative sans glossaire, sinon texte JA.
        var english = cues.map { cue in
            let translated = byID["t\(cue.index)"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (translated?.isEmpty == false) ? translated! : cue.text
        }
        var residualPositions = cues.indices.filter { position in
            english[position] != cues[position].text && Self.containsCJK(english[position])
        }
        if !residualPositions.isEmpty {
            print("traduction : \(residualPositions.count) cues avec résidus CJK — nouvelle tentative sans glossaire")
            let retryTurns = residualPositions.map { turns[$0] }
            let retryBatch = HighQualityTranslationBatch(source: source, turns: retryTurns, glossary: [])
            let retryExchange = try await translator.translate(retryBatch)
            let retryData = Data(retryExchange.response.utf8)
            let retryEnvelope = try JSONDecoder().decode(Envelope.self, from: retryData)
            for item in retryEnvelope.translations {
                let cueIndex = Int(item.id.dropFirst()) ?? 0
                let position = cues.firstIndex { $0.index == cueIndex }
                if let pos = position {
                    english[pos] = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let stillResidual = cues.indices.filter { position in
                english[position] != cues[position].text && Self.containsCJK(english[position])
            }
            for position in stillResidual {
                english[position] = cues[position].text
            }
            print("traduction : \(stillResidual.count) cues conservés en japonais (résidus persistants)")
        }

        // Préfixes de parlants sur le SRT EN.
        var prefixes: [String: String]?
        if !speakerSegments.isEmpty {
            prefixes = [:]
            for cue in cues {
                guard let speaker = Speakers.dominantSpeaker(
                    segments: speakerSegments,
                    start: cue.start,
                    end: cue.end
                ) else { continue }
                let label = (names ?? [:])[speaker] ?? letterLabel(for: speaker, in: speakerSegments)
                prefixes?[String(cue.index)] = "[\(label)]"
            }
        }
        let enCues = zip(cues, english).map { cue, text in
            Cue(index: cue.index, start: cue.start, end: cue.end, text: text)
        }
        let enURL = enSRTURL(for: command.video)
        try SRT.write(enCues, to: enURL, speakerPrefixes: prefixes)
        print("traduction : \(enCues.count) cues → \(enURL.lastPathComponent)")
        if let prefixes, !prefixes.isEmpty {
            print("préfixes de parlants : \(prefixes.values.count) cues affectés")
        }
    }

    private static func letterLabel(for speakerID: String, in segments: [RTTMSegment]) -> String {
        let labels = segments.compactMap(\.label).sorted()
        if let position = labels.firstIndex(of: speakerID) {
            return String(UnicodeScalar(UInt8(65 + position)))
        }
        return speakerID
    }

    private static func speakerLabel(
        for cue: Cue,
        segments: [RTTMSegment],
        names: [String: String]?,
        useLetters: Bool
    ) -> String? {
        guard !segments.isEmpty else { return nil }
        guard let speaker = Speakers.dominantSpeaker(
            segments: segments,
            start: cue.start,
            end: cue.end
        ) else { return nil }
        if let names, let name = names[speaker] {
            return name
        }
        if useLetters {
            return letterLabel(for: speaker, in: segments)
        }
        return nil
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)   // kana
                || (0x4E00...0x9FFF).contains(scalar.value) // kanji
                || (0x3400...0x4DBF).contains(scalar.value) // extension A
                || (0xFF66...0xFF9F).contains(scalar.value) // demi-chasse
                || (0x3000...0x303F).contains(scalar.value) // ponctuation CJK
        }
    }

    // ------------------------------------------------------------------
    // finale
    // ------------------------------------------------------------------

    static func finale(_ command: Command) async throws {
        try await transcribe(command)
        try await align(command)
        if !command.sansParlants {
            try await diarize(command)
        }
        try await translate(command)
    }
}
