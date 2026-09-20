import XCTest
import SceneKit
@testable import TraceBin

final class EasterEggLogoTests: XCTestCase {
    func testLogoHasSolidSidesAndRecessedFloor() throws {
        let scene = EasterEggLogo.makeScene()
        let model = try XCTUnwrap(scene.rootNode.childNode(withName: "logo", recursively: true))
        let rim = try XCTUnwrap(model.childNode(withName: "rim", recursively: false))
        let back = try XCTUnwrap(model.childNode(withName: "back", recursively: false))
        let floor = try XCTUnwrap(model.childNode(withName: "pocket-floor", recursively: false))
        let shape = try XCTUnwrap(rim.geometry as? SCNShape)
        XCTAssertEqual(shape.extrusionDepth, 14)
        XCTAssertEqual((back.geometry as? SCNShape)?.extrusionDepth, 6)
        XCTAssertTrue(try XCTUnwrap(shape.path).usesEvenOddFillRule)
        XCTAssertLessThan(floor.position.z, rim.position.z)
        XCTAssertGreaterThan(model.boundingBox.max.z - model.boundingBox.min.z, 19)
        let camera = try XCTUnwrap(scene.rootNode.childNodes.first { $0.camera != nil })
        XCTAssertGreaterThan(try XCTUnwrap(camera.camera).zFar, Double(camera.position.z) + 100,
                             "The entire rotating logo must lie inside the camera's viewing range")
    }

    func testReduceMotionStopsSpinAndTapAnimation() {
        let coordinator = EasterEggLogo.Coordinator()
        let model = SCNNode()
        coordinator.model = model
        coordinator.apply(spinning: true, flips: 0, reduceMotion: false)
        XCTAssertNotNil(model.action(forKey: "turn"))
        coordinator.apply(spinning: true, flips: 1, reduceMotion: true)
        XCTAssertFalse(model.hasActions)
        XCTAssertEqual(model.eulerAngles.y, 0)
        coordinator.apply(spinning: true, flips: 1, reduceMotion: false)
        XCTAssertNotNil(model.action(forKey: "turn"))
    }
}
