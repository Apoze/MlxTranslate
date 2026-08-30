import Foundation

// Types et constantes du mode temps réel (live).

// Énoncé sous-titré en direct.
struct LiveCue: Sendable {
    var index: Int
    var start: Double      // secondes (base 16 kHz)
    var end: Double        // secondes
    var japanese: String
    var previewEnglish: String?   // EN instant, bas (Apple, synchronisé)
    var finalEnglish: String?     // EN haute qualité (MLX, remplace la preview)
}

// Constantes d'endpointing (fidèles à WhisperASR).
enum LiveEndpointing {
    /// Échantillons par frame (100 ms à 16 kHz).
    static let frameSamples = 1_600
    /// Seuil RMS de silence.
    static let silenceThreshold: Float = 0.001
    /// Pause minimale (frames) pour couper.
    static let minSilenceFrames = 3
    /// Forçage : durée max d'un énoncé sans pause (secondes).
    static let forceCutSeconds = 12.0
    /// Période de vérification des pauses (secondes).
    static let pollSeconds = 0.4
    /// Résolution de l'échantillon (16 kHz).
    static let sampleRate = 16_000.0

    /// Index (dans `silenceFrames`) du DÉBUT de la dernière séquence de silence
    /// (≥ `minSilence` frames), si au moins une frame de parole la précède ; sinon nil.
    /// `silenceFrames[i] == 1` si la frame `i` est silencieuse. Fonction pure testable.
    static func lastSilenceRunStart(silenceFrames: [Int], minSilence: Int) -> Int? {
        var i = silenceFrames.count
        while i > 0 {
            i -= 1
            if silenceFrames[i] == 1 {
                var runStart = i
                while runStart > 0, silenceFrames[runStart - 1] == 1 {
                    runStart -= 1
                }
                let runLength = i - runStart + 1
                if runStart > 0 {
                    return runLength >= minSilence ? runStart : nil
                }
            }
        }
        return nil
    }
}

enum LiveFormat {
    /// hh:mm:ss.sss
    static func timecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let ms = max(0, Int((seconds - floor(seconds)) * 1000))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    /// hh:mm:ss
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Ligne de sortie : preview (provisoire) ou final (engagé).
    static func previewLine(_ cue: LiveCue) -> String {
        "[\(timecode(cue.start))s] ~ \(cue.previewEnglish ?? "")"
    }

    static func finalLine(_ cue: LiveCue) -> String {
        let en = cue.finalEnglish ?? cue.previewEnglish ?? ""
        return "[\(timecode(cue.start))–\(timecode(cue.end))] \(en)"
    }
}
