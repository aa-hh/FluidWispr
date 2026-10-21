@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The saved dictionary and pronunciation generation the save reads. Profile writes check it
/// from the store's actor, so it is read from Sendable closures.
private nonisolated final class DictionaryFixture: @unchecked Sendable {
    var entries: [SettingsStore.CustomDictionaryEntry]
    var generation: String? = "first"

    init(_ entries: [SettingsStore.CustomDictionaryEntry]) {
        self.entries = entries
    }
}

/// Stands in for the pronunciation store. It can park before or after the write so a test
/// can change the dictionary, the generation, or which save is current at that point.
@MainActor
private final class ProfileStoreFixture {
    var holdBeforeWrite = false
    var holdAfterWrite = false
    var fails = false
    var calls = 0
    var writes: [UUID] = []
    var held: CheckedContinuation<Void, Never>?

    func write(_ entryID: UUID, canPersist: @Sendable () -> Bool) async throws {
        self.calls += 1
        guard canPersist() else { throw CancellationError() }
        if self.holdBeforeWrite { await withCheckedContinuation { self.held = $0 } }
        guard canPersist(), !self.fails else { throw CancellationError() }
        self.writes.append(entryID)
        if self.holdAfterWrite { await withCheckedContinuation { self.held = $0 } }
    }
}

@MainActor
final class DictionaryTrainingSaveTests: XCTestCase {
    private typealias Entry = SettingsStore.CustomDictionaryEntry

    private var dictionary = DictionaryFixture([])
    private var store = ProfileStoreFixture()
    private var isCurrent = true

    override func setUp() async throws {
        try await super.setUp()
        self.dictionary = DictionaryFixture(Self.baseline())
        self.store = ProfileStoreFixture()
        self.isCurrent = true
    }

    private static func baseline() -> [Entry] {
        [Entry(triggers: ["fluid voice"], replacement: "FluidVoice"), Entry(triggers: ["other"], replacement: "Other")]
    }

    private static let voiceExamples = Array(
        repeating: PronunciationEnrollmentCapture(values: [0.1], sourceFrameCount: 1, modelKey: "fixture"),
        count: 3
    )

    private func makeSave(
        savePronunciation: Bool = true,
        accepted: [String]? = nil,
        lookupAvailable: Bool = true
    ) -> DictionaryTrainingSave {
        let dictionary = self.dictionary
        let store = self.store
        return DictionaryTrainingSave(
            replacement: "FluidVoice",
            variants: ["fluid boys"],
            enrollments: savePronunciation ? Self.voiceExamples : [],
            savePronunciation: savePronunciation,
            filterAliases: { variants in
                VoiceTrainingAliasFilter.Result(accepted: accepted ?? variants, rejected: [], lookupAvailable: lookupAvailable)
            },
            currentEntries: { dictionary.entries },
            pronunciationGeneration: { dictionary.generation },
            writeProfile: { entryID, _, _, _, canPersist in
                try await store.write(entryID, canPersist: canPersist)
            }
        )
    }

    private func start(_ save: DictionaryTrainingSave) -> Task<DictionaryTrainingSave.Outcome, Never> {
        Task { await save.run(isCurrent: { self.isCurrent }) }
    }

    private func waitForHold() async {
        for _ in 0..<100_000 where self.store.held == nil {
            await Task.yield()
        }
        XCTAssertNotNil(self.store.held, "The save never reached the profile store")
    }

    private func savedEntries(_ outcome: DictionaryTrainingSave.Outcome) -> [Entry]? {
        if case let .saved(entries) = outcome { return entries }
        return nil
    }

    // Turns red if the voice profile and the text rule stop sharing an id, or retraining an existing word gives it a new id.
    func testProfileAndRuleShareTheEntryID() async throws {
        for existing in [true, false] {
            self.dictionary.entries = existing ? Self.baseline() : []
            self.store.writes = []
            let original = self.dictionary.entries
            let entries = try XCTUnwrap(self.savedEntries(await self.makeSave().run(isCurrent: { true })))
            let saved = try XCTUnwrap(entries.first { $0.replacement == "FluidVoice" })
            XCTAssertEqual(self.store.writes, [saved.id])
            if existing { XCTAssertEqual(saved.id, original[0].id) }
        }
    }

    // Turns red if an edit, deletion, or import made while the profile is being written gets overwritten by the save.
    func testDictionaryEditDuringProfileWriteIsKept() async {
        for mutation in 0..<6 {
            self.dictionary.entries = Self.baseline()
            self.store = ProfileStoreFixture()
            self.store.holdBeforeWrite = true
            let task = self.start(self.makeSave())
            await self.waitForHold()
            var latest = self.dictionary.entries
            switch mutation {
            case 0: latest.append(Entry(triggers: ["new"], replacement: "New"))
            case 1: latest.removeLast()
            case 2: latest[1].triggers = ["updated"]
            case 3: latest = [Entry(triggers: ["imported"], replacement: "Imported")]
            case 4: latest.removeFirst()
            default: latest[0].replacement = "Edited"
            }
            self.dictionary.entries = latest
            self.store.held?.resume()
            let outcome = await task.value

            XCTAssertEqual(outcome, .failed("Your dictionary changed while saving. Try again."), "mutation \(mutation)")
            XCTAssertTrue(self.store.writes.isEmpty, "mutation \(mutation)")
        }
    }

    // Turns red if an edit made after the profile write but before the save resumes is overwritten.
    func testDictionaryEditAfterProfileWriteIsKept() async {
        self.store.holdAfterWrite = true
        let task = self.start(self.makeSave())
        await self.waitForHold()
        self.dictionary.entries = [Self.baseline()[1]]
        self.store.held?.resume()
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed("Your dictionary changed while saving. Try again."))
    }

    // Turns red if a save that a newer save replaced, or that was cancelled, still reports success or failure.
    func testReplacedSaveTouchesNothing() async {
        for failsInStore in [true, false] {
            self.store = ProfileStoreFixture()
            self.store.fails = failsInStore
            if failsInStore { self.store.holdBeforeWrite = true } else { self.store.holdAfterWrite = true }
            self.isCurrent = true
            let task = self.start(self.makeSave())
            await self.waitForHold()
            self.isCurrent = false
            self.store.held?.resume()
            let outcome = await task.value
            XCTAssertEqual(outcome, .superseded, "fails in store: \(failsInStore)")
        }
    }

    // Turns red if a profile store failure stops showing its own message.
    func testStoreFailureIsShown() async {
        self.store.fails = true
        let outcome = await self.makeSave().run(isCurrent: { true })
        XCTAssertEqual(outcome, .failed("Couldn't save the voice profile. Try again."))
    }

    // Turns red if spelling-only training touches the profile store, or stops keeping the word's id and the other rules.
    func testSpellingOnlySaveSkipsTheProfileStore() async throws {
        self.store.fails = true
        let original = self.dictionary.entries
        let entries = try XCTUnwrap(self.savedEntries(await self.makeSave(savePronunciation: false).run(isCurrent: { true })))
        XCTAssertEqual(self.store.calls, 0)
        XCTAssertEqual(entries.first?.id, original.first?.id)
        XCTAssertEqual(entries.last, original.last)
    }

    // Turns red if a save with no usable spellings and no voice profile adds a rule, or loses the reason it failed.
    func testRejectedSpellingsWithoutVoiceFailWithTheirReason() async {
        for available in [true, false] {
            let outcome = await self.makeSave(savePronunciation: false, accepted: [], lookupAvailable: available).run(isCurrent: { true })
            let expected = available
                ? "These recordings contain everyday words. Try again, or add a replacement manually."
                : "Couldn't check these words. Try saving again, or add a replacement manually."
            XCTAssertEqual(outcome, .failed(expected))
        }
        XCTAssertEqual(self.store.calls, 0)
    }

    // Turns red if turning pronunciation matching off and on during the profile write still saves the old voice examples.
    func testNewPronunciationGenerationRefusesTheWrite() async {
        self.store.holdBeforeWrite = true
        let task = self.start(self.makeSave())
        await self.waitForHold()
        self.dictionary.generation = "second"
        self.store.held?.resume()
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed("Couldn't save the voice profile. Try again."))
        XCTAssertTrue(self.store.writes.isEmpty)
    }

    // Turns red if fewer than three spellings can be saved, or fewer than three voice examples count as a finished voice profile.
    func testSaveNeedsThreeSpellingsAndThreeVoiceExamplesForAProfile() {
        for voice in 0..<3 {
            XCTAssertFalse(DictionaryTrainingProgress(spellingCount: 3, pronunciationCount: voice, pronunciationEnabled: true).pronunciationReady)
        }
        XCTAssertTrue(DictionaryTrainingProgress(spellingCount: 3, pronunciationCount: 3, pronunciationEnabled: true).pronunciationReady)
        let twoSpellings = DictionaryTrainingProgress(spellingCount: 2, pronunciationCount: 3, pronunciationEnabled: true)
        XCTAssertFalse(twoSpellings.canSave(replacement: "FluidVoice", hasVariants: true, isBusy: false))
        let ready = DictionaryTrainingProgress(spellingCount: 3, pronunciationCount: 0, pronunciationEnabled: true)
        XCTAssertTrue(ready.canSave(replacement: "FluidVoice", hasVariants: true, isBusy: false))
        XCTAssertFalse(ready.canSave(replacement: "FluidVoice", hasVariants: false, isBusy: false))
        XCTAssertFalse(ready.canSave(replacement: "FluidVoice", hasVariants: true, isBusy: true))
        XCTAssertFalse(ready.canSave(replacement: "", hasVariants: true, isBusy: false))
    }
}
