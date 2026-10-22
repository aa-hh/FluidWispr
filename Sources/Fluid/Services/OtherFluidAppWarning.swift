import AppKit

/// The release FluidVoice and every FluidWispr build listen for the same shortcut and write the
/// same Fluid.log, so a second copy running steals dictations and mixes its lines into our log.
/// Says so once per other copy, at launch and whenever one starts later.
enum OtherFluidAppWarning {
    struct Instance: Equatable {
        let processID: pid_t
        let bundleIdentifier: String?
        let name: String?
    }

    /// FluidVoice's release build and FluidWispr's Debug build. FluidWispr's own Release build
    /// keeps FluidVoice's identifier, so it is covered too.
    nonisolated static let bundleIdentifiers: Set<String> = ["com.FluidApp.app", "com.FluidApp.app.debug"]

    @MainActor private static var warnedProcessIDs: Set<pid_t> = []
    @MainActor private static var launchObserver: NSObjectProtocol?

    nonisolated static func others(among instances: [Instance], currentProcessID: pid_t) -> [Instance] {
        instances.filter { instance in
            guard instance.processID != currentProcessID,
                  let bundleIdentifier = instance.bundleIdentifier
            else { return false }
            return self.bundleIdentifiers.contains(bundleIdentifier)
        }
    }

    nonisolated static func message(for other: Instance) -> (title: String, body: String) {
        let name = other.name ?? "Another copy of FluidVoice"
        return (
            "\(name) is also running",
            "Both apps listen for the same shortcut, so dictations can go to the wrong one. Quit \(name) to keep FluidWispr reliable."
        )
    }

    @MainActor
    static func start() {
        guard !TestHost.isActive, self.launchObserver == nil else { return }
        self.warn(about: NSWorkspace.shared.runningApplications.map(Self.instance))
        self.launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.warn(about: [self.instance(app)])
            }
        }
    }

    private static func instance(_ app: NSRunningApplication) -> Instance {
        Instance(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, name: app.localizedName)
    }

    @MainActor
    private static func warn(about instances: [Instance]) {
        for other in self.others(among: instances, currentProcessID: ProcessInfo.processInfo.processIdentifier)
            where self.warnedProcessIDs.insert(other.processID).inserted
        {
            DebugLogger.shared.warning(
                "\(other.name ?? "unknown") (\(other.bundleIdentifier ?? "?"), pid \(other.processID)) is running too; it shares the shortcut and Fluid.log",
                source: "AppDelegate"
            )
            NotificationService.showOtherFluidAppRunning(message: self.message(for: other), processID: other.processID)
        }
    }
}
