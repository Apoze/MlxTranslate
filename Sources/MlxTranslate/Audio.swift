import Foundation

// Audio : extraction ffmpeg 16 kHz mono + lecture WAV PCM.

enum AudioError: LocalizedError {
    case ffmpegFailed(String)
    case wavMalformed(String)
    case wavUnsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .ffmpegFailed(let detail): "Extraction ffmpeg en échec : \(detail)"
        case .wavMalformed(let detail): "WAV invalide : \(detail)"
        case .wavUnsupportedFormat(let detail): "Format WAV non pris en charge : \(detail)"
        }
    }
}

enum Audio {
    static let sampleRate = 16_000

    /// Extrait l'audio d'un média vidéo vers `dest` (16 kHz mono WAV).
    static func extractWav(video: URL, to dest: URL) throws {
        var stderrData = Data()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
            "-i", video.path,
            "-vn", "-ac", "1", "-ar", "\(sampleRate)", "-f", "wav",
            dest.path,
        ]
        let pipe = Pipe()
        process.standardError = pipe
        let errorHandle = pipe.fileHandleForReading
        do {
            try process.run()
            stderrData = try errorHandle.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AudioError.ffmpegFailed(
                    String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        } catch let error as AudioError {
            throw error
        } catch {
            throw AudioError.ffmpegFailed(error.localizedDescription)
        }
    }

    /// Lit un WAV mono (16 bits, 24 bits, 32 bits float/int) vers des échantillons
    /// normalisés -1…1.
    static func loadWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw AudioError.wavMalformed("fichier trop court") }
        guard String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw AudioError.wavMalformed("en-tête RIFF/WAVE absent")
        }
        var offset = 12
        var formatCode: UInt16 = 0
        var channels: UInt16 = 0
        var sampleRateHz: UInt32 = 0
        var bitsPerSample: UInt16 = 0
        var dataStart: Int? = nil
        var dataLength = 0
        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let chunkSize = Int(
                UInt32(
                    littleEndian: data[(offset + 4)..<(offset + 8)].withUnsafeBytes {
                        $0.load(as: UInt32.self)
                    }
                )
            )
            let payloadStart = offset + 8
            guard payloadStart + min(chunkSize, data.count - payloadStart) <= data.count else { break }
            switch chunkID {
            case "fmt ":
                guard payloadStart + 16 <= data.count else { break }
                formatCode = UInt16(
                    littleEndian: data[payloadStart...(payloadStart + 1)].withUnsafeBytes {
                        $0.load(as: UInt16.self)
                    }
                )
                channels = UInt16(
                    littleEndian: data[(payloadStart + 2)..<(payloadStart + 4)].withUnsafeBytes {
                        $0.load(as: UInt16.self)
                    }
                )
                sampleRateHz = UInt32(
                    littleEndian: data[(payloadStart + 4)..<(payloadStart + 8)].withUnsafeBytes {
                        $0.load(as: UInt32.self)
                    }
                )
                bitsPerSample = UInt16(
                    littleEndian: data[(payloadStart + 14)..<(payloadStart + 16)].withUnsafeBytes {
                        $0.load(as: UInt16.self)
                    }
                )
            case "data":
                dataStart = payloadStart
                dataLength = chunkSize
            default:
                break
            }
            offset = payloadStart + chunkSize
            if chunkSize % 2 == 1 { offset += 1 }
        }
        guard let start = dataStart, channels == 1, formatCode == 1 || formatCode == 3 else {
            throw AudioError.wavUnsupportedFormat(
                "format=\(formatCode) canaux=\(channels) (attendu : PCM/float mono)"
            )
        }
        guard start + dataLength <= data.count else {
            throw AudioError.wavMalformed("chunk data tronqué")
        }
        let payload = data[start..<(start + dataLength)]
        switch (bitsPerSample, formatCode) {
        case (16, _):
            return decodePCM16(payload)
        case (32, 3):
            return decodeFloat32(payload)
        case (32, _):
            return decodeInt32(payload)
        case (24, _):
            return decodePCM24(payload)
        default:
            throw AudioError.wavUnsupportedFormat("\(bitsPerSample) bits/échantillon")
        }
    }

    private static func decodePCM16(_ payload: Data) -> [Float] {
        payload.withUnsafeBytes { buffer in
            let count = buffer.count / 2
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let value = Int16(bitPattern: buffer.load(fromByteOffset: i * 2, as: UInt16.self))
                samples[i] = Float(value) / 32_768
            }
            return samples
        }
    }

    private static func decodeFloat32(_ payload: Data) -> [Float] {
        payload.withUnsafeBytes { buffer in
            let count = buffer.count / 4
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                samples[i] = Float(bitPattern: buffer.load(fromByteOffset: i * 4, as: UInt32.self))
            }
            return samples
        }
    }

    private static func decodeInt32(_ payload: Data) -> [Float] {
        payload.withUnsafeBytes { buffer in
            let count = buffer.count / 4
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let value = Int32(bitPattern: buffer.load(fromByteOffset: i * 4, as: UInt32.self))
                samples[i] = Float(value) / 2_147_483_648
            }
            return samples
        }
    }

    private static func decodePCM24(_ payload: Data) -> [Float] {
        payload.withUnsafeBytes { buffer in
            let count = buffer.count / 3
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let value = Int32(buffer[i * 3])
                    | (Int32(buffer[i * 3 + 1]) << 8)
                    | (Int32(buffer[i * 3 + 2]) << 16)
                samples[i] = Float(value >> 8) / 8_388_608
            }
            return samples
        }
    }

    struct Window {
        let start: Double
        let end: Double
        let samples: ArraySlice<Float>
    }

    /// Découpe `samples` en fenêtres de `seconds` secondes (dernière plus courte).
    static func windows(_ samples: [Float], seconds: Int) -> [Window] {
        let frameCount = seconds * sampleRate
        guard frameCount > 0 else { return [] }
        var windows: [Window] = []
        var index = 0
        while index < samples.count {
            let stop = min(index + frameCount, samples.count)
            windows.append(.init(
                start: Double(index) / Double(sampleRate),
                end: Double(stop) / Double(sampleRate),
                samples: samples[index..<stop]
            ))
            index = stop
        }
        return windows
    }
}
