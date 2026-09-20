import SwiftData
import SwiftUI

/// Screen 2: the flattened sheet with the pocket outline, and the choices that shape the bin.
struct AdjustView: View {
    @Bindable var session: TraceSession
    let engine: TraceEngine
    /// Pops back to Home once the user is finished with the preview.
    let onDone: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("showMaskPath") private var showMaskPath = AppDefaults.showMaskPath
    @State private var drawProgress: CGFloat = 0
    @State private var isRetracing = false
    @State private var retraceError: String?
    @State private var showPaperCheck = false
    @State private var autoPreview = false
    @State private var validatedNotchSpec: BinSpec?
    @State private var notchEditor: NotchEditorRequest?
    @FocusState private var focusedField: FlatField?

    private enum FlatField { case width, depth, thickness }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                photoSection
                if session.mode == .bin {
                    NotchSection(spec: session.binSpec, notch: $session.notch, validatedSpec: $validatedNotchSpec) {
                        notchEditor = NotchEditorRequest(spec: session.binSpec)
                    }
                        .disabled(isRetracing)
                }
                fitSection
                    .id("fit")
                shapeSection
            }
            #if DEBUG
            .task {
                // `-scroll-fit`: scroll so the clearance control is in view, for screenshots.
                if ProcessInfo.processInfo.arguments.contains("-scroll-fit") {
                    try? await Task.sleep(for: .milliseconds(1200))
                    withAnimation { proxy.scrollTo("fit", anchor: .top) }
                }
            }
            #endif
        }
        .navigationTitle("Adjust")
        .fullScreenCover(item: $notchEditor) { request in
            FingerNotchEditor(spec: request.spec) { session.notch = $0 }
        }
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                PreviewView(spec: session.binSpec, onShare: { name, notch in saveToHistory(fileName: name, notch: notch) }, onDone: onDone)
            } label: {
                Text(session.mode == .bin ? "Preview Bin" : "Preview Insert")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRetracing || (session.mode == .flat && !session.flatFits) ||
                      (session.binSpec.notch != nil && validatedNotchSpec != session.binSpec))
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .toolbar {
            #if DEBUG
            if !AppDefaults.isScreenshotMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Paper check") { showPaperCheck = true }
                        .font(.footnote)
                }
            }
            #endif
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .navigationDestination(isPresented: $showPaperCheck) {
            PaperDebugView(result: PaperDebugResult(paper: session.paper, corrected: session.corrected, original: session.original, elapsedMS: 0))
        }
        .navigationDestination(isPresented: $autoPreview) {
            PreviewView(spec: session.binSpec, onShare: { name, notch in saveToHistory(fileName: name, notch: notch) }, onDone: onDone)
        }
        .task {
            #if DEBUG
            // Screenshot helpers: `-sample-flat` switches to a flat insert, `-sample-preview` opens the preview,
            // `-seed-history` saves this trace so Home has a row.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-sample-flat") {
                session.mode = .flat
                session.flatWidthMM = 180
                session.flatDepthMM = 200
                session.flatThicknessMM = 15
            }
            if args.contains("-seed-history") {
                saveToHistory(fileName: session.suggestedFileName)
            }
            if args.contains("-sample-preview") {
                try? await Task.sleep(for: .milliseconds(400))
                autoPreview = true
            }
            #endif
        }
        .task(id: session.clearanceMM) {
            await retrace()
        }
        .task {
            // Draw the outline around the tool once, like a pen tracing it. Starts after the push
            // transition has settled; an animation begun mid-transition is dropped by SwiftUI.
            guard drawProgress < 1 else { return }
            if reduceMotion {
                drawProgress = 1
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeInOut(duration: 0.6)) { drawProgress = 1 }
        }
        .sensoryFeedback(.selection, trigger: session.clearanceMM)
        .sensoryFeedback(.selection, trigger: session.mode)
        .sensoryFeedback(.selection, trigger: session.heightUnits)
        .sensoryFeedback(.selection, trigger: session.pocketDepth)
        .alert("Couldn't update the outline", isPresented: Binding(get: { retraceError != nil }, set: { if !$0 { retraceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(retraceError ?? "")
        }
    }

    // MARK: - Sections

    private var photoSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                outlinePreview
                if session.mode == .bin, session.notch != nil {
                    Label("Blue shows your finger notch", systemImage: "circle.dashed")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.primaryLine)
                        .font(.headline)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: session.primaryLine)
                    Text(session.secondaryLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: session.secondaryLine)
                    if showMaskPath {
                        Text("mask: \(session.outline.maskPath)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 4)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private var fitSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Clearance", value: String(format: "%.1f mm", session.clearanceMM))
                Slider(value: $session.clearanceMM, in: 0.3...1.5, step: 0.1) {
                    Text("Clearance")
                } minimumValueLabel: {
                    Text("Snug").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Loose").font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Fit")
        } footer: {
            Text("The gap between the tool and the pocket wall. 0.6 mm suits most printers. Lower it for a snug fit, raise it if the tool sticks.")
        }
    }

    private var shapeSection: some View {
        Section {
            Picker("Type", selection: $session.mode.animation()) {
                ForEach(BinMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            if session.mode == .bin {
                Stepper(value: $session.heightUnits, in: 2...6) {
                    LabeledContent("Height", value: "\(session.heightUnits)u · \(Int(session.heightMM)) mm")
                }
                Picker("Pocket depth", selection: $session.pocketDepth) {
                    ForEach(PocketDepth.allCases) { d in
                        Text(d.displayName).tag(d)
                    }
                }
            } else {
                mmRow("Width", value: $session.flatWidthMM, field: .width)
                mmRow("Depth", value: $session.flatDepthMM, field: .depth)
                mmRow("Thickness", value: $session.flatThicknessMM, field: .thickness)
            }
        } header: {
            Text("Shape")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                switch session.mode {
                case .bin:
                    Text("A gridfinity bin with standard feet. It snaps onto any gridfinity baseplate, so its size is chosen for you in 42 mm cells. \"To floor\" leaves a 1.2 mm base under the tool; a fixed depth keeps more material beneath it.")
                case .flat:
                    Text("A plain slab with no feet, for a drawer or case that has no baseplate. Type the inside size of the space it will sit in.")
                    if !session.flatFits {
                        Text("The tool does not fit in that size. Make it wider or deeper.")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var outlinePreview: some View {
        Image(decorative: session.corrected.image, scale: 1)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let w = session.corrected.widthMM
                    let h = session.corrected.heightMM
                    let pts = session.outline.points.map {
                        CGPoint(x: $0.x / w * geo.size.width, y: (1 - $0.y / h) * geo.size.height)
                    }
                    Path { path in
                        guard let first = pts.first else { return }
                        path.move(to: first)
                        for p in pts.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                    }
                    .trim(from: 0, to: drawProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: .green.opacity(0.5), radius: 3)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .id(session.outline.clearanceMM)
                    .transition(.opacity)
                    if session.mode == .bin, let points = session.binSpec.notchOnPaper {
                        NotchOverlay(points: points.map {
                            CGPoint(x: $0.x / w * geo.size.width, y: (1 - $0.y / h) * geo.size.height)
                        })
                    }
                }
            }
            .accessibilityLabel("Flattened sheet with the tool outline")
            .overlay(alignment: .topTrailing) {
                if isRetracing {
                    ProgressView()
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func mmRow(_ label: String, value: Binding<Double>, field: FlatField) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: field)
                    .frame(width: 80)
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    /// One record per session: sharing twice updates the row instead of adding another.
    private func saveToHistory(fileName: String, notch: FingerNotch? = nil) {
        let u = session.gridUnits
        let thumb = Thumbnail.make(corrected: session.corrected, outline: session.outline.points)
        let id = session.id
        let existing = try? modelContext.fetch(FetchDescriptor<TraceRecord>(predicate: #Predicate { $0.id == id }))
        if let record = existing?.first {
            record.name = fileName
            record.createdAt = Date()
            record.modeRaw = session.mode.rawValue
            record.clearanceMM = session.clearanceMM
            record.heightUnits = session.heightUnits
            record.pocketDepthMM = session.pocketDepth.millimetres
            record.flatWidthMM = session.mode == .flat ? session.flatWidthMM : nil
            record.flatDepthMM = session.mode == .flat ? session.flatDepthMM : nil
            record.flatThicknessMM = session.mode == .flat ? session.flatThicknessMM : nil
            record.outlineMM = session.outline.points
            record.gridN = u.n
            record.gridM = u.m
            record.maskPath = session.outline.maskPath
            record.thumbnail = thumb
            record.notch = notch
        } else {
            let record = TraceRecord(id: id, name: fileName, mode: session.mode, paper: session.paper,
                                     clearanceMM: session.clearanceMM, heightUnits: session.heightUnits,
                                     pocketDepthMM: session.pocketDepth.millimetres,
                                     flatWidthMM: session.mode == .flat ? session.flatWidthMM : nil,
                                     flatDepthMM: session.mode == .flat ? session.flatDepthMM : nil,
                                     flatThicknessMM: session.mode == .flat ? session.flatThicknessMM : nil,
                                     outlineMM: session.outline.points, gridN: u.n, gridM: u.m,
                                     maskPath: session.outline.maskPath, thumbnail: thumb)
            modelContext.insert(record)
            record.notch = notch
        }
        try? modelContext.save()
    }

    /// Re-runs only dilate, trace, and simplify. The mask is kept from the first pass.
    private func retrace() async {
        if session.outline.clearanceMM == session.clearanceMM { return }
        isRetracing = true
        defer { isRetracing = false }
        let mask = session.mask
        let clearance = session.clearanceMM
        let engine = self.engine
        do {
            let outline = try await Task.detached(priority: .userInitiated) {
                try engine.outline(from: mask, clearance: clearance)
            }.value
            if !Task.isCancelled {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                    session.outline = outline
                }
            }
        } catch is CancellationError {
        } catch {
            retraceError = error.localizedDescription
        }
    }
}
