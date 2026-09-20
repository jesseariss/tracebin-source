import SwiftUI

/// Full-screen capture. One instruction line, a paper-shaped guide, a shutter.
struct CameraView: View {
    let paper: Paper
    let onCapture: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var camera = CameraController()
    @State private var isCapturing = false
    @State private var errorMessage: String?
    @State private var breathe = false
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .opacity(isCapturing ? 0.6 : 1)
                .animation(.easeOut(duration: 0.2), value: isCapturing)

            guide

            VStack {
                Text("One tool on a sheet of paper, whole sheet in frame.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 12)
                Spacer()
                controls
            }

            statusOverlay

            Color.white
                .ignoresSafeArea()
                .opacity(flash ? 0.85 : 0)
                .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .alert("Capture failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Corner brackets with the paper's aspect ratio, held portrait like the phone. They breathe
    /// softly while the camera runs so the frame reads as live rather than printed on.
    private var guide: some View {
        GeometryReader { geo in
            let maxW = geo.size.width * 0.86
            let maxH = geo.size.height * 0.66
            let aspect = paper.longMM / paper.shortMM
            let w = min(maxW, maxH / aspect)
            let h = w * aspect
            CornerBrackets(length: 34, radius: 12)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: w, height: h)
                .opacity(breathe ? 0.95 : 0.6)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.46)
                .allowsHitTesting(false)
                .onAppear {
                    guard !reduceMotion else { breathe = true; return }
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
                }
        }
    }

    private var controls: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .foregroundStyle(.white)
                .frame(width: 80)

            Spacer()

            Button(action: capture) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                    Circle().fill(.white).frame(width: 64, height: 64)
                    if isCapturing {
                        ProgressView().tint(.black)
                    }
                }
            }
            .buttonStyle(ShutterButtonStyle())
            .accessibilityLabel("Take photo")
            .disabled(isCapturing || camera.status != .running)
            .opacity(camera.status == .running ? 1 : 0.4)

            Spacer()

            VStack(spacing: 6) {
                if camera.hasTorch {
                    Button {
                        camera.setTorch(!camera.isTorchOn)
                    } label: {
                        Image(systemName: camera.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title2)
                            .foregroundStyle(camera.isTorchOn ? .yellow : .white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .accessibilityLabel(camera.isTorchOn ? "Turn torch off" : "Turn torch on")
                }
                Text(paper.displayName)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(width: 80)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .unauthorized:
            message("Camera access is off.", detail: "Allow camera access in Settings, or choose a photo from your library instead.", showSettings: true)
        case .unavailable:
            message("No camera on this device.", detail: "Use Choose from Photos instead.", showSettings: false)
        case .failed(let text):
            message("Camera problem", detail: text, showSettings: false)
        case .idle, .running:
            EmptyView()
        }
    }

    private func message(_ title: String, detail: String, showSettings: Bool) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).multilineTextAlignment(.center)
            if showSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        .padding(32)
    }

    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if !reduceMotion {
            flash = true
            withAnimation(.easeOut(duration: 0.35)) { flash = false }
        }
        Task {
            do {
                let data = try await camera.capturePhoto()
                onCapture(data)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isCapturing = false
        }
    }
}

/// Four L-shaped corner marks, the document-scanner idiom.
struct CornerBrackets: Shape {
    var length: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = length
        let r = radius
        // top-left
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // top-right
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // bottom-right
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // bottom-left
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

/// The shutter sinks slightly under the finger.
struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
