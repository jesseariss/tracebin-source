import XCTest
import SwiftUI
import SwiftData
@testable import TraceBin

final class NotchEditingTests: XCTestCase {
    @MainActor
    func testSavedNotchAddEditAndRemovePersistWithoutSharing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TraceBinSaveTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("history.store"))
        try autoreleasepool {
            let container = try ModelContainer(for: TraceRecord.self, configurations: configuration)
            let context = ModelContext(container)
            context.insert(makeSavedRecord())
            try context.save()
        }
        let changes: [FingerNotch?] = [FingerNotch(x: 0, y: 10.6, widthMM: 12, depthMM: 4),
                                       FingerNotch(x: 10.6, y: 0, widthMM: 14, depthMM: 5), nil]
        for value in changes {
            try autoreleasepool {
                let container = try ModelContainer(for: TraceRecord.self, configurations: configuration)
                let context = ModelContext(container)
                let record = try XCTUnwrap(context.fetch(FetchDescriptor<TraceRecord>()).first)
                try record.saveNotch(value) { try context.save() }
            }
            try autoreleasepool {
                let container = try ModelContainer(for: TraceRecord.self, configurations: configuration)
                let records = try ModelContext(container).fetch(FetchDescriptor<TraceRecord>())
                XCTAssertEqual(records.count, 1, "Editing must not duplicate a history entry")
                let record = try XCTUnwrap(records.first)
                XCTAssertEqual(record.binSpec.notch, value)
                XCTAssertEqual(record.name, "saved-coupon")
                XCTAssertEqual(record.outlineMM, BinSpec.testCoupon(clearanceMM: 0.6).outline)
            }
        }
    }

    func testFailedNotchSaveRestoresPreviousRecordAndPreservesDraft() {
        enum SaveFailure: Error { case unavailable }
        let record = makeSavedRecord()
        let original = FingerNotch(x: 0, y: 10.6, widthMM: 12, depthMM: 4)
        record.notch = original
        var draft = NotchDraft(spec: record.binSpec)
        draft.notch.widthMM = 14
        for value in [draft.notch, nil] {
            XCTAssertThrowsError(try record.saveNotch(value) {
                XCTAssertEqual(record.notch, value, "The persistence callback sees the new value")
                throw SaveFailure.unavailable
            })
            XCTAssertEqual(record.notch, original, "Failed edits and removals must restore the record")
            XCTAssertEqual(draft.notch.widthMM, 14, "The editor draft remains available to retry")
        }
    }

    private func makeSavedRecord() -> TraceRecord {
        TraceRecord(name: "saved-coupon", mode: .bin, paper: .letter,
                    clearanceMM: 0.6, heightUnits: 2, pocketDepthMM: nil,
                    flatWidthMM: nil, flatDepthMM: nil, flatThicknessMM: nil,
                    outlineMM: BinSpec.testCoupon(clearanceMM: 0.6).outline,
                    gridN: 1, gridM: 1, maskPath: "test", thumbnail: Data())
    }

    func testEditorRequestKeepsItsIdentityAndSnapshot() {
        var spec = BinSpec.testCoupon(clearanceMM: 0.6)
        let request = NotchEditorRequest(spec: spec)
        let id = request.id
        spec.notch = FingerNotch(x: 0, y: 10.6)
        XCTAssertEqual(request.id, id)
        XCTAssertNil(request.spec.notch, "Parent updates must not replace inputs in the presented editor")
        XCTAssertNotEqual(NotchEditorRequest(spec: spec).id, id, "A later opening starts a fresh edit")
    }

    func testPhotoOverlayUndoesBinCenteringAndPreservesWidth() throws {
        var spec = BinSpec.testCoupon(clearanceMM: 0.6)
        spec.outline = spec.outline.map { $0 + Point2(83, 120) }
        spec.notch = FingerNotch(x: 3, y: 10.6, widthMM: 16, depthMM: 4)
        let points = try XCTUnwrap(spec.notchOnPaper)
        let bounds = try XCTUnwrap(Bounds2(points))
        XCTAssertEqual(bounds.center.x, 86, accuracy: 1e-9)
        XCTAssertEqual(bounds.center.y, 130.6, accuracy: 1e-9)
        XCTAssertEqual(bounds.width, 16, accuracy: 1e-9)
        XCTAssertEqual(bounds.height, 16, accuracy: 1e-9)
        spec.notch = nil
        XCTAssertNil(spec.notchOnPaper)
        spec.notch = FingerNotch(x: 0, y: 0)
        spec.mode = .flat
        XCTAssertNil(spec.notchOnPaper)
    }

    func testDraftDoesNotMutateOriginalUntilApplied() {
        var original = BinSpec.testCoupon(clearanceMM: 0.6)
        let plain = original
        var draft = NotchDraft(spec: original)
        draft.notch.widthMM = 12
        draft.move(to: Point2(10.6, 0))
        XCTAssertEqual(original, plain, "Cancel must leave the original untouched")
        original.notch = draft.notch
        XCTAssertEqual(original.notch, draft.notch)
        var editingAgain = NotchDraft(spec: original)
        editingAgain.notch.widthMM = 18
        XCTAssertEqual(original.notch?.widthMM, 12, "Editing an existing notch must also be isolated")
    }

    func testDraftClampsDepthToShorterBin() {
        var spec = BinSpec.testCoupon(clearanceMM: 0.6)
        spec.notch = FingerNotch(x: 0, y: 10.6, widthMM: 16, depthMM: 20)
        let draft = NotchDraft(spec: spec)
        XCTAssertEqual(draft.notch.depthMM, 5.8, accuracy: 1e-8)
        XCTAssertEqual(spec.notch?.depthMM, 20, "Opening then cancelling must not change saved values")
    }

    func testFinePositionMovesAroundCornersAndWraps() {
        var spec = BinSpec.testCoupon(clearanceMM: 0)
        spec.notch = FingerNotch(x: 9.5, y: -10)
        var draft = NotchDraft(spec: spec)
        draft.moveAlongEdge(by: 1)
        XCTAssertEqual(draft.notch.x, 10, accuracy: 1e-8)
        XCTAssertEqual(draft.notch.y, -9.5, accuracy: 1e-8)
        draft.moveAlongEdge(by: -1)
        XCTAssertEqual(draft.notch.x, 9.5, accuracy: 1e-8)
        XCTAssertEqual(draft.notch.y, -10, accuracy: 1e-8)
        draft.moveAlongEdge(by: 80)
        XCTAssertEqual(draft.notch.x, 9.5, accuracy: 1e-8)
        XCTAssertEqual(draft.notch.y, -10, accuracy: 1e-8)
        draft.move(to: Point2(-100, 0))
        XCTAssertEqual(draft.notch.x, -10, accuracy: 1e-8)
        XCTAssertEqual(draft.notch.y, 0, accuracy: 1e-8)
    }

    func testZoomAndPanCoordinateRoundTrip() {
        for scale: CGFloat in [1, 2, 6] {
            let viewport = NotchViewport(scale: scale, offset: CGSize(width: 91, height: -43))
            let size = CGSize(width: 390, height: 400)
            let point = Point2(12.3, -8.7)
            let screen = viewport.screenPoint(point, baseScale: 4, size: size)
            let result = viewport.modelPoint(screen, baseScale: 4, size: size)
            XCTAssertEqual(result.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(result.y, point.y, accuracy: 1e-9)
        }
    }

    func testInitialFocusCentersNewAndSavedNotches() {
        var spec = BinSpec.testCoupon(clearanceMM: 0.6)
        for notch in [NotchDraft(spec: spec).notch, FingerNotch(x: -13, y: 26, widthMM: 12)] {
            spec.notch = notch
            for size in [CGSize(width: 390, height: 340), CGSize(width: 320, height: 180)] {
                let focused = NotchViewport.focused(on: notch, spec: spec, size: size)
                let point = focused.screenPoint(notch.center, baseScale: NotchViewport.fitScale(spec: spec, size: size), size: size)
                XCTAssertEqual(point.x, size.width / 2, accuracy: 1e-9)
                XCTAssertEqual(point.y, size.height / 2, accuracy: 1e-9)
                XCTAssertTrue((1...3).contains(focused.scale))
                XCTAssertEqual(spec.notch, notch, "Focus changes only the camera, not the notch")
            }
        }
    }

    func testInitialFocusEnlargesSmallNotchAndFitResets() {
        let spec = BinSpec.testCoupon(clearanceMM: 0.6)
        let notch = FingerNotch(x: 0, y: 10.6, widthMM: 8)
        let size = CGSize(width: 390, height: 340)
        var viewport = NotchViewport.focused(on: notch, spec: spec, size: size)
        XCTAssertGreaterThan(viewport.scale, 1)
        viewport = NotchViewport()
        XCTAssertEqual(viewport.scale, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }

    func testPinchKeepsAnchorOverSamePointAndClampsZoom() {
        let size = CGSize(width: 390, height: 400)
        let start = NotchViewport(scale: 2, offset: CGSize(width: 40, height: -30))
        let anchor = UnitPoint(x: 0.2, y: 0.7)
        let screen = CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
        let original = start.modelPoint(screen, baseScale: 3, size: size)
        for factor: CGFloat in [0.01, 1, 2, 100] {
            let next = start.magnified(by: factor, anchor: anchor, size: size)
            let point = next.modelPoint(screen, baseScale: 3, size: size)
            XCTAssertEqual(point.x, original.x, accuracy: 1e-9)
            XCTAssertEqual(point.y, original.y, accuracy: 1e-9)
            XCTAssertTrue((1...6).contains(next.scale))
        }
    }
}
