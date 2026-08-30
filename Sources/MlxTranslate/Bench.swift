import Foundation
import Darwin
import MLX
import MLXAudioSTT
@preconcurrency import Speech
import Translation

// ---------------------------------------------------------------------------
// Bench — inspection HORS produit (RAM / latence / qualité) pour le choix de
// l'architecture « hybride » (live léger + qualité MLX).
//
//   mlxtranslate bench /tmp/test_ja.wav [--sans-apple] [--sans-asr] [--sans-mt]
//                              [--mt translategemma-4b,qwen3-1.7b,qwen3-4b,qwen3-8b]
//
// Toujours verbeux : stderr + fichier (MLXTRANSLATE_BENCH_LOG, défaut
// /tmp/mlx_bench.log) + rapport /tmp/mlx_bench_<date>.report (+ .json).
// Sorties qualité : /tmp/mlx_bench_<date>/asr_*.txt, mt_*.txt.
//
// Étapes :
//   1) Apple on-device : Speech JA progressif (temps réel) + Translation
//      JA→EN (TranslationSession lowLatency) — latences, RAM, qualité.
//   2) ASR MLX : SenseVoiceSmall (léger) + Qwen3-ASR 1,7B (baseline produit).
//   3) MT MLX : translategemma-4b, qwen3-1.7b, qwen3-4b, qwen3-8b —
//      charge, TTFC + total par ligne (simulation live avec contexte roulant),
//      RAM pic, qualité.
// ---------------------------------------------------------------------------

public enum Bench {
    static func run(_ command: Command) async throws {
        let session = BenchSession()
        try await session.execute(command)
    }
}

// MARK: - Log (toujours actif)

enum BenchLog {
    static let lock = NSLock()
    static var start = Date()
    static var lines: [String] = []
    static let fileURL: URL = {
        if let custom = ProcessInfo.processInfo.environment["MLXTRANSLATE_BENCH_LOG"] {
            return URL(fileURLWithPath: custom)
        }
        return URL(fileURLWithPath: "/tmp/mlx_bench.log")
    }()
    private static let wallClock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func begin() {
        lock.lock()
        start = Date()
        lines.removeAll()
        lock.unlock()
    }

    static func log(_ message: @autoclosure () -> String) {
        lock.lock()
        let now = Date()
        let t = now.timeIntervalSince(start)
        let line = "[bench \(wallClock.string(from: now)) t+\(String(format: "%.2f", t)) s] \(message())"
        lines.append(line)
        lock.unlock()
        FileHandle.standardError.write(Data((line + "\n").utf8))
        // Append fichier (robuste au crash).
        lock.lock()
        if let fh = try? FileHandle(forWritingTo: fileURL) {
            fh.seekToEndOfFile()
            fh.write(Data((line + "\n").utf8))
            try? fh.close()
        } else {
            try? Data((line + "\n").utf8).write(to: fileURL)
        }
        lock.unlock()
    }
}

// MARK: - Mesures système

enum BenchSystem {
    /// Footprint mémoire du processus (phys_footprint, comme le gauge Xcode).
    static func footprintBytes() -> UInt64 {
        WhisperKitRuntime.currentMemoryBytes()
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824)
    }

    /// RAM libre système (libre + inactive + spéculative, ~Xcode).
    static func freeRAMBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)
            + UInt64(stats.speculative_count)) * page
    }

    /// Swap système (total, utilisé) en octets.
    static func swapBytes() -> (total: UInt64, used: UInt64) {
        var length = 128
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("vm.swapusage", &buffer, &length, nil, 0) == 0 else {
            return (0, 0)
        }
        let text = String(cString: buffer)
        // « vm.swapusage: total = 15728640K (0x...), used = 14955520K (0x...) »
        func grab(_ key: String) -> UInt64 {
            guard let range = text.range(of: "\(key) = ") else { return 0 }
            var index = text.index(range.lowerBound, offsetBy: "\(key) = ".count)
            let end = text[index...].firstIndex { !$0.isNumber } ?? text.endIndex
            let digits = text[index..<end]
            return (UInt64(digits) ?? 0) * 1_024
        }
        return (grab("total"), grab("used"))
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Une ligne compacte d'état système.
    static func line(_ label: String) -> String {
        let footprint = footprintBytes()
        let free = freeRAMBytes()
        let total = ProcessInfo.processInfo.physicalMemory
        let swap = swapBytes()
        return "\(label) : footprint \(gb(footprint)) GB, RAM libre \(gb(free)) GB / \(gb(total)) GB, swap utilisé \(gb(swap.used)) GB / \(gb(swap.total)) GB"
    }

    /// Taille disque d'un modèle (cache HF ou cache custom WhisperASR).
    static func diskSizeGB(modelID: String) -> Double? {
        let fm = FileManager.default
        var dir: URL?
        if modelID.hasPrefix("mlx-community/") {
            let name = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
            let hub = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache")
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
            dir = hub.appendingPathComponent(name)
        } else if modelID == Qwen3ASRFinalRuntime.modelID {
            // Cache custom WhisperASR (mesuré ce session : 2,3 GB).
            dir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library")
                .appendingPathComponent("Caches")
                .appendingPathComponent("qwen3-speech")
                .appendingPathComponent("models")
                .appendingPathComponent("ph0ryn")
                .appendingPathComponent("Qwen3-ASR-1.7B-JA-MLX-8bit")
        }
        guard let dir, fm.fileExists(atPath: dir.path) else { return nil }
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return nil
        }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += UInt64(size)
        }
        return Double(total) / 1_073_741_824
    }
}

// MARK: - Session (état partagé entre les étapes)

final class BenchSession: @unchecked Sendable {
    struct Record: @unchecked Sendable {
        var numbers: [String: [String: Double]] = [:]
        var texts: [String: String] = [:]
        var mtDiskGB: [String: Double] = [:]
        var asrDiskGB: [String: Double] = [:]
    }

    private(set) var record = Record()
    var appleLines: [String] = []
    var sensevoiceLines: [String] = []
    var qwenLines: [String] = []
    private(set) var lastASRSource = "fallback"
    private var glossary: [HighQualityGlossaryPromptTerm] = []
    private let outputDir: URL = {
        let stamp = BenchLog.wallClockStamp()
        let url = URL(fileURLWithPath: "/tmp/mlx_bench_\(stamp)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // Lignes de repli si aucun ASR ne produit de texte.
    static let fallbackLines: [String] = [
        "きょう は てんき が いい よね",
        "ちょっと まってて、すぐ に いく から",
        "この みち を まっすぐ いって、みぎ に まがってください",
        "あした の かいぎ は なんじ に はじまりますか",
        "これ は ぼく が さいすき な おんがく です",
        "ちょっと つめたい な、コートを はおこう",
    ]

    func bestASRLines() -> [String] {
        let candidates: [(source: String, lines: [String])] = [
            ("qwen3asr", qwenLines),
            ("sensevoice", sensevoiceLines),
            ("applespeech", appleLines),
        ]
        let ranked = candidates
            .filter { !$0.lines.isEmpty }
            .sorted {
                $0.lines.joined(separator: " ").count
                    > $1.lines.joined(separator: " ").count
            }
        if let best = ranked.first {
            lastASRSource = best.source
            return best.lines
        }
        lastASRSource = "fallback"
        return Self.fallbackLines
    }

    // MARK: Exécution

    func execute(_ command: Command) async throws {
        BenchLog.begin()
        let started = Date()
        BenchLog.log("=== BENCH MLXTRANSLATE — \(command.video.lastPathComponent) — \(BenchSystem.osVersion()) ===")
        let samples = try Audio.loadWAV(command.video)
        samplesCount = samples.count
        let clipSeconds = Double(samples.count) / Double(Audio.sampleRate)
        BenchLog.log("clip : \(Int(clipSeconds.rounded())) s @ \(Audio.sampleRate) Hz (\(samples.count) échantillons)")
        BenchLog.log(BenchSystem.line("système initial"))

        // Glossaire (injection MT + context strings Apple).
        let glossaryURL = command.glossary ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mlxtranslate/glossaire.txt")
        do {
            glossary = try Glossaire.terms(from: glossaryURL)
            BenchLog.log("glossaire : \(glossary.count) termes (\(glossaryURL.lastPathComponent))")
        } catch {
            glossary = []
            BenchLog.log("glossaire : aucun (\(glossaryURL.path))")
        }

        // 1) Apple on-device.
        if !command.benchSansApple {
            if #available(macOS 26.4, *) {
                do {
                    try await benchApple(samples: samples)
                } catch {
                    BenchLog.log("[APPLE] échec : \(error.localizedDescription)")
                }
            } else {
                BenchLog.log("[APPLE] macOS < 26.4 — partie Apple sautée")
            }
        } else {
            BenchLog.log("[APPLE] sautée (--sans-apple)")
        }
        BenchLog.log(BenchSystem.line("après partie Apple"))

        // 2) ASR MLX.
        if !command.benchSansASR {
            do {
                try await benchSenseVoice(samples: samples)
            } catch {
                BenchLog.log("[ASR-SENSEVOICE] échec : \(error.localizedDescription)")
            }
            do {
                try await benchQwen3ASR(samples: samples)
            } catch {
                BenchLog.log("[ASR-QWEN3ASR] échec : \(error.localizedDescription)")
            }
        } else {
            BenchLog.log("[ASR-MLX] sautée (--sans-asr)")
        }
        BenchLog.log(BenchSystem.line("après partie ASR MLX"))

        // 3) Traduction MLX.
        if !command.benchSansMT {
            let all: [String] = ["translategemma-4b", "qwen3-1.7b", "qwen3-4b", "qwen3-8b"]
            let wanted = command.benchMT.isEmpty ? all : command.benchMT
            let input = bestASRLines()
            BenchLog.log("[MT] lignes d'entrée : \(input.count) (source : \(lastASRSource))")
            for raw in wanted {
                do {
                    try await benchMT(raw: raw, lines: input)
                } catch {
                    BenchLog.log("[MT-\(raw)] échec : \(error.localizedDescription)")
                }
            }
        } else {
            BenchLog.log("[MT] sautée (--sans-mt)")
        }
        BenchLog.log(BenchSystem.line("après partie MT"))

        finish(totalSeconds: Date().timeIntervalSince(started))
    }

    // MARK: Étape 1 — Apple on-device

    @available(macOS 26.4, *)
    private func benchApple(samples: [Float]) async throws {
        // --- 1a) Speech JA progressif (temps réel) ---
        record.numbers["apple-speech"] = [:]
        do {
            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: "ja")
            ) else {
                BenchLog.log("[APPLE-SPEECH] locale JA non supportée")
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .timeIndexedProgressiveTranscription
            )
            let assetStatus = await AssetInventory.status(forModules: [transcriber])
            BenchLog.log("[APPLE-SPEECH] AssetInventory.status(JA) = \(String(describing: assetStatus))")
            record.texts["apple-speech.assetStatus"] = String(describing: assetStatus)
            if assetStatus == .supported {
                if let request = try? await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                ) {
                    let installStart = Date()
                    try await request.downloadAndInstall()
                    let installSeconds = Date().timeIntervalSince(installStart)
                    BenchLog.log(
                        "[APPLE-SPEECH] installation assets on-device : \(String(format: "%.1f", installSeconds)) s"
                    )
                    record.numbers["apple-speech", default: [:]]["assetInstallSeconds"] = installSeconds
                }
            }
            let contextStrings = Glossaire.contextualStrings(terms: glossary)
            BenchLog.log(
                "[APPLE-SPEECH] contexte glossaire : \(contextStrings.count) context strings, lecture temps réel…"
            )

            let collector = ThreadSafeArray<String>()
            let service = AppleSpeechService()
            let start = Date()
            var firstUpdateSeconds: Double?
            var lastFinalSeconds: Double?
            try await service.start(
                localeIdentifier: locale.identifier,
                contextualStrings: contextStrings
            ) { [weak self] update in
                let t = Date().timeIntervalSince(start)
                let lock = Self.sharedLock
                lock.lock()
                if firstUpdateSeconds == nil { firstUpdateSeconds = t }
                if update.isFinal { lastFinalSeconds = t }
                lock.unlock()
                if update.isFinal {
                    collector.append(update.segment.text)
                }
                let kind = update.isFinal ? "FINAL" : "progressif"
                let finalized = update.finalizedThroughSample
                BenchLog.log(
                    "[APPLE-SPEECH] t+\(String(format: "%.1f", t)) [\(kind)] fin-finalisée@\(String(format: "%.1f", Double(finalized) / 16_000))s « \(String(update.segment.text.prefix(48))) »"
                )
            }
            // Lecture temps réel : pas de 250 ms.
            let chunkSize = Int(0.25 * Double(Audio.sampleRate))
            for offset in stride(from: 0, to: samples.count, by: chunkSize) {
                let slice = Array(samples[offset..<min(offset + chunkSize, samples.count)])
                try await service.send(samples: slice, startSample: offset)
                try await Task.sleep(for: .milliseconds(250))
            }
            let feedSeconds = Date().timeIntervalSince(start)
            await service.finish()
            let totalSeconds = Date().timeIntervalSince(start)
            let queueSeconds = totalSeconds - feedSeconds
            lockAll()
            let first = firstUpdateSeconds
            let lastFinal = lastFinalSeconds
            unlockAll()
            let finals = collector.snapshot()
            appleLines = finals
            BenchLog.log(
                "[APPLE-SPEECH] lecture \(String(format: "%.1f", feedSeconds)) s, finalisation complète t+\(String(format: "%.1f", totalSeconds)) s — file de fin (queue) : \(String(format: "%.1f", queueSeconds)) s"
            )
            BenchLog.log(
                "[APPLE-SPEECH] premier résultat t+\(String(format: "%.1f", first ?? -1)) s, dernier FINAL t+\(String(format: "%.1f", lastFinal ?? -1)) s, \(finals.count) segments finaux"
            )
            var apple = record.numbers["apple-speech", default: [:]]
            apple["feedSeconds"] = feedSeconds
            apple["queueSeconds"] = queueSeconds
            apple["firstUpdateSeconds"] = first ?? -1
            apple["lastFinalSeconds"] = lastFinal ?? -1
            apple["finalSegments"] = Double(finals.count)
            apple["textChars"] = Double(finals.joined(separator: " ").count)
            record.numbers["apple-speech"] = apple
            let textFile = outputDir.appendingPathComponent("asr_applespeech.txt")
            try? finals.joined(separator: "\n").write(to: textFile, atomically: true, encoding: .utf8)
            BenchLog.log("[APPLE-SPEECH] texte → \(textFile.path)")
        } catch {
            BenchLog.log("[APPLE-SPEECH] échec : \(error.localizedDescription)")
        }

        // --- 1b) Translation JA→EN (TranslationSession lowLatency) ---
        let sourceLines = appleLines.isEmpty ? Self.fallbackLines : appleLines
        let translator = AppleTranslationService()
        do {
            let probe = TranslationSession(
                installedSource: Locale.Language(identifier: "ja"),
                target: Locale.Language(identifier: "en"),
                preferredStrategy: .lowLatency
            )
            // Les propriétés async du framework peuvent HANGER (canal
            // d'observation bloqué) → deadlines courtes sur chaque lecture.
            let isReady: Bool
            do {
                isReady = try await withAsyncDeadline(
                    .seconds(15),
                    operationName: "bench probe isReady"
                ) {
                    await probe.isReady
                }
            } catch {
                isReady = false
                BenchLog.log("[APPLE-TRANSLATION] probe isReady : délai (15 s) — framework bloqué")
            }
            let canRequestDownloads: Bool
            do {
                canRequestDownloads = try await withAsyncDeadline(
                    .seconds(15),
                    operationName: "bench probe canRequestDownloads"
                ) {
                    await probe.canRequestDownloads
                }
            } catch {
                canRequestDownloads = false
                BenchLog.log("[APPLE-TRANSLATION] probe canRequestDownloads : délai (15 s)")
            }
            BenchLog.log(
                "[APPLE-TRANSLATION] isReady=\(isReady) canRequestDownloads=\(canRequestDownloads)"
            )
            record.texts["apple-translation.isReady"] = isReady ? "oui" : "non"
            if !isReady, canRequestDownloads {
                BenchLog.log("[APPLE-TRANSLATION] préparation (téléchargement éventuel)…")
                let prepareStart = Date()
                try await withAsyncDeadline(
                    .seconds(120),
                    operationName: "bench probe prepareTranslation"
                ) {
                    try await probe.prepareTranslation()
                }
                let readyAfter = await probe.isReady
                BenchLog.log(
                    "[APPLE-TRANSLATION] préparation : \(String(format: "%.1f", Date().timeIntervalSince(prepareStart))) s, isReady=\(readyAfter)"
                )
            }
            record.numbers["apple-translation"] = [:]
            try await translator.configure(sourceLocale: "ja")
            BenchLog.log("[APPLE-TRANSLATION] session JA→EN lowLatency prête")
            var latencies: [Double] = []
            var outputs: [String] = []
            let sampler = BenchSession.PeakSampler()
            for (index, line) in sourceLines.prefix(8).enumerated() {
                let lineStart = Date()
                do {
                    let en = try await translator.translate(line)
                    let ms = Date().timeIntervalSince(lineStart) * 1_000
                    latencies.append(ms)
                    outputs.append("\(index + 1). \(en)")
                    BenchLog.log(
                        "[APPLE-TRANSLATION] ligne \(index + 1) : \(String(format: "%.0f", ms)) ms → « \(String(en.prefix(72))) »"
                    )
                } catch {
                    BenchLog.log(
                        "[APPLE-TRANSLATION] ligne \(index + 1) échec : \(error.localizedDescription)"
                    )
                }
            }
            let mem = await sampler.stop()
            if !latencies.isEmpty {
                let mean = latencies.reduce(0, +) / Double(latencies.count)
                var t = record.numbers["apple-translation", default: [:]]
                t["latencyMeanMS"] = mean
                t["latencyMaxMS"] = latencies.max() ?? 0
                t["samples"] = Double(latencies.count)
                record.numbers["apple-translation"] = t
                record.numbers["apple-translation", default: [:]]["ramDeltaGB"] =
                    Double(mem.peak - mem.before) / 1_073_741_824
                BenchLog.log(
                    "[APPLE-TRANSLATION] latence moyenne \(String(format: "%.0f", mean)) ms (max \(String(format: "%.0f", latencies.max() ?? 0)) ms, n=\(latencies.count)), RAM pic +\(BenchSystem.gb(mem.peak - mem.before)) GB"
                )
            }
            let textFile = outputDir.appendingPathComponent("mt_apple.txt")
            try? outputs.joined(separator: "\n").write(to: textFile, atomically: true, encoding: .utf8)
            BenchLog.log("[APPLE-TRANSLATION] sorties → \(textFile.path)")
        } catch {
            BenchLog.log("[APPLE-TRANSLATION] non prête / échec : \(error.localizedDescription)")
        }
    }

    // Petits utilitaires de verrouillage partagés par les closures.
    private static let sharedLock = NSLock()
    private func lockAll() { Self.sharedLock.lock() }
    private func unlockAll() { Self.sharedLock.unlock() }

    final class ThreadSafeArray<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ value: T) {
            lock.lock(); items.append(value); lock.unlock()
        }
        func snapshot() -> [T] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    // MARK: Étape 2 — ASR MLX

    private func benchSenseVoice(samples: [Float]) async throws {
        try ensureMLXMetallib()
        let modelID = "mlx-community/SenseVoiceSmall"
        BenchLog.log("[ASR-SENSEVOICE] chargement de \(modelID) (1er passage : téléchargement ~0,9 GB)…")
        let sampler = BenchSession.PeakSampler()
        let loadStart = Date()
        let model = try await SenseVoiceModel.fromPretrained(modelID)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let mem = await sampler.stop()
        let diskGB = BenchSystem.diskSizeGB(modelID: modelID) ?? 0
        record.asrDiskGB["sensevoice"] = diskGB
        BenchLog.log(
            "[ASR-SENSEVOICE] chargement : \(String(format: "%.1f", loadSeconds)) s ; RAM avant/pic : \(BenchSystem.gb(mem.before)) → \(BenchSystem.gb(mem.peak)) GB (delta +\(BenchSystem.gb(mem.peak - mem.before)) GB), poids disque \(String(format: "%.2f", diskGB)) GB"
        )
        var entry: [String: Double] = [
            "loadSeconds": loadSeconds,
            "peakDeltaGB": Double(mem.peak - mem.before) / 1_073_741_824,
            "diskGB": diskGB,
        ]
        // Clip entier.
        let wholeStart = Date()
        let whole = model.generate(audio: MLXArray(samples), language: "ja")
        let wholeSeconds = Date().timeIntervalSince(wholeStart)
        entry["wholeClipSeconds"] = wholeSeconds
        entry["wholeTextChars"] = Double(whole.text.count)
        entry["internalGenTps"] = whole.generationTps
        BenchLog.log(
            "[ASR-SENSEVOICE] clip entier (\(Int(Double(samples.count) / 16_000)) s) : \(String(format: "%.2f", wholeSeconds)) s (\(String(format: "%.0f", Double(samples.count) / 16_000 / max(wholeSeconds, 0.001)))× temps réel), \(whole.text.count) car., langue « \(whole.language ?? "?") », TPS interne \(String(format: "%.1f", whole.generationTps))"
        )
        // Fenêtres 10 s (coût live par fenêtre).
        var windowTimes: [Double] = []
        let windowSamples = 10 * Audio.sampleRate
        var offset = 0
        while offset < min(samples.count, 4 * windowSamples) {
            let end = min(offset + windowSamples, samples.count)
            let slice = Array(samples[offset..<end])
            let wStart = Date()
            _ = model.generate(audio: MLXArray(slice), language: "ja")
            windowTimes.append(Date().timeIntervalSince(wStart))
            offset = end
        }
        if !windowTimes.isEmpty {
            entry["window10sMedianMS"] = BenchMath.median(windowTimes) * 1_000
            entry["window10sMaxMS"] = windowTimes.max()! * 1_000
        }
        record.numbers["asr-sensevoice"] = entry
        if !windowTimes.isEmpty {
            BenchLog.log(
                "[ASR-SENSEVOICE] fenêtres 10 s : médiane \(String(format: "%.0f", BenchMath.median(windowTimes) * 1_000)) ms, max \(String(format: "%.0f", windowTimes.max()! * 1_000)) ms"
            )
        } else {
            BenchLog.log("[ASR-SENSEVOICE] fenêtres 10 s : non mesurées (clip < 10 s)")
        }
        sensevoiceLines = BenchMath.splitLines(whole.text)
        let textFile = outputDir.appendingPathComponent("asr_sensevoice.txt")
        try? whole.text.write(to: textFile, atomically: true, encoding: .utf8)
        BenchLog.log("[ASR-SENSEVOICE] texte → \(textFile.path)")
    }

    private func benchQwen3ASR(samples: [Float]) async throws {
        try ensureMLXMetallib()
        let modelID = Qwen3ASRFinalRuntime.modelID
        BenchLog.log("[ASR-QWEN3ASR] chargement \(modelID) (baseline produit)…")
        let runtime = Qwen3ASRFinalRuntime()
        let sampler = BenchSession.PeakSampler()
        let loadStart = Date()
        try await runtime.prepare { fraction, message in
            BenchLog.log("[ASR-QWEN3ASR] \(Int(fraction * 100)) % — \(message)")
        }
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let mem = await sampler.stop()
        let diskGB = BenchSystem.diskSizeGB(modelID: modelID) ?? 0
        record.asrDiskGB["qwen3asr"] = diskGB
        var entry: [String: Double] = [
            "loadSeconds": loadSeconds,
            "peakDeltaGB": Double(mem.peak - mem.before) / 1_073_741_824,
            "diskGB": diskGB,
        ]
        // Clip entier.
        let wholeStart = Date()
        let whole = try await runtime.transcribe(audio: samples)
        let wholeSeconds = Date().timeIntervalSince(wholeStart)
        entry["wholeClipSeconds"] = wholeSeconds
        entry["wholeTextChars"] = Double(whole.count)
        BenchLog.log(
            "[ASR-QWEN3ASR] chargement (incl. warmup) : \(String(format: "%.1f", loadSeconds)) s, RAM pic +\(BenchSystem.gb(mem.peak - mem.before)) GB, disque \(String(format: "%.2f", diskGB)) GB"
        )
        BenchLog.log(
            "[ASR-QWEN3ASR] clip entier : \(String(format: "%.2f", wholeSeconds)) s, \(whole.count) car."
        )
        // Fenêtres 10 s.
        var windowTimes: [Double] = []
        let windowSamples = 10 * Audio.sampleRate
        var offset = 0
        while offset < min(samples.count, 4 * windowSamples) {
            let end = min(offset + windowSamples, samples.count)
            let slice = Array(samples[offset..<end])
            let wStart = Date()
            _ = try await runtime.transcribe(audio: slice)
            windowTimes.append(Date().timeIntervalSince(wStart))
            offset = end
        }
        if !windowTimes.isEmpty {
            entry["window10sMedianMS"] = BenchMath.median(windowTimes) * 1_000
            entry["window10sMaxMS"] = windowTimes.max()! * 1_000
            BenchLog.log(
                "[ASR-QWEN3ASR] fenêtres 10 s : médiane \(String(format: "%.0f", BenchMath.median(windowTimes) * 1_000)) ms, max \(String(format: "%.0f", windowTimes.max()! * 1_000)) ms"
            )
        }
        record.numbers["asr-qwen3asr"] = entry
        qwenLines = BenchMath.splitLines(whole)
        let textFile = outputDir.appendingPathComponent("asr_qwen3asr.txt")
        try? whole.write(to: textFile, atomically: true, encoding: .utf8)
        BenchLog.log("[ASR-QWEN3ASR] texte → \(textFile.path)")
    }

    // MARK: Étape 3 — Traduction MLX

    // MLX attend la bibliothèque de kernels Metal à côté de l'exécutable
    // (mlx.metallib) ; le bench la copie depuis le cache (~/.mlxtranslate)
    // si elle manque — même mécanisme que les modes live/pipeline.
    private func ensureMLXMetallib() throws {
        do {
            try Pipeline.ensureMetalLibrary()
        } catch {
            BenchLog.log("[MLX] \(error.localizedDescription)")
            throw error
        }
    }

    private func benchMT(raw: String, lines: [String]) async throws {
        try ensureMLXMetallib()
        let candidate = try LocalMLXTranslator.Candidate.cliValue(raw)
        let diskGB = BenchSystem.diskSizeGB(modelID: candidate.modelID) ?? 0
        record.mtDiskGB[raw] = diskGB
        BenchLog.log(
            "[MT-\(raw)] chargement \(candidate.modelID) (disque \(String(format: "%.2f", diskGB)) GB)…"
        )
        let translator = LocalMLXTranslator(candidate: candidate)
        let sampler = BenchSession.PeakSampler()
        let loadStart = Date()
        try await translator.prepare { fraction, message in
            BenchLog.log("[MT-\(raw)] \(Int(fraction * 100)) % — \(message)")
        }
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let mem = await sampler.stop()
        var entry: [String: Double] = [
            "loadSeconds": loadSeconds,
            "peakDeltaGB": Double(mem.peak - mem.before) / 1_073_741_824,
            "diskGB": diskGB,
        ]
        BenchLog.log(
            "[MT-\(raw)] chargement : \(String(format: "%.1f", loadSeconds)) s, RAM pic +\(BenchSystem.gb(mem.peak - mem.before)) GB"
        )
        // Simulation live : lignes JA avec contexte roulant (4 paires) + glossaire.
        var history: [HighQualityAcceptedTranslationPair] = []
        var ttfcSamples: [Double] = []
        var totalSamples: [Double] = []
        var outputs: [String] = []
        for (index, line) in lines.prefix(8).enumerated() {
            let lock = NSLock()
            var ttfc: Double?
            let lineStart = Date()
            do {
                let en = try await translator.translateLive(
                    japanese: line,
                    glossary: glossary,
                    history: history,
                    isFragment: false
                ) { chunk in
                    guard !LocalMLXTranslator.cleanLive(chunk).isEmpty else { return }
                    lock.lock()
                    if ttfc == nil {
                        ttfc = Date().timeIntervalSince(lineStart)
                    }
                    lock.unlock()
                }
                let total = Date().timeIntervalSince(lineStart)
                lock.lock()
                let first = ttfc ?? total
                lock.unlock()
                ttfcSamples.append(first)
                totalSamples.append(total)
                history.append(HighQualityAcceptedTranslationPair(
                    cueID: "bench-\(index)",
                    japanese: line,
                    english: en
                ))
                outputs.append("\(index + 1). \(en)")
                BenchLog.log(
                    "[MT-\(raw)] ligne \(index + 1)/\(min(lines.count, 8)) : TTFC \(String(format: "%.2f", first)) s, total \(String(format: "%.2f", total)) s"
                )
                BenchLog.log("[MT-\(raw)]   JA : \(String(line.prefix(64)))")
                BenchLog.log("[MT-\(raw)]   EN : \(String(en.prefix(96)))")
            } catch {
                BenchLog.log("[MT-\(raw)] ligne \(index + 1) échec : \(error.localizedDescription)")
            }
        }
        if !totalSamples.isEmpty {
            entry["ttfcMeanSeconds"] = totalSamples.isEmpty ? 0 : (ttfcSamples.reduce(0, +) / Double(ttfcSamples.count))
            entry["ttfcMaxSeconds"] = ttfcSamples.max() ?? 0
            entry["totalMeanSeconds"] = totalSamples.reduce(0, +) / Double(totalSamples.count)
            entry["lines"] = Double(totalSamples.count)
        }
        record.numbers["mt-\(raw)"] = entry
        BenchLog.log(
            "[MT-\(raw)] récap : TTFC moyen \(String(format: "%.2f", ttfcSamples.isEmpty ? 0 : ttfcSamples.reduce(0, +) / Double(max(ttfcSamples.count, 1)))) s, total moyen \(String(format: "%.2f", totalSamples.isEmpty ? 0 : totalSamples.reduce(0, +) / Double(max(totalSamples.count, 1)))) s (n=\(totalSamples.count))"
        )
        let textFile = outputDir.appendingPathComponent("mt_\(raw).txt")
        try? outputs.joined(separator: "\n").write(to: textFile, atomically: true, encoding: .utf8)
        BenchLog.log("[MT-\(raw)] sorties → \(textFile.path)")
        // Libération (fairness entre candidats).
        await translator.unload()
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: Rapport final

    private func finish(totalSeconds: Double) {
        let recap: [String]
        recap = buildRecap(totalSeconds: totalSeconds)
        for line in recap {
            BenchLog.log(line)
        }
        // Fichier rapport = log complet + récap.
        let stamp = BenchLog.wallClockStamp()
        let reportURL = URL(fileURLWithPath: "/tmp/mlx_bench_\(stamp).report")
        let reportText = BenchLog.lines.joined(separator: "\n") + "\n\n" + recap.joined(separator: "\n") + "\n"
        try? reportText.write(to: reportURL, atomically: true, encoding: .utf8)
        // JSON compact (machine).
        let json: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "macos": BenchSystem.osVersion(),
            "clipSeconds": Double(samplesCount),
            "totalSeconds": totalSeconds,
            "numbers": record.numbers,
            "texts": record.texts,
            "mtDiskGB": record.mtDiskGB,
            "asrDiskGB": record.asrDiskGB,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/mlx_bench_\(stamp).json"))
        }
        // Console (stdout) : récap uniquement.
        print("\n" + recap.joined(separator: "\n"))
        print("\nRapport : \(reportURL.path)\nLog     : \(BenchLog.fileURL.path)")
    }

    private var samplesCount: Int = 0

    private func buildRecap(totalSeconds: Double) -> [String] {
        var out: [String] = []
        out.append("==============================================================")
        out.append("TABLEAU RÉCAPITULATIF — bench \(Int(totalSeconds)) s")
        out.append("==============================================================")
        let swap = BenchSystem.swapBytes()
        out.append(
            "Système : \(BenchSystem.osVersion()), RAM \(BenchSystem.gb(ProcessInfo.processInfo.physicalMemory)) GB, swap utilisé \(BenchSystem.gb(swap.used)) GB"
        )
        out.append("")
        // ASR
        if let sv = record.numbers["asr-sensevoice"] {
            out.append(
                "ASR sensevoice  : charge \(String(format: "%.1f", sv["loadSeconds"] ?? 0)) s, RAM +\(String(format: "%.1f", sv["peakDeltaGB"] ?? 0)) GB (\(String(format: "%.1f", sv["diskGB"] ?? 0)) GB disque), fenêtre 10s médiane \(String(format: "%.0f", sv["window10sMedianMS"] ?? 0)) ms, clip \(String(format: "%.2f", sv["wholeClipSeconds"] ?? 0)) s"
            )
        }
        if let qw = record.numbers["asr-qwen3asr"] {
            out.append(
                "ASR qwen3asr    : charge \(String(format: "%.1f", qw["loadSeconds"] ?? 0)) s, RAM +\(String(format: "%.1f", qw["peakDeltaGB"] ?? 0)) GB (\(String(format: "%.1f", qw["diskGB"] ?? 0)) GB disque), fenêtre 10s médiane \(String(format: "%.0f", qw["window10sMedianMS"] ?? 0)) ms, clip \(String(format: "%.2f", qw["wholeClipSeconds"] ?? 0)) s"
            )
        }
        // MT
        for raw in ["translategemma-4b", "qwen3-1.7b", "qwen3-4b", "qwen3-8b"] {
            if let m = record.numbers["mt-\(raw)"] {
                out.append(
                    "MT \(raw.padding(toLength: 17, withPad: " ", startingAt: 0)) : charge \(String(format: "%.1f", m["loadSeconds"] ?? 0)) s, RAM +\(String(format: "%.1f", m["peakDeltaGB"] ?? 0)) GB (\(String(format: "%.1f", m["diskGB"] ?? 0)) GB disque), TTFC \(String(format: "%.2f", m["ttfcMeanSeconds"] ?? 0)) s / total \(String(format: "%.2f", m["totalMeanSeconds"] ?? 0)) s (moy.)"
                )
            }
        }
        // Apple
        if let asr = record.numbers["apple-speech"] {
            out.append(
                "Apple Speech JA : file de fin \(String(format: "%.1f", asr["queueSeconds"] ?? 0)) s, \(Int(asr["finalSegments"] ?? 0)) segments finaux (assets : \(record.texts["apple-speech.assetStatus"] ?? "?"))"
            )
        }
        if let tr = record.numbers["apple-translation"] {
            out.append(
                "Apple Transl.   : latence moyenne \(String(format: "%.0f", tr["latencyMeanMS"] ?? 0)) ms (isReady : \(record.texts["apple-translation.isReady"] ?? "?")), RAM +\(String(format: "%.1f", tr["ramDeltaGB"] ?? 0)) GB"
            )
        }
        // Latence live estimée (ASR fenêtre 10 s + TTFC traduction).
        let asrWindows: [String: Double] = [
            "sensevoice": record.numbers["asr-sensevoice"]?["window10sMedianMS"] ?? 0,
            "qwen3asr": record.numbers["asr-qwen3asr"]?["window10sMedianMS"] ?? 0,
        ]
        var pairs: [String] = []
        for (asrName, asrMS) in asrWindows {
            for raw in ["translategemma-4b", "qwen3-1.7b", "qwen3-4b", "qwen3-8b"] {
                guard let ttfc = record.numbers["mt-\(raw)"]?["ttfcMeanSeconds"] else { continue }
                let est = asrMS / 1_000 + ttfc
                pairs.append("  \(asrName) + \(raw) : ≈ \(String(format: "%.1f", est)) s (ASR \(String(format: "%.0f", asrMS)) ms + TTFC \(String(format: "%.2f", ttfc)) s)")
            }
        }
        if !pairs.isEmpty {
            out.append("")
            out.append("Latence live estimée (fin fenêtre ASR + TTFC traduction) :")
            out.append(contentsOf: pairs)
        }
        out.append("")
        out.append("Sorties qualité : \(outputDir.path) (asr_*.txt, mt_*.txt)")
        out.append("Source des lignes MT : \(lastASRSource)")
        return out
    }
}

// MARK: - Échantillonneur de pic mémoire

extension BenchSession {
    struct PeakSampler: @unchecked Sendable {
        private let before: UInt64
        private let task: Task<UInt64, Never>

        init() {
            before = BenchSystem.footprintBytes()
            task = Task.detached(priority: .utility) {
                var peak = BenchSystem.footprintBytes()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    let current = BenchSystem.footprintBytes()
                    if current > peak { peak = current }
                }
                return max(peak, BenchSystem.footprintBytes())
            }
        }

        func stop() async -> (before: UInt64, after: UInt64, peak: UInt64) {
            task.cancel()
            let peak = await task.value
            return (before, BenchSystem.footprintBytes(), peak)
        }
    }
}

// MARK: - Maths simples

enum BenchMath {
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// Découpe un texte JA en lignes de sous-titres (ponctuation + newlines).
    static func splitLines(_ text: String, cap: Int = 8) -> [String] {
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: "。、！？!?，\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { (4...80).contains($0.count) }
        return Array(parts.prefix(cap))
    }
}

// MARK: - Horodatage (utilisé par le log + les noms de fichiers)

extension BenchLog {
    static func wallClockStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
