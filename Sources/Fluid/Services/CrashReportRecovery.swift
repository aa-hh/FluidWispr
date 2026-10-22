import Darwin
import Foundation

/// Turns the raw records written by the crash signal handler
/// (`CrashSignalHandler.c`) into readable reports on the next launch.
///
/// The handler can only write numbers, so this is where signal names, image
/// offsets and `atos` commands come from. Each run writes its own
/// `crash-pending-<pid>.txt`; records from runs that are still alive are left
/// alone.
nonisolated enum CrashReportRecovery {
    static let pendingPrefix = "crash-pending-"
    static let pendingSuffix = ".txt"
    static let maxSavedReports = 20

    struct Image: Equatable {
        let start: UInt64
        let end: UInt64
        let uuid: String
        let path: String

        var name: String {
            (self.path as NSString).lastPathComponent
        }
    }

    struct Record: Equatable {
        var preamble: [String: String] = [:]
        var pid: Int32?
        var signal: Int32?
        var code: Int32?
        var address: UInt64?
        var time: Date?
        var isMainThread: Bool?
        var thread: UInt32?
        var frames: [UInt64] = []
        var images: [Image] = []
        var notes: [String] = []
        var isComplete = false
        /// A normal quit writes `exit clean`. A record with neither this nor a
        /// crash comes from a forced quit, a kill or a power loss.
        var exitedCleanly = false

        /// A clean exit leaves only the preamble behind.
        var describesCrash: Bool {
            self.signal != nil || !self.notes.isEmpty
        }
    }

    /// How a run that has ended stopped, for `RunLedger`.
    struct EndedRun: Equatable {
        let pid: Int32
        let crashed: Bool
        /// The crash time, or when the record was last written.
        let time: Date
        let app: String?
    }

    static func pendingFileName(pid: Int32) -> String {
        "\(self.pendingPrefix)\(pid)\(self.pendingSuffix)"
    }

    /// Lines written at install time, before any crash: `key value` pairs.
    static func preamble(appVersion: String, build: String, osVersion: String) -> String {
        "app \(appVersion) (\(build))\nos \(osVersion)\n"
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> Record? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first == "fluidcrash 1" else { return nil }

        var record = Record()
        for rawLine in lines.dropFirst() {
            let line = String(rawLine)
            let parts = line.split(separator: " ", maxSplits: 1)
            let key = parts.first.map(String.init) ?? ""
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "pid": record.pid = Int32(value)
            case "signal": record.signal = Int32(value)
            case "code": record.code = Int32(value)
            case "address": record.address = self.hex(value)
            case "time": record.time = TimeInterval(value).map(Date.init(timeIntervalSince1970:))
            case "main": record.isMainThread = value == "1"
            case "thread": record.thread = UInt32(value)
            case "frame":
                if let frame = self.hex(value) { record.frames.append(frame) }
            case "image":
                if let image = self.parseImage(value) { record.images.append(image) }
            case "note": record.notes.append(value)
            case "end": record.isComplete = true
            case "exit": record.exitedCleanly = value == "clean"
            default: record.preamble[key] = value
            }
        }
        return record
    }

    private static func parseImage(_ value: String) -> Image? {
        let fields = value.split(separator: " ", maxSplits: 3)
        guard fields.count == 4,
              let start = self.hex(String(fields[0])),
              let end = self.hex(String(fields[1]))
        else { return nil }
        return Image(start: start, end: end, uuid: String(fields[2]), path: String(fields[3]))
    }

    private static func hex(_ value: String) -> UInt64? {
        guard value.hasPrefix("0x") else { return nil }
        return UInt64(value.dropFirst(2), radix: 16)
    }

    // MARK: - Formatting

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGSYS: return "SIGSYS"
        case SIGTRAP: return "SIGTRAP"
        default: return "signal \(signal)"
        }
    }

    /// The report as log lines, each starting with `[CRASH]`.
    static func format(_ record: Record) -> [String] {
        var header = "Previous run crashed"
        if let signal = record.signal {
            header += ": \(self.signalName(signal))"
            if let code = record.code { header += " code \(code)" }
            if let address = record.address { header += " at \(self.hexString(address))" }
        } else {
            header += " with an uncaught exception"
        }
        if let isMain = record.isMainThread {
            header += isMain ? " on the main thread" : " on a background thread"
            if let thread = record.thread { header += " (thread \(thread))" }
        }
        if let pid = record.pid { header += ", pid \(pid)" }
        if let time = record.time { header += ", \(ISO8601DateFormatter().string(from: time))" }
        if let app = record.preamble["app"] { header += ", app \(app)" }
        if let os = record.preamble["os"] { header += ", macOS \(os)" }

        var lines = [header]
        lines += record.notes.map { "Note: \($0)" }
        for (index, frame) in record.frames.enumerated() {
            let position = "#\(index)".padding(toLength: 4, withPad: " ", startingAt: 0)
            if let image = self.image(containing: frame, in: record.images) {
                lines.append("\(position) \(image.name) \(self.hexString(frame)) \(image.name) + \(frame - image.start)")
            } else {
                lines.append("\(position) ??? \(self.hexString(frame))")
            }
        }
        for image in record.images {
            let frames = record.frames.filter { $0 >= image.start && $0 < image.end }
            lines.append("Image \(image.name) \(self.hexString(image.start)) \(image.uuid) \(image.path)")
            lines.append("Symbolicate: atos -o '\(image.path)' -l \(self.hexString(image.start)) \(frames.map(self.hexString).joined(separator: " "))")
        }
        if record.signal != nil, !record.isComplete {
            lines.append("Record was cut short; frames after the last one listed are missing.")
        }
        return lines.map { "[CRASH] \($0)" }
    }

    private static func image(containing address: UInt64, in images: [Image]) -> Image? {
        images.first { address >= $0.start && address < $0.end }
    }

    private static func hexString(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    // MARK: - Files

    /// Call before this run installs its handler. Reads every pending record
    /// left by a run that has ended, returns the
    /// formatted reports (one array of lines per crash), saves each report under
    /// `Crashes/`, and deletes the pending files. `isAlive` decides whether a
    /// pid still belongs to a running process. `ended` hears about every run
    /// that crashed or stopped without quitting; clean quits are not passed on.
    static func collectPendingReports(
        in directory: URL,
        currentPID: Int32,
        fileManager: FileManager = .default,
        now: Date = Date(),
        isAlive: (Int32) -> Bool = CrashReportRecovery.processIsAlive,
        ended: (EndedRun) -> Void = { _ in }
    ) -> [[String]] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var reports: [[String]] = []
        for name in names.sorted() where name.hasPrefix(self.pendingPrefix) && name.hasSuffix(self.pendingSuffix) {
            let pidText = name.dropFirst(self.pendingPrefix.count).dropLast(self.pendingSuffix.count)
            // This run has not opened its own record yet, so a file named with
            // its pid belongs to an earlier run that had the same pid.
            guard let pid = Int32(pidText), pid == currentPID || !isAlive(pid) else { continue }
            let url = directory.appendingPathComponent(name)
            defer { try? fileManager.removeItem(at: url) }
            // Latin-1 accepts any bytes, so a path cut mid-character by the
            // handler's line limit does not cost the whole record.
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  let record = self.parse(text)
            else { continue }
            guard record.describesCrash else {
                if !record.exitedCleanly {
                    let written = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                    ended(EndedRun(pid: pid, crashed: false, time: written ?? now, app: record.preamble["app"]))
                }
                continue
            }
            ended(EndedRun(pid: pid, crashed: true, time: record.time ?? now, app: record.preamble["app"]))
            let lines = self.format(record)
            reports.append(lines)
            self.save(lines, pid: pid, time: record.time ?? now, in: directory, fileManager: fileManager)
        }
        return reports
    }

    private static func save(_ lines: [String], pid: Int32, time: Date, in directory: URL, fileManager: FileManager) {
        let crashes = directory.appendingPathComponent("Crashes", isDirectory: true)
        try? fileManager.createDirectory(at: crashes, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = crashes.appendingPathComponent("crash-\(formatter.string(from: time))-\(pid).txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let saved = (try? fileManager.contentsOfDirectory(atPath: crashes.path))?
            .filter { $0.hasPrefix("crash-") }
            .sorted() ?? []
        for old in saved.dropLast(self.maxSavedReports) {
            try? fileManager.removeItem(at: crashes.appendingPathComponent(old))
        }
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
