import Foundation

enum AppDefaults {
    /// The "mask: subject / threshold" label under the Adjust photo. On for test builds, off for the store.
    static var showMaskPath: Bool {
        #if DEBUG
        return !isScreenshotMode
        #else
        return false
        #endif
    }

    /// Debug builds launched with `-screenshots` hide every developer aid so the screens look like release.
    static var isScreenshotMode: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-screenshots")
        #else
        return false
        #endif
    }
}
