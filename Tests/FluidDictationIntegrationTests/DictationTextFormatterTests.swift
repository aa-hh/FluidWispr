@testable import FluidVoice_Debug
import XCTest

@MainActor
final class DictationTextFormatterTests: XCTestCase {
    private let fluidVoiceEntry = SettingsStore.CustomDictionaryEntry(
        triggers: ["fluid boys"],
        replacement: "FluidVoice"
    )

    // Goes red if clean drops a step or runs them out of order: filler words, then the custom
    // dictionary, then spoken punctuation.
    func testCleanRemovesFillersAppliesDictionaryThenSpokenPunctuation() {
        let settings = DictationTextFormatter.Settings(
            removesFillerWords: true,
            fillerWords: ["um"],
            customDictionaryEntries: [self.fluidVoiceEntry],
            convertsSpokenPunctuation: true,
            punctuationRules: SettingsStore.defaultPunctuationDictionaryRules,
            spokenActionRules: SettingsStore.defaultSpokenFormattingActionRules
        )

        let cleaned = DictationTextFormatter.clean("um ship fluid boys today literal period", settings: settings)

        XCTAssertEqual(cleaned, "ship FluidVoice today.")
    }

    // Goes red if clean changes text while every one of its settings is off.
    func testCleanLeavesTextAloneWhenItsStepsAreOff() {
        let text = "um ship fluid boys today literal period"

        XCTAssertEqual(DictationTextFormatter.clean(text, settings: .init()), text)
    }

    // Goes red if the dictionary cache keeps serving old entries after the entries change
    // without a call to invalidateDictionaryCache.
    func testDictionaryUsesNewEntriesWithoutInvalidation() {
        let first = DictationTextFormatter.Settings(customDictionaryEntries: [self.fluidVoiceEntry])
        let second = DictationTextFormatter.Settings(customDictionaryEntries: [
            SettingsStore.CustomDictionaryEntry(triggers: ["fluid boys"], replacement: "FluidWispr"),
        ])

        XCTAssertEqual(DictationTextFormatter.applyCustomDictionary("try fluid boys", settings: first), "try FluidVoice")
        XCTAssertEqual(DictationTextFormatter.applyCustomDictionary("try fluid boys", settings: second), "try FluidWispr")
    }

    // Goes red if spoken formatting actions such as "new line" stop turning into a line break.
    func testCleanTurnsSpokenNewLineIntoLineBreak() {
        let settings = DictationTextFormatter.Settings(
            convertsSpokenPunctuation: true,
            spokenActionRules: SettingsStore.defaultSpokenFormattingActionRules
        )

        let cleaned = DictationTextFormatter.clean("line one literal new line line two", settings: settings)

        XCTAssertEqual(cleaned, "line one\nline two")
    }

    // Goes red if finalize drops a step or reorders literal formatting, GAAV and continuous
    // dictation. GAAV lowercases "Run", then smart caps raises it again after "Hello.".
    func testFinalizeRunsLiteralThenGAAVThenContinuousDictation() {
        let settings = DictationTextFormatter.Settings(
            formatsLiterals: true,
            gaavRemovesTrailingPeriod: true,
            gaavLowercasesFirstLetter: true,
            addsContinuousDictationSpacing: true,
            capitalizesFromContext: true
        )

        let finalized = DictationTextFormatter.finalize(
            "Run slash deploy.",
            precedingText: "Hello.",
            settings: settings
        )

        XCTAssertEqual(finalized, " Run /deploy ")
    }

    // Goes red if the terminal autocomplete step runs before continuous dictation adds its
    // trailing space, or stops dropping that space for a lone slash command in a coding app.
    func testFinalizeDropsTrailingSpaceAfterSlashCommandInCodingApp() {
        let settings = DictationTextFormatter.Settings(
            formatsLiterals: true,
            addsContinuousDictationSpacing: true
        )
        let claude = DictationTextFormatter.AppContext(appName: "Claude", bundleID: "com.anthropic.claudefordesktop")

        let inClaude = DictationTextFormatter.finalize("slash deploy", context: claude, precedingText: "", settings: settings)
        let elsewhere = DictationTextFormatter.finalize("slash deploy", precedingText: "", settings: settings)

        XCTAssertEqual(inClaude, "/deploy")
        XCTAssertEqual(elsewhere, "/deploy ")
    }

    // Goes red if context-aware capitalization stops lowercasing a segment that continues a
    // sentence, or spacing stops separating it from the text before the cursor.
    func testContinuousDictationLowercasesMidSentenceSegment() {
        let settings = DictationTextFormatter.Settings(
            addsContinuousDictationSpacing: true,
            capitalizesFromContext: true
        )

        let chained = DictationTextFormatter.applyContinuousDictationFormatting(
            "Next part",
            precedingText: "the first part",
            settings: settings
        )

        XCTAssertEqual(chained, " next part ")
    }
}
