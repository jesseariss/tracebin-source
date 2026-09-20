import SwiftUI

/// The flattened sheet plus where it was found, for the Paper check screen.
struct PaperDebugResult: Identifiable, Hashable {
    let id = UUID()
    let paper: Paper
    let corrected: CorrectedPaper
    let original: CGImage
    let elapsedMS: Int

    static func == (lhs: PaperDebugResult, rhs: PaperDebugResult) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Milestone 1 check: the flattened sheet, and the corners Vision picked on the original.
struct PaperDebugView: View {
    let result: PaperDebugResult

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Flattened sheet")
                    .font(.headline)
                Image(decorative: result.corrected.image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .border(Color.secondary.opacity(0.4))

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%@, %.1f × %.1f mm", result.paper.displayName, result.corrected.widthMM, result.corrected.heightMM))
                    Text("\(result.corrected.image.width) × \(result.corrected.image.height) px at 8 px/mm")
                    Text("Paper found by \(result.corrected.detector) detector")
                }
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

                Text("Where the sheet was found")
                    .font(.headline)
                    .padding(.top, 8)
                Image(decorative: result.original, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            let sx = geo.size.width / result.corrected.sourceSize.width
                            let sy = geo.size.height / result.corrected.sourceSize.height
                            let pts = result.corrected.sourceQuad.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
                            Path { path in
                                guard let first = pts.first else { return }
                                path.move(to: first)
                                for p in pts.dropFirst() { path.addLine(to: p) }
                                path.closeSubpath()
                            }
                            .stroke(Color.yellow, lineWidth: 3)
                            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                                Text(["TL", "TR", "BR", "BL"][i])
                                    .font(.caption2.bold())
                                    .padding(3)
                                    .background(.yellow, in: RoundedRectangle(cornerRadius: 4))
                                    .position(p)
                            }
                        }
                    }
                Text("If the yellow box misses a corner or grabs the wrong object, report which surface and paper size it was.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Paper check")
        .navigationBarTitleDisplayMode(.inline)
    }
}
