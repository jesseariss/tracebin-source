import PhotosUI
import SwiftData
import SwiftUI

/// A decoded, upright photo waiting to be processed.
struct CapturedPhoto {
    let image: CGImage
    let source: String   // "camera" or "library", for the debug log
}

/// Screen 1: capture, paper size, and the bins you have shared.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TraceRecord.createdAt, order: .reverse) private var records: [TraceRecord]

    @AppStorage("paper") private var paperRaw = Paper.letter.rawValue
    @AppStorage("defaultClearanceMM") private var defaultClearance = 0.6
    @AppStorage("defaultHeightUnits") private var defaultHeightUnits = 3

    @State private var showCamera = false
    @State private var showSettings = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var isProcessing = false
    @State private var processingStage = "Reading the photo…"
    @State private var session: TraceSession?
    @State private var historyRecord: TraceRecord?
    @State private var errorMessage: String?

    private let engine = TraceEngine()

    private var paper: Paper { Paper(rawValue: paperRaw) ?? .letter }

    #if DEBUG
    /// `-preview-coupon` launch argument opens the coupon preview straight away, for screenshots on the simulator.
    @State private var debugCoupon: BinSpec? = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-preview-coupon") || args.contains("-preview-notch") || args.contains("-adjust-notch") else { return nil }
        var spec = BinSpec.testCoupon(clearanceMM: 0.6)
        if args.contains("-preview-notch") {
            spec.notch = FingerNotch(x: 0, y: 10.6, widthMM: 16, depthMM: 4)
        }
        return spec
    }()
    /// `-easter-egg` opens the easter egg straight away.
    @State private var debugEgg = ProcessInfo.processInfo.arguments.contains("-easter-egg")
    @State private var debugNotchEditor = ProcessInfo.processInfo.arguments.contains("-edit-notch")
    #endif

    var body: some View {
        NavigationStack {
            List {
                heroSection
                paperSection
                historySection
                #if DEBUG
                if !AppDefaults.isScreenshotMode {
                Section {
                    Text(BuildInfo.stamp)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .secretTaps()
                }
                }
                #endif
            }
            .listStyle(.insetGrouped)
            .animation(.snappy, value: records.count)
            .navigationTitle("TraceBin")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraView(paper: paper) { data in
                    handleIncoming(data: data, source: "camera")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(item: $session) { session in
                AdjustView(session: session, engine: engine) { self.session = nil }
            }
            .navigationDestination(item: $historyRecord) { record in
                SavedBinAdjustView(spec: record.binSpec, onSaveNotch: { notch in
                    try record.saveNotch(notch) { try modelContext.save() }
                }, onShare: { name, _ in
                    record.name = name
                    try? modelContext.save()
                }) { historyRecord = nil }
            }
            #if DEBUG
            .fullScreenCover(isPresented: $debugEgg) { EasterEggView() }
            .fullScreenCover(isPresented: $debugNotchEditor) {
                FingerNotchEditor(spec: .testCoupon(clearanceMM: 0.6)) { _ in }
            }
            .navigationDestination(item: $debugCoupon) { spec in
                if ProcessInfo.processInfo.arguments.contains("-adjust-notch") {
                    SavedBinAdjustView(spec: spec) { debugCoupon = nil }
                } else {
                    PreviewView(spec: spec) { debugCoupon = nil }
                }
            }
            #endif
            .alert("Couldn't trace that photo", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        handleIncoming(data: data, source: "library")
                    } else {
                        errorMessage = "Could not read that photo from your library."
                    }
                    pickerItem = nil
                }
            }
            .overlay {
                if isProcessing {
                    ZStack {
                        Color.black.opacity(0.08).ignoresSafeArea()
                        ProgressView(processingStage)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: processingStage)
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isProcessing)
            .task {
                let engine = self.engine
                Task.detached(priority: .utility) { engine.warmUp() }
                #if DEBUG
                // `-open-sample`: trace Documents/sample.jpg straight away, for simulator screenshots.
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-open-sample"),
                   let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                   let data = try? Data(contentsOf: docs.appendingPathComponent("sample.jpg")) {
                    handleIncoming(data: data, source: "sample")
                }
                #endif
            }
        }
    }

    // MARK: - Sections

    private var heroSection: some View {
        Section {
            VStack(spacing: 14) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    showCamera = true
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 34, weight: .semibold))
                        Text("Capture")
                            .font(.title3.weight(.semibold))
                        Text("One tool on a sheet of paper, whole sheet in frame.")
                            .font(.footnote)
                            .opacity(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 18))

                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.medium))
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private var paperSection: some View {
        Section {
            Picker("Paper", selection: $paperRaw) {
                ForEach(Paper.allCases) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }
            .pickerStyle(.menu)
        } footer: {
            Text("Any plain sheet of this size. The paper sets the scale, so nothing else needs measuring.")
        }
    }

    @ViewBuilder
    private var historySection: some View {
        Section {
            if records.isEmpty {
                ContentUnavailableView {
                    Label("No bins yet", systemImage: "tray")
                } description: {
                    Text("Bins you share are kept here so you can share them again.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(records) { record in
                    Button {
                        historyRecord = record
                    } label: {
                        HistoryRow(record: record)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteRecords)
            }
        } header: {
            if !records.isEmpty { Text("History") }
        }
    }

    // MARK: - Actions

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(records[index])
        }
        try? modelContext.save()
    }

    /// Decodes the photo off the main thread, then traces straight away.
    private func handleIncoming(data: Data, source: String) {
        processingStage = "Reading the photo…"
        isProcessing = true
        Task.detached(priority: .userInitiated) {
            #if DEBUG
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: docs.appendingPathComponent("last_photo.jpg"), options: .atomic)
            }
            #endif
            let image = ImageLoader.load(data: data)
            await MainActor.run {
                guard let image else {
                    isProcessing = false
                    errorMessage = "Could not decode that photo."
                    return
                }
                runTrace(on: CapturedPhoto(image: image, source: source))
            }
        }
    }

    /// Paper, mask, and outline in one pass, then on to the Adjust screen.
    private func runTrace(on photo: CapturedPhoto) {
        let paper = self.paper
        let engine = self.engine
        let clearance = defaultClearance
        let height = defaultHeightUnits
        isProcessing = true
        TraceDebug.log("trace start (\(photo.source), \(photo.image.width)x\(photo.image.height), \(paper.rawValue))")
        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run { processingStage = "Finding the paper…" }
                let corrected = try engine.correctPaper(image: photo.image, paper: paper)
                await MainActor.run { processingStage = "Separating the tool…" }
                var mask: ToolMask
                #if DEBUG
                if photo.source == "sample",
                   let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                   let data = try? Data(contentsOf: docs.appendingPathComponent("sample_outline.json")),
                   let raw = try? JSONSerialization.jsonObject(with: data) as? [[Double]],
                   let m = engine.maskFromOutline(raw.map { Point2($0[0], $0[1]) }, corrected: corrected) {
                    mask = m
                } else {
                    mask = try engine.makeMask(from: corrected)
                }
                #else
                mask = try engine.makeMask(from: corrected)
                #endif
                await MainActor.run { processingStage = "Tracing the outline…" }
                let outline = try engine.outline(from: mask, clearance: clearance)
                await MainActor.run {
                    isProcessing = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    session = TraceSession(paper: paper, original: photo.image, mask: mask, outline: outline,
                                           clearanceMM: clearance, heightUnits: height)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// Thumbnail, name, size line, date.
struct HistoryRow: View {
    let record: TraceRecord

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let ui = UIImage(data: record.thumbnail) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(record.sizeLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    HomeView()
        .modelContainer(for: TraceRecord.self, inMemory: true)
}
