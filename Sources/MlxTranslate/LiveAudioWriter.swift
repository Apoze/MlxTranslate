import Foundation

// Spool de rattrapage de la capture live (16 kHz mono Float32) écrit en WAV
// (PCM 32-bit float), tourné toutes les `rotationSeconds` secondes (720 s = 12 min
// par défaut). C'est la sous-phase « writer + spool de rattrapage » : les fichiers WAV
// sont le spool de l'audio capturé, tournés et récupérables.
//
// Crash-safe : les données PCM sont écrites au fur et à mesure ; seule l'en-tête WAV
// (tailles) est mise à jour à chaque rotation/fin. En cas de panne, les données d'un
// segment sont récupérables (reconstruire l'en-tête à partir de la taille du fichier).
//
// Toutes les méthodes sont appelées sur la file de capture (sérialisées) — pas de lock
// interne.
final class LiveAudioWriter {
    private let baseURL: URL
    private let sampleRate: Int32
    private let rotationSamples: Int

    private var fileHandle: FileHandle?
    private var segmentSamples: Int = 0
    private var segmentIndex: Int = 0
    private var finished = false

    init(baseURL: URL, sampleRate: Int32 = 16_000, rotationSeconds: Int = 720) {
        self.baseURL = baseURL
        self.sampleRate = sampleRate
        self.rotationSamples = rotationSeconds * Int(sampleRate)
        // Le répertoire de base (captures/live-<ts>) doit exister pour écrire les segments.
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        } catch {
            Pipeline.log("capture audio : création du répertoire \(baseURL.lastPathComponent) échouée : \(error.localizedDescription)")
        }
    }

    private static func segmentURL(base: URL, index: Int) -> URL {
        base.appendingPathComponent("live-\(String(format: "%03d", index)).wav")
    }

    /// Ajoute des échantillons 16 kHz (écrit le PCM + met à jour l'en-tête) ; tourne
    /// (nouveau fichier) à la frontière de segment. Appelé sur la file de capture.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty, !finished else { return }
        if fileHandle == nil { startSegment() }
        guard let handle = fileHandle else { return }
        if let base = samples.withUnsafeBytes({ $0.baseAddress }) {
            let data = Data(bytes: base, count: samples.count * 4)
            _ = try? handle.write(contentsOf: data)
        }
        segmentSamples += samples.count
        if segmentSamples >= rotationSamples { rotate() }
    }

    /// Finalise le segment courant (met à jour l'en-tête WAV). Appelé à l'arrêt.
    func finish() {
        guard !finished else { return }
        finished = true
        rotate()
    }

    private func startSegment() {
        let url = Self.segmentURL(base: baseURL, index: segmentIndex)
        do {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            writeHeader(handle, dataSize: 0)
            try? handle.seek(toFileOffset: 44)
            fileHandle = handle
            segmentSamples = 0
            Pipeline.log("capture audio : segment \(segmentIndex) → \(url.lastPathComponent)")
        } catch {
            Pipeline.log("capture audio : création du WAV \(url.lastPathComponent) échouée : \(error.localizedDescription)")
        }
    }

    private func rotate() {
        if let handle = fileHandle {
            finalizeHeader(handle)
            try? handle.close()
            fileHandle = nil
        }
        segmentIndex += 1
        if !finished { startSegment() }
    }

    // En-tête WAV 44 octets (RIFF/WAVE, PCM 32-bit float).
    private func writeHeader(_ handle: FileHandle, dataSize: Int) {
        var header = Data()
        func addU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }
        func addU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }
        header.append(Data([0x52, 0x49, 0x46, 0x46])) // "RIFF"
        addU32(UInt32(36 + dataSize))                   // taille du fichier - 8
        header.append(Data([0x57, 0x41, 0x56, 0x45]))   // "WAVE"
        header.append(Data([0x66, 0x6d, 0x74, 0x20]))   // "fmt "
        addU32(16)                                        // taille du chunk fmt
        addU16(3)                                        // format = 3 (IEEE float)
        addU16(1)                                        // 1 canal
        addU32(UInt32(sampleRate))                        // fréquence
        addU32(UInt32(sampleRate) * 4)                    // débit
        addU16(4)                                        // alignement par bloc
        addU16(32)                                       // bits par échantillon
        header.append(Data([0x64, 0x61, 0x74, 0x61]))   // "data"
        addU32(UInt32(dataSize))
        try? handle.seek(toFileOffset: 0)
        _ = try? handle.write(contentsOf: header)
    }

    private func finalizeHeader(_ handle: FileHandle) {
        writeHeader(handle, dataSize: segmentSamples * 4)
        try? handle.seek(toFileOffset: UInt64(44 + segmentSamples * 4))
    }
}
