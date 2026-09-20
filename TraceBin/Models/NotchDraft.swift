import Foundation
import SwiftUI
import simd

/// Owned by the screen, not a recycled Form section. Freeze inputs for this presentation.
struct NotchEditorRequest: Identifiable {
    let id = UUID()
    let spec: BinSpec
}

/// Value-type draft: Save is the only point at which the parent receives the edited notch.
struct NotchDraft {
    let base: BinSpec
    var notch: FingerNotch

    init(spec: BinSpec) {
        base = spec
        let pocket = spec.centeredPocket
        let w = Gridfinity.footprintMM(units: spec.gridUnits.n)
        let h = Gridfinity.footprintMM(units: spec.gridUnits.m)
        func room(_ p: Point2) -> Double { min(w / 2 - abs(p.x), h / 2 - abs(p.y)) }
        let candidates = pocket.indices.map { (pocket[$0] + pocket[($0 + 1) % pocket.count]) / 2 }
        let p = candidates.max { room($0) < room($1) } ?? .zero
        notch = spec.notch ?? FingerNotch(x: p.x, y: p.y,
                                          widthMM: max(8, min(20, (room(p) - Gridfinity.wallMin) * 1.8)),
                                          depthMM: min(8, spec.maximumNotchDepth))
        notch.depthMM = max(1, min(notch.depthMM, spec.maximumNotchDepth))
        notch.widthMM = max(8, min(notch.widthMM, 40))
    }

    var spec: BinSpec { var result = base; result.notch = notch; return result }

    mutating func move(to point: Point2) {
        let target = nearestPocketPoint(point, polygon: base.centeredPocket)
        notch.x = target.x; notch.y = target.y
    }

    /// Follow arc length, not X/Y projections that get stuck on straight edges or corners.
    mutating func moveAlongEdge(by distance: Double) {
        let ring = base.centeredPocket
        guard ring.count > 1 else { return }
        var cumulative = 0.0, closestDistance = Double.infinity, position = 0.0
        var lengths: [Double] = []
        for i in ring.indices {
            let a = ring[i], d = ring[(i + 1) % ring.count] - a
            let length = simd_length(d)
            lengths.append(length)
            if length > 1e-9 {
                let t = max(0, min(1, simd_dot(notch.center - a, d) / (length * length)))
                let delta = simd_distance(notch.center, a + t * d)
                if delta < closestDistance { closestDistance = delta; position = cumulative + t * length }
            }
            cumulative += length
        }
        guard cumulative > 1e-9 else { return }
        var target = (position + distance).truncatingRemainder(dividingBy: cumulative)
        if target < 0 { target += cumulative }
        for i in ring.indices {
            if lengths[i] > 1e-9 && target <= lengths[i] {
                let p = ring[i] + (target / lengths[i]) * (ring[(i + 1) % ring.count] - ring[i])
                notch.x = p.x; notch.y = p.y
                return
            }
            target -= lengths[i]
        }
    }
}

/// Coordinate mapping kept separate from gestures so zoom/pan placement can be unit tested.
struct NotchViewport {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    /// Show the notch clearly on entry, with context around it and room for its full circle.
    static func focused(on notch: FingerNotch, spec: BinSpec, size: CGSize) -> NotchViewport {
        let base = fitScale(spec: spec, size: size)
        let diameter = min(140, min(size.width, size.height) * 0.55)
        let zoom = min(3, max(1, diameter / (notch.widthMM * base)))
        return NotchViewport(scale: zoom,
                             offset: CGSize(width: -notch.x * base * zoom,
                                            height: notch.y * base * zoom))
    }

    static func fitScale(spec: BinSpec, size: CGSize) -> CGFloat {
        max(0.01, min((size.width - 64) / Gridfinity.footprintMM(units: spec.gridUnits.n),
                      (size.height - 64) / Gridfinity.footprintMM(units: spec.gridUnits.m)))
    }

    func screenPoint(_ p: Point2, baseScale: CGFloat, size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + p.x * baseScale * scale,
                y: size.height / 2 + offset.height - p.y * baseScale * scale)
    }

    func modelPoint(_ p: CGPoint, baseScale: CGFloat, size: CGSize) -> Point2 {
        Point2((p.x - size.width / 2 - offset.width) / (baseScale * scale),
               -(p.y - size.height / 2 - offset.height) / (baseScale * scale))
    }

    func magnified(by factor: CGFloat, anchor: UnitPoint, size: CGSize) -> NotchViewport {
        let next = min(6, max(1, scale * factor))
        let ratio = next / scale
        let x = (anchor.x - 0.5) * size.width, y = (anchor.y - 0.5) * size.height
        return NotchViewport(scale: next, offset: CGSize(width: x - (x - offset.width) * ratio,
                                                        height: y - (y - offset.height) * ratio))
    }

    mutating func zoom(by factor: CGFloat) {
        let next = min(6, max(1, scale * factor))
        offset = CGSize(width: offset.width * next / scale, height: offset.height * next / scale)
        scale = next
    }
}
