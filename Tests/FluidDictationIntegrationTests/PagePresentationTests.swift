import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class PagePresentationTests: XCTestCase {
    private let destinations: [SidebarItem] = [
        .today, .yesterday, .earlier, .stats, .commandMode, .rewriteMode,
        .fileTranscription, .meetingTranscription, .customDictionary,
    ]

    // Turns red if a page title or its toolbar actions leak into Settings, reading the chrome
    // changes navigation, or Back stops returning to the page Settings was opened from.
    func testSettingsHidesPageChromeAndBackReturns() {
        var settings = SettingsNavigationState()
        XCTAssertEqual(AppPagePresentation(destination: nil, settings: settings).title, "Today", "A missing destination needs a useful title")
        XCTAssertEqual(Set(self.destinations.map(\.title)).count, self.destinations.count, "Each page needs a distinct title")
        for destination in self.destinations {
            let initial = settings
            let page = AppPagePresentation(destination: destination, settings: settings)
            XCTAssertEqual(page.title, destination.title)
            XCTAssertTrue(page.showsPageActions)
            XCTAssertEqual(settings, initial, "Reading chrome must not change navigation")
            for section in SettingsSection.allCases {
                settings.present(section, returningTo: destination)
                let snapshot = settings
                // A stale page underneath while Settings is visible.
                for hiddenDestination in self.destinations {
                    let hidden = AppPagePresentation(destination: hiddenDestination, settings: settings)
                    XCTAssertEqual(hidden.title, section.title, "Hidden content must not change the Settings title")
                    XCTAssertFalse(hidden.showsPageActions, "Hidden page actions must not leak into Settings")
                    XCTAssertEqual(settings, snapshot, "Presentation must not change the return destination")
                }
                XCTAssertEqual(settings.dismiss(), destination, "Back must return to the original page")
                XCTAssertEqual(AppPagePresentation(destination: destination, settings: settings), page, "Rapid Settings and Back must not keep stale chrome")
            }
        }
    }

    // Turns red if page toolbars stop showing by default, or hiding them in one view leaks
    // into another view's environment.
    func testPageToolbarVisibilityEnvironment() {
        var environment = EnvironmentValues()
        XCTAssertTrue(environment.fluidPageToolbarVisible, "Standalone page actions should show by default")
        environment.fluidPageToolbarVisible = false
        XCTAssertFalse(environment.fluidPageToolbarVisible, "Mounted hidden pages must hide their toolbar")
        XCTAssertTrue(EnvironmentValues().fluidPageToolbarVisible, "Toolbar visibility must not leak into another view")
    }

    // Turns red if a missing font name stops falling back to the system font, or the shipped
    // all-system typography stops matching Apple's fonts at the requested size and weight.
    func testTypographyFallsBackToSystemFonts() throws {
        XCTAssertNil(FluidTypography.resolvedName(for: .named("FluidVoice-Missing-Font")))
        XCTAssertNil(FluidTypography.resolvedName(for: .system))
        for design: Font.Design in [.default, .serif, .rounded, .monospaced] {
            XCTAssertNil(FluidTypography.name(for: design))
            XCTAssertEqual(
                Font.fluidSystem(size: 23, weight: .semibold, design: design),
                Font.system(size: 23, weight: .semibold, design: FluidTypography.systemDesign(for: design))
            )
            XCTAssertEqual(
                Font.fluidSystem(.caption, design: design),
                Font.system(.caption, design: FluidTypography.systemDesign(for: design))
            )
        }
        let native = NSFont.fluidSystemFont(ofSize: 18, weight: .semibold)
        let mono = NSFont.fluidMonospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(native.pointSize, 18)
        XCTAssertEqual(mono.pointSize, 13)
        if FluidTypography.systemDesign(for: .default) == .serif {
            let descriptor = try XCTUnwrap(NSFont.systemFont(ofSize: 18, weight: .semibold).fontDescriptor.withDesign(.serif))
            XCTAssertEqual(native, NSFont(descriptor: descriptor, size: 18))
        } else {
            XCTAssertEqual(native, NSFont.systemFont(ofSize: 18, weight: .semibold))
        }
        if FluidTypography.systemDesign(for: .monospaced) == .serif {
            let descriptor = try XCTUnwrap(NSFont.systemFont(ofSize: 13, weight: .regular).fontDescriptor.withDesign(.serif))
            XCTAssertEqual(mono, NSFont(descriptor: descriptor, size: 13))
        } else {
            XCTAssertEqual(mono, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        }
    }
}
