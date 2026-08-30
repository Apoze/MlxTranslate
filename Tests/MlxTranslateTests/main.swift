import Foundation
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

// MARK: - point d'entrée

runSRTChecks()
runEndpointingChecks()
runCLIParserChecks()
runCleanLiveChecks()
runDegradedChecks()
runAudioSpoolChecks()
runGoldenCheck()

print("[tests] \(checks) assertions, \(failures) échec(s)")
if failures > 0 {
    print("[tests] SUITE ÉCHOUÉE")
    exit(1)
} else {
    print("[tests] SUITE RÉUSSIE")
    exit(0)
}
