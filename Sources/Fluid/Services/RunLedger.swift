import Foundation

/// `Runs.log` beside `Fluid.log`: one line per app start, crash, forced quit and
/// day of dictation. Fluid.log rotates every few days; this file keeps months,
/// so `scripts/crash_free_days.py` can count crash-free days of use.
///
/// Line format: `<ISO 8601 UTC time> <event> pid=<pid> app=<version>`.
nonisolated enum RunLedger {
    enum Event: String {
        case start
        case crash
        /// Stopped without quitting: a forced quit, a kill or a power loss.
        case unclean
        /// The first delivered dictation of a day in this run.
        case use
    }

    static let fileName = "Runs.log"
    /// Past this size the oldest half is dropped. A line is about 70 bytes.
    static let maxBytes = 256 * 1024

    static func line(_ event: Event, time: Date, pid: Int32, app: String?) -> String {
        var line = "\(ISO8601DateFormatter().string(from: time)) \(event.rawValue) pid=\(pid)"
        if let app {
            line += " app=\(app.replacingOccurrences(of: " ", with: "_"))"
        }
        return line
    }

    static func append(_ line: String, in directory: URL, fileManager: FileManager = .default) {
        let url = directory.appendingPathComponent(self.fileName, isDirectory: false)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > self.maxBytes,
           let text = try? String(contentsOf: url, encoding: .utf8)
        {
            let lines = text.split(separator: "\n")
            try? (lines.suffix(lines.count / 2).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let data = Data((line + "\n").utf8)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
