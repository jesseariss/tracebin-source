import SwiftData
import SwiftUI

@main
struct TraceBinApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(for: TraceRecord.self)
    }
}
