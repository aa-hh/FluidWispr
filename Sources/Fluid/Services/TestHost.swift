import AppKit
import ObjectiveC

/// App-hosted XCTest runs launch the full app. Nothing from a test run may appear on screen:
/// no Dock icon, no main window, no overlays or panels opened by app code or by tests.
enum TestHost {
    static let isActive = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Call before any window exists. Every window keeps the alpha its code asks for, so tests
    /// can still assert it, but the window server is only ever given 0.
    static func hideUI() {
        _ = self.installWindowHiding
        NSApp.setActivationPolicy(.prohibited)
        // AppKit can order a window in without going through the methods swapped below (the main
        // window appeared this way when a test ordered its own window front). Catch those once per
        // event loop pass.
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where !window.testHostIsHidden {
                    window.testHostHide()
                }
            }
        }
    }

    private static let installWindowHiding: Void = {
        let pairs: [(Selector, Selector)] = [
            (#selector(setter: NSWindow.alphaValue), #selector(NSWindow.testHost_setAlphaValue(_:))),
            (#selector(getter: NSWindow.alphaValue), #selector(NSWindow.testHost_alphaValue)),
            (#selector(NSWindow.orderFront(_:)), #selector(NSWindow.testHost_orderFront(_:))),
            (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.testHost_orderFrontRegardless)),
            (#selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.testHost_makeKeyAndOrderFront(_:))),
            (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.testHost_orderWindow(_:relativeTo:))),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getInstanceMethod(NSWindow.self, original),
                  let b = class_getInstanceMethod(NSWindow.self, replacement)
            else { continue }
            method_exchangeImplementations(a, b)
        }
    }()
}

extension NSWindow {
    private static var testHostAlphaKey: UInt8 = 0

    // After the swap, calling a testHost_ method from inside itself runs the original AppKit one.

    @objc func testHost_setAlphaValue(_ value: CGFloat) {
        objc_setAssociatedObject(self, &Self.testHostAlphaKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // The open and close animations draw the window at full opacity whatever its alpha.
        self.animationBehavior = .none
        self.testHost_setAlphaValue(0)
    }

    @objc func testHost_alphaValue() -> CGFloat {
        objc_getAssociatedObject(self, &Self.testHostAlphaKey) as? CGFloat ?? 1
    }

    var testHostIsHidden: Bool {
        objc_getAssociatedObject(self, &Self.testHostAlphaKey) != nil
    }

    /// New windows start at alpha 1 without calling the setter, so re-set it before ordering in.
    func testHostHide() {
        self.alphaValue = self.alphaValue
    }

    /// A `defer: true` window gets its window server window only when ordered in, and an alpha set
    /// before that does not reach it. Send a changed value, then 0, so AppKit does not skip the call.
    private func testHostHideAfterOrderingIn() {
        self.testHost_setAlphaValue(0.001)
        self.testHost_setAlphaValue(0)
    }

    @objc func testHost_orderFront(_ sender: Any?) {
        self.testHostHide()
        self.testHost_orderFront(sender)
        self.testHostHideAfterOrderingIn()
    }

    @objc func testHost_orderFrontRegardless() {
        self.testHostHide()
        self.testHost_orderFrontRegardless()
        self.testHostHideAfterOrderingIn()
    }

    @objc func testHost_makeKeyAndOrderFront(_ sender: Any?) {
        self.testHostHide()
        self.testHost_makeKeyAndOrderFront(sender)
        self.testHostHideAfterOrderingIn()
    }

    @objc func testHost_orderWindow(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place != .out else { return self.testHost_orderWindow(place, relativeTo: otherWin) }
        self.testHostHide()
        self.testHost_orderWindow(place, relativeTo: otherWin)
        self.testHostHideAfterOrderingIn()
    }
}
