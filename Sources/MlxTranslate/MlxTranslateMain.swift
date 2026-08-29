import Foundation

@main
enum MlxTranslateMain {
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
            if command.verb == .finale {
                Pipeline.log("chaîne complète : ASR → alignement → parlants → traduction")
            }
            try await Pipeline.run(command)
        } catch is CLIParser.Help {
            print(String(describing: CLIParser.Help().localizedDescription ?? ""))
            exit(0)
        } catch {
            Pipeline.log("Erreur : \(error.localizedDescription)")
            exit(1)
        }
    }
}
