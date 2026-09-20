import Foundation

/// Gridfinity constants, copied from Reference/binforge.py (which took them from gridfinity-rebuilt-openscad).
enum Gridfinity {
    static let grid = 42.0
    static let binTop = 41.5
    static let unitH = 7.0
    /// Foot profile as (z, inset) pairs from the bottom. The last ring overlaps 0.25 mm into the body.
    /// The top two rings sit 0.02 mm inside the body wall so no foot shares an edge or a face with
    /// the body: slicers then see clean separate shells instead of edges owned by four triangles.
    static let profile: [(z: Double, inset: Double)] = [(0.0, 2.95), (0.8, 2.15), (2.6, 2.15), (4.95, footTopInset), (5.2, footTopInset)]
    static let footTopInset = 0.02
    static let rTop = 3.75
    static let wallMin = 0.95
    static let floorAboveBase = 1.2
    /// Distance the pocket outline keeps from the outer wall when choosing the bin size.
    static let clearanceFromWall = wallMin + 0.6

    /// binforge.build_bin's size rule: grid units needed for a pocket of this bounding size.
    static func units(forPocketWidth bw: Double, depth bh: Double) -> (n: Int, m: Int) {
        let n = max(1, Int(ceil((bw + 2 * clearanceFromWall + 0.5) / grid)))
        let m = max(1, Int(ceil((bh + 2 * clearanceFromWall + 0.5) / grid)))
        return (n, m)
    }

    static func footprintMM(units: Int) -> Double { Double(units) * grid - 0.5 }
}
