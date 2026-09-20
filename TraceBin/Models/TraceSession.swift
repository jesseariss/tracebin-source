import CoreGraphics
import Foundation
import Observation

enum BinMode: String, CaseIterable, Identifiable, Codable {
    case bin
    case flat

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .bin: return "Bin"
        case .flat: return "Flat insert"
        }
    }
}

enum PocketDepth: String, CaseIterable, Identifiable {
    case toFloor
    case mm12
    case mm8

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .toFloor: return "To floor"
        case .mm12: return "12 mm"
        case .mm8: return "8 mm"
        }
    }
    /// nil means the pocket goes all the way to the floor.
    var millimetres: Double? {
        switch self {
        case .toFloor: return nil
        case .mm12: return 12
        case .mm8: return 8
        }
    }
}

/// One trace in progress: the mask (fixed) plus everything the user can adjust.
@Observable
final class TraceSession: Identifiable, Hashable {
    let id = UUID()
    let paper: Paper
    let original: CGImage
    let mask: ToolMask
    var outline: Outline

    var clearanceMM: Double
    var heightUnits: Int
    var pocketDepth: PocketDepth = .toFloor
    var mode: BinMode = .bin
    var flatWidthMM: Double = 100
    var flatDepthMM: Double = 100
    var flatThicknessMM: Double = 15
    var notch: FingerNotch?

    init(paper: Paper, original: CGImage, mask: ToolMask, outline: Outline, clearanceMM: Double, heightUnits: Int) {
        self.paper = paper
        self.original = original
        self.mask = mask
        self.outline = outline
        self.clearanceMM = clearanceMM
        self.heightUnits = heightUnits
    }

    var corrected: CorrectedPaper { mask.corrected }

    /// Grid units for bin mode.
    var gridUnits: (n: Int, m: Int) {
        Gridfinity.units(forPocketWidth: outline.pocketWidthMM, depth: outline.pocketDepthMM)
    }

    var heightMM: Double { Double(heightUnits) * Gridfinity.unitH }

    /// True when the pocket plus minimum wall fits inside the flat insert the user typed.
    var flatFits: Bool {
        let margin = 2 * Gridfinity.clearanceFromWall
        return outline.pocketWidthMM + margin <= flatWidthMM && outline.pocketDepthMM + margin <= flatDepthMM
    }

    /// The live one-line summary shown on the Adjust screen.
    var summaryLine: String {
        let tool = String(format: "Tool %.0f × %.0f mm.", outline.toolWidthMM, outline.toolDepthMM)
        switch mode {
        case .bin:
            let u = gridUnits
            return tool + String(format: " Bin %d × %d units, %.1f × %.1f × %.0f mm.",
                                 u.n, u.m, Gridfinity.footprintMM(units: u.n), Gridfinity.footprintMM(units: u.m), heightMM)
        case .flat:
            return tool + String(format: " Insert %.0f × %.0f × %.0f mm.", flatWidthMM, flatDepthMM, flatThicknessMM)
        }
    }

    /// Headline for the Adjust screen: what will be made.
    var primaryLine: String {
        switch mode {
        case .bin:
            let u = gridUnits
            return String(format: "Bin %d × %d · %.1f × %.1f × %.0f mm", u.n, u.m,
                          Gridfinity.footprintMM(units: u.n), Gridfinity.footprintMM(units: u.m), heightMM)
        case .flat:
            return String(format: "Insert %.0f × %.0f × %.0f mm", flatWidthMM, flatDepthMM, flatThicknessMM)
        }
    }

    /// Second line: the tool itself and the clearance in use.
    var secondaryLine: String {
        String(format: "Tool %.0f × %.0f mm · clearance %.1f mm", outline.toolWidthMM, outline.toolDepthMM, clearanceMM)
    }

    /// Default file name, e.g. tool-bin-4x1x3.stl
    var suggestedFileName: String {
        switch mode {
        case .bin:
            let u = gridUnits
            return "tool-bin-\(u.n)x\(u.m)x\(heightUnits).stl"
        case .flat:
            return String(format: "tool-insert-%.0fx%.0fx%.0f.stl", flatWidthMM, flatDepthMM, flatThicknessMM)
        }
    }

    static func == (lhs: TraceSession, rhs: TraceSession) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
