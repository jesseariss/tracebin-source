import SwiftUI

/// A dashed edge and translucent fill keep the photo visible and do not rely on colour alone.
struct NotchOverlay: View {
    let points: [CGPoint]
    var body: some View {
        let path = Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        path.fill(.blue.opacity(0.25))
            .overlay(path.stroke(.white.opacity(0.9), lineWidth: 4))
            .overlay(path.stroke(.blue, style: StrokeStyle(lineWidth: 2.5, dash: [6, 3])))
            .allowsHitTesting(false)
            .accessibilityLabel("Finger notch position and width")
    }
}

/// Saved bins retain the exact outline, so a plan view avoids guessing photo alignment.
struct BinPlanPreview: View {
    let spec: BinSpec
    var body: some View {
        GeometryReader { geometry in
            let scale = NotchViewport.fitScale(spec: spec, size: geometry.size)
            let viewport = NotchViewport()
            let project: (Point2) -> CGPoint = {
                viewport.screenPoint($0, baseScale: scale, size: geometry.size)
            }
            ZStack {
                Canvas { context, _ in
                    func path(_ points: [Point2]) -> Path {
                        Path { path in
                            guard let first = points.first else { return }
                            path.move(to: project(first))
                            for point in points.dropFirst() { path.addLine(to: project(point)) }
                            path.closeSubpath()
                        }
                    }
                    let outer = path(roundedRect(cx: 0, cy: 0,
                                                w: Gridfinity.footprintMM(units: spec.gridUnits.n),
                                                h: Gridfinity.footprintMM(units: spec.gridUnits.m), r: Gridfinity.rTop))
                    context.fill(outer, with: .color(.orange.opacity(0.16)))
                    context.stroke(outer, with: .color(.secondary), lineWidth: 1)
                    let pocket = path(spec.centeredPocket)
                    context.fill(pocket, with: .color(.secondary.opacity(0.35)))
                    context.stroke(pocket, with: .color(.primary.opacity(0.6)), lineWidth: 1)
                }
                if let notch = spec.notch { NotchOverlay(points: notch.polygon.map(project)) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spec.notch == nil ? "Top-down bin and tool pocket" : "Top-down bin with finger notch shown by a blue dashed circle")
    }
}
