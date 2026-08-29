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
        let errorHandle = FileHandle(forWriting: pipe.fileHandleForReading)
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
            let chunkSize = Int(littleEndian: data.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes {
                $0.load(as: UInt32.self)
            })
            let payloadStart = offset + 8
            guard payloadStart + min(chunkSize, data.count - payloadStart) <= data.count else { break }
            switch chunkID {
            case "fmt ":
                guard payloadStart + 16 <= data.count else { break }
                formatCode = Int(littleEndian: data[payloadStart...payloadStart + 1].withUnsafeBytes {
                    $0.load(as: UInt16.self)
                })
                channels = Int(littleEndian: data[(payloadStart + 2)..<(payloadStart + 4)].withUnsafeBytes {
                    $0.load(as: UInt16.self)
                })
                sampleRateHz = Int(littleEndian: data[(payloadStart + 4)..<(payloadStart + 8)].withUnsafeBytes {
                    $0.load(as: UInt32.self)
                })
                bitsPerSample = Int(littleEndian: data[(payloadStart + 14)..<(payloadStart + 16)].withUnsafeBytes {
                    $0.load(as: UInt16.self)
                })
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
        switch bitsPerSample {
        case 16:
            return payload.withUnsafeBytes { buffer -> [Float] in
                let count = buffer.count / 2
                var samples = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    samples[i] = Float(buffer[i * 2...]) / 32_768
                }
                return samples
            }
        case 32 where formatCode == 3:
            return payload.withUnsafeBytes { buffer -> [Float] in
                let count = buffer.count / 4
                var samples = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    samples[i] = buffer[i * 4...]
                }
                return samples
            }
        case 32:
            return payload.withUnsafeBytes { buffer -> [Float] in
                let count = buffer.count / 4
                var samples = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    samples[i] = Float(Int(bitPattern: buffer[i * 4...])) / 2_147_483_648
                }
                return samples
            }
        case 24:
            return payload.withUnsafeBytes { buffer -> [Float] in
                let count = buffer.count / 3
                var samples = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    let value = Int32(buffer[i * 3]) | (Int32(buffer[i * 3 + 1]) << 8) | (Int32(buffer[i * 3 + 2]) << 16)
                    samples[i] = Float(value >> 8) / 8_388_608
                }
                return samples
            }
        default:
            throw AudioError.wavUnsupportedFormat("\(bitsPerSample) bits/échantillon")
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
