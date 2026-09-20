import Foundation

/// The sheet of paper under the tool. Its known size is the only scale reference the app uses.
enum Paper: String, CaseIterable, Identifiable, Codable {
    case letter
    case a4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .letter: return "US Letter"
        case .a4: return "A4"
        }
    }

    /// Short side in millimetres.
    var shortMM: Double {
        switch self {
        case .letter: return 215.9
        case .a4: return 210.0
        }
    }

    /// Long side in millimetres.
    var longMM: Double {
        switch self {
        case .letter: return 279.4
        case .a4: return 297.0
        }
    }

    var sizeLabel: String {
        String(format: "%.1f × %.1f mm", shortMM, longMM)
    }
}
