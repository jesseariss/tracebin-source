import Foundation

/// Debug-only trace log, appended to Documents/trace_debug.log so it can be pulled off a test phone.
enum TraceDebug {
    private static let queue = DispatchQueue(label: "com.jesseariss.tracebin.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        #if DEBUG
        let line = "\(formatter.string(from: Date())) \(message)\n"
        print("TRACEBIN " + message)
        queue.async {
            guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = docs.appendingPathComponent("trace_debug.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }
}
