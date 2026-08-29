import Foundation

// Analyse des arguments du CLI (aucune dépendance externe).

struct Command {
    enum Verb: String {
        case transcrire = "transcrire"
        case aligner = "aligner"
        case parlants = "parlants"
        case traduire = "traduire"
        case finale = "finale"
    }

    var verb: Verb
    var video: URL
    var asr: ASRBackend = .default
    var language: String = "ja"
    var speakerCount: Int?
    var model: LocalMLXTranslator.Candidate = .productDefault
    var glossary: URL?
    var names: String?
}

enum CLIParser {
    struct Help: LocalizedError {
        var errorDescription: String? {
            """
            mlxtranslate — transcription, alignement, parlants et traduction (local, MLX)

            Utilisation : mlxtranslate <commande> <média> [options]

            Commandes :
              transcrire  transcription ASR (texte par fenêtre, chunks.json)
              aligner     horodatage mot-à-mot, écrit « <nom> (JA).srt »
              parlants    diarisation, écrit le RTTM et annonce les parlants
              traduire    traduction EN, écrit « <nom> (EN).srt »
              finale      chaîne complète (ASR → alignement → parlants → traduction)
              aider       cette aide

            Options :
              --asr voxtral3b|voxtral|voxtral4b|qwen3asr
                     backend ASR (défaut : voxtral3b)
                     voxtral3b   = 3B forçage langue fort (offline, python)
                     voxtral     = 4B Realtime sidecar (direct/live)
                     voxtral4b   = 4B Realtime natif Swift
                     qwen3asr    = Qwen3-ASR 0,6B (test)
              --lang ja|auto                       langue forcée de l'ASR (défaut : ja)
              --nb N                               nombre de parlants forcé (défaut : auto)
              --modele qwen3-8b|qwen25-7b|qwen3-14b|gemma-12b|gemma-4b
                                                    modèle de traduction (défaut : qwen3-8b)
              --noms 0=Hirow,1=Klin                noms des parlants (l'indice suit le
                                                    temps de parole décroissant)
              --glossaire <chemin>                  glossaire (défaut : ~/.mlxtranslate/glossaire.txt)
            """
        }
    }

    static func parse(_ arguments: [String]) throws -> Command {
        var verb: Command.Verb?
        var video: URL?
        var asr = ASRBackend.default
        var language = "ja"
        var speakerCount: Int?
        var model = LocalMLXTranslator.Candidate.productDefault
        var glossary: URL?
        var names: String?

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "aider", "-h", "--help":
                throw Help()
            case "transcrire", "aligner", "parlants", "traduire", "finale":
                guard verb == nil else { throw unknown("commande en double : \(argument)") }
                verb = Command.Verb(rawValue: argument)
            case "--asr":
                guard index + 1 < arguments.count else { throw unknown("--asr sans valeur") }
                guard let parsed = ASRBackend(rawValue: arguments[index + 1].lowercased()) else {
                    throw unknown("backend ASR inconnu : \(arguments[index + 1])")
                }
                asr = parsed
                index += 1
            case "--lang":
                guard index + 1 < arguments.count else { throw unknown("--lang sans valeur") }
                language = arguments[index + 1].lowercased()
                index += 1
            case "--nb":
                guard index + 1 < arguments.count, let count = Int(arguments[index + 1]) else {
                    throw unknown("--nb attend un nombre")
                }
                guard HighQualitySpeakerCountPolicy.validExpectedCounts.contains(count) else {
                    throw unknown("--nb hors plage (\(HighQualitySpeakerCountPolicy.validExpectedCounts))")
                }
                speakerCount = count
                index += 1
            case "--modele":
                guard index + 1 < arguments.count else { throw unknown("--modele sans valeur") }
                model = try LocalMLXTranslator.Candidate.cliValue(arguments[index + 1])
                index += 1
            case "--noms":
                guard index + 1 < arguments.count else { throw unknown("--noms sans valeur") }
                names = arguments[index + 1]
                index += 1
            case "--glossaire":
                guard index + 1 < arguments.count else { throw unknown("glossaire sans valeur") }
                glossary = URL(
                    fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath as String
                )
                index += 1
            case _ where argument.hasPrefix("-"):
                throw unknown("option inconnue : \(argument)")
            default:
                guard video == nil else { throw unknown("média en double : \(argument)") }
                video = URL(
                    fileURLWithPath: NSString(string: argument).expandingTildeInPath as String
                )
            }
            index += 1
        }
        guard let selectedVerb = verb, let selectedVideo = video else {
            throw Help()
        }
        return Command(
            verb: selectedVerb,
            video: selectedVideo,
            asr: asr,
            language: language,
            speakerCount: speakerCount,
            model: model,
            glossary: glossary,
            names: names
        )
    }

    private static func unknown(_ detail: String) -> LocalizedError {
        UnknownArgument(detail: detail)
    }

    struct UnknownArgument: LocalizedError {
        let detail: String
        var errorDescription: String? { "« \(detail) » — utilisez `mlxtranslate aider`." }
    }
}

extension LocalMLXTranslator.Candidate {
    static func cliValue(_ raw: String) throws -> Self {
        switch raw.lowercased() {
        case "qwen25-7b", "qwen2.5-7b", "qwen2_5_7b": return .qwen2_5_7B
        case "qwen3-8b", "qwen3_8b": return .qwen3_8B
        case "qwen3-14b", "qwen3_14b": return .qwen3_14B
        case "gemma-12b", "gemma12b", "translategemma-12b": return .translateGemma12B
        case "gemma-4b", "gemma4b", "translategemma-4b": return .translateGemma4B
        default:
            throw CLIParser.UnknownArgument(detail: "modèle inconnu : \(raw)")
        }
    }
}
