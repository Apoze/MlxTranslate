import SwiftUI
@testable import MlxTranslate

/// Onglet Live : choix de l'application à capturer, du modèle de traduction, de la
/// latence ; Démarrer/Arrêter. Au démarrage, la barre de sous-titres flottante
/// (EN, preview → final) apparaît ; le SRT est écrit dans ~/.mlxtranslate.
struct LiveView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Application") {
                    HStack {
                        Picker("", selection: $model.liveApp) {
                            ForEach(model.liveApps, id: \.id) { app in
                                Text(app.name).tag(app.name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        Button {
                            model.refreshApps()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Actualiser la liste des applications capturables")
                    }
                }
                LabeledContent("Traduction (EN)") {
                    Picker("", selection: $model.liveModel) {
                        ForEach(Array(LocalMLXTranslator.Candidate.allCases), id: \.self) { c in
                            Text(c.displayLabel).tag(c)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                LabeledContent("Latence ASR") {
                    Picker("", selection: $model.liveDelay) {
                        ForEach(Array(VoxtralTranscriptionDelay.allCases), id: \.self) { d in
                            Text("\(d.rawValue) ms").tag(d)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }

            HStack {
                Button(model.liveRunning ? "Arrêter" : "Démarrer le live") {
                    if model.liveRunning {
                        model.stopLive()
                    } else {
                        model.startLive()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.liveApps.isEmpty && !model.liveRunning)
                Text(model.liveStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Au démarrage, une barre de sous-titres transparente et déplaçable "
                 + "apparaît sur l'écran (fenêtre séparée de celle-ci). Le SRT est écrit "
                 + "dans ~/.mlxtranslate.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}
