import UIKit

enum Thumbnail {
    /// JPEG of the corrected sheet with the outline drawn on it, `width` pixels wide.
    static func make(corrected: CorrectedPaper, outline: [Point2], width: CGFloat = 600) -> Data {
        let source = UIImage(cgImage: corrected.image)
        let scale = width / source.size.width
        let size = CGSize(width: width, height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            source.draw(in: CGRect(origin: .zero, size: size))
            guard let first = outline.first else { return }
            let path = UIBezierPath()
            func point(_ p: Point2) -> CGPoint {
                CGPoint(x: p.x / corrected.widthMM * size.width, y: (1 - p.y / corrected.heightMM) * size.height)
            }
            path.move(to: point(first))
            for p in outline.dropFirst() { path.addLine(to: point(p)) }
            path.close()
            path.lineWidth = 3
            path.lineJoinStyle = .round
            UIColor.black.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 5
            path.stroke()
            UIColor.systemGreen.setStroke()
            path.lineWidth = 3
            path.stroke()
            _ = ctx
        }
        return image.jpegData(compressionQuality: 0.75) ?? Data()
    }
}
