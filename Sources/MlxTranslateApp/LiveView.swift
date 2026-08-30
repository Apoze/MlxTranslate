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
                LabeledContent("ASR final") {
                    Picker("", selection: $model.liveASR) {
                        ForEach(Array(LiveFinalASR.allCases), id: \.self) { mode in
                            Text(mode.displayLabel).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                LabeledContent("Pseudo-live Qwen") {
                    Toggle("Snapshots roulants (2 s)", isOn: $model.livePseudoLive)
                        .disabled(model.liveASR != LiveFinalASR.qwenJA)
                        .help("Snapshots cumulatifs de la clause en cours (cadence 2 s) — mode Qwen3-ASR uniquement")
                }
                LabeledContent("Latence ASR") {
                    Picker("", selection: $model.liveDelay) {
                        ForEach(Array(VoxtralTranscriptionDelay.allCases), id: \.self) { d in
                            Text("\(d.rawValue) ms").tag(d)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    .disabled(model.liveASR != LiveFinalASR.voxtralQ4)
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
                 + "apparaît sur l'écran (fenêtre séparée de celle-ci) : 2 lignes — "
                 + "l'aperçu roulant en bas, le final le plus récent en haut (atténué). "
                 + "Le SRT est écrit dans ~/.mlxtranslate.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
    }
}
