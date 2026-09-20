import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import simd

/// The flattened sheet of paper, at exactly 8 px per millimetre.
struct CorrectedPaper {
    /// Canonical image of the sheet. 1 px = 0.125 mm.
    let image: CGImage
    /// Real-world size of the canonical image in millimetres.
    let widthMM: Double
    let heightMM: Double
    /// Detected corners in the source photo, in pixels with the origin at the top-left
    /// (drawing coordinates). Order: top-left, top-right, bottom-right, bottom-left.
    let sourceQuad: [CGPoint]
    let sourceSize: CGSize
    /// Which detector proposed the winning quad: "document" or "rectangle". For testing.
    let detector: String
}

/// The tool separated from the paper: a white-on-black image the size of the corrected sheet.
struct ToolMask {
    let image: CIImage
    /// "subject" (Vision foreground lifting) or "threshold" (Otsu on inverted luminance).
    let path: String
    /// Fraction of the sheet covered by the mask.
    let coverage: Double
    let corrected: CorrectedPaper
}

/// The pocket outline in millimetres: counter-clockwise, origin at the sheet's bottom-left, y up.
struct Outline {
    let points: [Point2]
    let bounds: Bounds2
    let clearanceMM: Double
    let maskPath: String

    /// Size of the pocket, which is the tool plus clearance all round.
    var pocketWidthMM: Double { bounds.width }
    var pocketDepthMM: Double { bounds.height }
    /// Approximate size of the tool itself.
    var toolWidthMM: Double { max(0, bounds.width - 2 * clearanceMM) }
    var toolDepthMM: Double { max(0, bounds.height - 2 * clearanceMM) }
}

/// Pure processing, no UI. Mirrors the pipeline in Reference/binforge.py.
struct TraceEngine {
    /// Fixed working resolution after perspective correction.
    static let pxPerMM: Double = 8.0
    static let mmPerPx: Double = 1.0 / pxPerMM

    private let context = CIContext(options: [.cacheIntermediates: false])

    init() {}

    // MARK: - Step 1: paper quad and perspective correction

    /// Finds the sheet of paper, flattens it, and resamples it to 8 px/mm.
    /// The output keeps the sheet's orientation as photographed: a portrait sheet
    /// gives a portrait image, so the tool looks the way the user saw it.
    func correctPaper(image: CGImage, paper: Paper) throws -> CorrectedPaper {
        let (roughQuad, detector) = try detectPaperQuad(in: image)   // CI coordinates: origin bottom-left, pixels
        let width = Double(image.width)
        let height = Double(image.height)
        // Detectors land a few pixels inside the real edge, which scales every tool up. Snap each
        // edge to the brightness step between paper and background.
        let quad = refineEdges(of: roughQuad, in: image)

        // Decide whether the sheet lies landscape or portrait in the photo by comparing
        // the average lengths of the horizontal and vertical edges of the quad.
        let topLen = (quad.topLeft.distance(to: quad.topRight) + quad.bottomLeft.distance(to: quad.bottomRight)) / 2
        let sideLen = (quad.topLeft.distance(to: quad.bottomLeft) + quad.topRight.distance(to: quad.bottomRight)) / 2
        guard topLen > 1, sideLen > 1 else { throw TraceError.paperNotFound }
        let ratio = topLen / sideLen
        guard ratio > 0.4, ratio < 2.5 else { throw TraceError.paperNotFound }
        let landscape = topLen >= sideLen
        let outWidthMM = landscape ? paper.longMM : paper.shortMM
        let outHeightMM = landscape ? paper.shortMM : paper.longMM

        // Reject quads that are far too small to be the sheet (a sticky note, a phone).
        let quadArea = abs(polygonArea([quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft]))
        guard quadArea > 0.04 * width * height else { throw TraceError.paperNotFound }

        let ci = CIImage(cgImage: image)
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ci
        filter.topLeft = quad.topLeft
        filter.topRight = quad.topRight
        filter.bottomRight = quad.bottomRight
        filter.bottomLeft = quad.bottomLeft
        filter.crop = true
        guard var flat = filter.outputImage, flat.extent.width > 1, flat.extent.height > 1, !flat.extent.isInfinite else {
            throw TraceError.internalFailure("perspective correction produced no image")
        }
        flat = flat.transformed(by: CGAffineTransform(translationX: -flat.extent.origin.x, y: -flat.extent.origin.y))

        let targetW = (outWidthMM * Self.pxPerMM).rounded()
        let targetH = (outHeightMM * Self.pxPerMM).rounded()
        let sx = targetW / flat.extent.width
        let sy = targetH / flat.extent.height
        flat = flat.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let targetRect = CGRect(x: 0, y: 0, width: targetW, height: targetH)
        guard let out = context.createCGImage(flat, from: targetRect) else {
            throw TraceError.internalFailure("could not render corrected image")
        }

        // Flip y for drawing on top of the source photo (UIKit/SwiftUI origin is top-left).
        let drawQuad = [quad.topLeft, quad.topRight, quad.bottomRight, quad.bottomLeft].map {
            CGPoint(x: $0.x, y: height - $0.y)
        }
        return CorrectedPaper(image: out,
                              widthMM: outWidthMM,
                              heightMM: outHeightMM,
                              sourceQuad: drawQuad,
                              sourceSize: CGSize(width: width, height: height),
                              detector: detector)
    }

    // MARK: - Step 2: tool mask

    /// Separates the tool from the paper. Tries subject lifting, then the brightness threshold,
    /// and keeps the first candidate that looks like a tool: not a speck, not the whole sheet.
    func makeMask(from corrected: CorrectedPaper, prefer: String? = nil) throws -> ToolMask {
        let sheet = CIImage(cgImage: corrected.image)
        let extent = sheet.extent
        var lastError: TraceError = .toolNotSeparable

        struct Candidate {
            let path: String
            let image: CIImage
            let coverage: Double
            let spanW: Double
            let spanH: Double
        }
        var candidates: [Candidate] = []

        for path in ["subject", "threshold"] {
            let raw: CIImage? = path == "subject" ? subjectMask(for: corrected.image) : thresholdMask(for: sheet)
            guard let raw, let rawCoverage = coverage(of: raw, in: extent) else {
                TraceDebug.log("mask \(path): no result")
                continue
            }
            TraceDebug.log(String(format: "mask %@: raw coverage %.3f", path, rawCoverage))
            if rawCoverage < 0.005 { lastError = .toolNotSeparable; continue }
            if rawCoverage > 0.60 { lastError = .toolTooLarge; continue }

            // Blank a 3 mm border so a sliver of desk along the sheet edge never becomes "the tool".
            let inset = 3.0 * Self.pxPerMM
            let black = CIImage(color: .black).cropped(to: extent)
            let cleaned = raw.cropped(to: extent.insetBy(dx: inset, dy: inset)).composited(over: black)

            // Keep only the largest object and redraw it as a solid shape, so holes and stray
            // shadow blobs disappear. A light close first seals pixel-scale slits.
            let closed = cleaned
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: Float(6)])
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: Float(6)])
                .cropped(to: extent)
            guard let closedCG = context.createCGImage(closed, from: extent) else {
                throw TraceError.internalFailure("could not render mask")
            }
            guard let largest = try? largestContour(in: closedCG) else {
                TraceDebug.log("mask \(path): no contour")
                lastError = .toolNotSeparable
                continue
            }
            let xs = largest.map { Double($0.x) }
            let ys = largest.map { Double($0.y) }
            let spanW = ((xs.max() ?? 0) - (xs.min() ?? 0)) * corrected.widthMM
            let spanH = ((ys.max() ?? 0) - (ys.min() ?? 0)) * corrected.heightMM
            TraceDebug.log(String(format: "mask %@: largest object %.1f x %.1f mm, %d pts", path, spanW, spanH, largest.count))
            if spanW > corrected.widthMM - 8 || spanH > corrected.heightMM - 8 {
                lastError = .toolTooLarge
                continue
            }
            if spanW < 3 || spanH < 3 {
                lastError = .toolNotSeparable
                continue
            }
            guard let solid = rasterize(normalizedPolygon: largest, width: closedCG.width, height: closedCG.height) else {
                throw TraceError.internalFailure("could not redraw mask")
            }
            let solidCI = CIImage(cgImage: solid)
            let finalCoverage = coverage(of: solidCI, in: extent) ?? rawCoverage
            if finalCoverage < 0.003 {
                lastError = .toolNotSeparable
                continue
            }
            candidates.append(Candidate(path: path, image: solidCI, coverage: finalCoverage, spanW: spanW, spanH: spanH))
        }

        guard !candidates.isEmpty else { throw lastError }

        // The threshold mask is pixel-accurate but reads chrome highlights as paper, so shiny tools
        // get bites taken out of them; subject lifting sees the whole tool but its edges are soft.
        // When both found the same object, keep the threshold edge and fill its bites with the
        // subject mask shrunk by 0.5 mm, so the subject only ever adds interior, never edge.
        var chosen = candidates[0]
        if let subject = candidates.first(where: { $0.path == "subject" }),
           let threshold = candidates.first(where: { $0.path == "threshold" }) {
            let agree = abs(subject.spanW - threshold.spanW) <= 2.5
                && abs(subject.spanH - threshold.spanH) <= 2.5
                && abs(subject.coverage - threshold.coverage) <= 0.12 * max(subject.coverage, 0.01)
            if agree {
                let shrunkSubject = subject.image
                    .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: Float(0.5 * Self.pxPerMM)])
                    .cropped(to: extent)
                let union = threshold.image.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: shrunkSubject])
                    .cropped(to: extent)
                chosen = Candidate(path: "threshold", image: union, coverage: coverage(of: union, in: extent) ?? threshold.coverage,
                                   spanW: threshold.spanW, spanH: threshold.spanH)
            } else {
                chosen = subject
            }
            TraceDebug.log("mask: subject and threshold \(agree ? "agree, using threshold filled by subject" : "differ, using subject")")
        }
        if let prefer, let forced = candidates.first(where: { $0.path == prefer }) {
            chosen = forced
        }

        // Close gaps narrower than ~6 mm: a wrench mouth or caliper jaws would otherwise print as
        // a thin, useless tongue of plastic inside the pocket. Anything a finger fits in stays.
        let gapRadius = Float(3.0 * Self.pxPerMM)
        let sealed = chosen.image
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: gapRadius])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: gapRadius])
            .cropped(to: extent)
        guard let sealedCG = context.createCGImage(sealed, from: extent),
              let contour = try? largestContour(in: sealedCG),
              let solid = rasterize(normalizedPolygon: contour, width: sealedCG.width, height: sealedCG.height) else {
            throw TraceError.internalFailure("could not seal mask")
        }
        let final = CIImage(cgImage: solid)
        let finalCoverage = coverage(of: final, in: extent) ?? chosen.coverage
        TraceDebug.log(String(format: "mask %@: chosen, coverage %.3f", chosen.path, finalCoverage))
        return ToolMask(image: final, path: chosen.path, coverage: finalCoverage, corrected: corrected)
    }

    #if DEBUG
    /// Screenshot helper: a mask built from a known outline (mm, y up) instead of the Vision models,
    /// because the simulator's subject-lifting model cannot handle real photos.
    func maskFromOutline(_ pointsMM: [Point2], corrected: CorrectedPaper) -> ToolMask? {
        let w = corrected.image.width
        let h = corrected.image.height
        let normalized = pointsMM.map { SIMD2<Float>(Float($0.x / corrected.widthMM), Float($0.y / corrected.heightMM)) }
        guard normalized.count >= 3, let solid = rasterize(normalizedPolygon: normalized, width: w, height: h) else { return nil }
        let ci = CIImage(cgImage: solid)
        let extent = CGRect(x: 0, y: 0, width: w, height: h)
        return ToolMask(image: ci, path: "sample", coverage: coverage(of: ci, in: extent) ?? 0, corrected: corrected)
    }
    #endif

    /// Loads the Vision models once so the first real trace does not pay for it.
    func warmUp() {
        let size = 64
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 24, height: 24))
        guard let img = ctx.makeImage() else { return }
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([VNDetectDocumentSegmentationRequest(), VNDetectRectanglesRequest(),
                              VNGenerateForegroundInstanceMaskRequest(), VNDetectContoursRequest()])
    }

    /// Largest top-level contour in a white-on-black image, as Vision normalized points (origin bottom-left).
    private func largestContour(in maskCG: CGImage) throws -> [SIMD2<Float>] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = false
        request.maximumImageDimension = max(maskCG.width, maskCG.height)
        let handler = VNImageRequestHandler(cgImage: maskCG, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw TraceError.toolNotSeparable
        }
        guard let contours = request.results?.first, contours.topLevelContourCount > 0 else {
            throw TraceError.toolNotSeparable
        }
        var best: [SIMD2<Float>] = []
        var bestArea = 0.0
        for contour in contours.topLevelContours {
            let pts = contour.normalizedPoints
            let a = abs(area(pts.map { Point2(Double($0.x), Double($0.y)) }))
            if a > bestArea {
                bestArea = a
                best = pts
            }
        }
        guard best.count >= 3 else { throw TraceError.toolNotSeparable }
        return best
    }

    /// Draws a filled white polygon on black. Core Graphics and Vision both use a bottom-left origin.
    private func rasterize(normalizedPolygon: [SIMD2<Float>], width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return nil
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: CGFloat(normalizedPolygon[0].x) * w, y: CGFloat(normalizedPolygon[0].y) * h))
        for p in normalizedPolygon.dropFirst() {
            ctx.addLine(to: CGPoint(x: CGFloat(p.x) * w, y: CGFloat(p.y) * h))
        }
        ctx.closePath()
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// Subject lifting. Vision may return several instances (the tool, the sheet itself, a shadow).
    /// Each is scored on its own and the largest one that could be a tool wins.
    private func subjectMask(for image: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
            let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            var best: (coverage: Double, mask: CIImage)?
            for instance in result.allInstances {
                let buffer = try result.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
                let mask = CIImage(cvPixelBuffer: buffer)
                guard let cov = coverage(of: mask, in: extent) else { continue }
                TraceDebug.log(String(format: "mask subject: instance %d coverage %.3f", instance, cov))
                guard cov >= 0.003, cov <= 0.60 else { continue }
                if best == nil || cov > best!.coverage {
                    best = (cov, mask)
                }
            }
            return best?.mask
        } catch {
            return nil
        }
    }

    /// Dark tool on white paper, robust to shadows across the sheet: compare each pixel with the
    /// local paper brightness (a wide blur of the sheet) instead of one global threshold.
    /// Anything darker than 62% of its surroundings is tool. Then open by 2 px to drop speckle.
    private func thresholdMask(for sheet: CIImage) -> CIImage? {
        let extent = sheet.extent
        let gray = sheet.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        // Local background: shrink 8x, clamp edges, blur ~40 mm, scale back up.
        let small = gray.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
        let blurred = small.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 40])
            .cropped(to: small.extent)
        let background = blurred.transformed(by: CGAffineTransform(scaleX: 8, y: 8)).clampedToExtent().cropped(to: extent)
        // ratio = gray / background   (divide blend: backdrop / source)
        let ratio = background.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: gray])
        let paper = ratio.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.62])
        let tool = paper.applyingFilter("CIColorInvert")
        let opened = tool
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 2])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2])
        return opened.cropped(to: extent)
    }

    /// Fraction of the extent that is white in the mask. Rendered in a linear colour space so the
    /// average is a true area fraction (an sRGB render would gamma-encode it and inflate small values).
    private func coverage(of mask: CIImage, in extent: CGRect) -> Double? {
        let avg = CIFilter.areaAverage()
        avg.inputImage = mask.cropped(to: extent)
        avg.extent = extent
        guard let out = avg.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        context.render(out, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linear)
        return Double(max(0, min(1, px[0])))
    }

    // MARK: - Step 3: clearance, contour, simplify, millimetres

    /// binforge.outline_from_mask: dilate by the clearance, trace the largest outer contour,
    /// convert to millimetres (y up), simplify to 0.25 mm, return counter-clockwise.
    func outline(from mask: ToolMask, clearance clearanceMM: Double, simplifyMM: Double = 0.25) throws -> Outline {
        let started = Date()
        defer { TraceDebug.log(String(format: "outline: clearance %.1f mm in %.0f ms", clearanceMM, Date().timeIntervalSince(started) * 1000)) }
        let radius = max(0.0, clearanceMM * Self.pxPerMM)
        let extent = mask.image.extent
        var dilated = mask.image
        if radius > 0 {
            dilated = mask.image
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: Float(radius)])
                .cropped(to: extent)
        }
        guard let maskCG = context.createCGImage(dilated, from: extent) else {
            throw TraceError.internalFailure("could not render mask")
        }

        let widthMM = mask.corrected.widthMM
        let heightMM = mask.corrected.heightMM
        // Vision's normalized points already have their origin at the bottom-left, which is the
        // y-up millimetre frame binforge.py produces by flipping image rows.
        let best = try largestContour(in: maskCG).map { Point2(Double($0.x) * widthMM, Double($0.y) * heightMM) }

        // Smooth over ~2 mm of contour before simplifying: subject masks are upscaled from a low
        // resolution and give gently wavy straight edges otherwise.
        let dense = dedupe(best)
        var perimeter = 0.0
        for i in 0..<dense.count {
            perimeter += simd_length(dense[(i + 1) % dense.count] - dense[i])
        }
        let spacing = max(0.01, perimeter / Double(max(1, dense.count)))
        let smoothRadius = min(24, Int((1.0 / spacing).rounded()))
        let simplified = simplifyClosed(smoothClosed(dense, radius: smoothRadius), simplifyMM)
        // A straight tool edge should be a straight pocket wall, not a gentle wave.
        let poly = ccw(straightenLongRuns(simplified, tolerance: 0.4, minLength: 12))
        guard poly.count >= 3, let bounds = Bounds2(poly) else { throw TraceError.toolNotSeparable }
        // A pocket that nearly spans the sheet cannot be walled in.
        if bounds.width > widthMM - 8 || bounds.height > heightMM - 8 {
            throw TraceError.toolTooLarge
        }
        return Outline(points: poly, bounds: bounds, clearanceMM: clearanceMM, maskPath: mask.path)
    }

    /// The whole pipeline in one call: paper, mask, outline.
    func trace(image: CGImage, paper: Paper, clearance: Double) throws -> Outline {
        let corrected = try correctPaper(image: image, paper: paper)
        let mask = try makeMask(from: corrected)
        return try outline(from: mask, clearance: clearance)
    }

    // MARK: - Edge refinement

    /// Slides each edge of the quad outward or inward to where the paper actually ends.
    /// For each edge, 15 brightness profiles are taken across it; the paper/background step in
    /// each gives an offset, and the median offset moves the edge. Edges with no clear step
    /// (sheet on a white desk) are left alone. Corners are rebuilt as line intersections.
    func refineEdges(of quad: Quad, in image: CGImage) -> Quad {
        let w = image.width
        let h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = ctx.data else { return quad }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = base.bindMemory(to: UInt8.self, capacity: w * h)
        // The quad is in Core Image coordinates (origin bottom-left) but the bitmap's first row is
        // the top of the image, so flip y when reading pixels.
        func lum(_ x: Double, _ y: Double) -> Double {
            let xi = max(0, min(w - 1, Int(x)))
            let yi = max(0, min(h - 1, h - 1 - Int(y)))
            return Double(px[yi * w + xi])
        }

        let pts = quad.points
        let cx = pts.map(\.x).reduce(0, +) / 4
        let cy = pts.map(\.y).reduce(0, +) / 4
        var lines: [(a: CGPoint, b: CGPoint)] = []
        var report: [String] = []
        for i in 0..<4 {
            let a = pts[i]
            let b = pts[(i + 1) % 4]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            var nx = Double(mid.x - cx)
            var ny = Double(mid.y - cy)
            let nlen = (nx * nx + ny * ny).squareRoot()
            let edgeLen = a.distance(to: b)
            guard nlen > 1, edgeLen > 50 else { lines.append((a, b)); continue }
            nx /= nlen
            ny /= nlen
            let reach = min(120.0, max(20.0, 0.04 * edgeLen))   // how far to look either side, px
            var offsets: [Double] = []
            for k in 0..<15 {
                let t = 0.12 + 0.76 * Double(k) / 14
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                var prof: [Double] = []
                var d = -reach
                while d <= reach {
                    prof.append(lum(Double(p.x) + nx * d, Double(p.y) + ny * d))
                    d += 1
                }
                let n = prof.count
                let innerCount = max(3, n / 4)
                let inner = prof[0..<innerCount].reduce(0, +) / Double(innerCount)
                let outer = prof[(n - innerCount)...].reduce(0, +) / Double(innerCount)
                guard inner - outer > 25 else { continue }   // no paper/background step here
                let thr = (inner + outer) / 2
                var j = 0
                while j < n - 1 && prof[j + 1] > thr { j += 1 }
                offsets.append(Double(j) - reach)
            }
            guard offsets.count >= 6 else {
                report.append("\(["top", "right", "bottom", "left"][i]): no step")
                lines.append((a, b))
                continue
            }
            offsets.sort()
            let shift = offsets[offsets.count / 2]
            report.append(String(format: "%@ %+.0f px", ["top", "right", "bottom", "left"][i], shift))
            lines.append((CGPoint(x: a.x + nx * shift, y: a.y + ny * shift), CGPoint(x: b.x + nx * shift, y: b.y + ny * shift)))
        }
        TraceDebug.log("paper edges refined: " + report.joined(separator: ", "))

        func intersect(_ l1: (a: CGPoint, b: CGPoint), _ l2: (a: CGPoint, b: CGPoint)) -> CGPoint? {
            let x1 = l1.a.x, y1 = l1.a.y, x2 = l1.b.x, y2 = l1.b.y
            let x3 = l2.a.x, y3 = l2.a.y, x4 = l2.b.x, y4 = l2.b.y
            let den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
            guard abs(den) > 1e-6 else { return nil }
            let t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / den
            return CGPoint(x: x1 + t * (x2 - x1), y: y1 + t * (y2 - y1))
        }
        // corner i is where edge (i-1) meets edge i: TL = left∩top, TR = top∩right, BR = right∩bottom, BL = bottom∩left
        guard let tl = intersect(lines[3], lines[0]), let tr = intersect(lines[0], lines[1]),
              let br = intersect(lines[1], lines[2]), let bl = intersect(lines[2], lines[3]) else { return quad }
        return Quad(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
    }

    /// Finds the sheet. Two detectors propose quads: the document segmenter (good on
    /// plain desks) and the rectangle detector (good on busy backgrounds where the
    /// segmenter grabs a rug or a placemat). Each candidate is then scored by what is
    /// inside it: a sheet of paper is bright, unsaturated, and brighter than its
    /// surroundings. Returns corners in pixels, origin bottom-left (Core Image convention).
    private func detectPaperQuad(in image: CGImage) throws -> (Quad, String) {
        let w = Double(image.width)
        let h = Double(image.height)
        func toPixels(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }

        let document = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 8
        rectangles.minimumSize = 0.12          // fraction of the image's shorter side
        rectangles.minimumAspectRatio = 0.45   // Letter is 0.77, A4 0.71, foreshortening allowed
        rectangles.maximumAspectRatio = 1.0
        rectangles.quadratureTolerance = 35    // degrees away from square corners, for tilt
        rectangles.minimumConfidence = 0.4

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([document, rectangles])

        var candidates: [(quad: Quad, confidence: Double, source: String)] = []
        if let d = document.results?.first {
            let q = orderCorners([d.topLeft, d.topRight, d.bottomRight, d.bottomLeft].map(toPixels))
            candidates.append((q, Double(d.confidence), "document"))
        }
        for r in rectangles.results ?? [] {
            let q = orderCorners([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft].map(toPixels))
            candidates.append((q, Double(r.confidence), "rectangle"))
        }
        guard !candidates.isEmpty else { throw TraceError.paperNotFound }

        // Score on a small copy of the photo; averaging colours does not need full resolution.
        let small = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: 512 / w, y: 512 / w))
        let scale = 512 / w
        var best: (score: Double, quad: Quad, source: String)?
        for c in candidates {
            // A sheet cut off by the photo's edge cannot give a true scale. Skip quads that touch the frame.
            let margin = 0.012 * min(w, h)
            let clipped = c.quad.points.contains {
                $0.x < margin || $0.y < margin || $0.x > w - margin || $0.y > h - margin
            }
            if clipped {
                TraceDebug.log("paper \(c.source): rejected (touches the photo edge)")
                continue
            }
            let q = c.quad.scaled(by: scale)
            guard let s = paperScore(for: q, in: small) else {
                TraceDebug.log("paper \(c.source): rejected (not paper-like)")
                continue
            }
            let total = s + 0.15 * c.confidence
            TraceDebug.log(String(format: "paper %@: score %.3f (conf %.2f) quad %@", c.source, total, c.confidence,
                                  c.quad.points.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined(separator: " ")))
            if best == nil || total > best!.score {
                best = (total, c.quad, c.source)
            }
        }
        guard let chosen = best else { throw TraceError.paperNotFound }
        return (chosen.quad, chosen.source)
    }

    /// Higher is more paper-like. Nil when the quad cannot be paper at all.
    /// Paper is bright and grey inside, and darker than what lies just outside on EVERY side.
    /// A quad that uses a fold crease as one edge has paper on both sides of that edge, so its
    /// weakest side gives it away. Bigger candidates win ties: the whole sheet contains any fake.
    private func paperScore(for quad: Quad, in small: CIImage) -> Double? {
        guard let inner = averageColor(inside: quad, of: small) else { return nil }
        let innerLum = luminance(inner)
        let innerSat = max(inner.r, inner.g, inner.b) - min(inner.r, inner.g, inner.b)
        guard innerLum > 0.35, innerSat < 0.35 else { return nil }

        var weakest = 1.0
        let pts = quad.points
        let cx = pts.map(\.x).reduce(0, +) / 4
        let cy = pts.map(\.y).reduce(0, +) / 4
        for i in 0..<4 {
            let a = pts[i]
            let b = pts[(i + 1) % 4]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            var nx = Double(mid.x - cx)
            var ny = Double(mid.y - cy)
            let len = (nx * nx + ny * ny).squareRoot()
            guard len > 1 else { continue }
            nx /= len
            ny /= len
            let depth = max(3.0, 0.12 * len)   // strip thickness just outside this edge
            let strip = Quad(topLeft: CGPoint(x: a.x + nx * depth, y: a.y + ny * depth),
                             topRight: CGPoint(x: b.x + nx * depth, y: b.y + ny * depth),
                             bottomRight: b, bottomLeft: a)
            guard let outside = averageColor(inside: strip, of: small) else { continue }
            weakest = min(weakest, innerLum - luminance(outside))
        }
        let sizeBonus = 0.15 * (abs(polygonArea(pts)) / Double(small.extent.width * small.extent.height)).squareRoot()
        return innerLum * (1 - innerSat) + 0.8 * max(0, weakest) + sizeBonus
    }

    private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    private func averageColor(inside quad: Quad, of image: CIImage) -> (r: Double, g: Double, b: Double)? {
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = quad.topLeft
        filter.topRight = quad.topRight
        filter.bottomRight = quad.bottomRight
        filter.bottomLeft = quad.bottomLeft
        filter.crop = true
        guard let patch = filter.outputImage, patch.extent.width > 2, patch.extent.height > 2, !patch.extent.isInfinite else { return nil }
        let avg = CIFilter.areaAverage()
        avg.inputImage = patch
        avg.extent = patch.extent
        guard let out = avg.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    /// Sorts four points into top-left, top-right, bottom-right, bottom-left
    /// (visual order, in a y-up coordinate system).
    private func orderCorners(_ points: [CGPoint]) -> Quad {
        let cx = points.map(\.x).reduce(0, +) / Double(points.count)
        let cy = points.map(\.y).reduce(0, +) / Double(points.count)
        // Clockwise on screen is counter-clockwise in y-up coordinates, so sort by descending angle.
        let sorted = points.sorted { atan2($0.y - cy, $0.x - cx) > atan2($1.y - cy, $1.x - cx) }
        // Start from the visual top-left: smallest x and largest y, i.e. minimum (x - y).
        guard let startIndex = sorted.indices.min(by: { (sorted[$0].x - sorted[$0].y) < (sorted[$1].x - sorted[$1].y) }) else {
            return Quad(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
        }
        let rotated = Array(sorted[startIndex...] + sorted[..<startIndex])
        return Quad(topLeft: rotated[0], topRight: rotated[1], bottomRight: rotated[2], bottomLeft: rotated[3])
    }
}

struct Quad {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    func scaled(by s: Double) -> Quad {
        Quad(topLeft: CGPoint(x: topLeft.x * s, y: topLeft.y * s),
             topRight: CGPoint(x: topRight.x * s, y: topRight.y * s),
             bottomRight: CGPoint(x: bottomRight.x * s, y: bottomRight.y * s),
             bottomLeft: CGPoint(x: bottomLeft.x * s, y: bottomLeft.y * s))
    }

    /// Grows the quad about its centroid; factor 1.3 grows every side by 30%.
    func expanded(by factor: Double) -> Quad {
        let cx = points.map(\.x).reduce(0, +) / 4
        let cy = points.map(\.y).reduce(0, +) / 4
        func grow(_ p: CGPoint) -> CGPoint { CGPoint(x: cx + (p.x - cx) * factor, y: cy + (p.y - cy) * factor) }
        return Quad(topLeft: grow(topLeft), topRight: grow(topRight), bottomRight: grow(bottomRight), bottomLeft: grow(bottomLeft))
    }
}

// MARK: - Small geometry helpers shared by the engine and the mesh builder

extension CGPoint {
    func distance(to other: CGPoint) -> Double {
        let dx = Double(other.x - x)
        let dy = Double(other.y - y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Signed area of a polygon (positive when counter-clockwise in a y-up system).
func polygonArea(_ poly: [CGPoint]) -> Double {
    guard poly.count >= 3 else { return 0 }
    var a = 0.0
    for i in 0..<poly.count {
        let p = poly[i]
        let q = poly[(i + 1) % poly.count]
        a += Double(p.x * q.y - q.x * p.y)
    }
    return a / 2
}
