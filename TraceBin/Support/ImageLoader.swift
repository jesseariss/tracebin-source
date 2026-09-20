import CoreGraphics
import Foundation
import ImageIO

/// Decodes a JPEG/HEIC into a CGImage that is upright and at most `maxPixels` in size.
/// Using ImageIO's thumbnail path downsamples while decoding, so a 48 MP photo never
/// has to be fully expanded in memory before Vision sees it.
enum ImageLoader {
    static let defaultMaxPixels = 12_000_000

    static func load(data: Data, maxPixels: Int = defaultMaxPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Double ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Double ?? 0
        let total = w * h
        var maxDimension = max(w, h)
        if total > Double(maxPixels), total > 0 {
            maxDimension *= (Double(maxPixels) / total).squareRoot()
        }
        if maxDimension < 1 { maxDimension = 8000 }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension.rounded(.down)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
