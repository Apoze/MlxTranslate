import Foundation

// SRT : modèle de cue, lecture/écriture, et post-traitement identique
// à l'ancien outil python (fusion des cues courts, scission des cues > 12 s).

struct Cue: Codable, Equatable, Sendable {
    var index: Int
    var start: Double
    var end: Double
    var text: String
}

let sentenceEnders: Set<Character> = Set("。！？…!?")

enum SRT {
    static func formatTime(_ time: Double) -> String {
        let clamped = max(0, time)
        let totalMilliseconds = Int((clamped * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let seconds = (totalMilliseconds / 1000) % 60
        let milliseconds = totalMilliseconds % 1000
        return String(
            format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds
        )
    }

    static func parseTime(_ raw: String) -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let millisecondSplit = trimmed.split(separator: ",", maxSplits: 1)
        let timeParts = millisecondSplit.first?.split(separator: ":") ?? []
        guard timeParts.count == 3,
              let hours = Double(timeParts[0]),
              let minutes = Double(timeParts[1]),
              let seconds = Double(timeParts[2]) else {
            return 0
        }
        let milliseconds = millisecondSplit.count > 1 ? Double(millisecondSplit[1]) ?? 0 : 0
        return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000
    }

    static func read(_ url: URL) throws -> [Cue] {
        let content = try String(contentsOf: url, encoding: .utf8)
        var cues: [Cue] = []
        var index = 0
        for block in content.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }
            let first = lines[0]
            guard lines[1].contains("-->") else { continue }
            if let parsedIndex = Int(first) { index = parsedIndex } else { index += 1 }
            let timeParts = lines[1].split(separator: "-->").map { $0.trimmingCharacters(in: .whitespaces) }
            guard timeParts.count == 2 else { continue }
            let start = parseTime(timeParts[0])
            let end = parseTime(timeParts[1])
            let text = lines.dropFirst(2).joined(separator: "\n")
            cues.append(Cue(index: index, start: start, end: end, text: text))
        }
        return cues
    }

    static func write(_ cues: [Cue], to url: URL, speakerPrefixes: [String: String]? = nil) throws {
        var blocks: [String] = []
        for (offset, cue) in cues.enumerated() {
            let prefix = speakerPrefixes?[String(cue.index)] ?? ""
            let textLines = cue.text.components(separatedBy: "\n")
            let firstLine = prefix.isEmpty ? textLines.first ?? "" : prefix + " " + (textLines.first ?? "")
            var lines: [String]
            if textLines.count > 1 {
                lines = [firstLine] + textLines.dropFirst()
            } else {
                lines = [firstLine]
            }
            blocks.append("\(cue.index)\n\(formatTime(cue.start)) --> \(formatTime(cue.end))\n" + lines.joined(separator: "\n"))
        }
        try (blocks.joined(separator: "\n\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Découpe un texte en phrases aux caractères finaux (on garde le final
    /// avec sa phrase). Les tronçons sans final restent ensemble.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if sentenceEnders.contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Contient au moins un caractère japonais (hiragana / katakana / kanji) ?
    /// Permet de sauter les tours non alignables (emoji « 🎵 », symboles…).
    static func containsJapanese(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if (0x3040...0x30FF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
            {
                return true
            }
        }
        return false
    }

    // ------------------------------------------------------------------
    // Post-traitement : même algorithme que l'outil python historique.
    //   (a) fusion avec le cue suivant si gap <= 3 s et (le cue ne se
    //       termine pas par un final, ou le cue est < 1,5 s et la fusion
    //       reste <= 15 s) ;
    //   (b) scission des cues > 12 s au final le plus proche du milieu.
    // ------------------------------------------------------------------

    static func postProcess(_ rawCues: [(start: Double, end: Double, text: String)]) -> [Cue] {
        var out: [[Double]] = rawCues.map { [$0.start, $0.end] }
        var texts: [String] = rawCues.map { $0.text }
        var changed = true
        while changed {
            changed = false
            var newOut: [[Double]] = []
            var newTexts: [String] = []
            var i = 0
            while i < out.count {
                let cs = out[i][0]
                let ce = out[i][1]
                let txt = texts[i]
                if i + 1 < out.count {
                    let ncs = out[i + 1][0]
                    let nce = out[i + 1][1]
                    let ntxt = texts[i + 1]
                    let gap = ncs - ce
                    let endsWithEnder = txt.last.map { sentenceEnders.contains($0) } ?? false
                    if gap <= 3.0 && (!endsWithEnder || ((ce - cs) < 1.5 && (nce - cs) <= 15.0)) {
                        newOut.append([cs, nce])
                        newTexts.append(txt + ntxt)
                        i += 2
                        changed = true
                        continue
                    }
                }
                newOut.append(out[i])
                newTexts.append(txt)
                i += 1
            }
            out = newOut
            texts = newTexts
        }

        var finalCues: [Cue] = []
        for pairIndex in out.indices {
            let cs = out[pairIndex][0]
            let ce = out[pairIndex][1]
            var parts: [(Double, Double, String)] = [(cs, ce, texts[pairIndex])]
            var again = true
            while again {
                again = false
                var next: [(Double, Double, String)] = []
                for part in parts {
                    next.append(contentsOf: splitOnce(part.0, part.1, part.2))
                }
                if next.count != parts.count { again = true }
                parts = next
            }
            for part in parts {
                finalCues.append(Cue(
                    index: finalCues.count + 1,
                    start: part.0,
                    end: part.1,
                    text: part.2.trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return finalCues
    }

    /// Reconstruit le texte d'une cue à partir des items caractère-à-caractère
    /// de l'aligneur, en insérant «。» aux vraies pauses (≥0,8 s) — l'ASR
    /// sort un texte sans ponctuation. Le point-virgule «、» est évité car
    /// les items sont au niveau caractère : un «、» tomberait au milieu d'un
    /// mot. Seules les longues silences (≥0,8 s) marquent une fin de phrase.
    static func punctuatedText(
        items: [HighQualityAlignmentItem],
        fallback: String
    ) -> String {
        guard !items.isEmpty else { return fallback }
        let sorted = items.sorted { $0.start < $1.start }
        var text = sorted[0].text
        var previousEnd = sorted[0].end
        for item in sorted.dropFirst() {
            let gap = item.start - previousEnd
            if gap >= 0.8 {
                text += "。" + item.text
            } else {
                text += item.text
            }
            previousEnd = item.end
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func splitOnce(_ cs: Double, _ ce: Double, _ text: String) -> [(Double, Double, String)] {
        let duration = ce - cs
        if duration <= 12.0 || text.count < 4 {
            return [(cs, ce, text)]
        }
        let candidates = text.indices.filter { sentenceEnders.contains(text[$0]) }
        let middle = text.count / 2
        let splitPoint: Int
        // On ne coupe que sur un point final « utilisable » (entre 20 % et 80 %
        // du texte). Sinon (Voxtral 4B sort du texte sans 「。」) on retombe sur
        // le point médian : un point final isolé en bout de phrase ne doit pas
        // empêcher de couper une longue cue.
        let usable = candidates.filter { index in
            let pos = text.distance(from: text.startIndex, to: index) + 1
            return pos > text.count / 5 && pos < text.count * 4 / 5
        }
        if let nearest = usable.min(by: { abs(text.distance(from: $0, to: text.startIndex) - middle) < abs(text.distance(from: $1, to: text.startIndex) - middle) }) {
            var point = text.distance(from: text.startIndex, to: nearest) + 1
            var index = text.index(text.startIndex, offsetBy: point)
            while index < text.endIndex, sentenceEnders.contains(text[index]) {
                point += 1
                index = text.index(after: index)
            }
            if point <= 0 || point >= text.count { splitPoint = middle + 1 } else { splitPoint = point }
        } else {
            splitPoint = middle + 1
        }
        if splitPoint <= 0 || splitPoint >= text.count { return [(cs, ce, text)] }
        let t1 = cs + duration * (Double(splitPoint) / Double(text.count))
        let first = text.prefix(splitPoint).trimmingCharacters(in: .whitespaces)
        let second = text.dropFirst(splitPoint).trimmingCharacters(in: .whitespaces)
        return [(cs, t1, first), (t1, ce, second)]
    }
}
