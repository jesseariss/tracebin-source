import Foundation
import simd

/// A vertex in millimetres.
typealias Vertex = SIMD3<Double>

/// binforge.Mesh: a flat triangle list, three vertices per triangle, outward-facing counter-clockwise.
struct Mesh {
    private(set) var vertices: [SIMD3<Float>] = []
    /// Vertex range of the pocket walls and floor, so the preview can colour them differently.
    var pocketRange: Range<Int>?

    var triangleCount: Int { vertices.count / 3 }

    mutating func add(_ a: Vertex, _ b: Vertex, _ c: Vertex) {
        vertices.append(SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)))
        vertices.append(SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z)))
        vertices.append(SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z)))
    }

    /// Fill a flat polygon at height z. `up` chooses which side the face points to.
    mutating func cap(_ poly: [Point2], z: Double, up: Bool) {
        for (i, j, k) in earclip(poly) {
            let a = Vertex(poly[i].x, poly[i].y, z)
            let b = Vertex(poly[j].x, poly[j].y, z)
            let c = Vertex(poly[k].x, poly[k].y, z)
            if up { add(a, b, c) } else { add(a, c, b) }
        }
    }

    /// Quads between two rings with equal point counts.
    mutating func walls(lower: [Vertex], upper: [Vertex], outward: Bool) {
        let n = lower.count
        for i in 0..<n {
            let a = lower[i]
            let b = lower[(i + 1) % n]
            let c = upper[(i + 1) % n]
            let d = upper[i]
            if outward {
                add(a, b, c); add(a, c, d)
            } else {
                add(a, c, b); add(a, d, c)
            }
        }
    }

    mutating func extend(_ other: Mesh) {
        vertices.append(contentsOf: other.vertices)
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let first = vertices.first else { return nil }
        var lo = first
        var hi = first
        for v in vertices {
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        return (lo, hi)
    }
}

// MARK: - Ear clipping (simple polygon, CCW)

/// binforge._inside: point in triangle, edges inclusive.
private func inside(_ p: Point2, _ a: Point2, _ b: Point2, _ c: Point2) -> Bool {
    func s(_ p1: Point2, _ p2: Point2, _ p3: Point2) -> Double {
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }
    let d1 = s(p, a, b)
    let d2 = s(p, b, c)
    let d3 = s(p, c, a)
    let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
    let hasPos = d1 > 0 || d2 > 0 || d3 > 0
    return !(hasNeg && hasPos)
}

/// binforge.earclip: index triangles for a simple CCW polygon. O(n^2) per ear, fine below ~2000 points.
func earclip(_ poly: [Point2]) -> [(Int, Int, Int)] {
    let n = poly.count
    guard n >= 3 else { return [] }
    var idx = Array(0..<n)
    var tris: [(Int, Int, Int)] = []
    tris.reserveCapacity(n)
    var guardCount = 0
    while idx.count > 3 && guardCount < 10 * n {
        guardCount += 1
        var found = false
        let m = idx.count
        for k in 0..<m {
            let i0 = idx[(k - 1 + m) % m]
            let i1 = idx[k]
            let i2 = idx[(k + 1) % m]
            let a = poly[i0], b = poly[i1], c = poly[i2]
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if cross <= 1e-12 { continue }   // reflex or degenerate
            var blocked = false
            for j in idx where j != i0 && j != i1 && j != i2 {
                let p = poly[j]
                // bridge_hole repeats two vertices; a twin sitting exactly on a corner is not a blocker.
                if p == a || p == b || p == c { continue }
                if inside(p, a, b, c) {
                    blocked = true
                    break
                }
            }
            if blocked { continue }
            tris.append((i0, i1, i2))
            idx.remove(at: k)
            found = true
            break
        }
        if !found {   // numerical trouble: clip the least-bad ear
            let m = idx.count
            tris.append((idx[m - 1], idx[0], idx[1]))
            idx.remove(at: 0)
        }
    }
    if idx.count == 3 {
        tris.append((idx[0], idx[1], idx[2]))
    }
    return tris
}

/// binforge.bridge_hole: merge one CW hole into a CCW outer polygon with a bridge edge.
/// Connects the hole's rightmost vertex to the nearest outer vertex on its right.
func bridgeHole(outer: [Point2], hole: [Point2]) -> [Point2] {
    var hi = 0
    for i in hole.indices where hole[i].x > hole[hi].x { hi = i }
    let hp = hole[hi]
    var oi = 0
    var bestLeft = true
    var bestDist = Double.infinity
    for i in outer.indices {
        let left = outer[i].x < hp.x
        let d = simd_length(outer[i] - hp)
        // Python's tuple order: (is_left, distance); False sorts before True.
        let better: Bool
        if left != bestLeft {
            better = !left
        } else {
            better = d < bestDist
        }
        if better {
            oi = i
            bestLeft = left
            bestDist = d
        }
    }
    var merged: [Point2] = Array(outer[...oi])
    for k in 0..<hole.count {
        merged.append(hole[(hi + k) % hole.count])
    }
    merged.append(hole[hi])
    merged.append(contentsOf: outer[oi...])
    return merged
}

// MARK: - Gridfinity parts

/// binforge.foot: one gridfinity foot, a loft of rounded rectangles through the profile, closed top and bottom.
func foot(cx: Double, cy: Double, mesh: inout Mesh) {
    var rings: [[Vertex]] = []
    for (z, inset) in Gridfinity.profile {
        let w = Gridfinity.binTop - 2 * inset
        let r = max(Gridfinity.rTop - inset, 0.5)
        let ring = ccw(roundedRect(cx: cx, cy: cy, w: w, h: w, r: r)).map { Vertex($0.x, $0.y, z) }
        rings.append(ring)
    }
    guard let bottom = rings.first, let top = rings.last else { return }
    mesh.cap(bottom.map { Point2($0.x, $0.y) }, z: bottom[0].z, up: false)
    for (lo, hi) in zip(rings, rings.dropFirst()) {
        mesh.walls(lower: lo, upper: hi, outward: true)
    }
    mesh.cap(top.map { Point2($0.x, $0.y) }, z: top[0].z, up: true)
}

/// binforge.body, with the heights as parameters so the flat insert can reuse it.
/// A solid block from z0 to top with a blind pocket whose floor is at floorZ.
/// pocket: CCW polygon in mm, bin-local coordinates with the origin at the bin centre.
func body(width: Double, depth: Double, z0: Double, top: Double, floorZ: Double,
          cornerRadius: Double, pocket: [Point2], mesh: inout Mesh) {
    let outer = ccw(roundedRect(cx: 0, cy: 0, w: width, h: depth, r: cornerRadius))
    let hole = Array(ccw(pocket).reversed())   // CW for bridging
    let topPoly = bridgeHole(outer: outer, hole: hole)
    // bottom cap (solid), outer walls
    mesh.cap(outer, z: z0, up: false)
    mesh.walls(lower: outer.map { Vertex($0.x, $0.y, z0) }, upper: outer.map { Vertex($0.x, $0.y, top) }, outward: true)
    // top annulus
    mesh.cap(topPoly, z: top, up: true)
    // pocket walls (inward-facing) and floor
    let pk = ccw(pocket)
    let pocketStart = mesh.vertices.count
    mesh.walls(lower: pk.map { Vertex($0.x, $0.y, floorZ) }, upper: pk.map { Vertex($0.x, $0.y, top) }, outward: false)
    mesh.cap(pk, z: floorZ, up: true)
    mesh.pocketRange = pocketStart..<mesh.vertices.count
}

struct BinResult {
    let mesh: Mesh
    let n: Int
    let m: Int
    let binWidthMM: Double
    let binDepthMM: Double
    let heightMM: Double
    let pocketWidthMM: Double
    let pocketDepthMM: Double
}

/// binforge.build_bin: choose the bin size from the pocket's bounding box, centre the pocket,
/// place one foot per grid cell, then the body. pocketDepthMM nil means down to the standard floor.
func buildBin(pocketMM: [Point2], heightUnits: Int = 3, pocketDepthMM: Double? = nil,
              clearanceFromWall: Double = Gridfinity.clearanceFromWall, notch: FingerNotch? = nil) -> BinResult {
    let b = Bounds2(pocketMM) ?? Bounds2([Point2(0, 0)])!
    let units = Gridfinity.units(forPocketWidth: b.width, depth: b.height)
    let n = units.n
    let m = units.m
    let c = b.center
    let pocket = pocketMM.map { $0 - c }

    var mesh = Mesh()
    for i in 0..<n {
        for j in 0..<m {
            let fx = -Double(n - 1) * Gridfinity.grid / 2 + Double(i) * Gridfinity.grid
            let fy = -Double(m - 1) * Gridfinity.grid / 2 + Double(j) * Gridfinity.grid
            foot(cx: fx, cy: fy, mesh: &mesh)
        }
    }
    let top = Double(heightUnits) * Gridfinity.unitH
    let standardFloor = Gridfinity.unitH + Gridfinity.floorAboveBase   // 8.2
    var floorZ = standardFloor
    if let depth = pocketDepthMM {
        floorZ = max(standardFloor, top - depth)
    }
    if let notch {
        if let cut = notchedBody(width: Gridfinity.footprintMM(units: n), depth: Gridfinity.footprintMM(units: m),
                                 z0: 4.95, top: top, floorZ: floorZ, cornerRadius: Gridfinity.rTop,
                                 pocket: pocket, notch: notch, minimumFloor: standardFloor) {
            let start = mesh.vertices.count
            mesh.extend(cut)
            if let range = cut.pocketRange { mesh.pocketRange = (start + range.lowerBound)..<(start + range.upperBound) }
        } else { mesh = Mesh() }
    } else {
        body(width: Gridfinity.footprintMM(units: n), depth: Gridfinity.footprintMM(units: m),
             z0: 4.95, top: top, floorZ: floorZ, cornerRadius: Gridfinity.rTop, pocket: pocket, mesh: &mesh)
    }
    return BinResult(mesh: mesh, n: n, m: m,
                     binWidthMM: Gridfinity.footprintMM(units: n), binDepthMM: Gridfinity.footprintMM(units: m),
                     heightMM: top, pocketWidthMM: b.width, pocketDepthMM: b.height)
}

/// Flat shadow-board insert: the body alone, from z = 0, at the exact size the user typed.
/// pocketDepthMM nil leaves a 1.2 mm floor.
func buildFlatInsert(pocketMM: [Point2], widthMM: Double, depthMM: Double, thicknessMM: Double,
                     pocketDepthMM: Double? = nil) -> Mesh {
    let b = Bounds2(pocketMM) ?? Bounds2([Point2(0, 0)])!
    let c = b.center
    let pocket = pocketMM.map { $0 - c }
    let minFloor = Gridfinity.floorAboveBase
    var floorZ = minFloor
    if let depth = pocketDepthMM {
        floorZ = max(minFloor, thicknessMM - depth)
    }
    floorZ = min(floorZ, max(minFloor, thicknessMM - 1.0))
    var mesh = Mesh()
    body(width: widthMM, depth: depthMM, z0: 0, top: thicknessMM, floorZ: floorZ,
         cornerRadius: min(Gridfinity.rTop, widthMM / 4, depthMM / 4), pocket: pocket, mesh: &mesh)
    return mesh
}
