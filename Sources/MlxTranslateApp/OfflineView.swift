import SwiftUI
import UniformTypeIdentifiers
@testable import MlxTranslate

/// Onglet Offline : drop d'une vidéo, options (traduire ou non, modèle), Lancer,
/// log + résultat. Branche `AppModel.runOffline()` sur la chaîne de la librairie.
struct OfflineView: View {
    @ObservedObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Zone de drop
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isTargeted ? Color.accentColor : Color.secondary,
                            style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .frame(height: 84)
                Text(model.offlineURL?.lastPathComponent ?? "Déposer une vidéo ici (.mp4, .mov, …)")
                    .font(.callout)
                    .foregroundStyle(isTargeted ? .primary : .secondary)
            }
            .onDrop(of: [UTType.movie, UTType.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.offlineURL = url }
                }
                return true
            }

            // Options
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Traduire (EN)", isOn: $model.offlineDoTranslate)
                if model.offlineDoTranslate {
                    Picker("Modèle de traduction", selection: $model.offlineModel) {
                        ForEach(Array(LocalMLXTranslator.Candidate.allCases), id: \.self) { c in
                            Text(c.displayLabel).tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(model.offlineRunning ? "…" : "Lancer") { model.runOffline() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.offlineRunning || model.offlineURL == nil)
                if !model.offlineRunning, let result = model.offlineResultURL {
                    Button("Ouvrir le dossier") {
                        NSWorkspace.shared.open(result.deletingLastPathComponent())
                    }
                }
            }

            if !model.offlineLog.isEmpty {
                Text(model.offlineLog)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(20)
    }
}
