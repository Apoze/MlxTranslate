import Foundation

// Analyse des arguments du CLI (aucune dépendance externe).

struct Command {
    enum Verb: String {
        case transcrire = "transcrire"
        case aligner = "aligner"
        case parlants = "parlants"
        case traduire = "traduire"
        case finale = "finale"
        case live = "live"
        case nettoyer = "nettoyer"
        case bench = "bench"
    }

    var verb: Verb
    var video: URL
    var asr: ASRBackend = .default
    var language: String = "ja"
    var speakerCount: Int?
    var model: LocalMLXTranslator.Candidate = .productDefault
    var glossary: URL?
    var names: String?
    var sansParlants: Bool = false
    // Live
    var app: String?
    var liveASR: LiveFinalASR = .productDefault
    var liveDelay: VoxtralTranscriptionDelay = .milliseconds960
    var sansTraduction: Bool = false
    var livePreview: Bool = true
    var liveOutput: URL?
    var maxSeconds: Double?
    var listApps: Bool = false
    /// Cadence des snapshots roulants Qwen (live uniquement ; 1/2/3 s).
    var liveCadence: QwenPseudoLiveCadence = .productDefault
    /// Source de la ligne roulante EN du live (mode Qwen) : Apple basse
    /// latence (défaut) ou MLX streaming (option lente, glossaire).
    var livePreviewSource: LivePreviewMode = .productDefault
    /// Modèle EN du live : `--modele` explicite, sinon le défaut live
    /// (qwen3-4b — distinct du défaut offline, `model`).
    var liveModel: LocalMLXTranslator.Candidate = .productDefault
    // Bench (inspection RAM / latence / qualité — pas le produit)
    var benchSansApple: Bool = false
    var benchSansASR: Bool = false
    var benchSansMT: Bool = false
    var benchMT: [String] = []
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
              live        sous-titres EN temps réel de l'audio d'une application (JA)
              nettoyer    nettoie les sessions ~/.mlxtranslate (runs, live-*.srt,
                          captures/), garde les modèles et le glossaire
              bench       inspection hors produit : RAM + latence + qualité des
                          outils Apple on-device et des modèles MLX candidats,
                          sur un clip (logs complets, sorties /tmp/mlx_bench_*)
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
              --sans-parlants                        finale sans diarisation (pas de noms de locuteurs)

            Live (JA → EN, temps réel) :
              live --list                             liste les applications capturables
              live --app <bundleID|nom>                capture l'audio de l'application
                --sans-preview                         pas de preview (traduction finale seule)
                --sans-traduction                      JA seul (pas de traduction EN finale)
                --modele <id>                          modèle EN (défaut live : qwen3-4b ;
                                                       `--modele qwen3-8b` force le 8b, etc.)
                --cadence 1|2|3                        cadence des snapshots roulants Qwen en
                                                       secondes (défaut : 2 ; prise en compte
                                                       au démarrage du live)
                --preview-source apple|mlx             ligne roulante : Apple (basse latence,
                                                        défaut) ou MLX streaming (lente)
                --glossaire <chemin>                   glossaire de la traduction EN
                --live-asr qwenja|voxtral              ASR final (défaut : qwenja, Qwen3-ASR 1,7B JA)
                --delay 960|1200|2400                  latence Voxtral (défaut : 960)
                --sortie <fichier>                     SRT live (défaut : ~/.mlxtranslate/live-<date>.srt)
                --max N                                arrêt automatique après N secondes
              bench <clip.wav>                       inspection RAM/latence/qualité :
                --sans-apple                         saute la partie Apple on-device
                --sans-asr                           saute les ASR MLX (SenseVoiceSmall,
                                                     Qwen3-ASR 1,7B)
                --sans-mt                            saute la partie traduction MLX
                --mt a,b,c                           sous-ensemble de modèles MT
                                                     (translategemma-4b, qwen3-1.7b,
                                                     qwen3-4b, qwen3-8b ; défaut : tous)
              Env : MLXTRANSLATE_BENCH_LOG = fichier de log bench (défaut /tmp/mlx_bench.log)
                    MLXTRANSLATE_PSEUDO_LIVE=0 désactive la roulante Qwen
                    pseudo-live (mode qwenja ; active par défaut).
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
        var sansParlants = false
        var app: String?
        var liveDelay = VoxtralTranscriptionDelay.milliseconds960
        var sansTraduction = false
        var livePreview = true
        var liveOutput: URL?
        var maxSeconds: Double?
        var liveASR = LiveFinalASR.productDefault
        var listApps = false
        var liveCadence = QwenPseudoLiveCadence.productDefault
        var livePreviewSource = LivePreviewMode.productDefault
        // `--modele` explicit (live) : sinon le défaut live (qwen3-4b) s'applique
        // indépendamment du défaut offline (qwen3-8b).
        var modelExplicit = false
        var benchSansApple = false
        var benchSansASR = false
        var benchSansMT = false
        var benchMT: [String] = []

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "aider", "-h", "--help":
                throw Help()
            case "transcrire", "aligner", "parlants", "traduire", "finale", "live", "nettoyer", "bench":
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
                modelExplicit = true
                index += 1
            case "--cadence":
                guard index + 1 < arguments.count else { throw unknown("--cadence sans valeur") }
                guard let raw = Int(arguments[index + 1]),
                      let parsed = QwenPseudoLiveCadence(rawValue: raw) else {
                    throw unknown("--cadence doit être 1, 2 ou 3")
                }
                liveCadence = parsed
                index += 1
            case "--preview-source":
                guard index + 1 < arguments.count else { throw unknown("--preview-source sans valeur") }
                guard let parsed = LivePreviewMode(rawValue: arguments[index + 1].lowercased()) else {
                    throw unknown("--preview-source doit être apple ou mlx")
                }
                livePreviewSource = parsed
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
            case "--sans-parlants":
                sansParlants = true
            case "--app":
                guard index + 1 < arguments.count else { throw unknown("--app sans valeur") }
                app = arguments[index + 1]
                index += 1
            case "--list":
                listApps = true
            case "--live-asr":
                guard index + 1 < arguments.count else { throw unknown("--live-asr sans valeur") }
                guard let parsed = LiveFinalASR.cliValue(arguments[index + 1]) else {
                    throw unknown("--live-asr doit être qwenja ou voxtral")
                }
                liveASR = parsed
                index += 1
            case "--delay":
                guard index + 1 < arguments.count,
                      let raw = Int(arguments[index + 1]),
                      let parsed = VoxtralTranscriptionDelay(rawValue: raw) else {
                    throw unknown("--delay doit être 960, 1200 ou 2400")
                }
                liveDelay = parsed
                index += 1
            case "--sans-traduction":
                sansTraduction = true
            case "--sans-preview":
                livePreview = false
            case "--sortie":
                guard index + 1 < arguments.count else { throw unknown("--sortie sans valeur") }
                liveOutput = URL(
                    fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath as String
                )
                index += 1
            case "--max":
                guard index + 1 < arguments.count, let seconds = Double(arguments[index + 1]) else {
                    throw unknown("--max attend une durée en secondes")
                }
                maxSeconds = seconds
                index += 1
            case "--sans-apple":
                benchSansApple = true
            case "--sans-asr":
                benchSansASR = true
            case "--sans-mt":
                benchSansMT = true
            case "--mt":
                guard index + 1 < arguments.count else { throw unknown("--mt sans valeur") }
                for item in arguments[index + 1].split(separator: ",") {
                    let raw = String(item).trimmingCharacters(in: .whitespaces)
                    guard !raw.isEmpty else { continue }
                    // Validation précoce : nom inconnu → erreur (et non échec tardif).
                    _ = try LocalMLXTranslator.Candidate.cliValue(raw)
                    benchMT.append(raw)
                }
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
        guard let selectedVerb = verb else {
            throw Help()
        }
        if selectedVerb == .live {
            // `live` n'a pas de média positionnel : l'app vient de `--app`.
            let videoURL = video ?? URL(fileURLWithPath: app ?? "live")
            // Modèle EN par défaut du live : qwen3-4b (testé : qualité
            // supérieure au 1.7b, sans ralentissement ressenti) ; `--modele`
            // reste disponible pour forcer un autre candidat (qwen3-8b…).
            let liveModel: LocalMLXTranslator.Candidate = modelExplicit ? model : .qwen3_4B
            return Command(
                verb: .live,
                video: videoURL,
                model: model,
                glossary: glossary,
                app: app,
                liveASR: liveASR,
                liveDelay: liveDelay,
                sansTraduction: sansTraduction,
                livePreview: livePreview,
                liveOutput: liveOutput,
                maxSeconds: maxSeconds,
                listApps: listApps,
                liveCadence: liveCadence,
                livePreviewSource: livePreviewSource,
                liveModel: liveModel
            )
        }
        if selectedVerb == .nettoyer {
            // `nettoyer` n'a pas de média : nettoie les sessions, garde les modèles.
            let videoURL = video ?? URL(fileURLWithPath: "nettoyer")
            return Command(verb: .nettoyer, video: videoURL)
        }
        if selectedVerb == .bench {
            // `bench` exige un clip 16 kHz en argument positionnel.
            guard let clip = video else {
                throw unknown("bench : média manquant (ex. `mlxtranslate bench /tmp/test_ja.wav`)")
            }
            return Command(
                verb: .bench,
                video: clip,
                model: model,
                glossary: glossary,
                benchSansApple: benchSansApple,
                benchSansASR: benchSansASR,
                benchSansMT: benchSansMT,
                benchMT: benchMT
            )
        }
        guard let selectedVideo = video else {
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
            names: names,
            sansParlants: sansParlants
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
        case "qwen3-1.7b", "qwen3_1.7b", "qwen3-1b7", "qwen3_1b7": return .qwen3_1B7
        case "qwen3-4b", "qwen3_4b": return .qwen3_4B
        default:
            throw CLIParser.UnknownArgument(detail: "modèle inconnu : \(raw)")
        }
    }
}
