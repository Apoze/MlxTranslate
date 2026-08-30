import Foundation
@testable import MlxTranslate

@main
enum MlxTranslateMain {
    // Codes de sortie distincts (0 succès, 2 média, 3 transcrire, 4 aligner,
    // 5 parlants, 6 traduire, 7 TCC/capture). Permet aux scripts de détecter
    // l'étape en échec.
    static func exitCode(for error: Error) -> Int32 {
        if let pipelineError = error as? Pipeline.PipelineError {
            switch pipelineError {
            case .mediaNotFound, .audioMissing: return 2
            case .chunksMissing, .transcriptionFailed, .emptyTranscription, .metalLibraryMissing: return 3
            case .alignmentFailed, .jaSRTMissing: return 4
            case .diarizationFailed, .rttmMissing: return 5
            case .translationFailed: return 6
            }
        }
        if error is LiveCaptureError || error is LiveError {
            return 7  // TCC/capture (mode live)
        }
        return 1
    }

    static func main() async {
        do {
            let command = try CLIParser.parse(CommandLine.arguments)
            if command.verb == .live {
                if command.listApps {
                    try await Live.listApps()
                } else if #available(macOS 26.4, *) {
                    try await Live.run(command)
                } else {
                    Pipeline.log("Le mode live (traduction EN) nécessite macOS 26.4 ou plus récent.")
                    exit(1)
                }
                return
            }
            if command.verb == .bench {
                // Inspection RAM / latence / qualité (hors produit).
                try await Bench.run(command)
                return
            }
            if command.verb == .finale {
                Pipeline.log("chaîne complète : ASR → alignement → parlants → traduction")
            }
            try await Pipeline.run(command)
        } catch is CLIParser.Help {
            print(String(describing: CLIParser.Help().localizedDescription ?? ""))
            exit(0)
        } catch let error {
            Pipeline.log("Erreur : \(error.localizedDescription)")
            exit(exitCode(for: error))
        }
    }
}
