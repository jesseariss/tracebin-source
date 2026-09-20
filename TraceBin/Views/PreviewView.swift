import SceneKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The STL type. iOS already knows the extension; the Info.plist declaration is the fallback.
    static var stl: UTType {
        UTType(filenameExtension: "stl") ?? UTType(importedAs: "public.standard-tesselated-geometry-format")
    }
}

/// What ShareLink hands to AirDrop, Files, or a slicer app: an .stl file in the temp folder.
struct STLFile: Transferable {
    let data: Data
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .stl) { file in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TraceBinExport", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(file.fileName)
            try file.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// Screen 3: rotating 3D preview, file name, Share, Done.
struct PreviewView: View {
    let spec: BinSpec
    /// Called with the final file name when the user opens the share sheet. Saves to history.
    let onShare: ((String, FingerNotch?) -> Void)?
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fileName: String
    @State private var mesh: Mesh?
    @State private var stlData: Data?
    @State private var buildError: String?
    @State private var shareCount = 0
    @State private var spinning = true
    @State private var builtSpec: BinSpec?
    @State private var meshID = UUID()

    init(spec: BinSpec, onShare: ((String, FingerNotch?) -> Void)? = nil, onDone: @escaping () -> Void) {
        self.spec = spec
        self.onShare = onShare
        self.onDone = onDone
        _fileName = State(initialValue: spec.fileName)
    }

    var body: some View {
        Form {
            Section {
                ZStack {
                    if let mesh {
                        MeshSceneView(mesh: mesh, spinning: $spinning)
                            .id(meshID)
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                            .overlay(alignment: .bottomTrailing) {
                                Button {
                                    spinning.toggle()
                                } label: {
                                    Image(systemName: spinning ? "pause.fill" : "play.fill")
                                        .font(.footnote.weight(.semibold))
                                        .frame(width: 34, height: 34)
                                        .background(.regularMaterial, in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(spinning ? "Stop turning" : "Start turning")
                                .padding(10)
                            }
                    } else if let buildError {
                        Text(buildError).foregroundStyle(.red).padding()
                    } else {
                        ProgressView("Building…")
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(spec.summaryLine)
                    Text("Drag to turn, pinch to zoom.")
                    #if DEBUG
                    if let mesh, !AppDefaults.isScreenshotMode {
                        Text("\(mesh.triangleCount) triangles").font(.caption2.monospaced())
                    }
                    #endif
                }
            }

            if let notch = spec.notch, spec.mode == .bin {
                Section {
                    Label(String(format: "Finger notch · %.1f mm wide · %.1f mm deep", notch.widthMM,
                                 min(notch.depthMM, spec.maximumNotchDepth)), systemImage: "hand.point.up.left")
                } footer: {
                    Text("Go back to Adjust to change the notch.")
                }
            }

            Section {
                LabeledContent("File name") {
                    TextField("tool-bin", text: $fileName)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                }
            } footer: {
                Text("Opens in Bambu Studio, PrusaSlicer, OrcaSlicer, and Cura.")
            }
        }
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let stlData, builtSpec == spec {
                    ShareLink(item: STLFile(data: stlData, fileName: cleanFileName),
                              preview: SharePreview(cleanFileName, image: Image(systemName: "cube"))) {
                        Label("Share STL", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        shareCount += 1
                        onShare?(cleanFileName, spec.notch)
                    })
                } else {
                    Button {} label: {
                        Label("Share STL", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .disabled(true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sensoryFeedback(.success, trigger: shareCount)
        .onAppear { if reduceMotion { spinning = false } }
        .task(id: spec) { await build(spec: spec) }
    }

    /// Always ends in .stl and never contains a path separator.
    private var cleanFileName: String {
        var name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if name.isEmpty { name = "tool-bin" }
        if !name.lowercased().hasSuffix(".stl") { name += ".stl" }
        return name
    }

    private func build(spec: BinSpec) async {
        stlData = nil
        builtSpec = nil
        mesh = nil
        buildError = nil
        // Wait briefly for a slider/drag to settle; never share the preceding mesh.
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        #if DEBUG
        let dump = spec.outline.map { String(format: "[%.3f,%.3f]", $0.x, $0.y) }.joined(separator: ",")
        TraceDebug.log("outline \(spec.outline.count) pts area \(area(spec.outline)) [\(dump)]")
        #endif
        let built: Mesh = await Task.detached(priority: .userInitiated) { spec.buildMesh() }.value
        guard !Task.isCancelled else { return }
        guard built.triangleCount > 0 else {
            buildError = spec.notch == nil
                ? "The bin came out empty. Go back and try a different clearance."
                : "This notch cannot be safely built here. Move it along the tool edge or reduce its width. Keep it away from the bin's outside wall."
            return
        }
        let data = await Task.detached { STLWriter.data(for: built) }.value
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
            mesh = built
            meshID = UUID()
        }
        stlData = data
        builtSpec = spec
    }
}

/// SceneKit view of the triangle list, slowly turning until touched, with touch camera control.
struct MeshSceneView: UIViewRepresentable {
    let mesh: Mesh
    @Binding var spinning: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.scene = makeScene(coordinator: context.coordinator)
        // Any touch on the model stops the auto-spin so pinch and drag are not fighting it.
        let touch = TouchDownRecognizer(target: context.coordinator, action: #selector(Coordinator.touched))
        touch.cancelsTouchesInView = false
        touch.delegate = context.coordinator
        view.addGestureRecognizer(touch)
        context.coordinator.apply(spinning: spinning)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(spinning: spinning)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MeshSceneView
        var spinner: SCNNode?
        private var isSpinning = false

        init(_ parent: MeshSceneView) { self.parent = parent }

        func apply(spinning: Bool) {
            guard let spinner, spinning != isSpinning else { return }
            isSpinning = spinning
            if spinning {
                spinner.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 24)), forKey: "spin")
            } else {
                spinner.removeAction(forKey: "spin")
            }
        }

        @objc func touched() {
            if parent.spinning {
                DispatchQueue.main.async { self.parent.spinning = false }
            }
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }

    private func makeScene(coordinator: Coordinator) -> SCNScene {
        let scene = SCNScene()
        let geometry = Self.geometry(for: mesh)

        let shell = SCNMaterial()
        shell.diffuse.contents = UIColor(red: 0.98, green: 0.62, blue: 0.18, alpha: 1)
        shell.lightingModel = .physicallyBased
        shell.roughness.contents = 0.55
        shell.metalness.contents = 0.0

        let pocket = SCNMaterial()
        pocket.diffuse.contents = UIColor(red: 0.55, green: 0.33, blue: 0.10, alpha: 1)
        pocket.lightingModel = .physicallyBased
        pocket.roughness.contents = 0.8
        pocket.metalness.contents = 0.0
        geometry.materials = geometry.elements.count > 1 ? [shell, pocket] : [shell]

        // Our mesh is z-up; SceneKit is y-up. Tilt the model inside a spinner node.
        let model = SCNNode(geometry: geometry)
        model.eulerAngles.x = -.pi / 2
        model.castsShadow = true
        let b = mesh.bounds ?? (SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 1, 1))
        let size = b.max - b.min
        let centre = (b.max + b.min) / 2
        model.position = SCNVector3(-centre.x, -b.min.z, centre.y)   // sit on y = 0, centred

        let spinner = SCNNode()
        spinner.addChildNode(model)
        scene.rootNode.addChildNode(spinner)
        coordinator.spinner = spinner


        let radius = max(size.x, size.y, size.z)
        let camera = SCNCamera()
        camera.zFar = Double(radius) * 20
        camera.fieldOfView = 40
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, radius * 1.1, radius * 1.4)
        camNode.look(at: SCNVector3(0, size.z * 0.4, 0))
        scene.rootNode.addChildNode(camNode)

        // Key light with shadows so the pocket reads as a recess, plus soft fill.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.castsShadow = true
        key.light?.shadowMode = .deferred
        key.light?.shadowSampleCount = 16
        key.light?.shadowRadius = 3
        key.light?.shadowColor = UIColor(white: 0, alpha: 0.45)
        key.eulerAngles = SCNVector3(-Float.pi / 2.6, Float.pi / 5, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 350
        scene.rootNode.addChildNode(fill)
        return scene
    }

    /// One vertex per triangle corner, flat normals. Two elements when the mesh has a pocket,
    /// so the recess can wear its own material.
    static func geometry(for mesh: Mesh) -> SCNGeometry {
        let v = mesh.vertices
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        positions.reserveCapacity(v.count)
        normals.reserveCapacity(v.count)
        var i = 0
        while i + 2 < v.count {
            let a = v[i], b = v[i + 1], c = v[i + 2]
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : SIMD3<Float>(0, 0, 1)
            for p in [a, b, c] {
                positions.append(SCNVector3(p.x, p.y, p.z))
                normals.append(SCNVector3(n.x, n.y, n.z))
            }
            i += 3
        }
        var elements: [SCNGeometryElement] = []
        if let pr = mesh.pocketRange, !pr.isEmpty {
            let outer = Array(0..<Int32(pr.lowerBound)) + Array(Int32(pr.upperBound)..<Int32(positions.count))
            let inner = Array(Int32(pr.lowerBound)..<Int32(pr.upperBound))
            elements = [SCNGeometryElement(indices: outer, primitiveType: .triangles),
                        SCNGeometryElement(indices: inner, primitiveType: .triangles)]
        } else {
            elements = [SCNGeometryElement(indices: Array(0..<Int32(positions.count)), primitiveType: .triangles)]
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
                           elements: elements)
    }
}

/// Fires on the first finger down and then gets out of the way.
final class TouchDownRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        state = .recognized
    }
}
