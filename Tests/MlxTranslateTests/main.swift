import AudioCommon
import Foundation
import Qwen3ASR
@testable import MlxTranslate

// Suite de tests autoportante (pas de XCTest / swift-testing dans le toolchain
// Command Line Tools) : un main.swift à code niveau supérieur qui exécute des
// assertions pures (SRT, endpointing, parsing CLI) et sort avec un code 0/1.
// Lancement : swift test  (ou swift run sur la cible de tests).

// MARK: - micro-framework d'assertion

private var checks = 0
private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("ÉCHEC : \(message)")
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("ÉCHEC : \(message) — attendu \(expected), obtenu \(actual)")
    }
}

private func checkClose(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String) {
    checks += 1
    if abs(actual - expected) > accuracy {
        failures += 1
        print("ÉCHEC : \(message) — attendu \(expected), obtenu \(actual)")
    }
}

private func checkThrows<E: Error>(_ type: E.Type, _ message: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("ÉCHEC : \(message) — aucune erreur jetée")
    } catch is E {
        // attendu
    } catch {
        failures += 1
        print("ÉCHEC : \(message) — erreur inattendue : \(error)")
    }
}

// MARK: - SRT (fonctions pures)

private func runSRTChecks() {
    // formatTime / parseTime (allers-retours)
    for t in [0.0, 1.0, 59.999, 60.0, 3661.5, 3661.512] {
        checkClose(SRT.parseTime(SRT.formatTime(t)), t, accuracy: 0.001, "allers-retours temps \(t)")
    }
    checkEqual(SRT.formatTime(-5), "00:00:00,000", "formatTime négatif borné à 0")
    checkEqual(SRT.formatTime(3661.5), "01:01:01,500", "formatTime heures")

    // sentences / containsJapanese
    // Chaque caractère final (。！？…) délimite une phrase : le « ? » ici est
    // une phrase à part (le « … » reste accolé à « Fin »).
    checkEqual(
        SRT.sentences("Bonjour。Salut!?Fin…reste"),
        ["Bonjour。", "Salut!", "?", "Fin…", "reste"],
        "scission des phrases aux terminaisons"
    )
    check(SRT.containsJapanese("こんにちは"), "détecte hiragana")
    check(SRT.containsJapanese("test漢字"), "détecte kanji")
    check(SRT.containsJapanese("カタカナ"), "détecte katakana")
    check(!SRT.containsJapanese("hello"), "pas de japonais dans « hello »")
    check(!SRT.containsJapanese(""), "chaîne vide")

    // postProcess : fusion des cues courtes (gap <= 3 s, pas de final)
    let merged = SRT.postProcess([(0.0, 1.0, "bonjour"), (1.5, 2.5, "salut")])
    checkEqual(merged.count, 1, "fusion des cues proches")
    checkClose(merged[0].start, 0.0, accuracy: 0.01, "démarrage fusion")
    checkClose(merged[0].end, 2.5, accuracy: 0.01, "fin fusion")

    // postProcess : scission d'une cue > 12 s (scission itérative → plusieurs
    // morceaux, ici 3 ; on vérifie la couverture [0, 20] sans chevauchement).
    let longText = String(repeating: "mot。", count: 20)
    let split = SRT.postProcess([(0.0, 20.0, longText)])
    check(split.count >= 2, "scission d'une cue 20 s en plusieurs cues (obtenu \(split.count))")
    checkClose(split.first?.start ?? -1, 0.0, accuracy: 0.01, "scission démarre à 0")
    checkClose(split.last?.end ?? -1, 20.0, accuracy: 0.01, "scission finit à 20")
    for i in split.dropFirst().indices {
        checkClose(split[i].start, split[i - 1].end, accuracy: 0.01, "pas de chevauchement")
    }

    // read / write (allers-retours)
    do {
        let cues: [Cue] = [
            Cue(index: 1, start: 0.0, end: 1.5, text: "Premier"),
            Cue(index: 2, start: 2.0, end: 3.5, text: "Second")
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("srt_roundtrip_\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        try SRT.write(cues, to: url)
        let readBack = try SRT.read(url)
        checkEqual(readBack.count, 2, "allers-retours SRT (nb cues)")
        checkEqual(readBack[0].text, "Premier", "allers-retours SRT (texte)")
        checkClose(readBack[1].start, 2.0, accuracy: 0.01, "allers-retours SRT (début)")
        checkClose(readBack[1].end, 3.5, accuracy: 0.01, "allers-retours SRT (fin)")
    } catch {
        check(false, "allers-retours SRT a jeté : \(error)")
    }
}

// MARK: - Endpointing (fonction pure)

private func runEndpointingChecks() {
    // 1 = frame silencieuse, 0 = parole.
    check(LiveEndpointing.lastSilenceRunStart(silenceFrames: [0, 0, 0, 0, 0], minSilence: 3) == nil,
          "pas de silence → nil")
    checkEqual(LiveEndpointing.lastSilenceRunStart(silenceFrames: [0, 0, 1, 1, 1, 1], minSilence: 3) ?? -1,
               2, "séquence de silence après parole → début de la séquence (2)")
    check(LiveEndpointing.lastSilenceRunStart(silenceFrames: [0, 0, 1, 1, 0, 0], minSilence: 3) == nil,
          "séquence trop courte → nil")
    check(LiveEndpointing.lastSilenceRunStart(silenceFrames: [1, 1, 1, 1, 0, 0], minSilence: 3) == nil,
          "pas de parole avant → nil")
    checkEqual(LiveEndpointing.lastSilenceRunStart(silenceFrames: [0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 1], minSilence: 3) ?? -1,
               7, "la séquence la plus À DROITE gagne")
}

// MARK: - Parsing CLI

private func runCLIParserChecks() {
    func parse(_ args: [String]) -> Command {
        try! CLIParser.parse(["mlxtranslate"] + args)
    }

    // verbes + options
    let transcrire = parse(["transcrire", "video.mp4"])
    checkEqual(transcrire.verb, .transcrire, "verbe transcrire")
    checkEqual(transcrire.video.lastPathComponent, "video.mp4", "média positionnel")

    let live = parse(["live", "--app", "org.videolan.vlc", "--max", "30"])
    checkEqual(live.verb, .live, "verbe live")
    checkEqual(live.app ?? "nil", "org.videolan.vlc", "option --app")
    checkClose(live.maxSeconds ?? -1, 30, accuracy: 0.001, "option --max")
    checkEqual(live.listApps, false, "sans --list")

    checkEqual(parse(["live", "--list"]).listApps, true, "option --list")
    checkEqual(parse(["live", "--app", "VLC", "--sans-traduction"]).sansTraduction, true, "flag --sans-traduction")
    checkEqual(parse(["traduire", "video.mp4", "--modele", "qwen3-8b"]).model, .qwen3_8B, "option --modele")

    // --- Cadence Qwen (live) : parsing + défaut
    checkEqual(parse(["live", "--app", "VLC", "--cadence", "1"]).liveCadence, .seconds1, "option --cadence 1")
    checkEqual(parse(["live", "--app", "VLC", "--cadence", "3"]).liveCadence, .seconds3, "option --cadence 3")
    checkEqual(parse(["live", "--app", "VLC"]).liveCadence, QwenPseudoLiveCadence.productDefault, "cadence défaut (2 s)")
    checkThrows(CLIParser.UnknownArgument.self, "--cadence invalide → UnknownArgument") {
        _ = try CLIParser.parse(["mlxtranslate", "live", "--cadence", "5"])
    }
    checkThrows(CLIParser.UnknownArgument.self, "--cadence sans valeur → UnknownArgument") {
        _ = try CLIParser.parse(["mlxtranslate", "live", "--cadence"])
    }

    // --- Modèle EN du live : défaut 1,7B ; `--modele` explicite respecté ;
    //     le défaut offline (8b) reste inchangé.
    checkEqual(parse(["live", "--app", "VLC"]).liveModel, .qwen3_1B7, "défaut live : qwen3-1.7b")
    checkEqual(parse(["live", "--app", "VLC", "--modele", "qwen3-8b"]).liveModel, .qwen3_8B, "live : --modele explicite")
    checkEqual(parse(["live", "--app", "VLC", "--modele", "qwen3-4b"]).liveModel, .qwen3_4B, "live : --modele 4b")
    checkEqual(parse(["traduire", "video.mp4"]).model, .qwen3_8B, "défaut offline inchangé (8b)")
    checkEqual(parse(["live", "--app", "VLC"]).model, .qwen3_8B, "live sans --modele : `model` (champ offline) inchangé")

    // erreurs
    checkThrows(CLIParser.Help.self, "help → Help") { _ = try CLIParser.parse(["mlxtranslate", "--help"]) }
    checkThrows(CLIParser.Help.self, "sans verbe → Help") { _ = try CLIParser.parse(["mlxtranslate"]) }
    checkThrows(CLIParser.Help.self, "transcrire sans média → Help") {
        _ = try CLIParser.parse(["mlxtranslate", "transcrire"])
    }
    checkThrows(CLIParser.UnknownArgument.self, "option inconnue → UnknownArgument") {
        _ = try CLIParser.parse(["mlxtranslate", "live", "--inconnu"])
    }
    checkThrows(CLIParser.UnknownArgument.self, "--max non numérique → UnknownArgument") {
        _ = try CLIParser.parse(["mlxtranslate", "live", "--max", "abc"])
    }
    checkThrows(CLIParser.UnknownArgument.self, "--modele inconnu → UnknownArgument") {
        _ = try CLIParser.parse(["mlxtranslate", "traduire", "video.mp4", "--modele", "foo"])
    }
}

// MARK: - golden offline (gated : MLXTRANSLATE_RUN_GOLDEN=1)
//
// Lance la chaîne complète (ASR → alignement → parlants → traduction) sur un
// clip via le binaire CLI, et vérifie que le SRT EN est produit. Lent (les
// modèles chargent) — activé seulement si l'env est posé :
//   MLXTRANSLATE_RUN_GOLDEN=1
//   MLXTRANSLATE_GOLDEN_CLIP=<clip>  (défaut /tmp/test_ja.wav)
//   MLXTRANSLATE_CLI=<binaire>       (défaut ./.build/debug/mlxtranslate)

private func runGoldenCheck() {
    guard ProcessInfo.processInfo.environment["MLXTRANSLATE_RUN_GOLDEN"] != nil else {
        print("[golden] désactivée (MLXTRANSLATE_RUN_GOLDEN=1 pour lancer la chaîne complète)")
        return
    }
    let env = ProcessInfo.processInfo.environment
    let clip = NSString(string: env["MLXTRANSLATE_GOLDEN_CLIP"] ?? "/tmp/test_ja.wav").expandingTildeInPath
    let cli = NSString(string: env["MLXTRANSLATE_CLI"] ?? ".build/debug/mlxtranslate").expandingTildeInPath
    let clipURL = URL(fileURLWithPath: clip)
    let enSRT = clipURL.deletingLastPathComponent()
        .appendingPathComponent("\(clipURL.deletingPathExtension().lastPathComponent) (EN).srt")
    do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["finale", clip]
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        check(process.terminationStatus == 0, "golden : CLI `finale` sort 0 (sortie : …\(output.suffix(160)))")
        check(FileManager.default.fileExists(atPath: enSRT.path), "golden : SRT EN « \(enSRT.lastPathComponent) » présent")
        if FileManager.default.fileExists(atPath: enSRT.path) {
            let content = (try? String(contentsOf: enSRT, encoding: .utf8)) ?? ""
            check(!content.isEmpty, "golden : SRT EN non vide (\(content.count) caractères)")
        }
    } catch {
        check(false, "golden : erreur (\(error))")
    }
}

// MARK: - Cas dégradés offline (muet, longue vidéo, sans dialogue)

private func runDegradedChecks() {
    // --- Audio muet : la transcription produit des chunks vides, l'alignement
    // jetterait PipelineError.emptyTranscription. On vérifie les briques pures
    // qui font que les chunks vides ne produisent aucun tour alignable.
    checkEqual(SRT.sentences("").count, 0, "audio muet : aucune phrase dans la chaîne vide")
    checkEqual(SRT.sentences("   ").count, 0, "audio muet : aucune phrase dans des espaces")
    check(!SRT.containsJapanese(""), "audio muet : pas de japonais dans la chaîne vide")

    // --- Longue vidéo : le chunking Audio.windows découpe en fenêtres de N s.
    // Une vidéo de 2 min à 16 kHz = 192000 échantillons ; fenêtre 20 s = 320000.
    let sampleRate = Audio.sampleRate
    let longSamples = Array(repeating: Float(0), count: 2 * 60 * sampleRate)  // 2 min
    let windows = Audio.windows(longSamples, seconds: 20)
    checkEqual(windows.count, 6, "longue vidéo : 2 min → 6 fenêtres de 20 s")
    if windows.count == 6 {
        checkClose(windows[0].start, 0.0, accuracy: 0.001, "fenêtre 0 démarre à 0")
        checkClose(windows[5].end, 120.0, accuracy: 0.001, "fenêtre 5 finit à 120 s")
        for w in windows { check(w.end - w.start <= 20.0 + 0.001, "fenêtre ≤ 20 s") }
    }
    // Une durée inférieure à la fenêtre → une seule fenêtre.
    checkEqual(Audio.windows(Array(repeating: Float(0), count: 5 * sampleRate), seconds: 20).count,
               1, "courte vidéo : une seule fenêtre")

    // --- Pas de dialogue : les textes non-japonais (musique, bruit) ne sont
    // pas alignables (containsJapanese = false), donc ignorés par l'alignement.
    check(!SRT.containsJapanese("♪ ♫ ♪"), "sans dialogue : pas de japonais dans des notes de musique")
    check(!SRT.containsJapanese("abc 123 ???"), "sans dialogue : pas de japonais dans du texte latin")
    check(SRT.containsJapanese("はい"), "dialogue : détecte le japonais")
}

// MARK: - Spool de rattrapage live (writer WAV tourné, 720 s)

private func runAudioSpoolChecks() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlxtest-spool-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: tmp)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let base = tmp.appendingPathComponent("live-test")
    // Rotation 1 s (16 000 échantillons à 16 kHz) pour tester la rotation sans attendre.
    let writer = LiveAudioWriter(baseURL: base, sampleRate: 16_000, rotationSeconds: 1)
    // 4 batches de 5 000 échantillons = 20 000 au total (1,25 s) → 1 rotation.
    for _ in 0..<4 {
        writer.append(Array(repeating: 0.5, count: 5_000))
    }
    writer.finish()
    let seg0 = base.appendingPathComponent("live-000.wav")
    let seg1 = base.appendingPathComponent("live-001.wav")
    check(FileManager.default.fileExists(atPath: seg0.path), "spool : segment 0 existe")
    check(FileManager.default.fileExists(atPath: seg1.path), "spool : rotation a créé le segment 1")
    if let data = try? Data(contentsOf: seg0) {
        check(data.count >= 44, "spool : fichier ≥ 44 octets (en-tête WAV)")
        if data.count >= 44 {
            checkEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF", "spool : magic RIFF")
            checkEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE", "spool : magic WAVE")
            // Taille du chunk data (offset 40..43, little-endian) = 20 000 échantillons * 4.
            let dataSize = Int(data[40]) | (Int(data[41]) << 8) | (Int(data[42]) << 16) | (Int(data[43]) << 24)
            checkEqual(dataSize, 20_000 * 4, "spool : taille data segment 0")
            checkEqual(data.count, 44 + 20_000 * 4, "spool : taille fichier segment 0")
        }
    } else {
        check(false, "spool : segment 0 lisible")
    }
    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - cleanLive (suppression des marqueurs, streaming)

private func runCleanLiveChecks() {
    // Marqueurs complets retirés, texte anglais conservé.
    checkEqual(
        LocalMLXTranslator.cleanLive("<<<CURRENT:live>>>\nLet's go!\n<<<END_CURRENT:live>>>"),
        "Let's go!",
        "cleanLive : marqueurs complets retirés"
    )
    // Marqueurs partiels en cours de streaming (sans « >>> ») retirés.
    checkEqual(LocalMLXTranslator.cleanLive("<<"), "", "cleanLive : « << » partiel")
    checkEqual(LocalMLXTranslator.cleanLive("<<<CURRENT"), "", "cleanLive : « <<<CURRENT » partiel")
    checkEqual(LocalMLXTranslator.cleanLive("<<<CURRENT:live>>"), "", "cleanLive : « <<<CURRENT:live>> » partiel")
    // Texte + marqueur partiel en fin de ligne → le texte est conservé.
    checkEqual(
        LocalMLXTranslator.cleanLive("<<<CURRENT:live>>>\nLet's go!\n<<"),
        "Let's go!",
        "cleanLive : texte + « << » partiel"
    )
    checkEqual(
        LocalMLXTranslator.cleanLive("<<<CURRENT:live>>>\nLet's go!\n<<<END"),
        "Let's go!",
        "cleanLive : texte + « <<<END » partiel"
    )
    // Texte simple sans marqueur.
    checkEqual(LocalMLXTranslator.cleanLive("Let's go!"), "Let's go!", "cleanLive : texte simple")
    checkEqual(LocalMLXTranslator.cleanLive(""), "", "cleanLive : entrée vide")
}

// MARK: - Live final tier (garde des vides, parse --live-asr, modèles optionnels)

private func runLiveFinalTierChecks() {
    // Défauts du tier final.
    checkEqual(LiveFinalASR.productDefault, .qwenJA, "tier final par défaut : qwenja")
    checkEqual(LiveFinalASR.cliValue("qwenja"), .qwenJA, "parse qwenja")
    checkEqual(LiveFinalASR.cliValue("VOXTRAL"), .voxtralQ4, "parse voxtral (insensible à la casse)")
    check(LiveFinalASR.cliValue("autre") == nil, "parse inconnu → nil")

    // Garde des vides : on ne nourrit jamais le LLM avec une entrée vide.
    checkEqual(LiveClauseSelection.select(qwenJapanese: "こんにちは", appleJapanese: "こんにちは"),
               "こんにちは", "qwen non vide → qwen")
    checkEqual(LiveClauseSelection.select(qwenJapanese: "  ", appleJapanese: "こんにちは"),
               "こんにちは", "qwen vide → fallback Apple")
    checkEqual(LiveClauseSelection.select(qwenJapanese: "  ", appleJapanese: nil),
               nil, "qwen vide + Apple absente → nil (clause JA seul)")
    checkEqual(LiveClauseSelection.select(qwenJapanese: "  ", appleJapanese: "   "),
               nil, "qwen vide + Apple vide → nil")
    checkEqual(LiveClauseSelection.select(qwenJapanese: "   ", appleJapanese: "   "),
               nil, "les deux vides → nil")

    // CLI : --live-asr.
    let live = try! CLIParser.parse(["mlxtranslate", "live", "--app", "VLC"])
    checkEqual(live.liveASR, .qwenJA, "--live-asr absent → qwenja par défaut")
    let liveVoxtral = try! CLIParser.parse(["mlxtranslate", "live", "--app", "VLC", "--live-asr", "voxtral"])
    checkEqual(liveVoxtral.liveASR, .voxtralQ4, "--live-asr voxtral")
    checkThrows(CLIParser.UnknownArgument.self, "--live-asr inconnu → UnknownArgument") {
        _ = try CLIParser.parse(["mlxtranslate", "live", "--app", "VLC", "--live-asr", "whisper"])
    }
    checkThrows(CLIParser.UnknownArgument.self, "--live-asr sans valeur → UnknownArgument") {
        _ = try CLIParser.parse(["mlxtranslate", "live", "--app", "VLC", "--live-asr"])
    }
}

// MARK: - Endpointing sémantique (décisions, terminaison japonaise, stabilité, silence)

private func runSemanticEndpointerChecks() {
    // Décision : table (règles du plan validé).
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 0.5, isTerminal: true, isStable: true, windowSeconds: 5),
        .commitFinal, "terminale + stable → commitFinal"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 2.0, isTerminal: true, isStable: false, windowSeconds: 5),
        .commitFinal, "terminale + silence 2 s (sans stabilité) → commitFinal"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 0.5, isTerminal: true, isStable: false, windowSeconds: 5, appleFinalized: true),
        .commitFinal, "terminale + finalisation Apple → commitFinal"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 0.5, isTerminal: false, isStable: true, windowSeconds: 5),
        .hold, "incomplète + stable + silence court → hold"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 2.0, isTerminal: false, isStable: true, windowSeconds: 5),
        .commitFragment, "incomplète + silence 2 s → commitFragment"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 0.4, isTerminal: false, isStable: false, windowSeconds: 5),
        .hold, "incomplète + silence < 2 s → hold"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 1.5, isTerminal: true, isStable: true, windowSeconds: 13),
        .forceCut, "fenêtre ≥ 12 s → forceCut (prioritaire)"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 1.5, isTerminal: true, isStable: true, windowSeconds: 11.9),
        .commitFinal, "fenêtre < 12 s + terminale + stable → commitFinal"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 1.99, isTerminal: true, isStable: false, windowSeconds: 5),
        .hold, "terminale + 1,99 s (< 2 s) + instable → hold"
    )
    checkEqual(
        LiveSemanticEndpointer.evaluate(silenceSeconds: 2.5, isTerminal: false, isStable: false, windowSeconds: 13),
        .forceCut, "fenêtre ≥ 12 s → forceCut même sur clause incomplète"
    )

    // Terminaison japonaise : ponctuation + fins conservatrices (liste WhisperASR).
    check(LiveSemanticEndpointer.isTerminalJapanese("これは何でした"), "terminale : fin « でした »")
    check(LiveSemanticEndpointer.isTerminalJapanese("わかりませんでした"), "terminale : fin « ません »")
    check(LiveSemanticEndpointer.isTerminalJapanese("そうですか。"), "terminale : point terminal « 。 »")
    check(LiveSemanticEndpointer.isTerminalJapanese("本当？"), "terminale : point d'interrogation « ？」")
    check(LiveSemanticEndpointer.isTerminalJapanese("  本当です  "), "terminale : « です » (marge ignorée)")
    check(!LiveSemanticEndpointer.isTerminalJapanese("はい"), "non terminale : « はい »")
    check(!LiveSemanticEndpointer.isTerminalJapanese("本当"), "non terminale : mot nu")
    check(!LiveSemanticEndpointer.isTerminalJapanese("ちょっと待って"), "non terminale : « 待って » (non dans la liste)")
    check(!LiveSemanticEndpointer.isTerminalJapanese(""), "non terminale : chaîne vide")
    check(!LiveSemanticEndpointer.isTerminalJapanese("   "), "non terminale : espaces")

    // Silence de fin (fonction pure : frames 100 ms, seuil 0,001).
    func makeAudio(speechSeconds: Double, silenceSeconds: Double) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(Int((speechSeconds + silenceSeconds) * 16_000))
        for _ in 0..<Int(speechSeconds * 16_000) { out.append(0.5) }
        for _ in 0..<Int(silenceSeconds * 16_000) { out.append(0) }
        return out
    }
    checkClose(LiveSemanticEndpointer.trailingSilenceSeconds(makeAudio(speechSeconds: 4, silenceSeconds: 2.5)),
               2.5, accuracy: 0.001, "silence de fin : 2,5 s après parole")
    checkClose(LiveSemanticEndpointer.trailingSilenceSeconds(makeAudio(speechSeconds: 0, silenceSeconds: 3)),
               3.0, accuracy: 0.001, "silence de fin : tampon entièrement silencieux")
    checkClose(LiveSemanticEndpointer.trailingSilenceSeconds(makeAudio(speechSeconds: 3, silenceSeconds: 0)),
               0, accuracy: 0.001, "silence de fin : toute parole → 0")
    checkClose(LiveSemanticEndpointer.trailingSilenceSeconds([0.5, 0.5, 0.5]),
               0, accuracy: 0.001, "silence de fin : moins d'une frame → 0")
    var middleSilence = makeAudio(speechSeconds: 2, silenceSeconds: 1)
    middleSilence.append(contentsOf: makeAudio(speechSeconds: 1, silenceSeconds: 0))
    checkClose(LiveSemanticEndpointer.trailingSilenceSeconds(middleSilence),
               0, accuracy: 0.001, "silence de fin : silence médian (pas en fin) → 0")

    // Suivi de stabilité : fenêtre 1,12 s, observations espacées de 0,4 s.
    var tracker = SnapshotStabilityTracker()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check(!tracker.observe("A", now: t0), "stabilité : première observation → false")
    check(!tracker.observe("A", now: t0.addingTimeInterval(0.4)), "stabilité : 0,4 s → false")
    check(!tracker.observe("A", now: t0.addingTimeInterval(0.8)), "stabilité : 0,8 s → false")
    check(tracker.observe("A", now: t0.addingTimeInterval(1.2)), "stabilité : 1,2 s ≥ 1,12 s → true")
    check(!tracker.observe("B", now: t0.addingTimeInterval(1.6)), "stabilité : changement de texte → false")
    check(!tracker.observe("B", now: t0.addingTimeInterval(2.5)), "stabilité : B depuis 0,9 s → false")
    check(tracker.observe("B", now: t0.addingTimeInterval(2.8)), "stabilité : B depuis 1,2 s → true")
    tracker.reset()
    check(!tracker.observe("C", now: t0.addingTimeInterval(3.0)), "stabilité : reset → repart de zéro")
}

// MARK: - Pseudo-live (coordinateur Qwen) + context strings glossaire

private func runPseudoLiveCoordinatorChecks() {
    let sr = Int(LiveEndpointing.sampleRate)
    let cad2 = QwenPseudoLiveCadence.productDefault.sampleCount

    // Cadences : échantillons 16 kHz par intervalle.
    checkEqual(QwenPseudoLiveCadence.seconds1.sampleCount, sr, "cadence 1 s")
    checkEqual(QwenPseudoLiveCadence.seconds2.sampleCount, 2 * sr, "cadence 2 s")
    checkEqual(QwenPseudoLiveCadence.seconds3.sampleCount, 3 * sr, "cadence 3 s")
    checkEqual(QwenPseudoLiveCadence.productDefault, .seconds2, "cadence par défaut 2 s")

    // Début de preview : max(notBefore, speechStart) (preRoll 0).
    checkEqual(QwenPseudoLiveCoordinator.previewStart(speechStart: 100, notBefore: 300), 300,
               "previewStart : notBefore > speechStart")
    checkEqual(QwenPseudoLiveCoordinator.previewStart(speechStart: 500, notBefore: 300), 500,
               "previewStart : speechStart > notBefore")

    // Porte de cadence : rien avant, work à la cadence, coalescement ensuite.
    var c = QwenPseudoLiveCoordinator(cadence: .seconds2)
    check(c.observe(speechStart: 0, availableThrough: cad2 - sr) == nil,
          "observe : avant la cadence → nil")
    let wFirst = c.observe(speechStart: 0, availableThrough: cad2)!
    checkEqual(wFirst.range, 0..<cad2, "observe : cadence atteinte → work [0, cad2)")
    checkEqual(c.observe(speechStart: 0, availableThrough: 2 * cad2), nil,
               "observe : work en vol → coalescé (nil)")
    checkEqual(c.coalescedTickCount, 1, "coalescedTickCount incrémenté")
    let completion = c.completePreview(wFirst, source: "s1")
    // Le coalescé a surclassé le premier work (latest-wins) : il est obsolète.
    check(completion.accepted == nil, "preview surclassé par un coalescé → rejeté (stale)")
    checkEqual(c.staleResultCount, 1, "staleResultCount incrémenté")
    checkEqual(completion.next?.range, 0..<2 * cad2, "work coalescé renvoyé (latest-wins)")
    if let next = completion.next {
        let done = c.completePreview(next, source: "s2")
        checkEqual(done.accepted?.source, "s2", "coalescé à jour → accepté")
        check(done.next == nil, "plus de work en attente")
    }

    // Preview à jour (pas de coalescé) → accepté directement.
    var c2 = QwenPseudoLiveCoordinator(cadence: .seconds2)
    let w2 = c2.observe(speechStart: 0, availableThrough: cad2)!
    let ok = c2.completePreview(w2, source: "ok")
    checkEqual(ok.accepted?.source, "ok", "preview à jour → accepté")
    check(ok.next == nil, "pas de work coalescé")

    // stageFinal : le range est définitif, les previews sont bloquées.
    var c3 = QwenPseudoLiveCoordinator(cadence: .seconds2)
    let final = c3.stageFinal(range: 0..<cad2, stableThrough: cad2)
    checkEqual(c3.generation, 1, "stageFinal : génération incrémentée")
    check(c3.observe(speechStart: 0, availableThrough: 2 * cad2) == nil,
          "previewNotBefore : début de phrase avant la borne stable → nil")
    check(c3.observe(speechStart: cad2, availableThrough: 2 * cad2 - sr) == nil,
          "nouvelle phrase : avant la cadence → nil")
    check(c3.observe(speechStart: cad2, availableThrough: 2 * cad2) == nil,
          "final en attente : preview de cadence coalescée (nil)")
    checkEqual(c3.completeFinal(final)?.range, cad2..<2 * cad2,
               "completeFinal : libère le slot et renvoie le travail coalescé")

    // Le preview en vol devient obsolète après un stageFinal.
    var c4 = QwenPseudoLiveCoordinator(cadence: .seconds2)
    let w4 = c4.observe(speechStart: 0, availableThrough: cad2)!
    _ = c4.stageFinal(range: 0..<cad2, stableThrough: cad2)
    let stale = c4.completePreview(w4, source: "obsolète")
    check(stale.accepted == nil, "génération incrémentée : preview en vol obsolète")
    checkEqual(c4.staleResultCount, 1, "staleResultCount (post stageFinal)")

    // failPreview → dégradé + travail coalescé éventuel.
    var c5 = QwenPseudoLiveCoordinator(cadence: .seconds2)
    let w5 = c5.observe(speechStart: 0, availableThrough: cad2)!
    check(c5.failPreview(w5) == nil, "failPreview sans pending → nil")
    checkEqual(c5.previewStatus, .degraded, "failPreview → état dégradé")

    // Préviews désactivées (MLXTRANSLATE_PSEUDO_LIVE=0) → observe silencieux.
    var c6 = QwenPseudoLiveCoordinator(cadence: .seconds2, previewsEnabled: false)
    check(c6.observe(speechStart: 0, availableThrough: 5 * cad2) == nil,
          "préviews désactivées → nil")

    // cancel : fin du live → plus de previews.
    var c7 = QwenPseudoLiveCoordinator(cadence: .seconds2)
    c7.cancel()
    checkEqual(c7.previewStatus, .unavailable, "cancel → indisponible")
    check(c7.observe(speechStart: 0, availableThrough: 5 * cad2) == nil,
          "cancel : plus de previews")

    // Context strings glossaire : aplatir les formes JA, dédupliquer, plafonner.
    let terms = [
        HighQualityGlossaryPromptTerm(id: "t1", japanese: ["子供", "子"], english: "monster", englishAliases: []),
        HighQualityGlossaryPromptTerm(id: "t2", japanese: ["子", "  "], english: "child", englishAliases: []),
        HighQualityGlossaryPromptTerm(id: "t3", japanese: ["  闇 "], english: "dark", englishAliases: []),
    ]
    checkEqual(Glossaire.contextualStrings(terms: terms), ["子供", "子", "闇"],
               "contextualStrings : aplat + dédoublonnage + trim")
    var many: [HighQualityGlossaryPromptTerm] = []
    for i in 0..<150 {
        many.append(HighQualityGlossaryPromptTerm(id: "m\(i)", japanese: ["form\(i)"], english: "e", englishAliases: []))
    }
    checkEqual(Glossaire.contextualStrings(terms: many).count, 100, "contextualStrings : plafond 100")
    checkEqual(Glossaire.contextualStrings(terms: []), [], "contextualStrings : vide")
}

// MARK: - Garde monotone de la preview (la ligne ne rétrécit jamais)

private func runPreviewMonotoneChecks() {
    var m = PreviewMonotone()
    checkEqual(m.accept("Bonjour"), "Bonjour", "monotone : vide → texte")
    checkEqual(m.accept(""), "Bonjour", "monotone : candidat vide garde l'existant")
    checkEqual(m.accept("Bonjour, salut"), "Bonjour, salut", "monotone : extension (préfixe) acceptée")
    checkEqual(m.accept("Bonjour"), "Bonjour, salut", "monotone : rétrécissement retenu")
    checkEqual(m.accept("Salut, tout va"), "Salut, tout va", "monotone : correction même longueur acceptée")
    checkEqual(m.accept("Salut!"), "Salut, tout va", "monotone : correction plus courte retenu")
    checkEqual(m.accept("Salut! Tout va bien"), "Salut! Tout va bien", "monotone : rattrapage (plus long) accepté")
    checkEqual(m.accept("Salut! Tout va bien"), "Salut! Tout va bien", "monotone : identique → no-op")
    m.reset()
    checkEqual(m.accept(""), "", "monotone : après reset, vide reste vide")
    checkEqual(m.accept("A"), "A", "monotone : après reset, accepte un texte court")
}

// MARK: - Superposition live (machine d'état pure + résolveur de mise en page)

private func runLiveOverlayStateChecks() {
    // Contenu : fenêtre de 2 finaux + aperçu roulant.
    var s = LiveOverlayState()
    check(!s.hasContent, "overlay : vide au démarrage")
    checkEqual(s.topText, "", "overlay : ligne haute vide")
    checkEqual(s.bottomText, "", "overlay : ligne basse vide")

    s.commitFinal("Un")
    checkEqual(s.bottomText, "Un", "overlay : final en bas (blanc)")
    checkEqual(s.topText, "", "overlay : pas encore de final précédent")

    s.showPreview("Roulant…")
    checkEqual(s.bottomText, "Roulant…", "overlay : l'aperçu prend la ligne basse")
    checkEqual(s.topText, "Un", "overlay : le final précédent s'estompe en haut")

    s.commitFinal("Deux")
    checkEqual(s.bottomText, "Deux", "overlay : final 2 en bas")
    checkEqual(s.topText, "Un", "overlay : final 1 défile en haut")

    s.commitFinal("Trois")
    checkEqual(s.topText, "Deux", "overlay : fenêtre de 2 — final 1 sort")
    checkEqual(s.bottomText, "Trois", "overlay : final 3 en bas")

    s.showPreview("")
    checkEqual(s.bottomText, "Trois", "overlay : aperçu vide → retour au final")
    checkEqual(s.topText, "Deux", "overlay : haut inchangé (final précédent)")

    s.reset()
    check(!s.hasContent, "overlay : reset vide la fenêtre")

    // Résolveur : estimation des lignes + rétrécissement de police.
    let probe = LiveOverlayState()
    checkEqual(probe.estimatedLines("", font: 20), 1, "overlay : texte vide = 1 ligne de réserve")
    checkEqual(probe.estimatedLines(String(repeating: "a", count: 79), font: 20), 1,
               "overlay : 79 car. = 1 ligne à 20 pt")
    checkEqual(probe.estimatedLines(String(repeating: "a", count: 80), font: 20), 2,
               "overlay : 80 car. = 2 lignes à 20 pt")
    checkEqual(probe.fittedFont(""), 20, "overlay : police max si vide")
    checkEqual(probe.fittedFont(String(repeating: "a", count: 238)), 19,
               "overlay : 238 car. → rétrécit à 19 pt")
    checkEqual(probe.fittedFont(String(repeating: "a", count: 300)), 15,
               "overlay : 300 car. → 15 pt (plancher 14 pt)")
    checkEqual(probe.truncated(String(repeating: "a", count: 250)).count, 250,
               "overlay : 250 car. non tronqués")
    checkEqual(probe.truncated(String(repeating: "a", count: 251)).count, 251,
               "overlay : 251 car. → troncature + « … »")

    // Mise en page : hauteur + hystérésis.
    var l = LiveOverlayState()
    checkClose(l.layout.panelHeight, 64, accuracy: 0.01, "overlay : hauteur par défaut 64")
    l.showPreview("Court")
    checkEqual(l.layout.bottomFont, 20, "overlay : texte court reste à 20 pt")
    checkEqual(l.layout.bottomLines, 1, "overlay : texte court sur 1 ligne")

    let long = String(repeating: "mot ", count: 63)   // 252 car. → plafonné 250
    l.showPreview(long)
    checkEqual(l.layout.bottomText.count, 251, "overlay : plafonné à 250 + « … »")
    check(l.layout.bottomFont < 20, "overlay : texte long rétrécit (< 20 pt)")
    check(l.layout.bottomLines <= 3, "overlay : jamais plus de 3 lignes")
    check(l.layout.panelHeight <= 192, "overlay : hauteur plafonnée à 192")

    // Hystérésis : la hauteur ne fait que croître entre aperçus.
    let tall = l.layout.panelHeight
    l.showPreview("Hi")
    checkClose(l.layout.panelHeight, tall, accuracy: 0.01,
               "overlay : pas de rétrécissement pendant les aperçus (hystérésis)")

    // Recomputation complète au commit : la hauteur peut rétrécir.
    l.commitFinal("Fin")
    checkClose(l.layout.panelHeight, 64, accuracy: 0.01,
               "overlay : commit → recomputation (retour au minimum ici)")

    // Bornes max : 3 lignes haut + 3 lignes bas = 192.
    var m = LiveOverlayState()
    let a = String(repeating: "premier terme ", count: 18)   // ~252 car. → 250
    let b = String(repeating: "second terme ", count: 18)
    m.commitFinal(a)
    m.commitFinal(b)
    checkEqual(Int(m.layout.panelHeight), 192, "overlay : 3+3 lignes = 192 px")
    checkEqual(m.layout.topLines, 3, "overlay : ligne haute sur 3 lignes")
    checkEqual(m.layout.bottomLines, 3, "overlay : ligne basse sur 3 lignes")

    // Garde monotone : la ligne de preview ne rétrécit jamais entre deux
    // passes (le début d'une nouvelle passe de re-traduction ne remplace pas
    // le texte complet précédent ; elle tient jusqu'au rattrapage ou au commit).
    var m2 = LiveOverlayState()
    m2.showPreview("Hello, I'm doing well")
    checkEqual(m2.bottomText, "Hello, I'm doing well", "overlay : preview affichée")
    m2.showPreview("Hello,")
    checkEqual(m2.bottomText, "Hello, I'm doing well", "overlay : rétrécissement retenu (monotone)")
    m2.showPreview("Hello, I'm doing well, thank you")
    checkEqual(m2.bottomText, "Hello, I'm doing well, thank you", "overlay : extension affichée")
    m2.showPreview("")
    checkEqual(m2.bottomText, "Hello, I'm doing well, thank you", "overlay : aperçu vide n'efface pas la ligne")
    m2.commitFinal("Fin")
    checkEqual(m2.bottomText, "Fin", "overlay : commit efface la ligne de preview")
    m2.showPreview("Hi")
    checkEqual(m2.bottomText, "Hi", "overlay : post-commit, preview courte acceptée (garde remise à zéro)")
}


// MARK: - Modèles live (gated : MLXTRANSLATE_RUN_LIVE_MODELS=1)
//
// Charge Qwen3-ASR 1,7B JA + Qwen3-ForcedAligner (cache locaux), transcrit un
// extrait du clip de test et vérifie la monotonie de l'alignement. Lent
// (chargement des modèles) — activé seulement si l'env est posé :
//   MLXTRANSLATE_RUN_LIVE_MODELS=1
//   MLXTRANSLATE_LIVE_CLIP=<clip 16 kHz>  (défaut /tmp/test_ja.wav)

private func runLiveModelsCheck() async {
    guard ProcessInfo.processInfo.environment["MLXTRANSLATE_RUN_LIVE_MODELS"] != nil else {
        print("[live-models] désactivé (MLXTRANSLATE_RUN_LIVE_MODELS=1 pour charger les modèles)")
        return
    }
    let env = ProcessInfo.processInfo.environment
    let clip = NSString(string: env["MLXTRANSLATE_LIVE_CLIP"] ?? "/tmp/test_ja.wav").expandingTildeInPath

    // Extrait de 10 s au début du clip (WAV mono normalisé -1…1).
    guard let audio = try? Audio.loadWAV(URL(fileURLWithPath: clip)) else {
        check(false, "live-models : clip « \(clip) » lisible")
        return
    }
    let excerpt = Array(audio.prefix(10 * 16_000))
    check(excerpt.count == 10 * 16_000, "live-models : extrait de 10 s lu")

    let asr = Qwen3ASRFinalRuntime()
    do {
        try await asr.prepare(progress: { _, _ in })
        let asrPrepared = await asr.isPrepared
        check(asrPrepared, "Qwen3-ASR 1.7B JA : préparé (chargement offline + warmup)")
        let started = Date()
        let text = try await asr.transcribe(audio: excerpt)
        let elapsed = Date().timeIntervalSince(started)
        print("[live-models] Qwen3-ASR : \(elapsed) s pour 10 s d'audio → « \(text.prefix(80)) »")
        check(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              "Qwen3-ASR : transcription non vide")

        let aligner = Qwen3AlignerRuntime()
        try await aligner.prepare(progress: { _, _ in })
        let alignerPrepared = await aligner.isPrepared
        check(alignerPrepared, "Qwen3-ForcedAligner : préparé (cache HF)")
        let aligned = try await aligner.align(audio: excerpt, text: text)
        print("[live-models] aligneur : \(aligned.count) mots")
        for (i, w) in aligned.enumerated() {
            print("  [\(i)] \(w.text)  start=\(String(format: "%.2f", w.startTime)) end=\(String(format: "%.2f", w.endTime))")
        }
        check(!aligned.isEmpty, "aligneur : au moins un mot aligné")
        var monotone = true
        var withinAudio = true
        let audioSeconds = Float(excerpt.count) / 16_000
        for (i, word) in aligned.enumerated() {
            check(word.endTime >= word.startTime, "aligneur : intervalle non négatif (\(i))")
            // L'aligneur peut placer le dernier mot légèrement au-delà de la fin
            // de l'audio (estimation de la fin du mot) : tolérance d'1 s.
            if word.startTime > audioSeconds + 1.0 { withinAudio = false }
            if i > 0, word.startTime < aligned[i - 1].startTime - 0.08 { monotone = false }
        }
        check(monotone, "aligneur : timestamps monotones")
        check(withinAudio, "aligneur : timestamps dans l'audio (≤ \(audioSeconds + 1.0) s)")
    } catch {
        check(false, "live-models : erreur (\(error))")
    }
}

// MARK: - endpointing « lâche » (LivePausePlanner, port WhisperASR)

private func runPausePlannerChecks() {
    let sr = Int(LiveEndpointing.sampleRate)
    func at(_ seconds: Double) -> Int { Int(seconds * Double(sr)) }

    var planner = LivePausePlanner()
    // Sans parole dans la fenêtre → rien à décider.
    checkEqual(planner.observe(windowStart: 0, available: at(3), trailingSilenceSeconds: 0.5, speechStart: nil), nil, "planner : fenêtre sans parole → nil")
    // Phrase < 1,5 s + pause 0,5 s → nil (regroupement).
    checkEqual(planner.observe(windowStart: 0, available: at(2.4), trailingSilenceSeconds: 0.5, speechStart: at(1.0)), nil, "planner : phrase de 1,4 s → nil")
    // Phrase ≥ 1,5 s + silence ≥ 0,5 s → commit au silence.
    checkEqual(planner.observe(windowStart: 0, available: at(2.0), trailingSilenceSeconds: 0.5, speechStart: 0), .pause, "planner : phrase de 2 s + pause 0,5 s → .pause")
    // Silenc trop court → nil.
    var planner2 = LivePausePlanner()
    checkEqual(planner2.observe(windowStart: 0, available: at(2.0), trailingSilenceSeconds: 0.2, speechStart: 0), nil, "planner : pause de 0,2 s → nil")
    // Filet dur : fenêtre ≥ 15 s → .forced (même à vide).
    var planner3 = LivePausePlanner()
    checkEqual(planner3.observe(windowStart: 0, available: at(15), trailingSilenceSeconds: 0, speechStart: nil), .forced, "planner : fenêtre de 15 s vide → .forced")
    // Parole continue ≥ 15 s → .forced.
    var planner4 = LivePausePlanner()
    checkEqual(planner4.observe(windowStart: 0, available: at(15.2), trailingSilenceSeconds: 0, speechStart: 0), .forced, "planner : parole continue de 15,2 s → .forced")
    // 14,9 s de parole continue → encore nil.
    var planner5 = LivePausePlanner()
    checkEqual(planner5.observe(windowStart: 0, available: at(14.9), trailingSilenceSeconds: 0, speechStart: 0), nil, "planner : parole continue de 14,9 s → nil")
    // Persistance entre observations (début de phrase mémorisé) :
    // 1re observation avant le début de la parole, 2e après.
    var planner6 = LivePausePlanner()
    checkEqual(planner6.observe(windowStart: 0, available: at(1.0), trailingSilenceSeconds: 0.5, speechStart: nil), nil, "planner : pré-parole → nil")
    checkEqual(planner6.observe(windowStart: 0, available: at(2.5), trailingSilenceSeconds: 0.5, speechStart: 0), .pause, "planner : début de parole mémorisé → .pause")
    // Reset après commit : nouvelle fenêtre, pas de « pause » immédiate.
    var planner7 = LivePausePlanner()
    checkEqual(planner7.observe(windowStart: 0, available: at(2.0), trailingSilenceSeconds: 0.5, speechStart: 0), .pause, "planner : commit")
    planner7.reset()
    checkEqual(planner7.observe(windowStart: at(2.0), available: at(2.5), trailingSilenceSeconds: 0, speechStart: at(2.0)), nil, "planner : après reset, phrase de 0,5 s → nil")

    // firstSpeechSample (VAD de fenêtre, RMS) :
    let frame = LiveEndpointing.frameSamples
    let zeros = [Float](repeating: 0, count: 10 * frame)
    checkEqual(LivePausePlanner.firstSpeechSample(samples: zeros, windowStart: 0), nil, "planner VAD : fenêtre silencieuse → nil")
    var speech = zeros
    speech[3 * frame] = 0.5
    checkEqual(LivePausePlanner.firstSpeechSample(samples: speech, windowStart: 0), 3 * frame, "planner VAD : parole à 3,0 s → échantillon \(3 * frame)")
    var midFrame = [Float](repeating: 0, count: 5 * frame)
    midFrame[2500] = 0.5
    checkEqual(LivePausePlanner.firstSpeechSample(samples: midFrame, windowStart: 100_000), 100_000 + frame, "planner VAD : frame de parole décalée → début de frame")
    var atThreshold = [Float](repeating: 0, count: 2 * frame)
    atThreshold[frame] = LiveEndpointing.silenceThreshold
    checkEqual(LivePausePlanner.firstSpeechSample(samples: atThreshold, windowStart: 0), frame, "planner VAD : amplitude au seuil → parole")
    var belowThreshold = [Float](repeating: 0, count: 2 * frame)
    belowThreshold[frame] = LiveEndpointing.silenceThreshold - 0.0001
    checkEqual(LivePausePlanner.firstSpeechSample(samples: belowThreshold, windowStart: 0), nil, "planner VAD : amplitude sous le seuil → silence")
}

// MARK: - repli des répétitions dégénérées (LiveRepetition)

private func runRepetitionChecks() {
    // « はい、 » × 100 (musique/silence) → unité × 3 + « … ».
    checkEqual(
        LiveRepetition.collapse(String(repeating: "はい、", count: 100)),
        String(repeating: "はい、", count: 3) + "…",
        "repli : 「はい、」×100 → 3 unités + …"
    )
    // Tronquage en pleine unité (sortie ASR coupée) : le reste est conservé.
    checkEqual(
        LiveRepetition.collapse(String(repeating: "はい、", count: 100) + "は"),
        String(repeating: "はい、", count: 3) + "は" + "…",
        "repli : répétition + reste partiel → 3 unités + reste + …"
    )
    // Texte normal (≥ minRun, non périodique) → inchangé.
    let normal = "今日はいい天気ですね、散歩にはもってこいですよ、ぜひ一緒にどうですか、本当にありがとうごさいた。"
    checkEqual(LiveRepetition.collapse(normal), normal, "repli : texte normal ≥ 40 car. → inchangé")
    // Trop court (< minRun) → inchangé.
    checkEqual(LiveRepetition.collapse("あ"), "あ", "repli : texte court → inchangé")
    checkEqual(
        LiveRepetition.collapse(String(repeating: "はい、", count: 10)),
        String(repeating: "はい、", count: 10),
        "repli : 30 caractères (< minRun) → inchangé"
    )
    // Unité latine.
    checkEqual(
        LiveRepetition.collapse(String(repeating: "abc", count: 20)),
        String(repeating: "abc", count: 3) + "…",
        "repli : « abc »×20 → 3 unités + …"
    )
    // Préfixe normal + répétition en fin de texte : le préfixe est conservé.
    checkEqual(
        LiveRepetition.collapse("こんにちは " + String(repeating: "いい、", count: 20)),
        "こんにちは " + String(repeating: "いい、", count: 3) + "…",
        "repli : préfixe + répétition → préfixe conservé"
    )
    // Répétition d'un caractère (période 1).
    checkEqual(
        LiveRepetition.collapse(String(repeating: "a", count: 50)),
        "aaa…",
        "repli : « a »×50 → 3 caractères + …"
    )
}

// MARK: - dédoublonnage SRT des cues identiques (LiveOutput)

private func runLiveOutputDedupChecks() async {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mlx-dedup-\(UUID().uuidString)")
    let fileURL = dir.appendingPathComponent("out.srt")
    let out = LiveOutput(fileURL: fileURL)

    let i1 = await out.commit(start: 0, end: 2, japanese: "こんにちは", english: "hello", show: false)
    let i2 = await out.commit(start: 2, end: 4, japanese: "世界", english: "world", show: false)
    let i3 = await out.commit(start: 4, end: 6, japanese: "世界", english: "world", show: false)
    let i4 = await out.commit(start: 6, end: 8, japanese: "また", english: "world", show: false)
    let i5 = await out.commit(start: 8, end: 10, japanese: "さようなら", english: "goodbye", show: false)

    checkEqual(i1, 1, "SRT dedup : premier cue → index 1")
    checkEqual(i2, 2, "SRT dedup : second cue → index 2")
    checkEqual(i3, 2, "SRT dedup : texte identique → dernier cue (pas de nouveau)")
    checkEqual(i4, 2, "SRT dedup : identique au dernier (étendu) → toujours le dernier")
    checkEqual(i5, 3, "SRT dedup : texte différent → nouveau cue")
    let count = await out.committedCount
    checkEqual(count, 3, "SRT dedup : 3 cues (pas 5)")

    let srtText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    check(srtText.contains("00:00:02,000 --> 00:00:08,000"), "SRT dedup : le cue dupliqué est ÉTENDU (fin 8 s)")
    checkEqual(srtText.components(separatedBy: "world").count - 1, 1, "SRT dedup : « world » n'apparaît qu'une fois")
    check(srtText.contains("hello") && srtText.contains("goodbye"), "SRT dedup : cues distincts conservés")

    // Mode sans-traduction : le texte dédupliqué est le JA (« (JA) … »).
    let out2 = LiveOutput(fileURL: dir.appendingPathComponent("out-ja.srt"))
    let j1 = await out2.commit(start: 0, end: 1, japanese: "はい", english: nil, show: false)
    let j2 = await out2.commit(start: 1, end: 2, japanese: "はい", english: nil, show: false)
    checkEqual(j1, 1, "SRT dedup JA : premier cue → 1")
    checkEqual(j2, 1, "SRT dedup JA : JA identique → dernier cue")
    checkEqual(await out2.committedCount, 1, "SRT dedup JA : 1 cue")
}

// MARK: - point d'entrée

runSRTChecks()
runEndpointingChecks()
runCLIParserChecks()
runCleanLiveChecks()
runDegradedChecks()
runAudioSpoolChecks()
runLiveFinalTierChecks()
runSemanticEndpointerChecks()
runPseudoLiveCoordinatorChecks()
runPreviewMonotoneChecks()
runLiveOverlayStateChecks()
runPausePlannerChecks()
runRepetitionChecks()
await runLiveOutputDedupChecks()
runGoldenCheck()
await runLiveModelsCheck()

print("[tests] \(checks) assertions, \(failures) échec(s)")
if failures > 0 {
    print("[tests] SUITE ÉCHOUÉE")
    exit(1)
} else {
    print("[tests] SUITE RÉUSSIE")
    exit(0)
}
