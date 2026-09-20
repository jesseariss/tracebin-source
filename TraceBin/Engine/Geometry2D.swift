import Foundation
import simd

/// A point in millimetres. Ports of the 2D helpers in Reference/binforge.py, same names in camelCase.
typealias Point2 = SIMD2<Double>

/// binforge.rounded_rect: counter-clockwise rounded rectangle centred at (cx, cy).
func roundedRect(cx: Double, cy: Double, w: Double, h: Double, r: Double, seg: Int = 6) -> [Point2] {
    let r = max(0.05, min(r, w / 2, h / 2))
    var pts: [Point2] = []
    let corners: [(Double, Double, Double)] = [
        (cx + w / 2 - r, cy + h / 2 - r, 0),
        (cx - w / 2 + r, cy + h / 2 - r, 90),
        (cx - w / 2 + r, cy - h / 2 + r, 180),
        (cx + w / 2 - r, cy - h / 2 + r, 270),
    ]
    for (x, y, a0) in corners {
        for i in 0...seg {
            let a = (a0 + 90 * Double(i) / Double(seg)) * .pi / 180
            pts.append(Point2(x + r * cos(a), y + r * sin(a)))
        }
    }
    return dedupe(pts)
}

/// binforge.dedupe: drop consecutive duplicates and a closing point equal to the first.
func dedupe(_ pts: [Point2], eps: Double = 1e-6) -> [Point2] {
    var out: [Point2] = []
    for p in pts {
        if let last = out.last, abs(last.x - p.x) <= eps, abs(last.y - p.y) <= eps { continue }
        out.append(p)
    }
    if out.count > 1, let f = out.first, let l = out.last, abs(f.x - l.x) < eps, abs(f.y - l.y) < eps {
        out.removeLast()
    }
    return out
}

/// binforge.area: signed area, positive when counter-clockwise.
func area(_ poly: [Point2]) -> Double {
    guard poly.count >= 3 else { return 0 }
    var a = 0.0
    for i in 0..<poly.count {
        let p = poly[i]
        let q = poly[(i + 1) % poly.count]
        a += p.x * q.y - q.x * p.y
    }
    return a / 2
}

/// binforge.ccw: make the polygon counter-clockwise.
func ccw(_ poly: [Point2]) -> [Point2] {
    area(poly) > 0 ? poly : poly.reversed()
}

/// binforge.douglas_peucker on an open chain.
func douglasPeucker(_ pts: [Point2], _ eps: Double) -> [Point2] {
    if pts.count < 3 { return pts }
    func dist(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
        let d = b - a
        if d.x == 0 && d.y == 0 { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, d) / simd_dot(d, d)))
        return simd_length(p - (a + t * d))
    }
    var dmax = 0.0
    var idx = 0
    let first = pts[0]
    let last = pts[pts.count - 1]
    for i in 1..<(pts.count - 1) {
        let d = dist(pts[i], first, last)
        if d > dmax {
            dmax = d
            idx = i
        }
    }
    if dmax > eps {
        let left = douglasPeucker(Array(pts[...idx]), eps)
        let right = douglasPeucker(Array(pts[idx...]), eps)
        return Array(left.dropLast()) + right
    }
    return [first, last]
}

/// binforge.simplify_closed: split the ring at the point farthest from pts[0] so both halves are open chains.
func simplifyClosed(_ poly: [Point2], _ eps: Double) -> [Point2] {
    guard poly.count > 3 else { return poly }
    let origin = poly[0]
    var far = 0
    var farDist = -1.0
    for i in poly.indices {
        let d = simd_length(poly[i] - origin)
        if d > farDist {
            farDist = d
            far = i
        }
    }
    let a = douglasPeucker(Array(poly[...far]), eps)
    let b = douglasPeucker(Array(poly[far...]) + [poly[0]], eps)
    return dedupe(Array(a.dropLast()) + Array(b.dropLast()))
}

/// Moving average around a closed ring: each point becomes the mean of its neighbours within
/// `radius` steps on either side. Knocks down pixel and mask noise; rounds sharp corners slightly.
func smoothClosed(_ pts: [Point2], radius: Int) -> [Point2] {
    let n = pts.count
    guard radius > 0, n > 2 * radius + 1 else { return pts }
    var out: [Point2] = []
    out.reserveCapacity(n)
    let count = Double(2 * radius + 1)
    for i in 0..<n {
        var acc = Point2(0, 0)
        for d in -radius...radius {
            acc += pts[((i + d) % n + n) % n]
        }
        out.append(acc / count)
    }
    return out
}

/// Collapses long, nearly straight stretches of a closed polygon to single segments.
/// A stretch qualifies when its chord is at least `minLength` and every point in between lies
/// within `tolerance` of that chord. Real curves keep their points: a 10 mm chord on a 25 mm
/// radius arc already bows more than 0.5 mm.
func straightenLongRuns(_ poly: [Point2], tolerance: Double, minLength: Double) -> [Point2] {
    let n = poly.count
    guard n > 4 else { return poly }
    func deviation(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
        let d = b - a
        let len2 = simd_dot(d, d)
        if len2 < 1e-12 { return simd_length(p - a) }
        let t = simd_dot(p - a, d) / len2
        return simd_length(p - (a + t * d))
    }
    // Start from a point that is a genuine corner so a straight run is not split by the seam:
    // the point farthest from the centroid is never in the middle of a straight stretch.
    let c = poly.reduce(Point2(0, 0), +) / Double(n)
    var start = 0
    var far = -1.0
    for i in 0..<n {
        let d = simd_length(poly[i] - c)
        if d > far { far = d; start = i }
    }
    let ring = Array(poly[start...] + poly[..<start])
    var out: [Point2] = []
    var i = 0
    while i < n {
        var j = i + 1
        var best = i + 1
        // Extend the run while everything between i and j stays close to the chord i..j.
        while j < n {
            var ok = true
            for k in (i + 1)..<j where deviation(ring[k], ring[i], ring[j]) > tolerance {
                ok = false
                break
            }
            if !ok { break }
            best = j
            j += 1
        }
        if best > i + 1, simd_length(ring[best] - ring[i]) >= minLength {
            // The chord sits inside the noise on a convex edge. Shift it out by the mean signed
            // offset of the points it replaces, so the straightened edge keeps the true position.
            // The polygon is counter-clockwise, so "outside" is to the right of i -> best.
            let a = ring[i]
            let b = ring[best]
            let d = b - a
            let len = simd_length(d)
            let right = Point2(d.y / len, -d.x / len)
            var mean = 0.0
            for k in (i + 1)..<best {
                mean += simd_dot(ring[k] - a, right)
            }
            mean /= Double(best - i - 1)
            let shift = right * mean
            out.append(a + shift)
            out.append(b + shift)
            i = best + 1
        } else {
            out.append(ring[i])
            i += 1
        }
    }
    return dedupe(out)
}

/// Axis-aligned bounds of a polygon.
struct Bounds2 {
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var center: Point2 { Point2((minX + maxX) / 2, (minY + maxY) / 2) }

    init?(_ pts: [Point2]) {
        guard let f = pts.first else { return nil }
        minX = f.x; maxX = f.x; minY = f.y; maxY = f.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
    }
}
