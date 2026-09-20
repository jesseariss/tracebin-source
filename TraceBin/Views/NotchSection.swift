import SwiftUI

/// The same discoverable entry on new traces and saved bins, before the export preview.
struct NotchSection: View {
    let spec: BinSpec
    @Binding var notch: FingerNotch?
    @Binding var validatedSpec: BinSpec?
    let onEdit: () -> Void
    @State private var checking = true

    private var current: BinSpec { var result = spec; result.notch = notch; return result }

    var body: some View {
        Section {
            Button(action: onEdit) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.16))
                        RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.35)).frame(width: 20, height: 40)
                        Circle().fill(.blue.opacity(0.3)).frame(width: 24, height: 24).offset(x: 12)
                        Circle().stroke(.blue, lineWidth: 2).frame(width: 24, height: 24).offset(x: 12)
                    }.frame(width: 58, height: 58).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notch == nil ? "Add finger notch" : "Edit finger notch").font(.headline)
                        if let notch {
                            Text(String(format: "%.1f mm wide · %.1f mm deep", notch.widthMM,
                                        min(notch.depthMM, spec.maximumNotchDepth)))
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Make room to lift your tool out.").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if notch != nil {
                if checking {
                    Label("Checking notch…", systemImage: "hourglass").font(.footnote)
                } else if validatedSpec != current {
                    Label("The bin has changed. Edit or remove the notch before previewing.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
                Button("Remove notch", role: .destructive) { notch = nil }
            }
        } header: {
            Text("Finger notch")
        } footer: {
            Text("Optional. Position and size it in a full-screen view.")
        }
        .task(id: current) {
            let candidate = current
            checking = true
            validatedSpec = nil
            if candidate.notch == nil {
                validatedSpec = candidate; checking = false; return
            }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let valid = await Task.detached(priority: .userInitiated) { candidate.buildMesh().triangleCount > 0 }.value
            guard !Task.isCancelled else { return }
            validatedSpec = valid ? candidate : nil
            checking = false
        }
    }
}

/// Saved bins persist accepted notch edits immediately, independently of STL export.
struct SavedBinAdjustView: View {
    @State private var spec: BinSpec
    @State private var validatedSpec: BinSpec?
    @State private var notchEditor: NotchEditorRequest?
    @State private var saveError: String?
    let onSaveNotch: ((FingerNotch?) throws -> Void)?
    let onShare: ((String, FingerNotch?) -> Void)?
    let onDone: () -> Void

    init(spec: BinSpec, onSaveNotch: ((FingerNotch?) throws -> Void)? = nil,
         onShare: ((String, FingerNotch?) -> Void)? = nil, onDone: @escaping () -> Void) {
        _spec = State(initialValue: spec)
        self.onSaveNotch = onSaveNotch
        self.onShare = onShare
        self.onDone = onDone
    }

    var body: some View {
        Form {
            Section {
                Text(spec.fileName).font(.headline)
                Text(spec.summaryLine).foregroundStyle(.secondary)
            } header: { Text("Saved bin") }
            if spec.mode == .bin {
                Section {
                    BinPlanPreview(spec: spec).frame(height: 220)
                    if spec.notch != nil {
                        Label("Blue shows your finger notch", systemImage: "circle.dashed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NotchSection(spec: spec, notch: Binding(get: { spec.notch }, set: { value in
                    do { try saveNotch(value) }
                    catch { saveError = error.localizedDescription }
                }), validatedSpec: $validatedSpec) {
                    notchEditor = NotchEditorRequest(spec: spec)
                }
            }
        }
        .fullScreenCover(item: $notchEditor) { request in
            FingerNotchEditor(spec: request.spec) { try saveNotch($0) }
        }
        .alert("Couldn't save the notch", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your saved bin has not changed. Please try again. \(saveError ?? "")")
        }
        .navigationTitle("Adjust")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                PreviewView(spec: spec, onShare: onShare, onDone: onDone)
            } label: {
                Text(spec.mode == .bin ? "Preview Bin" : "Preview Insert")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(spec.notch != nil && validatedSpec != spec)
            .padding(.horizontal).padding(.vertical, 10).background(.bar)
        }
    }

    private func saveNotch(_ value: FingerNotch?) throws {
        try onSaveNotch?(value)
        spec.notch = value
    }
}
