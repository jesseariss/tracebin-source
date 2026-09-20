import SwiftUI

/// Editing is local until Done. Cancel never writes into a trace or history.
struct FingerNotchEditor: View {
    let spec: BinSpec
    let onSave: (FingerNotch) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicType
    @State private var draft: NotchDraft
    @State private var validated: FingerNotch?
    @State private var checking = true
    @State private var viewport = NotchViewport()
    @State private var hasInitialFocus = false
    @State private var saveError: String?
    @State private var dragOrigin: Point2?
    @State private var dragPan: CGSize?
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var pinchAnchor = UnitPoint.center
    @GestureState private var isPinching = false
    @GestureState private var isDragging = false

    init(spec: BinSpec, onSave: @escaping (FingerNotch) throws -> Void) {
        self.spec = spec
        self.onSave = onSave
        _draft = State(initialValue: NotchDraft(spec: spec))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dynamicType.isAccessibilitySize ? "Place on an edge" : "Tap an edge. Drag the handle.")
                                .font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                            if !dynamicType.isAccessibilitySize {
                                Text("Pinch to zoom • Drag elsewhere to pan")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal).padding(.top, 12)
                    canvas.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    HStack(spacing: 12) {
                        Button { viewport.zoom(by: 0.5) } label: {
                            Image(systemName: "minus.magnifyingglass").font(.system(size: 22)).frame(width: 44, height: 44)
                        }.accessibilityLabel("Zoom out").disabled(viewport.scale <= 1)
                        Text("\(Int(viewport.scale * 100))%")
                            .font(.caption.monospacedDigit()).frame(minWidth: 40)
                        Button { viewport.zoom(by: 2) } label: {
                            Image(systemName: "plus.magnifyingglass").font(.system(size: 22)).frame(width: 44, height: 44)
                        }.accessibilityLabel("Zoom in").disabled(viewport.scale >= 6)
                        Spacer()
                        Button("Fit") { viewport = NotchViewport() }
                            .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Fit entire bin on screen")
                    }.padding(.horizontal)
                    Divider()
                    ScrollView { controls.padding() }
                        .frame(height: min(geometry.size.height * (dynamicType.isAccessibilitySize ? 0.58 : 0.48),
                                           dynamicType.isAccessibilitySize ? 430 : 285))
                        .background(.regularMaterial)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Finger notch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        do { try onSave(draft.notch); dismiss() }
                        catch { saveError = error.localizedDescription }
                    }
                        .fontWeight(.semibold).disabled(checking || validated != draft.notch)
                }
            }
            .task(id: draft.notch) { await validate() }
            .alert("Couldn't save the notch", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your edit is still here. Try Done again. \(saveError ?? "")")
            }
        }
        .interactiveDismissDisabled()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if checking || (validated != nil && validated != draft.notch) {
                Label("Checking fit…", systemImage: "hourglass").font(.footnote)
            } else if validated == draft.notch {
                Label("Fits in your bin. Floor and feet protected.", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("Move the notch or reduce its width to fit safely.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.red)
            }
            dimensionControl("Width", value: $draft.notch.widthMM, range: 8...40)
            dimensionControl("Cut depth", value: $draft.notch.depthMM, range: 1...spec.maximumNotchDepth)
            HStack {
                Text("Fine position").font(.subheadline)
                Spacer()
                Button { draft.moveAlongEdge(by: -1) } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Move notch backward one millimetre along the edge")
                Button { draft.moveAlongEdge(by: 1) } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44)
                }.accessibilityLabel("Move notch forward one millimetre along the edge")
            }
            Text("Depth is measured from the top. Maximum \(spec.maximumNotchDepth, specifier: "%.1f") mm.")
                .font(.caption).foregroundStyle(.secondary)
        }.buttonStyle(.borderless)
    }

    private func dimensionControl(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 0) {
            LabeledContent(title, value: String(format: "%.1f mm", value.wrappedValue))
                .font(.subheadline).monospacedDigit()
            HStack {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 0.5) } label: {
                    Image(systemName: "minus").frame(width: 44, height: 44)
                }.accessibilityLabel("Decrease \(title) by half a millimetre").disabled(value.wrappedValue <= range.lowerBound)
                Slider(value: value, in: range).accessibilityLabel("\(title) in millimetres")
                    .accessibilityValue(String(format: "%.1f", value.wrappedValue))
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + 0.5) } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }.accessibilityLabel("Increase \(title) by half a millimetre").disabled(value.wrappedValue >= range.upperBound)
            }
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let base = NotchViewport.fitScale(spec: spec, size: size)
            let visible = viewport.magnified(by: pinch, anchor: pinchAnchor, size: size)
            let scale = base * visible.scale
            let center = visible.screenPoint(draft.notch.center, baseScale: base, size: size)
            ZStack {
                Canvas { context, _ in
                    func path(_ points: [Point2]) -> Path {
                        Path { p in
                            for (i, point) in points.enumerated() {
                                let screen = visible.screenPoint(point, baseScale: base, size: size)
                                if i == 0 { p.move(to: screen) } else { p.addLine(to: screen) }
                            }
                            p.closeSubpath()
                        }
                    }
                    let outer = path(roundedRect(cx: 0, cy: 0,
                                                w: Gridfinity.footprintMM(units: spec.gridUnits.n),
                                                h: Gridfinity.footprintMM(units: spec.gridUnits.m), r: Gridfinity.rTop))
                    context.fill(outer, with: .color(.orange.opacity(0.16)))
                    context.stroke(outer, with: .color(.primary.opacity(0.6)), lineWidth: 1.5)
                    context.fill(path(spec.centeredPocket), with: .color(.secondary.opacity(0.35)))
                    context.stroke(path(spec.centeredPocket), with: .color(.primary.opacity(0.6)), lineWidth: 1)
                    let circle = path(draft.notch.polygon)
                    context.fill(circle, with: .color(.blue.opacity(0.25)))
                    context.stroke(circle, with: .color(.blue), lineWidth: 3)
                }
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.blue, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 3)
                    .position(center).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4)
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { value in
                    guard !isPinching else { dragOrigin = nil; dragPan = nil; return }
                    if dragOrigin == nil && dragPan == nil {
                        let distance = hypot(value.startLocation.x - center.x, value.startLocation.y - center.y)
                        if distance <= max(32, draft.notch.widthMM * scale / 2) { dragOrigin = draft.notch.center }
                        else { dragPan = viewport.offset }
                    }
                    if let origin = dragOrigin {
                        draft.move(to: origin + Point2(value.translation.width / scale, -value.translation.height / scale))
                    } else if let origin = dragPan {
                        viewport.offset = CGSize(width: origin.width + value.translation.width,
                                                 height: origin.height + value.translation.height)
                    }
                }
                .onEnded { _ in dragOrigin = nil; dragPan = nil }
                .exclusively(before: SpatialTapGesture().onEnded { value in
                    draft.move(to: visible.modelPoint(value.location, baseScale: base, size: size))
                }))
            .simultaneousGesture(MagnifyGesture()
                .updating($isPinching) { _, state, _ in state = true }
                .updating($pinch) { value, state, _ in state = value.magnification }
                .updating($pinchAnchor) { value, state, _ in state = value.startAnchor }
                .onEnded { value in
                    viewport = viewport.magnified(by: value.magnification, anchor: value.startAnchor, size: size)
                    dragOrigin = nil; dragPan = nil
                })
            .onChange(of: isDragging) { _, active in
                if !active { dragOrigin = nil; dragPan = nil }
            }
            .onChange(of: size, initial: true) { _, size in
                guard !hasInitialFocus, size.width > 64, size.height > 64 else { return }
                viewport = .focused(on: draft.notch, spec: spec, size: size)
                hasInitialFocus = true
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Top-down view of the tool pocket and finger notch")
            .accessibilityHint("Use Fine position below to move the notch along the edge.")
        }
    }

    private func validate() async {
        checking = true
        validated = nil
        let candidate = draft
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        let valid = await Task.detached(priority: .userInitiated) { candidate.spec.buildMesh().triangleCount > 0 }.value
        guard !Task.isCancelled else { return }
        validated = valid ? candidate.notch : nil
        checking = false
    }
}
