import Foundation

/// Standalone checks of the Private AI settings controller and view source. No app launch, defaults, keys or models.
/// The session, carousel and update transaction checks live in PrivateAISettingsSessionTests (XCTest).
@main
struct PrivateAISettingsBoundaryTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        await PrivateAIControllerChecks.run(check: check)
        let section = try String(contentsOfFile: "Sources/Fluid/UI/AISettings/FluidIntelligenceLiveSection.swift", encoding: .utf8)
        check(section.contains("Label(\"Active\", systemImage: \"checkmark.circle.fill\")"), "Active is informational, not a disabled action")
        check(!section.contains("onReady: self.makePrimary"), "Model activation must not silently assign the main shortcut")
        check(!section.contains("modelPanel") && !section.contains("Model details…"), "Model menu never opens a duplicate management sheet")
        check(!section.contains("Reset verification") && !section.contains("Troubleshooting"), "Model menu exposes no reset or troubleshooting submenu")
        check(section.contains(".alert(\"Delete downloaded model?\""), "Deletion requires explicit confirmation")
        check(section.components(separatedBy: "Open models folder").count == 2, "Shared Manage sheet owns the only folder action")
        check(section.contains("if files?.installed == false, let bytes"), "Download size is visible before installation")
        let card = try String(contentsOfFile: "Sources/Fluid/UI/AISettings/FluidModelShowcaseCard.swift", encoding: .utf8)
        check(!card.contains(".popover("), "Model information stays inside its card")
        check(card.contains("Button { self.showsInfo.toggle() }"), "Information toggles only local presentation state")
        check(
            card.contains("self.reduceMotion ? nil") && card.contains("ZStack(alignment: .topLeading)"),
            "Inline information respects reduced motion and shares stable content bounds"
        )
        print("Passed \(checks) FI boundary/controller assertions")
    }
}
