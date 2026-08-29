import CryptoKit
import Darwin
import Foundation

enum VoxtralModelVariant: String, CaseIterable, Codable, Sendable {
    case q4
    case q6

    var modelID: String {
        switch self {
        case .q4: "iris-sfg/Voxtral-Mini-4B-Realtime-2602-4bit"
        case .q6: "mlx-community/Voxtral-Mini-4B-Realtime-6bit"
        }
    }

    var modelRevision: String {
        switch self {
        case .q4: "12091661ce5f58788624fa49fad9ddbbf67cf063"
        case .q6: "02eb0caeb9dafb554c17a72b93dbf40cd3736c31"
        }
    }

    /// The public Q6 snapshot is a voxmlx export, while the bundled helper
    /// loads mlx-audio snapshots. Keep the requested artifact pinned for
    /// provenance, but build the compatible Q6 once from the official FP16
    /// source with mlx-audio's pinned converter.
    var conversionSource: (modelID: String, revision: String)? {
        switch self {
        case .q4:
            nil
        case .q6:
            (
                "mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16",
                "9977a0f5c0fce8472083af92957497118adc412b"
            )
        }
    }

    var localSnapshotID: String {
        switch self {
        case .q4:
            modelRevision
        case .q6:
            "mlx-audio-q6-9977a0f5-v1"
        }
    }

    var localArtifactRevision: String {
        switch self {
        case .q4:
            modelRevision
        case .q6:
            "mlx-audio-\(VoxtralHelperManifest.mlxAudioCommit)-9977a0f5c0fce8472083af92957497118adc412b-q6-g64-affine"
        }
    }

    var displayName: String { rawValue.uppercased() }
}

enum VoxtralTranscriptionDelay: Int, CaseIterable, Codable, Sendable {
    case milliseconds960 = 960
    case milliseconds1200 = 1_200
    case milliseconds2400 = 2_400
}

struct VoxtralContinuousConfiguration: Codable, Equatable, Sendable {
    let model: VoxtralModelVariant
    let delay: VoxtralTranscriptionDelay

    static let `default` = Self(model: .q4, delay: .milliseconds960)
    static let storageKey = "localVoxtralContinuousConfiguration"
    static let selectableConfigurations: [Self] = [
        .default,
        Self(model: .q6, delay: .milliseconds960),
        Self(model: .q6, delay: .milliseconds1200),
        Self(model: .q6, delay: .milliseconds2400),
    ]

    var storageValue: String { "\(model.rawValue)-\(delay.rawValue)" }

    var label: String {
        if self == .default { return "Voxtral Q4 — 960 ms (recommended)" }
        if model == .q6, delay == .milliseconds2400 {
            return "Voxtral Q6 — 2400 ms (quality test, slow)"
        }
        return "Voxtral \(model.displayName) — \(delay.rawValue) ms (experimental)"
    }

    static func stored(in defaults: UserDefaults = .standard) -> Self {
        guard let value = defaults.string(forKey: storageKey),
              let configuration = selectableConfigurations.first(where: {
                  $0.storageValue == value
              }) else { return .default }
        return configuration
    }

    var modelSnapshotDirectoryName: String {
        "voxtral-\(model.localSnapshotID)"
    }

    var stabilityGuardSamples: Int {
        VoxtralHelperManifest.sampleRate
            * (delay.rawValue + VoxtralHelperManifest.transportBlockMilliseconds)
            / 1_000
    }
}

enum VoxtralHelperManifest {
    static let mlxAudioVersion = "0.4.5"
    static let mlxAudioCommit = "04151c6abb74b886f879a4457ccdc96761f10102"
    // Compatibility aliases for the existing Q4/960 product default. Runtime
    // work must use its selected VoxtralContinuousConfiguration instead.
    static let modelID = VoxtralContinuousConfiguration.default.model.modelID
    static let modelRevision = VoxtralContinuousConfiguration.default.model.modelRevision
    static let pythonVersion = "3.12"
    static let uvVersion = "0.11.28"
    static let uvArchiveSHA256 = "33540eb7c883ab857eff79bd5ac2aa31fe27b595abecb4a9c003a2c998447232"
    static let uvLockSHA256 = "d8047fd0a07300a8bfac4472c4d3ec5f0af46fa74f87217ed8eaf2292203d0db"
    static let runtimePatchVersion = "continuous-stream-v4"
    static let runtimePatchSHA256 = "67768e28e14087b79b7eae9960bf3e8719a64864b689949a312cb76177656efe"
    static let transcriptionDelayMilliseconds =
        VoxtralContinuousConfiguration.default.delay.rawValue
    static let sampleRate = 16_000
    static let modelFrameSamples = 1_280
    static let transportBlockMilliseconds = 160
    static let metalCacheLimitBytes = 512 * 1_024 * 1_024

    /// Compatibility hook retained for older Q4/960 benchmark readers.
    static var runtimeTranscriptionDelayMilliseconds: Int {
        ProcessInfo.processInfo.environment["WHISPERASR_VOXTRAL_TEST_DELAY_MS"] == "480"
            ? 480 : transcriptionDelayMilliseconds
    }

    static let uvArchiveURL = URL(
        string: "https://github.com/astral-sh/uv/releases/download/0.11.28/uv-aarch64-apple-darwin.tar.gz"
    )!

    static var installationID: String {
        "mlx-audio-\(mlxAudioCommit)-lock-\(uvLockSHA256)-python-\(pythonVersion)-\(runtimePatchVersion)"
    }

    /// SwiftPM normally looks for its resource bundle beside the executable.
    /// A correctly formed macOS application must instead keep it in
    /// Contents/Resources, so support both layouts without relying on
    /// `Bundle.module`'s single generated path.
    static func bundledResource(
        _ name: String,
        extension fileExtension: String
    ) -> URL? {
        if let moduleResource = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "VoxtralHelper"
        ) {
            return moduleResource
        }
        let bundleName = "WhisperASR_WhisperASRApp.bundle"
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL { roots.append(resourceURL) }
        roots.append(Bundle.main.bundleURL)
        roots.append(Bundle.main.bundleURL.deletingLastPathComponent())
        if let executableURL = Bundle.main.executableURL {
            roots.append(executableURL.deletingLastPathComponent())
            roots.append(executableURL.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fileName = "\(name).\(fileExtension)"
        for root in roots {
            let candidate = root
                .appendingPathComponent(bundleName, isDirectory: true)
                .appendingPathComponent("VoxtralHelper", isDirectory: true)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

enum VoxtralHelperError: LocalizedError, Equatable {
    case invalidState(String)
    case invalidAudioRange(expected: Int?, actual: Range<Int>, sampleCount: Int)
    case invalidUVArchive
    case processFailed(String)
    case serverUnavailable(String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidState(let message),
             .processFailed(let message),
             .serverUnavailable(let message),
             .protocolFailure(let message):
            return message
        case .invalidAudioRange(let expected, let actual, let sampleCount):
            let expectedDescription = expected.map(String.init) ?? "the first sample"
            return "Voxtral expected audio at \(expectedDescription), got \(actual) with \(sampleCount) samples."
        case .invalidUVArchive:
            return "The downloaded uv archive did not match its audited SHA-256."
        }
    }
}

struct VoxtralEmissionMarker: Equatable, Sendable {
    let generatedIndex: Int
    let decoderPosition: Int
    let delayFrames: Int
    /// Absolute sample in the application's contiguous 16 kHz PCM timeline.
    let proxyEndSample: Int
    /// UTF-8 byte offset in the helper session's raw append-only transcript.
    let groupTextStartUTF8: Int
    /// False markers are telemetry only and must never create a boundary.
    let isUsable: Bool
}

enum VoxtralHelperEvent: Equatable, Sendable {
    case ready
    case acknowledged(through: Int)
    /// Newly emitted append-only text. The complete transcript is retained
    /// once inside the runtime and sent only for the final consistency check.
    case delta(text: String, sentThrough: Int?)
    case emissionMarker(VoxtralEmissionMarker)
    case completed(transcript: String, sentThrough: Int?)
    case failed(String)
}

struct VoxtralHelperEventPipe {
    private var continuation: AsyncStream<VoxtralHelperEvent>.Continuation?

    mutating func start() -> AsyncStream<VoxtralHelperEvent> {
        continuation?.finish()
        let pair = AsyncStream.makeStream(
            of: VoxtralHelperEvent.self,
            bufferingPolicy: .unbounded
        )
        continuation = pair.continuation
        return pair.stream
    }

    func yield(_ event: VoxtralHelperEvent) {
        continuation?.yield(event)
    }

    mutating func finish() {
        continuation?.finish()
        continuation = nil
    }
}

struct VoxtralHelperProgress: Equatable, Sendable {
    let sentThrough: Int?
    let acknowledgedThrough: Int?
    let backlogSamples: Int
    let maximumBacklogSamples: Int
    let transcript: String
    let helperRSSBytes: UInt64?
    let helperProcessIdentifier: Int32?
}

struct VoxtralHelperSessionGeneration: Equatable, Sendable {
    private(set) var current: UInt64?
    private var next: UInt64 = 0

    mutating func begin() -> UInt64 {
        next &+= 1
        current = next
        return next
    }

    mutating func invalidate() {
        current = nil
    }

    func accepts(_ generation: UInt64) -> Bool {
        current == generation
    }
}

struct VoxtralHelperFeedCursor: Equatable, Sendable {
    private(set) var sessionBaseSample: Int?
    private(set) var sentThrough: Int?
    private(set) var acknowledgedThrough: Int?
    private var pendingAcknowledgements: [Int] = []

    var backlogSamples: Int {
        guard let sentThrough else { return 0 }
        return sentThrough - (acknowledgedThrough ?? sentThrough)
    }

    mutating func stage(_ range: Range<Int>, sampleCount: Int) throws {
        guard range.count == sampleCount,
              sentThrough == nil || range.lowerBound == sentThrough else {
            throw VoxtralHelperError.invalidAudioRange(
                expected: sentThrough,
                actual: range,
                sampleCount: sampleCount
            )
        }
        if sessionBaseSample == nil { sessionBaseSample = range.lowerBound }
        if acknowledgedThrough == nil { acknowledgedThrough = range.lowerBound }
        sentThrough = range.upperBound
        pendingAcknowledgements.append(range.upperBound)
    }

    mutating func acknowledgeNext() -> Int? {
        guard !pendingAcknowledgements.isEmpty else { return nil }
        // Appends wait for their FIFO barrier, so this queue normally contains
        // a single entry. Use a deque only if concurrent producers are added.
        let end = pendingAcknowledgements.removeFirst()
        acknowledgedThrough = end
        return end
    }

    func absoluteSample(forRelativeSample sample: Int) -> Int? {
        guard let sessionBaseSample else { return nil }
        let (absolute, overflow) = sessionBaseSample.addingReportingOverflow(sample)
        guard !overflow else { return nil }
        return absolute
    }
}

enum VoxtralRealtimeWire {
    enum Event: Equatable {
        case sessionCreated
        case sessionUpdated
        case delta(String)
        case emissionMarker(
            generatedIndex: Int,
            decoderPosition: Int,
            delayFrames: Int,
            proxyEndSample: Int,
            groupTextStartUTF8: Int,
            isUsable: Bool
        )
        case completed(String)
        case committed
        case error(String)
        case ignored(String)
    }

    static func sessionUpdateMessage(model: String? = nil) throws -> String {
        var transcription: [String: Any] = [:]
        if let model { transcription["model"] = model }
        let object: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": VoxtralHelperManifest.sampleRate],
                        "transcription": transcription,
                        "turn_detection": NSNull(),
                    ],
                ],
            ],
        ]
        return try encode(object)
    }

    static func barrierMessage() throws -> String {
        try encode(["type": "session.update", "session": [:] as [String: Any]])
    }

    static func appendMessage(samples: [Float]) throws -> String {
        try encode([
            "type": "input_audio_buffer.append",
            "audio": pcm16Data(samples).base64EncodedString(),
        ])
    }

    static func commitMessage() throws -> String {
        try encode(["type": "input_audio_buffer.commit"])
    }

    static func pcm16Data(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let finite = sample.isFinite ? min(1, max(-1, sample)) : 0
            let scale: Float = finite < 0 ? 32_768 : 32_767
            var value = Int16((finite * scale).rounded()).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ text: String) throws -> Event {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            throw VoxtralHelperError.protocolFailure("Voxtral helper returned invalid JSON.")
        }
        switch type {
        case "session.created": return .sessionCreated
        case "session.updated": return .sessionUpdated
        case "conversation.item.input_audio_transcription.delta":
            return .delta(object["delta"] as? String ?? "")
        case "whisperasr.voxtral.emission_marker":
            guard let generatedIndex = object["generated_index"] as? Int,
                  let decoderPosition = object["decoder_position"] as? Int,
                  let delayFrames = object["delay_frames"] as? Int,
                  let proxyEndSample = object["proxy_end_sample"] as? Int,
                  let groupTextStartUTF8 = object["group_text_start_utf8"] as? Int,
                  let isUsable = object["is_usable"] as? Bool else {
                throw VoxtralHelperError.protocolFailure(
                    "Voxtral helper returned an invalid emission marker."
                )
            }
            return .emissionMarker(
                generatedIndex: generatedIndex,
                decoderPosition: decoderPosition,
                delayFrames: delayFrames,
                proxyEndSample: proxyEndSample,
                groupTextStartUTF8: groupTextStartUTF8,
                isUsable: isUsable
            )
        case "conversation.item.input_audio_transcription.completed":
            return .completed(object["transcript"] as? String ?? "")
        case "input_audio_buffer.committed": return .committed
        case "error":
            let error = object["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? "Unknown Voxtral helper error.")
        default: return .ignored(type)
        }
    }

    private static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let result = String(data: data, encoding: .utf8) else {
            throw VoxtralHelperError.protocolFailure("Could not encode a Voxtral helper message.")
        }
        return result
    }
}

/// Operational wrapper around mlx-audio's OpenAI-compatible realtime server.
/// Clause boundaries and PCM validation deliberately remain in AppState.
actor VoxtralHelperRuntime {
    enum Status: Equatable, Sendable {
        case idle
        case preparing
        case ready
        case streaming
        case stopping
        case failed(String)
    }

    private let rootDirectory: URL
    private let urlSession: URLSession
    private var configuration: VoxtralContinuousConfiguration

    private var status: Status = .idle
    private var eventPipe = VoxtralHelperEventPipe()
    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var serverPort: Int?
    private var webSocket: URLSessionWebSocketTask?
    private var receiverTask: Task<Void, Never>?
    private var receiverGeneration: UInt64?
    private var sendTail: Task<Void, Error>?
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var sessionGeneration = VoxtralHelperSessionGeneration()
    private var feedCursor = VoxtralHelperFeedCursor()
    private var maximumBacklogSamples = 0
    private var transcript = ""

    init(
        rootDirectory: URL? = nil,
        configuration: VoxtralContinuousConfiguration = .default
    ) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 600
        sessionConfiguration.timeoutIntervalForResource = 3_600
        urlSession = URLSession(configuration: sessionConfiguration)
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.configuration = configuration
    }

    func currentStatus() -> Status { status }
    func currentConfiguration() -> VoxtralContinuousConfiguration { configuration }

    func progress() -> VoxtralHelperProgress {
        VoxtralHelperProgress(
            sentThrough: feedCursor.sentThrough,
            acknowledgedThrough: feedCursor.acknowledgedThrough,
            backlogSamples: feedCursor.backlogSamples,
            maximumBacklogSamples: maximumBacklogSamples,
            transcript: transcript,
            helperRSSBytes: helperRSSBytes(),
            helperProcessIdentifier: serverProcess?.isRunning == true
                ? serverProcess?.processIdentifier : nil
        )
    }

    func prepare(
        configuration requestedConfiguration: VoxtralContinuousConfiguration? = nil,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws {
        if let requestedConfiguration, requestedConfiguration != configuration {
            await cancel()
            stopServer()
            status = .idle
            configuration = requestedConfiguration
        }
        if (status == .ready || status == .streaming), serverProcess?.isRunning == true {
            return
        }
        if status == .ready || status == .streaming || isFailed {
            await cancel()
            stopServer()
            status = .idle
        }
        guard status == .idle else {
            throw VoxtralHelperError.invalidState("Voxtral helper is already being prepared.")
        }
        status = .preparing
        do {
            try createDirectories()
            progress(0.05, "Preparing local Voxtral runtime…")
            try await installUVIfNeeded()
            progress(0.15, "Preparing managed Python 3.12…")
            try installEnvironmentIfNeeded()
            progress(
                0.45,
                configuration.model.conversionSource == nil
                    ? "Downloading the audited Voxtral \(configuration.model.displayName) snapshot…"
                    : "Downloading the source and building local Voxtral Q6…"
            )
            try downloadModelIfNeeded()
            progress(0.80, "Starting the local Voxtral helper…")
            try launchServer()
            try await waitForServer()
            progress(0.88, "Loading Voxtral \(configuration.model.displayName)…")
            try await loadModel()
            progress(0.95, "Warming the incremental stream…")
            try await warmStreamingPath()
            status = .ready
            progress(1, "Voxtral \(configuration.model.displayName) is ready.")
        } catch {
            stopServer()
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    func startSession(
        delayMilliseconds: Int? = nil
    ) async throws -> AsyncStream<VoxtralHelperEvent> {
        let selectedDelay = configuration.delay.rawValue
        guard delayMilliseconds == nil || delayMilliseconds == selectedDelay else {
            throw VoxtralHelperError.invalidState(
                "This Voxtral helper process is pinned to \(selectedDelay) ms."
            )
        }
        guard status == .ready, serverProcess?.isRunning == true else {
            throw VoxtralHelperError.invalidState("Voxtral helper is not ready.")
        }
        if let receiver = receiverTask {
            let generation = receiverGeneration
            await receiver.value
            if receiverGeneration == generation {
                receiverTask = nil
                receiverGeneration = nil
            }
            guard status == .ready, serverProcess?.isRunning == true else {
                throw VoxtralHelperError.invalidState("Voxtral helper is not ready.")
            }
        }
        let socket = try makeWebSocket()
        webSocket = socket
        feedCursor = VoxtralHelperFeedCursor()
        maximumBacklogSamples = 0
        transcript = ""
        status = .streaming
        let generation = sessionGeneration.begin()
        socket.resume()
        do {
            try await awaitEvent(.sessionCreated, from: socket)
            guard sessionGeneration.accepts(generation), webSocket === socket else {
                throw CancellationError()
            }
            try await send(
                VoxtralRealtimeWire.sessionUpdateMessage(model: modelDirectory.path),
                to: socket
            )
            try await awaitEvent(.sessionUpdated, from: socket)
            guard sessionGeneration.accepts(generation), webSocket === socket else {
                throw CancellationError()
            }

            let events = eventPipe.start()
            eventPipe.yield(.ready)
            receiverTask = Task { [weak self] in
                await self?.receiveLoop(socket, generation: generation)
            }
            receiverGeneration = generation
            return events
        } catch {
            failSession(error, generation: generation)
            throw error
        }
    }

    func append(samples: [Float], range: Range<Int>) async throws {
        guard status == .streaming, let webSocket else {
            throw VoxtralHelperError.invalidState("Voxtral is not streaming.")
        }
        guard let generation = sessionGeneration.current else {
            throw VoxtralHelperError.invalidState("Voxtral session is unavailable.")
        }
        guard !samples.isEmpty else { return }

        let append = try VoxtralRealtimeWire.appendMessage(samples: samples)
        let barrier = try VoxtralRealtimeWire.barrierMessage()
        try feedCursor.stage(range, sampleCount: samples.count)
        maximumBacklogSamples = max(maximumBacklogSamples, feedCursor.backlogSamples)
        let previous = sendTail
        let runtime = self
        let send = Task {
            try await withAsyncDeadline(
                .seconds(15),
                operationName: "Voxtral audio append",
                onTimeout: {
                    webSocket.cancel(with: .goingAway, reason: nil)
                }
            ) {
                if let previous { try await previous.value }
                try await webSocket.send(.string(append))
                try await webSocket.send(.string(barrier))
                try await runtime.waitUntilAcknowledged(
                    through: range.upperBound,
                    generation: generation
                )
            }
        }
        sendTail = send
        do {
            // mlx-audio does not acknowledge append events. An empty standard
            // session.update is a FIFO barrier: session.updated is emitted only
            // after the preceding audio has been fed and decoded.
            try await send.value
        } catch {
            let reportedError: Error = error is AsyncDeadlineError
                ? VoxtralHelperError.serverUnavailable(
                    "Voxtral stopped processing audio for 15 seconds. Audio was retained."
                )
                : error
            failSession(reportedError, generation: generation)
            throw reportedError
        }
    }

    /// Keep at most one audio block in flight. Capture remains independent in
    /// AudioRecorder, while transient MLX scheduling delays can recover without
    /// filling the WebSocket queue or triggering a destructive stream restart.
    private func waitUntilAcknowledged(
        through target: Int,
        generation: UInt64
    ) async throws {
        while (feedCursor.acknowledgedThrough ?? Int.min) < target {
            try Task.checkCancellation()
            guard status == .streaming, sessionGeneration.accepts(generation) else {
                throw VoxtralHelperError.invalidState(
                    "Voxtral stopped before acknowledging audio through sample \(target)."
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func stopAndFlush() async throws -> String {
        guard status == .streaming, webSocket != nil else {
            throw VoxtralHelperError.invalidState("Voxtral is not streaming.")
        }
        guard let generation = sessionGeneration.current else {
            throw VoxtralHelperError.invalidState("Voxtral session is unavailable.")
        }
        status = .stopping
        let runtime = self
        do {
            return try await Self.awaitFinalTranscript {
                try await runtime.waitForFinalTranscript()
            }
        } catch {
            failSession(error, generation: generation)
            throw error
        }
    }

    static func awaitFinalTranscript(
        deadline: Duration = .seconds(15),
        operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        do {
            return try await withAsyncDeadline(
                deadline,
                operationName: "Voxtral final transcript",
                operation: operation
            )
        } catch is AsyncDeadlineError {
            throw VoxtralHelperError.serverUnavailable(
                "Voxtral did not finish its final transcript within 15 seconds. Audio was retained."
            )
        }
    }

    private func waitForFinalTranscript() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                finishContinuation = continuation
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.sendCommit()
                    } catch {
                        await self.failCurrentSession(error)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelPendingFinish()
            }
        }
    }

    private func cancelPendingFinish() {
        finishContinuation?.resume(throwing: CancellationError())
        finishContinuation = nil
    }

    func cancel() async {
        status = .stopping
        sessionGeneration.invalidate()
        finishContinuation?.resume(throwing: CancellationError())
        finishContinuation = nil
        let receiver = receiverTask
        let retiringGeneration = receiverGeneration
        receiver?.cancel()
        sendTail?.cancel()
        sendTail = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        eventPipe.finish()
        await receiver?.value
        if receiverGeneration == retiringGeneration {
            receiverTask = nil
            receiverGeneration = nil
        }
        feedCursor = VoxtralHelperFeedCursor()
        maximumBacklogSamples = 0
        transcript = ""
        status = serverProcess?.isRunning == true ? .ready : .idle
    }

    func shutdown() async {
        await cancel()
        stopServer()
        status = .idle
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private var toolsDirectory: URL { rootDirectory.appendingPathComponent("Tools", isDirectory: true) }
    private var uvExecutable: URL { toolsDirectory.appendingPathComponent("uv") }
    private var environmentDirectory: URL { rootDirectory.appendingPathComponent("Environment", isDirectory: true) }
    private var projectDirectory: URL { rootDirectory.appendingPathComponent("Project", isDirectory: true) }
    private var pythonExecutable: URL { environmentDirectory.appendingPathComponent("bin/python") }
    private var modelDirectory: URL {
        rootDirectory
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(configuration.modelSnapshotDirectoryName, isDirectory: true)
    }
    private var logsDirectory: URL { rootDirectory.appendingPathComponent("Logs", isDirectory: true) }
    private var environmentStamp: URL { environmentDirectory.appendingPathComponent(".installation-id") }
    private var modelStamp: URL { modelDirectory.appendingPathComponent(".revision") }

    private func createDirectories() throws {
        for directory in [rootDirectory, toolsDirectory, logsDirectory, modelDirectory.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let manifest: [String: String] = [
            "mlxAudioVersion": VoxtralHelperManifest.mlxAudioVersion,
            "mlxAudioCommit": VoxtralHelperManifest.mlxAudioCommit,
            "modelID": configuration.model.modelID,
            "modelRevision": configuration.model.modelRevision,
            "modelLocalSnapshotID": configuration.model.localSnapshotID,
            "modelLocalArtifactRevision": configuration.model.localArtifactRevision,
            "modelConversionSourceID": configuration.model.conversionSource?.modelID ?? "",
            "modelConversionSourceRevision": configuration.model.conversionSource?.revision ?? "",
            "transcriptionDelayMilliseconds": String(configuration.delay.rawValue),
            "pythonVersion": VoxtralHelperManifest.pythonVersion,
            "uvVersion": VoxtralHelperManifest.uvVersion,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: rootDirectory.appendingPathComponent("runtime-manifest.json"), options: .atomic)
    }

    private func installUVIfNeeded() async throws {
        if FileManager.default.isExecutableFile(atPath: uvExecutable.path) { return }
        let (archive, _) = try await urlSession.download(from: VoxtralHelperManifest.uvArchiveURL)
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == VoxtralHelperManifest.uvArchiveSHA256 else {
            throw VoxtralHelperError.invalidUVArchive
        }

        let archiveCopy = rootDirectory.appendingPathComponent("uv.tar.gz")
        try? FileManager.default.removeItem(at: archiveCopy)
        try FileManager.default.copyItem(at: archive, to: archiveCopy)
        defer { try? FileManager.default.removeItem(at: archiveCopy) }
        try run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archiveCopy.path, "-C", toolsDirectory.path]
        )
        let extracted = toolsDirectory
            .appendingPathComponent("uv-aarch64-apple-darwin", isDirectory: true)
            .appendingPathComponent("uv")
        try FileManager.default.moveItem(at: extracted, to: uvExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: uvExecutable.path
        )
        try? FileManager.default.removeItem(
            at: toolsDirectory.appendingPathComponent("uv-aarch64-apple-darwin")
        )
    }

    private func installEnvironmentIfNeeded() throws {
        let installed = try? String(contentsOf: environmentStamp, encoding: .utf8)
        if installed == VoxtralHelperManifest.installationID,
           FileManager.default.isExecutableFile(atPath: pythonExecutable.path) {
            try applyRuntimePatch()
            return
        }

        try installLockedProject()
        try? FileManager.default.removeItem(at: environmentDirectory)
        let environment = managedEnvironment()
        try run(
            executable: uvExecutable,
            arguments: ["python", "install", VoxtralHelperManifest.pythonVersion],
            environment: environment
        )
        try run(
            executable: uvExecutable,
            arguments: [
                "sync", "--frozen", "--no-dev", "--no-install-project",
                "--project", projectDirectory.path,
                "--python", VoxtralHelperManifest.pythonVersion,
            ],
            environment: environment.merging(
                ["UV_PROJECT_ENVIRONMENT": environmentDirectory.path],
                uniquingKeysWith: { _, override in override }
            )
        )
        try applyRuntimePatch()
        try VoxtralHelperManifest.installationID.write(
            to: environmentStamp,
            atomically: true,
            encoding: .utf8
        )
    }

    private func applyRuntimePatch() throws {
        guard let patch = VoxtralHelperManifest.bundledResource(
            "patch_runtime",
            extension: "py"
        ) else {
            throw VoxtralHelperError.processFailed("The audited Voxtral runtime patch is missing.")
        }
        let data = try Data(contentsOf: patch)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == VoxtralHelperManifest.runtimePatchSHA256 else {
            throw VoxtralHelperError.processFailed("The audited Voxtral runtime patch was modified.")
        }
        try run(
            executable: pythonExecutable,
            arguments: [patch.path],
            environment: managedEnvironment()
        )
    }

    private func installLockedProject() throws {
        guard let pyproject = VoxtralHelperManifest.bundledResource(
            "pyproject",
            extension: "toml"
        ), let lock = VoxtralHelperManifest.bundledResource(
            "uv",
            extension: "lock"
        ) else {
            throw VoxtralHelperError.processFailed("The bundled Voxtral Python lock is missing.")
        }
        let lockData = try Data(contentsOf: lock)
        let digest = SHA256.hash(data: lockData).map { String(format: "%02x", $0) }.joined()
        guard digest == VoxtralHelperManifest.uvLockSHA256 else {
            throw VoxtralHelperError.processFailed("The bundled Voxtral Python lock was modified.")
        }
        try? FileManager.default.removeItem(at: projectDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: pyproject,
            to: projectDirectory.appendingPathComponent("pyproject.toml")
        )
        try lockData.write(to: projectDirectory.appendingPathComponent("uv.lock"), options: .atomic)
    }

    private func downloadModelIfNeeded() throws {
        let parentDirectory = modelDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        let lockURL = parentDirectory.appendingPathComponent(
            ".\(modelDirectory.lastPathComponent).install.lock"
        )
        try withExclusiveFileLock(at: lockURL) {
            try downloadModelWhileLocked()
        }
    }

    private func downloadModelWhileLocked() throws {
        let expectedStamp = configuration.model.localArtifactRevision
        let installed = try? String(contentsOf: modelStamp, encoding: .utf8)
        if installed == expectedStamp, modelInstallationIsValid(at: modelDirectory) { return }

        let parentDirectory = modelDirectory.deletingLastPathComponent()
        let stagingPrefix = ".\(modelDirectory.lastPathComponent).partial-"
        for item in try FileManager.default.contentsOfDirectory(
            at: parentDirectory,
            includingPropertiesForKeys: nil
        ) where item.lastPathComponent.hasPrefix(stagingPrefix) {
            try FileManager.default.removeItem(at: item)
        }

        let stagingDirectory = modelDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(stagingPrefix)\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let script: String
        if configuration.model.conversionSource != nil {
            script = """
            import os
            from mlx_audio.convert import convert
            convert(
                hf_path=os.environ["WHISPERASR_SOURCE_MODEL_ID"],
                revision=os.environ["WHISPERASR_SOURCE_MODEL_REVISION"],
                mlx_path=os.environ["WHISPERASR_MODEL_DIRECTORY"],
                quantize=True,
                q_bits=6,
                q_group_size=64,
                q_mode="affine",
                model_domain="stt",
            )
            """
        } else {
            script = """
            import os
            from huggingface_hub import snapshot_download
            snapshot_download(
                repo_id=os.environ["WHISPERASR_MODEL_ID"],
                revision=os.environ["WHISPERASR_MODEL_REVISION"],
                local_dir=os.environ["WHISPERASR_MODEL_DIRECTORY"],
            )
            """
        }
        var environment = managedEnvironment()
        environment["WHISPERASR_MODEL_ID"] = configuration.model.modelID
        environment["WHISPERASR_MODEL_REVISION"] = configuration.model.modelRevision
        environment["WHISPERASR_SOURCE_MODEL_ID"] =
            configuration.model.conversionSource?.modelID ?? configuration.model.modelID
        environment["WHISPERASR_SOURCE_MODEL_REVISION"] =
            configuration.model.conversionSource?.revision ?? configuration.model.modelRevision
        environment["WHISPERASR_MODEL_DIRECTORY"] = stagingDirectory.path
        try run(
            executable: pythonExecutable,
            arguments: ["-c", script],
            environment: environment
        )
        guard modelInstallationIsValid(at: stagingDirectory) else {
            throw VoxtralHelperError.processFailed("The Voxtral model installation is incomplete.")
        }
        try expectedStamp.write(
            to: stagingDirectory.appendingPathComponent(".revision"),
            atomically: true,
            encoding: .utf8
        )
        if FileManager.default.fileExists(atPath: modelDirectory.path) {
            _ = try FileManager.default.replaceItemAt(
                modelDirectory,
                withItemAt: stagingDirectory,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: stagingDirectory, to: modelDirectory)
        }
    }

    private func withExclusiveFileLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw VoxtralHelperError.processFailed("The Voxtral model install lock could not be opened.")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw VoxtralHelperError.processFailed("The Voxtral model install lock could not be acquired.")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func modelInstallationIsValid(at directory: URL) -> Bool {
        let required = ["config.json", "model.safetensors"]
        guard required.allSatisfy({ fileName in
            let path = directory.appendingPathComponent(fileName).path
            guard FileManager.default.fileExists(atPath: path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.uint64Value > 0
        }) else { return false }

        guard configuration.model == .q6 else { return true }
        guard ["model.safetensors.index.json", "tekken.json"].allSatisfy({ fileName in
            let path = directory.appendingPathComponent(fileName).path
            guard FileManager.default.fileExists(atPath: path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.uint64Value > 0
        }), let attributes = try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("model.safetensors").path
        ), let weightSize = attributes[.size] as? NSNumber,
        weightSize.uint64Value == 3_623_484_043,
        let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["model_type"] as? String == "voxtral_realtime",
        let quantization = object["quantization"] as? [String: Any],
        quantization["bits"] as? Int == 6,
        quantization["group_size"] as? Int == 64,
        quantization["mode"] as? String == "affine" else {
            return false
        }
        return true
    }

    private func launchServer() throws {
        if serverProcess?.isRunning == true { return }
        let port = try Self.availableLoopbackPort()
        let launcher = rootDirectory.appendingPathComponent("launch_voxtral_helper.py")
        let script = """
        import os, signal, threading, time
        import mlx.core as mx
        mx.set_cache_limit(\(VoxtralHelperManifest.metalCacheLimitBytes))
        parent = int(os.environ["WHISPERASR_PARENT_PID"])
        def watch_parent():
            while os.getppid() == parent:
                time.sleep(1)
            os.kill(os.getpid(), signal.SIGTERM)
        threading.Thread(target=watch_parent, daemon=True).start()
        from mlx_audio.server import main
        main()
        """
        try script.write(to: launcher, atomically: true, encoding: .utf8)

        let logURL = logsDirectory.appendingPathComponent("server.log")
        try Data().write(to: logURL, options: .atomic)
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = pythonExecutable
        process.arguments = [
            launcher.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--realtime",
            "--realtime-model", modelDirectory.path,
            "--realtime-transcription-delay-ms",
            String(configuration.delay.rawValue),
            "--log-dir", logsDirectory.path,
        ]
        var environment = managedEnvironment()
        environment["WHISPERASR_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()
        serverProcess = process
        serverLogHandle = log
        serverPort = port
    }

    private func waitForServer() async throws {
        guard let serverPort else {
            throw VoxtralHelperError.serverUnavailable("Voxtral helper has no loopback port.")
        }
        let url = URL(string: "http://127.0.0.1:\(serverPort)/")!
        for _ in 0..<300 {
            guard serverProcess?.isRunning == true else {
                throw VoxtralHelperError.serverUnavailable(serverLogTail())
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1
            if let (_, response) = try? await urlSession.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw VoxtralHelperError.serverUnavailable("Voxtral helper did not start in 30 seconds.")
    }

    private func loadModel() async throws {
        guard let serverPort else {
            throw VoxtralHelperError.serverUnavailable("Voxtral helper has no loopback port.")
        }
        var components = URLComponents(string: "http://127.0.0.1:\(serverPort)/v1/models")!
        components.queryItems = [URLQueryItem(name: "model_name", value: modelDirectory.path)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3_600
        let (_, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoxtralHelperError.serverUnavailable(
                "Voxtral \(configuration.model.displayName) could not be loaded."
            )
        }
    }

    private func warmStreamingPath() async throws {
        let socket = try makeWebSocket()
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try await awaitEvent(.sessionCreated, from: socket)
        try await send(VoxtralRealtimeWire.sessionUpdateMessage(model: modelDirectory.path), to: socket)
        try await awaitEvent(.sessionUpdated, from: socket)
        try await send(
            VoxtralRealtimeWire.appendMessage(samples: [Float](repeating: 0, count: 16_000)),
            to: socket
        )
        try await send(VoxtralRealtimeWire.barrierMessage(), to: socket)
        try await awaitEvent(.sessionUpdated, from: socket)
        try await send(VoxtralRealtimeWire.commitMessage(), to: socket)
        try await awaitEventMatching(from: socket) {
            if case .completed = $0 { return true }
            return false
        }
    }

    private func makeWebSocket() throws -> URLSessionWebSocketTask {
        guard let serverPort else {
            throw VoxtralHelperError.serverUnavailable("Voxtral helper has no loopback port.")
        }
        return urlSession.webSocketTask(
            with: URL(string: "ws://127.0.0.1:\(serverPort)/v1/realtime")!
        )
    }

    private func receiveLoop(
        _ socket: URLSessionWebSocketTask,
        generation: UInt64
    ) async {
        do {
            while !Task.isCancelled {
                guard sessionGeneration.accepts(generation), webSocket === socket else {
                    return
                }
                let message = try await socket.receive()
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8) else { continue }
                    text = value
                @unknown default: continue
                }
                guard sessionGeneration.accepts(generation), webSocket === socket else {
                    return
                }
                try handle(VoxtralRealtimeWire.decode(text), generation: generation)
                guard sessionGeneration.accepts(generation), webSocket === socket else {
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            failSession(error, generation: generation)
        }
    }

    private func handle(
        _ event: VoxtralRealtimeWire.Event,
        generation: UInt64
    ) throws {
        guard sessionGeneration.accepts(generation) else { return }
        switch event {
        case .sessionUpdated:
            if let end = feedCursor.acknowledgeNext() {
                eventPipe.yield(.acknowledged(through: end))
            }
        case .delta(let delta):
            transcript += delta
            eventPipe.yield(.delta(text: delta, sentThrough: feedCursor.sentThrough))
        case .emissionMarker(
            let generatedIndex,
            let decoderPosition,
            let delayFrames,
            let relativeEndSample,
            let groupTextStartUTF8,
            let isUsable
        ):
            let absoluteEndSample = feedCursor.absoluteSample(
                forRelativeSample: relativeEndSample
            )
            let (relativeFrame, frameOverflow) = generatedIndex.subtractingReportingOverflow(
                delayFrames
            )
            let (expectedProxy, proxyOverflow) = max(0, relativeFrame)
                .multipliedReportingOverflow(by: VoxtralHelperManifest.modelFrameSamples)
            let (promptOffset, promptOverflow) = delayFrames.addingReportingOverflow(33)
            let (expectedDecoderPosition, decoderOverflow) = generatedIndex
                .addingReportingOverflow(promptOffset)
            let structurallyUsable = isUsable
                && !frameOverflow
                && !proxyOverflow
                && !promptOverflow
                && !decoderOverflow
                && generatedIndex >= delayFrames
                && decoderPosition == expectedDecoderPosition
                && relativeEndSample == expectedProxy
                && groupTextStartUTF8 >= 0
                && absoluteEndSample != nil
            eventPipe.yield(.emissionMarker(VoxtralEmissionMarker(
                generatedIndex: generatedIndex,
                decoderPosition: decoderPosition,
                delayFrames: delayFrames,
                proxyEndSample: absoluteEndSample ?? feedCursor.sessionBaseSample ?? 0,
                groupTextStartUTF8: groupTextStartUTF8,
                isUsable: structurallyUsable
            )))
        case .completed(let completed):
            transcript = completed
            eventPipe.yield(.completed(transcript: completed, sentThrough: feedCursor.sentThrough))
            guard status == .stopping else { return }
            finishContinuation?.resume(returning: completed)
            finishContinuation = nil
            sessionGeneration.invalidate()
            sendTail = nil
            webSocket?.cancel(with: .normalClosure, reason: nil)
            webSocket = nil
            status = .ready
            eventPipe.finish()
        case .error(let message):
            throw VoxtralHelperError.protocolFailure(message)
        case .sessionCreated, .committed, .ignored:
            break
        }
    }

    private func sendCommit() async throws {
        guard let webSocket else {
            throw VoxtralHelperError.invalidState("Voxtral WebSocket is unavailable.")
        }
        try await sendTail?.value
        try await send(VoxtralRealtimeWire.commitMessage(), to: webSocket)
    }

    private func failCurrentSession(_ error: Error) {
        guard let generation = sessionGeneration.current else { return }
        failSession(error, generation: generation)
    }

    private func failSession(_ error: Error, generation: UInt64) {
        guard sessionGeneration.accepts(generation) else { return }
        sessionGeneration.invalidate()
        finishContinuation?.resume(throwing: error)
        finishContinuation = nil
        receiverTask?.cancel()
        sendTail?.cancel()
        sendTail = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        status = .failed(error.localizedDescription)
        eventPipe.yield(.failed(error.localizedDescription))
        eventPipe.finish()
    }

    private func awaitEvent(
        _ expected: VoxtralRealtimeWire.Event,
        from socket: URLSessionWebSocketTask
    ) async throws {
        try await awaitEventMatching(from: socket) { $0 == expected }
    }

    private func awaitEventMatching(
        from socket: URLSessionWebSocketTask,
        predicate: (VoxtralRealtimeWire.Event) -> Bool
    ) async throws {
        while true {
            let message = try await withAsyncDeadline(
                .seconds(10),
                operationName: "Voxtral WebSocket handshake",
                onTimeout: {
                    socket.cancel(with: .goingAway, reason: nil)
                },
                operation: {
                    try await socket.receive()
                }
            )
            let text: String
            switch message {
            case .string(let value): text = value
            case .data(let data):
                guard let value = String(data: data, encoding: .utf8) else { continue }
                text = value
            @unknown default: continue
            }
            let event = try VoxtralRealtimeWire.decode(text)
            if case .error(let message) = event {
                throw VoxtralHelperError.protocolFailure(message)
            }
            if predicate(event) { return }
        }
    }

    private func send(_ text: String, to socket: URLSessionWebSocketTask) async throws {
        try await withAsyncDeadline(
            .seconds(10),
            operationName: "Voxtral WebSocket send",
            onTimeout: {
                socket.cancel(with: .goingAway, reason: nil)
            },
            operation: {
                try await socket.send(.string(text))
            }
        )
    }

    private func stopServer() {
        guard let process = serverProcess else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        serverProcess = nil
        serverPort = nil
        try? serverLogHandle?.close()
        serverLogHandle = nil
    }

    private func managedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["UV_PYTHON_INSTALL_DIR"] = rootDirectory.appendingPathComponent("Python").path
        environment["UV_CACHE_DIR"] = rootDirectory.appendingPathComponent("Cache/uv").path
        let huggingFaceCache = rootDirectory.appendingPathComponent("Cache/huggingface")
        environment["HF_HOME"] = huggingFaceCache.path
        environment["HF_HUB_CACHE"] = huggingFaceCache
            .appendingPathComponent("hub", isDirectory: true).path
        return environment
    }

    /// Physical footprint includes Metal/IOSurface allocations that ordinary
    /// resident-size accounting misses for the MLX child process.
    private func helperRSSBytes() -> UInt64? {
        guard let pid = serverProcess?.processIdentifier,
              serverProcess?.isRunning == true else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            UnsafeMutableRawPointer(pointer).withMemoryRebound(
                to: rusage_info_t?.self,
                capacity: 1
            ) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    private func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws {
        let logURL = logsDirectory.appendingPathComponent("setup.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        try log.seekToEnd()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = log
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VoxtralHelperError.processFailed(
                "\(executable.lastPathComponent) exited with status \(process.terminationStatus). See \(logURL.path)."
            )
        }
    }

    private func serverLogTail() -> String {
        let url = logsDirectory.appendingPathComponent("server.log")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data.suffix(4_096), encoding: .utf8),
              !text.isEmpty else {
            return "Voxtral helper stopped before becoming ready."
        }
        return text
    }

    private static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw VoxtralHelperError.serverUnavailable("Could not allocate a loopback socket.")
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            throw VoxtralHelperError.serverUnavailable("Could not bind a loopback socket.")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            throw VoxtralHelperError.serverUnavailable("Could not inspect the loopback socket.")
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
