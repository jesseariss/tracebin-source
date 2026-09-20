import SwiftUI

/// Defaults for new traces, the test coupon, and the privacy note.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultClearanceMM") private var defaultClearance = 0.6
    @AppStorage("defaultHeightUnits") private var defaultHeightUnits = 3
    @AppStorage("showMaskPath") private var showMaskPath = AppDefaults.showMaskPath

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Clearance", value: String(format: "%.1f mm", defaultClearance))
                        Slider(value: $defaultClearance, in: 0.3...1.5, step: 0.1)
                    }
                    Stepper(value: $defaultHeightUnits, in: 2...6) {
                        LabeledContent("Height", value: "\(defaultHeightUnits)u · \(defaultHeightUnits * 7) mm")
                    }
                } header: {
                    Text("Defaults for new traces")
                } footer: {
                    Text("You can still change both on the Adjust screen for each bin.")
                }

                Section {
                    NavigationLink("Preview test coupon") {
                        PreviewView(spec: .testCoupon(clearanceMM: defaultClearance)) { dismiss() }
                    }
                } header: {
                    Text("Test coupon")
                } footer: {
                    Text("A 1 × 1 bin with a pocket for a 20 mm block, made with the clearance above. Print it and try a 20 mm calibration cube. Loose: lower the clearance. Tight: raise it.")
                }

                #if DEBUG
                Section {
                    Toggle("Show mask method label", isOn: $showMaskPath)
                } header: {
                    Text("Testing")
                } footer: {
                    Text("Shows whether the tool was separated by subject lifting or by brightness threshold. Debug builds only.")
                }
                #endif

                Section {
                    LabeledContent("Version", value: BuildInfo.version)
                        .secretTaps()
                } header: {
                    Text("About")
                } footer: {
                    Text("Photos are processed on this iPhone and never leave it. TraceBin has no account and makes no network calls.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
