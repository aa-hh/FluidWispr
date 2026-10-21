import Darwin
import Foundation

/// Run by Tests/run_crash_handler_tests.sh with the directory of records the
/// crash harness left behind and the harness binary's path.
@main
enum CrashReportRecoveryTests {
    static func main() throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 3, "usage: tests <records directory> <harness path>")
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let harnessName = (arguments[2] as NSString).lastPathComponent

        self.parsesAndFormatsAWrittenRecord()
        try self.readsRecordsFromRealCrashes(in: directory, harnessName: harnessName)
        try self.collectsOnlyEndedRuns()
    }

    // Goes red if the record format and the parser drift apart, or the report
    // stops giving image offsets that atos can use.
    static func parsesAndFormatsAWrittenRecord() {
        let text = """
        fluidcrash 1
        app 1.6.11 (42)
        os Version 27.0
        pid 812
        signal 11
        code 2
        address 0x0000000000000010
        time 1792540800
        main 1
        thread 259
        frame 0x0000000100003f00
        frame 0x0000000190001234
        frame 0x0000000000000042
        image 0x0000000100000000 0x0000000100010000 00112233445566778899aabbccddeeff /Applications/FluidVoice.app/Contents/MacOS/FluidVoice
        end
        """
        guard let record = CrashReportRecovery.parse(text) else { preconditionFailure("record did not parse") }
        precondition(record.signal == SIGSEGV && record.code == 2 && record.address == 0x10)
        precondition(record.pid == 812 && record.isMainThread == true && record.thread == 259)
        precondition(record.frames == [0x1_0000_3F00, 0x1_9000_1234, 0x42])
        precondition(record.images.count == 1 && record.images[0].name == "FluidVoice")
        precondition(record.preamble["app"] == "1.6.11 (42)")
        precondition(record.isComplete && record.describesCrash)

        let lines = CrashReportRecovery.format(record)
        precondition(lines.allSatisfy { $0.hasPrefix("[CRASH] ") })
        precondition(lines[0].contains("SIGSEGV code 2 at 0x10 on the main thread"), lines[0])
        precondition(lines[0].contains("app 1.6.11 (42)"), lines[0])
        precondition(lines.contains("[CRASH] #0   FluidVoice 0x100003f00 FluidVoice + 16128"), "\(lines)")
        precondition(lines.contains("[CRASH] #2   ??? 0x42"), "\(lines)")
        precondition(lines.contains { $0.contains("atos -o '/Applications/FluidVoice.app/Contents/MacOS/FluidVoice' -l 0x100000000 0x100003f00") })

        // A record without "end" is reported as cut short instead of dropped.
        let cut = CrashReportRecovery.parse("fluidcrash 1\nsignal 6\nframe 0x10\n")
        precondition(cut?.isComplete == false)
        precondition(cut.map(CrashReportRecovery.format)?.last?.contains("cut short") == true)

        precondition(CrashReportRecovery.parse("not a record") == nil)
        precondition(CrashReportRecovery.parse("fluidcrash 1\napp x (1)\npid 3\n")?.describesCrash == false)
    }

    // Goes red if the C handler stops writing a record from inside a real
    // signal: no signal line, no frames walked, the harness image missing, or
    // a crash on a background thread or a stack overflow losing its record.
    static func readsRecordsFromRealCrashes(in directory: URL, harnessName: String) throws {
        let manifest = try String(contentsOf: directory.appendingPathComponent("manifest.txt"), encoding: .utf8)
        var records: [String: CrashReportRecovery.Record] = [:]
        for line in manifest.split(separator: "\n") {
            let fields = line.split(separator: " ")
            let url = directory.appendingPathComponent(CrashReportRecovery.pendingFileName(pid: Int32(fields[1]) ?? -1))
            let text = try String(contentsOf: url, encoding: .utf8)
            records[String(fields[0])] = CrashReportRecovery.parse(text)
        }

        guard let segv = records["segv"] else { preconditionFailure("segv record missing") }
        precondition(segv.signal == SIGSEGV && segv.address == 0 && segv.isMainThread == true, "\(segv)")
        precondition(segv.isComplete, "segv record not finished")
        precondition(segv.preamble["app"] == "harness (1)" && segv.pid != nil)
        guard let harness = segv.images.first(where: { $0.name == harnessName }) else {
            preconditionFailure("harness image missing from \(segv.images)")
        }
        // crash_level3, crash_level2, crash_level1 and main all live in the harness.
        let harnessFrames = segv.frames.filter { $0 >= harness.start && $0 < harness.end }
        precondition(harnessFrames.count >= 4, "walked only \(segv.frames.count) frames: \(segv.frames)")
        precondition(harness.uuid.count == 32 && harness.uuid != String(repeating: "0", count: 32))

        precondition(records["abort"]?.signal == SIGABRT && records["abort"]?.isComplete == true)
        let overflow = records["overflow"]?.signal
        precondition(overflow == SIGSEGV || overflow == SIGBUS, "stack overflow not recorded")
        precondition(records["thread"]?.signal == SIGSEGV && records["thread"]?.isMainThread == false)
        precondition(records["note"]?.notes == ["Uncaught exception Test: line one line two"])
        precondition(records["clean"]?.describesCrash == false)
    }

    // Goes red if launch recovery reports a clean exit as a crash, reads the
    // file of a run that is still going, or leaves pending files behind.
    static func collectsOnlyEndedRuns() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("crash-recovery-\(UUID().uuidString)") // isolation-ok
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let crashed = "fluidcrash 1\npid 101\nsignal 6\ntime 1792540800\nend\n"
        let clean = "fluidcrash 1\npid 102\n"
        let running = "fluidcrash 1\npid 103\nsignal 6\nend\n"
        let current = "fluidcrash 1\npid 104\nsignal 6\nend\n"
        for (pid, text) in [(101, crashed), (102, clean), (103, running), (104, current)] {
            try text.write(to: directory.appendingPathComponent(CrashReportRecovery.pendingFileName(pid: Int32(pid))), atomically: true, encoding: .utf8)
        }

        let reports = CrashReportRecovery.collectPendingReports(in: directory, currentPID: 104, isAlive: { $0 == 103 })
        precondition(reports.count == 1 && reports[0][0].contains("SIGABRT") && reports[0][0].contains("pid 101"), "\(reports)")

        let left = try fileManager.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(CrashReportRecovery.pendingPrefix) }.sorted()
        precondition(left == [CrashReportRecovery.pendingFileName(pid: 103), CrashReportRecovery.pendingFileName(pid: 104)], "\(left)")
        let saved = try fileManager.contentsOfDirectory(atPath: directory.appendingPathComponent("Crashes").path)
        precondition(saved == ["crash-20261021-000000-101.txt"], "\(saved)")
    }
}
