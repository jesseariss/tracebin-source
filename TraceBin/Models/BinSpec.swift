import Foundation

/// Everything needed to build one bin, independent of where it came from
/// (a live trace session, a history record, or the test coupon).
struct BinSpec: Hashable {
    var outline: [Point2]
    var mode: BinMode
    var heightUnits: Int
    var pocketDepthMM: Double?
    var flatWidthMM: Double
    var flatDepthMM: Double
    var flatThicknessMM: Double
    var fileName: String
    var summaryLine: String
    var notch: FingerNotch? = nil

    var centeredPocket: [Point2] {
        let center = Bounds2(outline)?.center ?? .zero
        return outline.map { $0 - center }
    }

    var maximumNotchDepth: Double {
        max(1, Double(heightUnits) * Gridfinity.unitH - Gridfinity.unitH - Gridfinity.floorAboveBase)
    }

    /// Undo the builder's centring to align the notch with the corrected paper photo.
    var notchOnPaper: [Point2]? {
        guard mode == .bin, let notch, let bounds = Bounds2(outline) else { return nil }
        return notch.polygon.map { $0 + bounds.center }
    }

    var gridUnits: (n: Int, m: Int) {
        let b = Bounds2(outline) ?? Bounds2([Point2(0, 0)])!
        return Gridfinity.units(forPocketWidth: b.width, depth: b.height)
    }

    func buildMesh() -> Mesh {
        switch mode {
        case .bin:
            return buildBin(pocketMM: outline, heightUnits: heightUnits, pocketDepthMM: pocketDepthMM, notch: notch).mesh
        case .flat:
            return buildFlatInsert(pocketMM: outline, widthMM: flatWidthMM, depthMM: flatDepthMM,
                                   thicknessMM: flatThicknessMM, pocketDepthMM: pocketDepthMM)
        }
    }

    /// A 1 x 1 bin with a square pocket for a 20 mm block, to check fit and tune clearance.
    static func testCoupon(clearanceMM: Double) -> BinSpec {
        let half = 10.0 + clearanceMM
        let square = [Point2(-half, -half), Point2(half, -half), Point2(half, half), Point2(-half, half)]
        return BinSpec(outline: square, mode: .bin, heightUnits: 2, pocketDepthMM: nil,
                       flatWidthMM: 42, flatDepthMM: 42, flatThicknessMM: 10,
                       fileName: String(format: "test-coupon-%.1fmm.stl", clearanceMM),
                       summaryLine: String(format: "Test coupon: 20 mm square pocket at %.1f mm clearance. Bin 1 × 1 units, 41.5 × 41.5 × 14 mm.", clearanceMM))
    }
}

extension TraceSession {
    var binSpec: BinSpec {
        BinSpec(outline: outline.points, mode: mode, heightUnits: heightUnits,
                pocketDepthMM: pocketDepth.millimetres,
                flatWidthMM: flatWidthMM, flatDepthMM: flatDepthMM, flatThicknessMM: flatThicknessMM,
                fileName: suggestedFileName, summaryLine: summaryLine, notch: mode == .bin ? notch : nil)
    }
}
