import Foundation

// Parlants : RTTM (lecture/écriture), affectation du parlant dominant
// par cue (chevauchement maximal, sinon segment le plus proche),
// et mapping de noms.

struct RTTMSegment: Codable, Equatable, Sendable {
    var speakerID: String
    var label: String?
    var start: Double
    var duration: Double

    var end: Double { start + duration }
}

enum Speakers {
    /// Analyse un RTTM au format whisperkit-cli :
    ///   SPEAKER <fichier> <id> <début> <durée> <NA> <NA> <libellé> <NA> <NA>
    static func parseRTTM(_ url: URL) throws -> [RTTMSegment] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var segments: [RTTMSegment] = []
        for line in content.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 5,
                  fields[0].uppercased() == "SPEAKER",
                  let start = Double(fields[3]),
                  let duration = Double(fields[4]) else { continue }
            let speakerID = fields[2]
            let label = fields.count >= 8 && fields[7] != "<NA>" ? fields[7] : nil
            segments.append(RTTMSegment(speakerID: speakerID, label: label, start: start, duration: duration))
        }
        return segments
    }

    /// Écrit un RTTM au même format (libellés A, B, C… par identifiant).
    static func writeRTTM(
        _ spans: [HighQualityDiarizationSpan],
        to url: URL,
        fileName: String
    ) throws {
        let ordered = spans.sorted { ($0.speakerID, $0.start) < ($1.speakerID, $1.start) }
        var lines: [String] = []
        for span in ordered {
            let label = label(forSpeakerID: span.speakerID, in: ordered)
            lines.append(String(
                format: "SPEAKER %@ %@ %.3f %.3f <NA> <NA> %@ <NA> <NA>",
                fileName,
                String(span.speakerID),
                span.start,
                span.end - span.start,
                label
            ))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func label(forSpeakerID id: Int, in spans: [HighQualityDiarizationSpan]) -> String {
        let ids = Set(spans.map(\.speakerID)).sorted()
        guard let position = ids.firstIndex(of: id) else { return "S" }
        return String(UnicodeScalar(UInt8(65 + position)))
    }

    /// Parlant dominant d'un intervalle : qui recouvre le plus de temps ;
    /// à défaut, le segment le plus proche (tolérance 5 s, mesurée :
    /// tous les cues non recouverts le sont à moins de 4,5 s).
    static func dominantSpeaker(
        segments: [RTTMSegment],
        start: Double,
        end: Double
    ) -> String? {
        var totals: [String: Double] = [:]
        for segment in segments {
            let overlap = min(end, segment.end) - max(start, segment.start)
            if overlap > 0 {
                totals[segment.speakerID, default: 0] += overlap
            }
        }
        if let best = totals.max(by: { $0.value < $1.value }) {
            return best.key
        }
        var nearestGap = 5.0
        var nearest: String? = nil
        for segment in segments {
            let gap = segment.start >= end
                ? segment.start - end
                : (segment.end <= start) ? start - segment.end : 0
            if gap < nearestGap {
                nearestGap = gap
                nearest = segment.speakerID
            }
        }
        return nearest
    }

    /// Ordre des parlants par temps de parole décroissant (pour `--noms 0=…`).
    static func speakerOrder(
        segments: [RTTMSegment]
    ) -> [(speakerID: String, label: String?, total: Double)] {
        var totals: [String: Double] = [:]
        var labels: [String: String?] = [:]
        for segment in segments {
            totals[segment.speakerID, default: 0] += segment.duration
            labels[segment.speakerID] = segment.label
        }
        return totals
            .sorted { $0.value > $1.value }
            .map { entry in
                (
                    speakerID: entry.key,
                    label: labels[entry.key] ?? nil,
                    total: entry.value
                )
            }
    }

    /// `--noms 0=Hirow,1=Klin` : l'indice pointe dans l'ordre du
    /// temps de parole décroissant. Retourne [speakerID → nom].
    static func parseNameMapping(
        _ raw: String,
        speakerOrder: [(speakerID: String, label: String?, total: Double)]
    ) throws -> [String: String] {
        var mapping: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, let index = Int(parts[0]) else {
                throw NameMappingError.invalidPair(String(pair))
            }
            guard index >= 0, index < speakerOrder.count else {
                throw NameMappingError.outOfRange(String(pair))
            }
            mapping[speakerOrder[index].speakerID] = parts[1]
        }
        return mapping
    }

    enum NameMappingError: LocalizedError {
        case invalidPair(String)
        case outOfRange(String)

        var errorDescription: String? {
            switch self {
            case .invalidPair(let pair): "paire de noms invalide : « \(pair) » (attendu : 0=Nom,1=Nom…)"
            case .outOfRange(let pair): "indice hors plage : « \(pair) »"
            }
        }
    }
}
