import SceneKit
import SwiftUI

/// Decorative artwork only. This never changes printable bin geometry.
struct EasterEggLogo: UIViewRepresentable {
    let spinning: Bool
    let flips: Int
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.isUserInteractionEnabled = false // SwiftUI owns tap-to-flip and dismissal.
        view.scene = Self.makeScene()
        context.coordinator.model = view.scene?.rootNode.childNode(withName: "logo", recursively: true)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.apply(spinning: spinning, flips: flips, reduceMotion: reduceMotion)
        view.isPlaying = !reduceMotion && (spinning || flips > 0)
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        coordinator.model?.removeAllActions()
        view.isPlaying = false
        view.scene = nil
    }

    final class Coordinator {
        var model: SCNNode?
        private var wasSpinning = false
        private var lastFlip = 0

        func apply(spinning: Bool, flips: Int, reduceMotion: Bool) {
            guard let model else { return }
            let shouldSpin = spinning && !reduceMotion
            let flip = flips != lastFlip && !reduceMotion
            defer { wasSpinning = shouldSpin; lastFlip = flips }
            if reduceMotion {
                model.removeAllActions()
                model.eulerAngles = SCNVector3Zero
            } else if flip || shouldSpin != wasSpinning {
                model.removeAction(forKey: "turn")
                var actions: [SCNAction] = []
                if flip {
                    let turn = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 0.9)
                    turn.timingMode = .easeInEaseOut
                    actions.append(turn)
                }
                if shouldSpin {
                    actions.append(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 12)))
                }
                if !actions.isEmpty { model.runAction(.sequence(actions), forKey: "turn") }
            }
        }
    }

    static func makeScene() -> SCNScene {
        let scene = SCNScene()
        let tilt = SCNNode()
        tilt.eulerAngles = SCNVector3(-0.25, -0.35, -0.04)
        scene.rootNode.addChildNode(tilt)
        let model = SCNNode()
        model.name = "logo"
        tilt.addChildNode(model)

        let orange = SCNMaterial()
        orange.diffuse.contents = UIColor(red: 1, green: 0.57, blue: 0.08, alpha: 1)
        orange.lightingModel = .physicallyBased
        orange.roughness.contents = 0.55
        let green = SCNMaterial()
        green.diffuse.contents = UIColor.systemGreen
        green.emission.contents = UIColor.systemGreen.withAlphaComponent(0.2)
        green.lightingModel = .physicallyBased
        let dark = SCNMaterial()
        dark.diffuse.contents = UIColor(red: 0.18, green: 0.32, blue: 0.12, alpha: 1)
        dark.lightingModel = .physicallyBased

        let outer = UIBezierPath(roundedRect: CGRect(x: -50, y: -50, width: 100, height: 100), cornerRadius: 12)
        // SwiftUI's path is y-down. SceneKit's shape plane is y-up.
        var flipY = CGAffineTransform(scaleX: 1, y: -1)
        let wrench = WrenchOutline().path(in: CGRect(x: -36, y: -36, width: 72, height: 72)).cgPath
        let pocket = wrench.copy(using: &flipY)!
        let rimPath = UIBezierPath(cgPath: outer.cgPath)
        rimPath.append(UIBezierPath(cgPath: pocket))
        rimPath.usesEvenOddFillRule = true

        func part(_ name: String, path: UIBezierPath, depth: CGFloat, z: Float, material: SCNMaterial) {
            let shape = SCNShape(path: path, extrusionDepth: depth)
            shape.materials = [material]
            let node = SCNNode(geometry: shape)
            node.name = name
            node.position.z = z
            model.addChildNode(node)
        }
        // SCNShape extrudes equally to either side of z=0. The joined surfaces meet at z=-6.
        part("back", path: outer, depth: 6, z: -9, material: orange)
        part("rim", path: rimPath, depth: 14, z: 1, material: orange)
        part("pocket-floor", path: UIBezierPath(cgPath: pocket), depth: 0.2, z: -5.8, material: dark)
        let stroke = pocket.copy(strokingWithWidth: 1.3, lineCap: .round, lineJoin: .round, miterLimit: 2)
        part("green-outline", path: UIBezierPath(cgPath: stroke), depth: 0.4, z: 8.1, material: green)

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 36
        camera.camera?.zNear = 1
        camera.camera?.zFar = 1000
        camera.position = SCNVector3(0, 0, 220)
        scene.rootNode.addChildNode(camera)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1100
        key.eulerAngles = SCNVector3(-0.6, -0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 400
        scene.rootNode.addChildNode(fill)
        return scene
    }
}
