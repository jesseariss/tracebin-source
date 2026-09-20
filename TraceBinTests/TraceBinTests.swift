import XCTest
@testable import TraceBin

final class PaperTests: XCTestCase {
    func testPaperSizes() {
        XCTAssertEqual(Paper.letter.shortMM, 215.9)
        XCTAssertEqual(Paper.letter.longMM, 279.4)
        XCTAssertEqual(Paper.a4.shortMM, 210)
        XCTAssertEqual(Paper.a4.longMM, 297)
    }

    func testCanonicalPixelSize() {
        // 8 px/mm: Letter is 2235 x 1727 px in landscape.
        XCTAssertEqual((Paper.letter.longMM * TraceEngine.pxPerMM).rounded(), 2235)
        XCTAssertEqual((Paper.letter.shortMM * TraceEngine.pxPerMM).rounded(), 1727)
    }
}
