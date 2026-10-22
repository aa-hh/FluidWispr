@testable import FluidVoice_Debug
import XCTest

final class OtherFluidAppWarningTests: XCTestCase {
    // Turns red if the release FluidVoice, a second FluidWispr build or this process stops being told apart from other apps.
    func testFindsOnlyOtherFluidCopies() {
        let instances = [
            OtherFluidAppWarning.Instance(processID: 10, bundleIdentifier: "com.FluidApp.app.debug", name: "FluidVoice Debug"),
            OtherFluidAppWarning.Instance(processID: 11, bundleIdentifier: "com.FluidApp.app", name: "FluidVoice"),
            OtherFluidAppWarning.Instance(processID: 12, bundleIdentifier: "com.FluidApp.app.debug", name: "FluidVoice Debug"),
            OtherFluidAppWarning.Instance(processID: 13, bundleIdentifier: "com.apple.Notes", name: "Notes"),
            OtherFluidAppWarning.Instance(processID: 14, bundleIdentifier: nil, name: nil),
        ]
        XCTAssertEqual(
            OtherFluidAppWarning.others(among: instances, currentProcessID: 10).map(\.processID),
            [11, 12]
        )
    }

    // Turns red if the warning stops naming the other app or stops saying what to do.
    func testMessageNamesTheOtherApp() {
        let message = OtherFluidAppWarning.message(
            for: .init(processID: 11, bundleIdentifier: "com.FluidApp.app", name: "FluidVoice")
        )
        XCTAssertEqual(message.title, "FluidVoice is also running")
        XCTAssertTrue(message.body.contains("Quit FluidVoice"))
        let unnamed = OtherFluidAppWarning.message(for: .init(processID: 11, bundleIdentifier: "com.FluidApp.app", name: nil))
        XCTAssertEqual(unnamed.title, "Another copy of FluidVoice is also running")
    }
}
