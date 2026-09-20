import Foundation
import simd

/// One round access pocket. Position uses the centred bin coordinate system, in millimetres.
struct FingerNotch: Hashable, Codable {
    var x: Double
    var y: Double
    var widthMM: Double = 20
    var depthMM: Double = 8

    var center: Point2 { Point2(x, y) }
    var polygon: [Point2] {
        (0..<48).map { i in
            let angle = 2 * Double.pi * Double(i) / 48
            return center + widthMM / 2 * Point2(cos(angle), sin(angle))
        }
    }
}

// Ports of the optional finger-notch extension in Reference/binforge.py.
// Split both boundaries at their shared intersections before assembling surfaces. This keeps
// identical vertices on the top, ledge, floor and walls instead of leaving STL T-junctions.
private struct NotchEdge {
    let a: Point2
    let b: Point2
    let insideOther: Bool
}

func pointInPolygon(_ p: Point2, _ polygon: [Point2]) -> Bool {
    var inside = false
    for i in polygon.indices {
        let a = polygon[i], b = polygon[(i + 1) % polygon.count]
        if (a.y > p.y) != (b.y > p.y),
           p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
    }
    return inside
}

/// Snap the control to the tool boundary, so the round cutout stays connected to the pocket.
func nearestPocketPoint(_ p: Point2, polygon: [Point2]) -> Point2 {
    var best = polygon.first ?? .zero
    var distance = Double.infinity
    for i in polygon.indices {
        let a = polygon[i], d = polygon[(i + 1) % polygon.count] - a
        let length = simd_length_squared(d)
        guard length > 1e-12 else { continue }
        let q = a + min(1, max(0, simd_dot(p - a, d) / length)) * d
        let candidate = simd_length_squared(p - q)
        if candidate < distance { distance = candidate; best = q }
    }
    return best
}

private func splitNotchEdges(_ a: [Point2], _ b: [Point2]) -> ([NotchEdge], [NotchEdge])? {
    func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
    var sa = a.map { [(0.0, $0)] }, sb = b.map { [(0.0, $0)] }
    var intersections = 0
    for i in a.indices {
        let p = a[i], r = a[(i + 1) % a.count] - p
        for j in b.indices {
            let q = b[j], s = b[(j + 1) % b.count] - q
            let denominator = cross(r, s)
            if abs(denominator) < 1e-10 { continue }
            let t = cross(q - p, s) / denominator
            let u = cross(q - p, r) / denominator
            if t >= 0, t <= 1, u >= 0, u <= 1 {
                // Reuse the exact same intersection on both rings.
                let point = p + t * r
                sa[i].append((t, point)); sb[j].append((u, point))
                intersections += 1
            }
        }
    }
    guard intersections >= 2 else { return nil }
    func edges(_ splits: [[(Double, Point2)]], other: [Point2]) -> [NotchEdge] {
        let ring = dedupe(splits.flatMap { $0.sorted { $0.0 < $1.0 }.map { $0.1 } })
        return ring.indices.map { i in
            let p = ring[i], q = ring[(i + 1) % ring.count]
            return NotchEdge(a: p, b: q, insideOther: pointInPolygon((p + q) / 2, other))
        }
    }
    return (edges(sa, other: b), edges(sb, other: a))
}

private func notchLoops(_ edges: [NotchEdge]) -> [[Point2]]? {
    var remaining = edges
    var loops: [[Point2]] = []
    while !remaining.isEmpty {
        let first = remaining.removeFirst()
        var ring = [first.a]
        var end = first.b
        while simd_distance(end, first.a) > 1e-6 {
            ring.append(end)
            guard let index = remaining.firstIndex(where: { simd_distance($0.a, end) < 1e-6 }) else { return nil }
            end = remaining.remove(at: index).b
        }
        guard ring.count >= 3, area(ring) > 1e-6 else { return nil }
        loops.append(ring)
    }
    return loops
}

/// A validated two-depth pocket. Unsupported tangencies/holes fail closed, never export
/// a silently missing notch. The original body builder is unchanged when the notch is off.
func notchedBody(width: Double, depth: Double, z0: Double, top: Double, floorZ: Double,
                 cornerRadius: Double, pocket: [Point2], notch: FingerNotch,
                 minimumFloor: Double) -> Mesh? {
    guard notch.x.isFinite, notch.y.isFinite, notch.widthMM.isFinite, notch.depthMM.isFinite,
          notch.widthMM >= 8, notch.widthMM <= 40, notch.depthMM >= 1,
          top > minimumFloor else { return nil }
    let circle = notch.polygon
    // An inset rounded rectangle also protects the curved outer corners, not just the sides.
    let safe = roundedRect(cx: 0, cy: 0, w: width - 2 * Gridfinity.wallMin,
                           h: depth - 2 * Gridfinity.wallMin,
                           r: max(0.05, cornerRadius - Gridfinity.wallMin))
    guard circle.allSatisfy({ pointInPolygon($0, safe) }),
          let (toolEdges, notchEdges) = splitNotchEdges(ccw(pocket), circle),
          let union = notchLoops(toolEdges.filter { !$0.insideOther } + notchEdges.filter { !$0.insideOther }),
          union.count == 1 else { return nil }
    let notchFloor = max(minimumFloor, top - notch.depthMM)
    let low = min(floorZ, notchFloor), high = max(floorZ, notchFloor)
    let outer = ccw(roundedRect(cx: 0, cy: 0, w: width, h: depth, r: cornerRadius))
    var mesh = Mesh()
    // Validate ear clipping rather than accepting its legacy numerical fallback for new geometry.
    func cap(_ poly: [Point2], z: Double, up: Bool = true) -> Bool {
        let triangles = earclip(poly)
        let areas = triangles.map { area([poly[$0.0], poly[$0.1], poly[$0.2]]) }
        guard triangles.count == poly.count - 2, areas.allSatisfy({ $0 > 1e-10 }),
              abs(areas.reduce(0, +) - area(poly)) < 1e-5 else { return false }
        mesh.cap(poly, z: z, up: up)
        return true
    }
    guard cap(outer, z: z0, up: false) else { return nil }
    mesh.walls(lower: outer.map { Vertex($0.x, $0.y, z0) },
               upper: outer.map { Vertex($0.x, $0.y, top) }, outward: true)
    guard cap(bridgeHole(outer: outer, hole: union[0].reversed()), z: top) else { return nil }
    let pocketStart = mesh.vertices.count
    func walls(_ edges: [NotchEdge], bottom: Double, top: Double) {
        guard top - bottom > 1e-8 else { return }
        for e in edges {
            let a = Vertex(e.a.x, e.a.y, bottom), b = Vertex(e.b.x, e.b.y, bottom)
            let c = Vertex(e.b.x, e.b.y, top), d = Vertex(e.a.x, e.a.y, top)
            mesh.add(a, c, b); mesh.add(a, d, c)
        }
    }
    let exposed = toolEdges.filter { !$0.insideOther } + notchEdges.filter { !$0.insideOther }
    walls(exposed, bottom: high, top: top)
    if high - low < 1e-8 {
        guard cap(union[0], z: low) else { return nil }
    } else {
        let deep = floorZ < notchFloor ? toolEdges : notchEdges
        let shallow = floorZ < notchFloor ? notchEdges : toolEdges
        walls(deep, bottom: low, top: high)
        guard cap(deep.map { $0.a }, z: low),
              let ledges = notchLoops(shallow.filter { !$0.insideOther } + deep.filter { $0.insideOther }.map {
                  NotchEdge(a: $0.b, b: $0.a, insideOther: false)
              }) else { return nil }
        for ledge in ledges { guard cap(ledge, z: high) else { return nil } }
    }
    mesh.pocketRange = pocketStart..<mesh.vertices.count
    return mesh
}
