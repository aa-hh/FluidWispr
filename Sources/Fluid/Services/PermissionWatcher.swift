import AppKit
import AVFoundation
import Combine
import Foundation

/// Watches the microphone and Accessibility grants while the app runs, so the recording pill
/// can show its lock bubble when one is taken away and clear it when it comes back. Grants seen
/// in earlier runs count too: macOS quits the app when the microphone is turned off, so the next
/// launch is the first chance to show the lock.
@MainActor
final class PermissionWatcher: ObservableObject {
    nonisolated enum Permission: String, Hashable, CaseIterable {
        case microphone
        case accessibility
    }

    struct Change: Equatable {
        enum Kind: Equatable {
            case revoked
            case restored
        }

        let permission: Permission
        let kind: Kind
    }

    static let shared = PermissionWatcher()

    nonisolated static let grantedBeforeDefaultsKey = "PermissionWatcherGrantedBefore"

    /// Permissions that were granted earlier, in this run or a previous one, and are not granted now.
    @Published private(set) var revoked: Set<Permission> = []

    private let isGranted: @MainActor (Permission) -> Bool
    private let saveEverGranted: @MainActor (Set<Permission>) -> Void
    private var everGranted: Set<Permission>
    private var subscribers: [UUID: AsyncStream<Change>.Continuation] = [:]
    private var pollTask: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(
        isGranted: @escaping @MainActor (Permission) -> Bool = PermissionWatcher.systemGrant,
        everGranted: Set<Permission> = PermissionWatcher.loadEverGranted(),
        saveEverGranted: @escaping @MainActor (Set<Permission>) -> Void = PermissionWatcher.storeEverGranted
    ) {
        self.isGranted = isGranted
        self.everGranted = everGranted
        self.saveEverGranted = saveEverGranted
    }

    nonisolated static func loadEverGranted() -> Set<Permission> {
        let names = UserDefaults.standard.stringArray(forKey: Self.grantedBeforeDefaultsKey) ?? []
        return Set(names.compactMap(Permission.init(rawValue:)))
    }

    nonisolated static func storeEverGranted(_ permissions: Set<Permission>) {
        UserDefaults.standard.set(permissions.map(\.rawValue).sorted(), forKey: Self.grantedBeforeDefaultsKey)
    }

    static func systemGrant(_ permission: Permission) -> Bool {
        switch permission {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Each call returns its own stream of every later change.
    func changes() -> AsyncStream<Change> {
        let (stream, continuation) = AsyncStream.makeStream(of: Change.self)
        let key = UUID()
        self.subscribers[key] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in self?.subscribers[key] = nil }
        }
        return stream
    }

    /// Checks every 2 s, when the app becomes active, and when the system's Accessibility list changes.
    func start() {
        guard self.pollTask == nil else { return }
        self.refresh()
        self.pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.refresh()
            }
        }
        let refreshOnMain: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.observers = [
            (NotificationCenter.default, NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: refreshOnMain
            )),
            (DistributedNotificationCenter.default(), DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main, using: refreshOnMain
            )),
        ]
    }

    /// Reads both grants and publishes what changed. A permission counts as revoked only after it
    /// was seen granted, so a first launch before setup never reports one.
    func refresh() {
        for permission in Permission.allCases {
            if self.isGranted(permission) {
                if self.everGranted.insert(permission).inserted {
                    self.saveEverGranted(self.everGranted)
                }
                if self.revoked.contains(permission) {
                    self.revoked.remove(permission)
                    DebugLogger.shared.info("Permission restored: \(permission)", source: "PermissionWatcher")
                    self.publish(Change(permission: permission, kind: .restored))
                }
            } else if self.everGranted.contains(permission), !self.revoked.contains(permission) {
                self.revoked.insert(permission)
                DebugLogger.shared.warning("Permission revoked: \(permission)", source: "PermissionWatcher")
                self.publish(Change(permission: permission, kind: .revoked))
            }
        }
    }

    /// Opens the System Settings pane where the user turns this permission back on.
    func openSettings(for permission: Permission) {
        let pane = switch permission {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func publish(_ change: Change) {
        for continuation in self.subscribers.values {
            continuation.yield(change)
        }
    }
}
