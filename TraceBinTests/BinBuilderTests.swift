import XCTest
import SwiftData
@testable import TraceBin

/// Pocket outline recovered from Reference/wrench_bin.stl (the 37 floor-ring vertices at z = 8.2).
let referenceWrenchPocket: [Point2] = [
        Point2(-58.85, 11.75),
        Point2(-62.25, 9.75),
        Point2(-64.15, 7.75),
        Point2(-65.45, 5.55),
        Point2(-66.25, 3.15),
        Point2(-66.55, 0.55),
        Point2(-66.05, -4.05),
        Point2(-65.05, -6.45),
        Point2(-63.75, -8.35),
        Point2(-60.35, -11.15),
        Point2(-56.05, -12.55),
        Point2(-51.25, -12.45),
        Point2(-47.05, -10.85),
        Point2(-43.75, -7.85),
        Point2(-41.75, -3.65),
        Point2(47.95, -3.65),
        Point2(49.25, -6.05),
        Point2(51.65, -8.25),
        Point2(54.15, -9.35),
        Point2(57.65, -9.65),
        Point2(60.85, -9.05),
        Point2(63.65, -7.35),
        Point2(65.55, -4.95),
        Point2(66.55, -1.95),
        Point2(66.55, 1.85),
        Point2(65.25, 5.35),
        Point2(62.45, 8.15),
        Point2(58.95, 9.45),
        Point2(55.15, 9.45),
        Point2(52.15, 8.45),
        Point2(49.75, 6.55),
        Point2(47.95, 3.55),
        Point2(-41.75, 3.55),
        Point2(-43.15, 6.85),
        Point2(-46.15, 10.15),
        Point2(-49.95, 12.05),
        Point2(-54.55, 12.55),
]

/// Rotated controller outline from a test phone; its bridged top face used to triangulate with overlaps.
let rotatedControllerPocket: [Point2] = [
    Point2(126.326, 56.443),
    Point2(132.578, 58.161),
    Point2(137.703, 60.38),
    Point2(142.079, 62.635),
    Point2(148.08, 66.506),
    Point2(156.081, 72.518),
    Point2(169.764, 85.195),
    Point2(173.27, 89.821),
    Point2(179.015, 96.071),
    Point2(185.772, 104.822),
    Point2(191.522, 113.448),
    Point2(197.497, 124.449),
    Point2(199.746, 129.699),
    Point2(200.237, 132.949),
    Point2(200.236, 136.7),
    Point2(198.754, 141.325),
    Point2(194.898, 148.451),
    Point2(192.473, 151.701),
    Point2(189.334, 154.014),
    Point2(186.209, 155.389),
    Point2(184.146, 156.952),
    Point2(172.645, 174.078),
    Point2(157.502, 193.705),
    Point2(139.532, 213.582),
    Point2(139.141, 214.207),
    Point2(139.016, 216.707),
    Point2(138.141, 220.207),
    Point2(134.754, 224.708),
    Point2(129.953, 229.204),
    Point2(126.827, 231.521),
    Point2(121.327, 233.884),
    Point2(119.826, 233.896),
    Point2(118.951, 234.396),
    Point2(116.451, 234.396),
    Point2(115.451, 233.896),
    Point2(112.826, 233.896),
    Point2(111.825, 233.396),
    Point2(109.45, 233.335),
    Point2(108.2, 232.782),
    Point2(104.7, 232.271),
    Point2(94.323, 228.862),
    Point2(85.947, 225.617),
    Point2(79.322, 222.77),
    Point2(71.821, 218.145),
    Point2(62.445, 213.491),
    Point2(58.819, 211.269),
    Point2(45.119, 200.33),
    Point2(35.63, 190.955),
    Point2(31.637, 185.204),
    Point2(28.792, 179.704),
    Point2(27.503, 176.328),
    Point2(27.068, 172.203),
    Point2(29.003, 166.452),
    Point2(31.214, 164.202),
    Point2(34.066, 162.39),
    Point2(38.942, 161.264),
    Point2(41.067, 161.764),
    Point2(45.443, 161.764),
    Point2(46.318, 162.265),
    Point2(49.818, 162.89),
    Point2(72.821, 171.515),
    Point2(75.571, 171.515),
    Point2(77.947, 170.015),
    Point2(79.884, 168.203),
    Point2(81.009, 166.577),
    Point2(81.134, 162.327),
    Point2(83.269, 158.827),
    Point2(86.072, 156.514),
    Point2(89.073, 156.231),
    Point2(90.26, 155.326),
    Point2(109.013, 131.574),
    Point2(114.763, 124.824),
    Point2(115.611, 123.074),
    Point2(115.263, 119.823),
    Point2(117.281, 115.948),
    Point2(120.451, 113.26),
    Point2(124.452, 113.135),
    Point2(126.229, 110.947),
    Point2(128.14, 107.447),
    Point2(129.085, 104.197),
    Point2(128.89, 101.197),
    Point2(112.888, 75.319),
    Point2(111.022, 70.444),
    Point2(110.524, 67.319),
    Point2(110.533, 65.193),
    Point2(111.07, 63.693),
    Point2(114.451, 59.275),
    Point2(117.576, 57.255),
    Point2(119.576, 56.523),
]

final class BinBuilderTests: XCTestCase {
    func testNotchOffPreservesOriginalSTL() {
        let original = buildBin(pocketMM: referenceWrenchPocket)
        let off = buildBin(pocketMM: referenceWrenchPocket, notch: nil)
        XCTAssertEqual(STLWriter.data(for: original.mesh), STLWriter.data(for: off.mesh))
    }

    func testNotchedBodyMatchesPythonReference() {
        let rectangle = [Point2(-30, -5), Point2(30, -5), Point2(30, 5), Point2(-30, 5)]
        let mesh = notchedBody(width: 83.5, depth: 41.5, z0: 4.95, top: 21, floorZ: 8.2,
                               cornerRadius: 3.75, pocket: rectangle,
                               notch: FingerNotch(x: 0, y: 5), minimumFloor: 8.2)
        XCTAssertEqual(mesh?.triangleCount, 242)
        XCTAssertTrue(mesh.map { isClosedManifold($0, allowSharedEdges: false) } ?? false)
    }

    func testSmallCouponNotchIsClosed() {
        var spec = BinSpec.testCoupon(clearanceMM: 0.6)
        spec.notch = FingerNotch(x: 0, y: 10.6, widthMM: 16, depthMM: 4)
        let mesh = spec.buildMesh()
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        XCTAssertTrue(isClosedManifold(mesh, allowSharedEdges: true))
    }

    func testNotchDepthsAreClosedAndPreserveFootprint() {
        for toolDepth: Double? in [nil, 8] {
            for cutDepth in [3.0, 8, 12.8, 100] {
                let notch = FingerNotch(x: 0, y: 3.55, widthMM: 20, depthMM: cutDepth)
                let result = buildBin(pocketMM: referenceWrenchPocket, pocketDepthMM: toolDepth, notch: notch)
                XCTAssertGreaterThan(result.mesh.triangleCount, 0, "depth \(cutDepth), tool \(String(describing: toolDepth))")
                XCTAssertTrue(isClosedManifold(result.mesh, allowSharedEdges: true), "depth \(cutDepth)")
                guard let bounds = result.mesh.bounds else { continue }
                XCTAssertEqual(bounds.max.x - bounds.min.x, 167.5, accuracy: 0.001)
                XCTAssertEqual(bounds.max.y - bounds.min.y, 41.5, accuracy: 0.001)
                XCTAssertEqual(bounds.max.z, 21)
                XCTAssertEqual(bounds.min.z, 0)
                if let range = result.mesh.pocketRange {
                    XCTAssertGreaterThanOrEqual(result.mesh.vertices[range].map(\.z).min()!, 8.2 - 0.001)
                } else { XCTFail("Missing pocket surface range") }
            }
        }
    }

    func testUnsafeNotchCannotExport() {
        for notch in [FingerNotch(x: 0, y: 20, widthMM: 20),
                      FingerNotch(x: 0, y: 0, widthMM: 2),
                      FingerNotch(x: .nan, y: 0),
                      FingerNotch(x: 75, y: 0, widthMM: 8)] {
            XCTAssertEqual(buildBin(pocketMM: referenceWrenchPocket, notch: notch).mesh.triangleCount, 0)
        }
    }

    func testNotchRecordRoundTrip() {
        let record = TraceRecord(name: "notch", mode: .bin, paper: .letter, clearanceMM: 0.6,
                                 heightUnits: 3, pocketDepthMM: nil, flatWidthMM: nil, flatDepthMM: nil,
                                 flatThicknessMM: nil, outlineMM: referenceWrenchPocket, gridN: 4, gridM: 1,
                                 maskPath: "test", thumbnail: Data())
        XCTAssertNil(record.binSpec.notch)
        let notch = FingerNotch(x: 0, y: 3.55)
        record.notch = notch
        XCTAssertEqual(record.binSpec.notch, notch)
        XCTAssertEqual(STLWriter.data(for: record.binSpec.buildMesh()),
                       STLWriter.data(for: buildBin(pocketMM: referenceWrenchPocket, notch: notch).mesh))
        record.notch = nil
        XCTAssertNil(record.notchData)
    }

    @MainActor
    func testNotchSurvivesHistoryStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceBinNotchTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("history.store"))
        let notch = FingerNotch(x: 0, y: 3.55)
        try autoreleasepool {
            let container = try ModelContainer(for: TraceRecord.self, configurations: configuration)
            let context = ModelContext(container)
            for enabled in [false, true] {
                let record = TraceRecord(name: enabled ? "notched" : "plain", mode: .bin, paper: .letter,
                                         clearanceMM: 0.6, heightUnits: 3, pocketDepthMM: nil,
                                         flatWidthMM: nil, flatDepthMM: nil, flatThicknessMM: nil,
                                         outlineMM: referenceWrenchPocket, gridN: 4, gridM: 1,
                                         maskPath: "test", thumbnail: Data())
                record.notch = enabled ? notch : nil
                context.insert(record)
            }
            try context.save()
        }
        let container = try ModelContainer(for: TraceRecord.self, configurations: configuration)
        let records = try ModelContext(container).fetch(FetchDescriptor<TraceRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertNil(records.first { $0.name == "plain" }?.notch)
        let saved = try XCTUnwrap(records.first { $0.name == "notched" })
        XCTAssertEqual(saved.notch, notch)
        XCTAssertEqual(STLWriter.data(for: saved.binSpec.buildMesh()),
                       STLWriter.data(for: buildBin(pocketMM: referenceWrenchPocket, notch: notch).mesh))
    }

    func testNotchPlacementSweepHasNoOpenEdges() {
        for outline in [referenceWrenchPocket, rotatedControllerPocket] {
            let center = Bounds2(outline)!.center
            let pocket = outline.map { $0 - center }
            var accepted = 0
            for index in stride(from: 0, to: pocket.count, by: 3) {
                let p = (pocket[index] + pocket[(index + 1) % pocket.count]) / 2
                for width in [8.0, 16, 24, 40] {
                    let result = buildBin(pocketMM: outline, pocketDepthMM: 8,
                                          notch: FingerNotch(x: p.x, y: p.y, widthMM: width, depthMM: 10))
                    if result.mesh.triangleCount == 0 { continue } // rejected safely near walls or tangencies
                    accepted += 1
                    XCTAssertTrue(isClosedManifold(result.mesh, allowSharedEdges: true), "edge \(index), width \(width)")
                }
            }
            XCTAssertGreaterThan(accepted, 5, "Ordinary placements must work")
        }
    }

    /// The top face is the outer rectangle minus the pocket, joined by a bridge. Every triangle
    /// must be counter-clockwise and their areas must add up to exactly that annulus.
    func testTopFaceHasNoOverlaps() {
        for (name, pocket) in [("wrench", referenceWrenchPocket), ("rotated controller", rotatedControllerPocket)] {
            let r = buildBin(pocketMM: pocket, heightUnits: 3)
            let outer = ccw(roundedRect(cx: 0, cy: 0, w: r.binWidthMM, h: r.binDepthMM, r: Gridfinity.rTop))
            let centre = Bounds2(pocket)!.center
            let hole = Array(ccw(pocket.map { $0 - centre }).reversed())
            let merged = bridgeHole(outer: outer, hole: hole)
            let tris = earclip(merged)
            XCTAssertEqual(tris.count, merged.count - 2, name)
            var total = 0.0
            for t in tris {
                let a = area([merged[t.0], merged[t.1], merged[t.2]])
                XCTAssertGreaterThanOrEqual(a, -1e-9, "\(name): clockwise triangle")
                total += abs(a)
            }
            XCTAssertEqual(total, area(outer) - abs(area(pocket)), accuracy: 0.5, name)
        }
    }

    /// The reference file has 1360 triangles and spans 167.5 x 41.5 x 21 mm.
    func testWrenchBinMatchesReference() {
        let result = buildBin(pocketMM: referenceWrenchPocket, heightUnits: 3)
        XCTAssertEqual(result.n, 4)
        XCTAssertEqual(result.m, 1)
        XCTAssertEqual(Double(result.mesh.triangleCount), 1360, accuracy: 13.6)   // within 1%
        let b = result.mesh.bounds!
        XCTAssertEqual(b.min.x, -83.75, accuracy: 0.01)
        XCTAssertEqual(b.max.x, 83.75, accuracy: 0.01)
        XCTAssertEqual(b.min.y, -20.75, accuracy: 0.01)
        XCTAssertEqual(b.max.y, 20.75, accuracy: 0.01)
        XCTAssertEqual(b.min.z, 0, accuracy: 0.01)
        XCTAssertEqual(b.max.z, 21, accuracy: 0.01)
    }

    func testStlBytesMatchTriangleCount() {
        let result = buildBin(pocketMM: referenceWrenchPocket, heightUnits: 3)
        let data = STLWriter.data(for: result.mesh)
        XCTAssertEqual(data.count, 84 + result.mesh.triangleCount * 50)
        let count = data.withUnsafeBytes { $0.load(fromByteOffset: 80, as: UInt32.self) }
        XCTAssertEqual(Int(UInt32(littleEndian: count)), result.mesh.triangleCount)
    }

    /// The bin is five shells (four feet, one body). The end feet share their z = 4.95 ring with
    /// the body's bottom ring, so an edge may appear twice per direction. What must never happen
    /// is a directed edge without its reverse: that would be a hole.
    func testWrenchBinIsWatertight() {
        let result = buildBin(pocketMM: referenceWrenchPocket, heightUnits: 3)
        XCTAssertTrue(isClosedManifold(result.mesh, allowSharedEdges: true), "mesh has open edges")
    }

    func testFlatInsertIsWatertight() {
        let mesh = buildFlatInsert(pocketMM: referenceWrenchPocket, widthMM: 160, depthMM: 60, thicknessMM: 15)
        let b = mesh.bounds!
        XCTAssertEqual(b.max.x - b.min.x, 160, accuracy: 0.01)
        XCTAssertEqual(b.max.y - b.min.y, 60, accuracy: 0.01)
        XCTAssertEqual(b.max.z, 15, accuracy: 0.01)
        XCTAssertEqual(b.min.z, 0, accuracy: 0.01)
        XCTAssertTrue(isClosedManifold(mesh, allowSharedEdges: false))
    }

    func testPocketDepthOptionRaisesFloor() {
        let deep = buildBin(pocketMM: referenceWrenchPocket, heightUnits: 3)
        let shallow = buildBin(pocketMM: referenceWrenchPocket, heightUnits: 3, pocketDepthMM: 8)
        // Shallower pocket: same triangle count, floor at 21 - 8 = 13 instead of 8.2.
        XCTAssertEqual(deep.mesh.triangleCount, shallow.mesh.triangleCount)
        let zs = Set(shallow.mesh.vertices.map { ($0.z * 100).rounded() / 100 })
        XCTAssertTrue(zs.contains(13.0))
        XCTAssertFalse(zs.contains(8.2))
    }

    private func isClosedManifold(_ mesh: Mesh, allowSharedEdges: Bool) -> Bool {
        struct Key: Hashable { let a: SIMD3<Float>; let b: SIMD3<Float> }
        var directed: [Key: Int] = [:]
        let v = mesh.vertices
        var i = 0
        while i + 2 < v.count {
            let tri = [v[i], v[i + 1], v[i + 2]]
            for k in 0..<3 {
                directed[Key(a: tri[k], b: tri[(k + 1) % 3]), default: 0] += 1
            }
            i += 3
        }
        for (key, count) in directed {
            let reverse = directed[Key(a: key.b, b: key.a)] ?? 0
            if allowSharedEdges {
                if count != reverse { return false }
            } else if count != 1 || reverse != 1 {
                return false
            }
        }
        return true
    }
}
