import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

// Capture d'audio par application (ScreenCaptureKit, 48 kHz mono) + resampling
// 48→16 kHz (AVAudioConverter) + tampon 16 kHz borné + primitives de silence
// (RMS / lastSilenceCut) pour l'endpointing.
//
// Port dissocié de whisperASR/Sources/AudioRecorder.swift (CanonicalPCMResampler,
// accumulatePCMSamples, rmsEnergy, lastSilenceCut, loadAvailableApps) : sans UI,
// sans writer m4a ni spool de recovery (phase 2).

// Résampleur 48 kHz Float32 mono → 16 kHz Float32 mono (anti-alias via AVAudioConverter).
final class PCMResampler {
    static let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private let converter: AVAudioConverter
    private let outputFrameCapacity: AVAudioFrameCount
    private var finished = false

    init(outputFrameCapacity: AVAudioFrameCount = 4_096) {
        guard let converter = AVAudioConverter(from: Self.sourceFormat, to: Self.targetFormat) else {
            preconditionFailure("AVAudioConverter 48k→16k unavailable")
        }
        self.converter = converter
        self.outputFrameCapacity = max(1, outputFrameCapacity)
    }

    func reset() {
        converter.reset()
        finished = false
    }

    /// Ajoute des échantillons 48 kHz et renvoie la sortie 16 kHz (drain partiel).
    func append(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty, !finished else { return [] }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: Self.sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = input.floatChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            channel.update(from: baseAddress, count: source.count)
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        var supplied = false
        return drain(requireEndOfStream: false) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
    }

    /// Vide la queue retardée en fin de flux.
    func finish() -> [Float] {
        guard !finished else { return [] }
        finished = true
        return drain(requireEndOfStream: true) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(
        requireEndOfStream: Bool,
        input: @escaping AVAudioConverterInputBlock
    ) -> [Float] {
        var result: [Float] = []
        let maximumIterations = requireEndOfStream ? 32 : 4_096
        for _ in 0..<maximumIterations {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: Self.targetFormat, frameCapacity: outputFrameCapacity
            ) else { return result }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: input)
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(
                    start: channel, count: Int(output.frameLength)
                ))
            }
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if requireEndOfStream { continue }
                return result
            case .endOfStream:
                return result
            case .error:
                return result
            @unknown default:
                return result
            }
        }
        return result
    }
}

// App capturable (id + nom + le SCRunningApplication pour le filtre SCK).
struct CaptureApp: Identifiable {
    let id: String
    let name: String
    let running: SCRunningApplication

    init(bundleID: String, name: String, running: SCRunningApplication) {
        self.id = bundleID
        self.name = name
        self.running = running
    }
}

// Erreurs de capture d'écran (mode live).
enum LiveCaptureError: LocalizedError {
    case tccDenied
    case noDisplay
    case startup(String)

    var errorDescription: String? {
        switch self {
        case .tccDenied:
            return "La capture d'écran n'est pas autorisée.\n"
                + "  → Accordez « Enregistrement de l'écran » à votre terminal"
                + " (System Settings → Confidentialité et sécurité → Enregistrement de l'écran),\n"
                + "    puis relancez la commande."
        case .noDisplay:
            return "Aucun écran capturable trouvé."
        case .startup(let detail):
            return "Échec de la capture : \(detail)"
        }
    }
}

// Capture SCK + tampon 16 kHz borné. Toutes les écritures du tampon se font sur la
// file de capture (sérialisée) ; les lectures (feed/endpoint) passent par le lock.
final class AppCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private struct BufState {
        var buffer: [Float] = []
        var trimOffset: Int = 0
    }

    private let captureQueue = DispatchQueue(label: "mlxtranslate.live.capture", qos: .userInitiated)
    private let resampler = PCMResampler()
    private let bufLock = OSAllocatedUnfairLock(initialState: BufState())
    private var stream: SCStream?
    private var running = false

    /// Callback (thread-safe) appelé si le flux SCK échoue en cours (app fermée,
    /// TCC révoquée, écran déconnecté). Le live engine s'en sert pour arrêter la
    /// boucle proprement au lieu de poller dans le vide.
    var onStreamFailure: (@Sendable (Error) -> Void)?

    /// Applis capturables : ceux avec des fenêtres et une politique d'activation .regular.
    static func listApps() async throws -> [CaptureApp] {
        let content = try await AppCapture.shareableContent()
        let selfBundle = Bundle.main.bundleIdentifier
        let appsWithWindows = Set(content.windows.map { $0.owningApplication?.bundleIdentifier })
        let apps = content.applications
            .filter {
                $0.bundleIdentifier != selfBundle
                    && !$0.applicationName.isEmpty
                    && appsWithWindows.contains($0.bundleIdentifier)
                    && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
            }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        return apps.map { CaptureApp(bundleID: $0.bundleIdentifier, name: $0.applicationName, running: $0) }
    }

    // Contenu SCK, avec un message clair si l'autorisation TCC est refusée.
    private static func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            if error.localizedDescription.lowercased().contains("tcc") {
                throw LiveCaptureError.tccDenied
            }
            throw error
        }
    }

    func start(app: SCRunningApplication) async throws {
        guard !running else { return }
        let content = try await AppCapture.shareableContent()
        guard let display = content.displays.first else {
            throw LiveCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 1
        config.sampleRate = 48_000
        // Video minimale (requis par SCK, on ne l'utilise pas).
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        captureQueue.sync {
            resampler.reset()
            bufLock.withLock { state in
                state.buffer.removeAll(keepingCapacity: true)
                state.trimOffset = 0
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        running = true
    }

    func stop() async {
        guard running else { return }
        running = false
        captureQueue.sync {
            // Draine la queue retardée du résampleur en fin de flux.
            _ = resampler.finish()
        }
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { return }
        let sampleCount = totalLength / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }
        let floatPtr = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)
        let source = Array(UnsafeBufferPointer(start: floatPtr, count: sampleCount))
        let resampled = resampler.append(source)
        if !resampled.isEmpty {
            bufLock.withLock { state in
                state.buffer.append(contentsOf: resampled)
            }
        }
    }

    // MARK: SCStreamDelegate

    /// Le flux SCK a échoué (app fermée, TCC révoquée, écran déconnecté, …).
    /// On notifie le live engine pour qu'il arrête la boucle proprement.
    func streamDidFailWithError(_ stream: SCStream, error: Error, for output: SCStreamOutput?) {
        Pipeline.log("capture : échec du flux SCK (\(error.localizedDescription))")
        onStreamFailure?(error)
    }

    // MARK: Tampon 16 kHz (lectures)

    /// Nombre total d'échantillons 16 kHz accumulés (index absolu).
    func sampleCount() -> Int {
        bufLock.withLock { $0.trimOffset + $0.buffer.count }
    }

    /// Échantillons 16 kHz dans `[from, to)` (indices absolus).
    func samples(from: Int, upTo to: Int) -> [Float] {
        bufLock.withLock { state in
            let start = max(0, from - state.trimOffset)
            let end = min(to - state.trimOffset, state.buffer.count)
            guard end > start else { return [] }
            return Array(state.buffer[start..<end])
        }
    }

    /// RMS de la plage absolue `[from, from+count)`.
    func rmsEnergy(from: Int, count: Int) -> Float {
        bufLock.withLock { state in
            let start = from - state.trimOffset
            guard start >= 0 else { return 0 }
            let end = min(start + count, state.buffer.count)
            guard end > start else { return 0 }
            var sum: Float = 0
            for i in start..<end {
                let s = state.buffer[i]
                sum += s * s
            }
            return (sum / Float(end - start)).squareRoot()
        }
    }

    /// Index (absolu) au DÉBUT de la dernière séquence de silence ≥ `minSilenceFrames`
    /// frames (frame = `frameSamples` échantillons) dans `[from, to)`, si au moins une
    /// frame de parole la précède. Renvoie nil sinon.
    func lastSilenceCut(from: Int, upTo to: Int) -> Int? {
        bufLock.withLock { state in
            let frameSamples = LiveEndpointing.frameSamples
            let threshold = LiveEndpointing.silenceThreshold
            let minSilence = LiveEndpointing.minSilenceFrames
            let count = to - state.trimOffset
            guard count >= frameSamples else { return nil }
            var frameStarts: [Int] = []
            var frameStart = from - state.trimOffset
            while frameStart + frameSamples <= count {
                var silent = true
                var offset = frameStart
                while offset < frameStart + frameSamples {
                    if state.buffer[offset].magnitude >= threshold {
                        silent = false
                        break
                    }
                    offset += 1
                }
                frameStarts.append(silent ? 1 : 0)
                frameStart += frameSamples
            }
            guard let runStart = LiveEndpointing.lastSilenceRunStart(
                silenceFrames: frameStarts, minSilence: minSilence
            ) else { return nil }
            // Index absolu au début de la séquence de silence.
            return (from - state.trimOffset) + runStart * frameSamples + state.trimOffset
        }
    }

    /// Libère les échantillons avant `upTo` (index absolu) pour borner la mémoire.
    func trim(upTo: Int) {
        bufLock.withLock { state in
            let index = upTo - state.trimOffset
            guard index > 0 else { return }
            let trimCount = min(index, state.buffer.count)
            state.buffer.removeFirst(trimCount)
            state.trimOffset += trimCount
        }
    }
}
