import Foundation
@testable import MlxTranslate

// Libellés lisibles des candidats de modèle de traduction (sélecteurs de la GUI).
extension LocalMLXTranslator.Candidate {
    var displayLabel: String {
        switch self {
        case .qwen3_8B: "qwen3-8b (défaut)"
        case .qwen2_5_7B: "qwen2.5-7b"
        case .qwen3_14B: "qwen3-14b"
        case .translateGemma12B: "gemma-12b"
        case .translateGemma4B: "gemma-4b"
        }
    }
}
