import Foundation

// Glossaire : lit le fichier de termes (format « - forme1 / forme2 → anglais »)
// vers des HighQualityGlossaryPromptTerm.

enum Glossaire {
    /// Analyse le glossaire. Lignes reconnues :
    ///   - FORME / FORME  → anglais          (formes JA → EN)
    ///   - FORME  → anglais  (note)           (la note [?]/(…) est écartée)
    ///   - anglais  (= FORME JA)              (EN d'abord, JA entre parenthèses)
    ///   - anglais / alias                     (sans forme JA)
    static func terms(from url: URL) throws -> [HighQualityGlossaryPromptTerm] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let content = try String(contentsOf: url, encoding: .utf8)
        var terms: [HighQualityGlossaryPromptTerm] = []
        var nextID = 1
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            let body = String(trimmed.dropFirst(2))
            let term: HighQualityGlossaryPromptTerm?
            if let arrowRange = body.range(of: "→") {
                let jaPart = String(body[..<arrowRange.lowerBound])
                let enPart = String(body[arrowRange.upperBound...])
                // Cas « anglais (= FORME JA) » : la forme JA est dans la parenthèse.
                if let paren = enPart.range(of: "(= ") {
                    let english = stripNote(String(enPart[..<paren.lowerBound]))
                    let jaInside = dropClosingParen(String(enPart[paren.upperBound...]))
                    term = HighQualityGlossaryPromptTerm(
                        id: "term-\(nextID)",
                        japanese: splitForms(jaInside),
                        english: english.isEmpty ? "glossaire" : english,
                        englishAliases: []
                    )
                } else {
                    let (english, aliases) = splitEnglish(enPart)
                    term = HighQualityGlossaryPromptTerm(
                        id: "term-\(nextID)",
                        japanese: splitForms(jaPart),
                        english: english.isEmpty ? "glossaire" : english,
                        englishAliases: aliases
                    )
                }
            } else {
                // Ligne anglaise seule (phrase récurrente), éventuellement
                // avec la forme JA en note : « Freeze it! (= 凍らせろ！) ».
                let (english, aliases) = splitEnglish(body)
                var japanese: [String] = []
                if let paren = body.range(of: "(= ") {
                    let inside = dropClosingParen(String(body[paren.upperBound...]))
                    japanese = splitForms(inside)
                }
                term = HighQualityGlossaryPromptTerm(
                    id: "term-\(nextID)",
                    japanese: japanese,
                    english: english,
                    englishAliases: aliases
                )
            }
            if let parsed = term, !parsed.english.isEmpty {
                terms.append(parsed)
                nextID += 1
            }
        }
        return terms
    }

    /// Formes japonaises du glossaire, à passer au Speech analyzer comme
    /// « context strings » (bias lexical : le transcribeur Apple privilégie ces
    /// termes propres). Aplati, dédupliqué (ordre préservé), plafonné à 100
    /// (limite du framework).
    static func contextualStrings(terms: [HighQualityGlossaryPromptTerm], cap: Int = 100) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in terms {
            for form in term.japanese {
                let trimmed = form.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                out.append(trimmed)
            }
        }
        return Array(out.prefix(cap))
    }

    /// Découpe une liste de formes JA séparées par « / » et écarte
    /// les notes entre parenthèses : « 子供 (monstre) » → « 子供 ».
    private static func splitForms(_ part: String) -> [String] {
        part.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { form in
                if let open = form.range(of: " ("),
                   form.lastIndex(of: ")") != nil {
                    return String(form[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
                return form
            }
            .filter { !$0.isEmpty }
    }

    /// Sépare le terme EN principal de ses alias (après un « / ») et
    /// écarte les notes « [?] (…) ».
    private static func splitEnglish(_ part: String) -> (String, [String]) {
        var cleaned = part.trimmingCharacters(in: .whitespaces)
        if let bracket = cleaned.range(of: " [?]") {
            cleaned = String(cleaned[..<bracket.lowerBound])
        }
        if let paren = cleaned.range(of: " (") {
            cleaned = String(cleaned[..<paren.lowerBound])
        }
        let pieces = cleaned.split(separator: "/").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'«»"))
        }.filter { !$0.isEmpty }
        let main = pieces.first ?? ""
        let aliases = Array(pieces.dropFirst())
        return (main, aliases)
    }

    private static func dropClosingParen(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(")") {
            return String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func stripNote(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        if let bracket = cleaned.range(of: " [?]") {
            cleaned = String(cleaned[..<bracket.lowerBound])
        }
        if let paren = cleaned.range(of: " (") {
            cleaned = String(cleaned[..<paren.lowerBound])
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
