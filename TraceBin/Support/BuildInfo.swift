import Foundation

/// Version and build time, read from the app bundle. The build time is the executable's
/// modification date, so it is correct whoever built it and needs no script.
enum BuildInfo {
    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (\(b))"
    }

    /// Debug only: file timestamps are a "required reason" API, so release builds do not touch them.
    static var builtAt: Date? {
        #if DEBUG
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
        #else
        return nil
        #endif
    }

    static var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        let when = builtAt.map { f.string(from: $0) } ?? "unknown time"
        #if DEBUG
        return "\(version) · debug · built \(when)"
        #else
        return "\(version) · built \(when)"
        #endif
    }
}
