import Foundation

@main
enum MlxTranslateMain {
    static func main() async {
        do {
            let command = try CLIParser.parse(CommandLine.arguments)
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
