import SwiftUI

/// Tap the version number five times in a row to see this. Tap the bin to flip it, tap anywhere
/// else to go back.
struct EasterEggView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var gridVisible = false
    @State private var binScale: CGFloat = 0.3
    @State private var binOffset: CGFloat = -700
    @State private var spinning = false
    @State private var flips = 0
    @State private var textVisible = false

    private let charcoal = Color(red: 0.11, green: 0.11, blue: 0.12)

    var body: some View {
        ZStack {
            charcoal.ignoresSafeArea()
            GridBackdrop()
                .opacity(gridVisible ? 1 : 0)
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    credits
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .sensoryFeedback(.impact(weight: .heavy), trigger: binOffset)
        .sensoryFeedback(.success, trigger: textVisible)
        .sensoryFeedback(.impact(weight: .medium), trigger: flips)
        .statusBarHidden()
        .task { await play() }
    }

    private var credits: some View {
        VStack(spacing: 24) {
            Spacer()
            bin
                .scaleEffect(binScale)
                .offset(y: binOffset)
                .onTapGesture { if !reduceMotion { flips += 1 } }
                .accessibilityLabel("An orange gridfinity bin with a wrench pocket")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Tap to spin")
                .accessibilityAction { if !reduceMotion { flips += 1 } }

            VStack(spacing: 8) {
                Text("TraceBin")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(BuildInfo.version)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, 6)
            }
            .opacity(textVisible ? 1 : 0)

            VStack(spacing: 8) {
                Text("Contributors")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Eric, Matt, Blake, Nicole, Mike, Attila, Chris")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("/r/gridfinity")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .opacity(textVisible ? 1 : 0)

            Spacer()
            Text("Tap anywhere to go back")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))
                .opacity(textVisible ? 1 : 0)
                .padding(.bottom, 24)
        }
    }

    /// The scene rotates the solid model, not a flattened screenshot of the scene.
    private var bin: some View {
        EasterEggLogo(spinning: spinning && !AppDefaults.isScreenshotMode,
                      flips: flips, reduceMotion: reduceMotion)
            .frame(width: 250, height: 250)
            .contentShape(Rectangle())
    }

    private func play() async {
        if reduceMotion {
            gridVisible = true
            binScale = 1
            binOffset = 0
            textVisible = true
            return
        }
        withAnimation(.easeOut(duration: 0.8)) { gridVisible = true }
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        withAnimation(.spring(duration: 0.8, bounce: 0.45)) {
            binScale = 1
            binOffset = 0
        }
        do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
        withAnimation(.easeOut(duration: 0.5)) { textVisible = true }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        spinning = true
    }
}

/// A 42 mm gridfinity grid, drawn faintly, with a vignette so it fades toward the edges.
private struct GridBackdrop: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 42
            var path = Path()
            var x = size.width.truncatingRemainder(dividingBy: cell) / 2
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += cell
            }
            var y = size.height.truncatingRemainder(dividingBy: cell) / 2
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += cell
            }
            context.stroke(path, with: .color(Color.accentColor.opacity(0.28)), lineWidth: 1)
        }
        .mask {
            RadialGradient(colors: [.white, .white.opacity(0.05)], center: .center, startRadius: 40, endRadius: 520)
        }
    }
}

/// The logo's closed wrench outline, also used to cut the decorative 3D pocket.
struct WrenchOutline: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0.30, 0.06))                                   // left jaw, outer tip
        path.addLine(to: p(0.42, 0.04))                                // left jaw, inner tip
        path.addLine(to: p(0.42, 0.20))                                // down the jaw
        path.addLine(to: p(0.58, 0.20))                                // across the mouth
        path.addLine(to: p(0.58, 0.04))                                // up the right jaw
        path.addLine(to: p(0.70, 0.06))                                // right jaw, outer tip
        path.addQuadCurve(to: p(0.59, 0.42), control: p(0.82, 0.30))   // round the head
        path.addLine(to: p(0.59, 0.90))                                // handle, right edge
        path.addQuadCurve(to: p(0.41, 0.90), control: p(0.50, 1.02))   // handle end
        path.addLine(to: p(0.41, 0.42))                                // handle, left edge
        path.addQuadCurve(to: p(0.30, 0.06), control: p(0.18, 0.30))   // round the head
        path.closeSubpath()
        return path
    }
}

/// Counts quick taps on a view and opens the easter egg on the fifth.
struct SecretTapModifier: ViewModifier {
    @State private var taps = 0
    @State private var lastTap = Date.distantPast
    @State private var showEgg = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                let now = Date()
                taps = now.timeIntervalSince(lastTap) < 1.5 ? taps + 1 : 1
                lastTap = now
                if taps >= 5 {
                    taps = 0
                    showEgg = true
                }
            }
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .fullScreenCover(isPresented: $showEgg) { EasterEggView() }
    }
}

extension View {
    /// Five quick taps open the easter egg.
    func secretTaps() -> some View { modifier(SecretTapModifier()) }
}

#Preview {
    EasterEggView()
}
