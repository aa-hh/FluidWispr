@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class DictionaryLearningTests: XCTestCase {
    private let experimentKeys = [
        "DictionarySharedFeatureMatcherEnabled",
        "DictionaryTemporalMatcherEnabled",
        "DictionaryNegativeLearningEnabled",
        "DictionaryNegativeComparisonEnabled",
        "DictionaryPronunciationGeneration",
    ]
    private var savedPreferences: [Any?] = []
    private var folders: [URL] = []

    override func setUp() {
        super.setUp()
        // The experiment switches only read the app's standard defaults, so save and restore them.
        self.savedPreferences = self.experimentKeys.map { UserDefaults.standard.object(forKey: $0) } // isolation-ok: restored in tearDown
    }

    override func tearDown() {
        for (key, value) in zip(self.experimentKeys, self.savedPreferences) {
            UserDefaults.standard.set(value, forKey: key) // isolation-ok: restores the saved value
        }
        for folder in self.folders {
            try? FileManager.default.removeItem(at: folder)
        }
        self.folders = []
        super.tearDown()
    }

    private func candidate(_ before: String, _ after: String) -> AutomaticDictionaryCorrectionCandidate? {
        let range = NSRange(location: 0, length: (before as NSString).length)
        guard let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after) else { return nil }
        let atEnd = AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(change, after: after, insertedRange: range)
        guard AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(change, insertedRange: range, allowsInsertionAtEnd: atEnd) else { return nil }
        return AutomaticDictionaryCorrectionDetector.candidate(before: before, after: after, insertedRange: range, allowsInsertionAtEnd: true)
    }

    // Turns red if plurals, verb endings, added or removed words, punctuation-only edits or
    // word splits get learned as dictionary corrections.
    func testCorrectionDetectorRejectsGrammarAndPhraseEdits() {
        let rejected = [
            ("cat", "cats"), ("cats", "cat"), ("box", "boxes"), ("party", "parties"),
            ("file", "file's"), ("file", "file’s"), ("walk", "walked"), ("walk", "walking"),
            ("move", "moving"), ("move", "moved"), ("The cat sits", "The cats sits"),
            ("I use tools", "I use better tools"), ("I use tools daily", "I use tools often daily"),
            ("cat", "black cat"), ("cat", "cat today"), ("black cat", "cat"),
            ("hello", "hello"), ("hello", "hello!"), ("hello", ""),
            ("use foo now", "use bar baz now"), ("use foo now", "use bar,baz now"),
            ("use foo now", "use bar.baz now"), ("use foo now", "use bar/baz now"),
            ("I met foo bar today", "I met baz today"),
        ]
        for (before, after) in rejected {
            XCTAssertNil(self.candidate(before, after), "Reject \(before) → \(after)")
        }
    }

    // Turns red if a one-word spelling repair (names, casing, accents, hyphens, other scripts)
    // stops becoming a candidate, or sentence punctuation hides it.
    func testCorrectionDetectorKeepsSpellingRepairs() {
        let accepted = [
            ("Jon", "John"), ("Barat", "Barath"), ("Barad", "Barath"),
            ("Dflash", "DFlash"), ("manimekali", "Manimekalai"), ("Jhon", "John"),
            ("O'Neal", "O'Neill"), ("Anne-Mari", "Anne-Marie"), ("Jose", "José"),
            ("Jo", "Jos"), ("東京", "京都"), ("foo", "Kubernetes"), ("helllo", "hello"),
        ]
        for (before, after) in accepted {
            let result = self.candidate(before, after)
            XCTAssertEqual(result?.heardText, before, "Keep \(before) → \(after)")
            XCTAssertEqual(result?.correctedText, after, "Keep \(before) → \(after)")
        }
        let punctuated = self.candidate("I met Barat.", "I met Barath.")
        XCTAssertEqual(punctuated?.heardText, "Barat", "Sentence punctuation")
        XCTAssertEqual(punctuated?.correctedText, "Barath", "Sentence punctuation")
    }

    // Turns red if an edit outside the dictated text counts, a phrase typed one key at a time
    // becomes a word correction at any step, or undoing back to the original still counts.
    func testCorrectionDetectorFollowsTypedEdits() {
        let before = "Title: I met Barat"
        XCTAssertNil(
            AutomaticDictionaryCorrectionDetector.candidate(before: before, after: "Heading: I met Barat", insertedRange: (before as NSString).range(of: "I met Barat")),
            "Outside insertion"
        )
        // Evaluate the accumulated edit, as the observer does after rapid keystrokes.
        for intermediate in ["better t", "better to", "better too", "better tool", "better tools"] {
            XCTAssertNil(self.candidate("I use tools", "I use " + intermediate), "Typed phrase never becomes a word correction")
        }
        XCTAssertNotNil(self.candidate("I met Barat", "I met Barath"), "Typed spelling repair")
        XCTAssertNil(self.candidate("I met Barat", "I met Barat"), "Undo returns to original")
    }

    // Turns red if switching the shared matcher off leaves older matching or negative learning
    // on, switching it on depends on the older preference, or a quick off and on keeps stale work.
    func testMatcherExperimentSwitch() {
        for key in self.experimentKeys {
            UserDefaults.standard.set(true, forKey: key) // isolation-ok: restored in tearDown
        }
        UserDefaults.standard.set(false, forKey: self.experimentKeys[0]) // isolation-ok: restored in tearDown
        XCTAssertFalse(DictionaryMatcherExperiment.positiveEnabled, "Off overrides legacy matching preferences")
        XCTAssertFalse(DictionaryMatcherExperiment.needsFrames, "Off overrides legacy matching preferences")
        XCTAssertFalse(DictionaryMatcherExperiment.collectNegatives, "Off disables negative audio learning")
        XCTAssertFalse(DictionaryMatcherExperiment.compareNegatives, "Off disables negative comparisons")
        UserDefaults.standard.set(true, forKey: self.experimentKeys[0]) // isolation-ok: restored in tearDown
        UserDefaults.standard.set(false, forKey: self.experimentKeys[1]) // isolation-ok: restored in tearDown
        XCTAssertTrue(DictionaryMatcherExperiment.positiveEnabled, "On selects fast matching independently of legacy preference")
        XCTAssertTrue(DictionaryMatcherExperiment.needsFrames, "On selects fast matching independently of legacy preference")
        let beforeToggle = DictionaryMatcherExperiment.generation
        DictionaryMatcherExperiment.setEnabled(false)
        DictionaryMatcherExperiment.setEnabled(true)
        XCTAssertNotEqual(DictionaryMatcherExperiment.generation, beforeToggle, "Rapid off-on invalidates earlier pronunciation work")
    }

    private let positive = DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1, 0, 1, 0])
    private let negative = DictionaryMatchFrames(hiddenSize: 2, values: [0, 1, 0, 1, 0, 1])

    // Turns red if the matcher accepts a different sound, loosens its thresholds for isolated or
    // short recordings, accepts with missing or invalid frames, or lets one correction veto a match.
    func testExperimentalMatcherScoring() async {
        let refs = [self.positive, self.positive, self.positive]
        XCTAssertEqual(DictionaryExperimentalMatcher.positive(query: self.positive, references: refs)?.accepted, true, "Accept identical positives")
        XCTAssertEqual(DictionaryExperimentalMatcher.positive(query: self.negative, references: refs)?.accepted, false, "Reject a different sequence")
        let contextual = DictionaryMatchFrames(hiddenSize: 2, values: [0.6, 0.8, 0.6, 0.8, 0.6, 0.8])
        let sharedDecision = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextual, references: refs)
        XCTAssertEqual(sharedDecision?.accepted, true, "Shared sentence features use their calibrated operating point")
        XCTAssertEqual(DictionaryExperimentalMatcher.positive(query: contextual, references: refs)?.accepted, false, "Shared thresholds must not loosen isolated-query scoring")
        let weakContext = DictionaryMatchFrames(hiddenSize: 2, values: [0.58, 0.814_616, 0.58, 0.814_616, 0.58, 0.814_616])
        let weakShared = await DictionaryExperimentalMatcher.compareSharedFeatures(query: weakContext, references: refs)
        XCTAssertEqual(weakShared?.accepted, false, "Shared matching still rejects weak overall similarity")
        let missingShared = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextual, references: [self.positive])
        XCTAssertNil(missingShared, "Missing reference features must not accept a candidate")
        let contextualChunk = DictionaryMatchFrames(hiddenSize: 2, values: [0.56, 0.828_493, 0.56, 0.828_493, 0.56, 0.828_493])
        let chunkDecision = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextualChunk, references: refs, chunked: true)
        let shortDecision = await DictionaryExperimentalMatcher.compareSharedFeatures(query: contextualChunk, references: refs)
        XCTAssertEqual(chunkDecision?.accepted, true, "Long-window calibration accepts")
        XCTAssertEqual(shortDecision?.accepted, false, "Long-window calibration must not loosen the short-recording operating point")
        XCTAssertNil(DictionaryExperimentalMatcher.positive(query: self.positive, references: [self.positive]), "Missing enrollments fallback")
        XCTAssertNil(DictionaryExperimentalMatcher.metrics(reference: self.positive, query: .init(hiddenSize: 2, values: [.nan, 0])), "Reject nonfinite values")
        XCTAssertFalse(DictionaryMatchFrames(hiddenSize: 2, values: []).isValid, "Reject empty frames")
        XCTAssertFalse(DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1]).isValid, "Reject inconsistent dimensions")
        XCTAssertFalse(DictionaryMatchFrames(hiddenSize: 1025, values: [Float](repeating: 1, count: 1025)).isValid, "Bound hidden size")
        XCTAssertFalse(DictionaryMatchFrames(hiddenSize: 1, values: [Float](repeating: 1, count: 193)).isValid, "Bound duration")
        XCTAssertTrue(DictionaryExperimentalMatcher.negativeAllows(query: self.positive, references: refs, negatives: []), "Empty bank is inert")
        XCTAssertTrue(DictionaryExperimentalMatcher.negativeAllows(query: self.positive, references: refs, negatives: [self.positive]), "One correction cannot veto equally strong positives")
        XCTAssertFalse(DictionaryExperimentalMatcher.negativeAllows(query: self.negative, references: refs, negatives: [self.negative]), "Close negative with margin vetoes")
        XCTAssertTrue(DictionaryExperimentalMatcher.negativeAllows(query: self.positive, references: refs, negatives: [self.negative]), "Unrelated negative is inert")
    }

    private func evidence(entryID: UUID) -> DictionaryAcousticEvidence {
        DictionaryAcousticEvidence(
            id: UUID(),
            entryID: entryID,
            label: "Manimekalai",
            profileKey: "profile",
            modelKey: "parakeet-v2",
            sourceWordRange: 1..<2,
            frames: self.positive
        )
    }

    private func context(
        _ text: String = "Hello Manimekalai today",
        events: [DictionaryAcousticEvidence],
        date: Date,
        selected: String = "Manimekalai"
    ) throws -> DictionaryLearningCorrectionContext {
        let alignment = DictionaryLearningAlignment(
            modelKey: "parakeet-v2",
            words: [.init(text: "raw", start: 0, end: 1)],
            acousticOutput: text,
            acousticEvidence: events
        )
        let recording = try XCTUnwrap(DictionaryLearningRecording(alignment: alignment, samples: [0.1, 0.1], now: date))
        return .init(recording: recording, deliveredTextBeforeEdit: text, selectedUTF16Range: (text as NSString).range(of: selected))
    }

    // Turns red if a negative example is taken from anything but a clean one-word swap of the
    // exact accepted occurrence in a fresh, unchanged recording, or it keeps the full audio.
    func testNegativeEvidenceResolver() throws {
        let now = Date()
        let evidence = self.evidence(entryID: UUID())
        let base = try self.context(events: [evidence], date: now)
        let correction = try XCTUnwrap(DictionaryNegativeEvidenceResolver.resolve(context: base, heard: "Manimekalai", corrected: "another", now: now))
        XCTAssertEqual(correction.evidence.id, evidence.id, "Keep exact accepted occurrence")
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: base, heard: "Manimekalai", corrected: "better Manimekalai", now: now), "Added words never become negatives")
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: base, heard: "Manimekalai", corrected: "Manimekalais", now: now), "Plural edits never become negatives")
        let featureOnly = try XCTUnwrap(DictionaryLearningRecording(alignment: base.recording.alignment, samples: [0.1], retainAudio: false, now: now))
        XCTAssertTrue(featureOnly.samples.isEmpty, "Negative-only observation does not retain full PCM")
        XCTAssertEqual(featureOnly.alignment.acousticEvidence.count, 1)
        let punctuated = try self.context("Hello Manimekalai.", events: [evidence], date: now)
        let punctuationContext = DictionaryLearningCorrectionContext(
            recording: punctuated.recording,
            deliveredTextBeforeEdit: punctuated.deliveredTextBeforeEdit,
            selectedUTF16Range: NSRange(location: 6, length: 12)
        )
        XCTAssertNotNil(
            DictionaryNegativeEvidenceResolver.resolve(context: punctuationContext, heard: "Manimekalai", corrected: "another", now: now),
            "Sentence punctuation still maps to the exact occurrence"
        )
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: base, heard: "Manimekalai", corrected: "MANIMEKALAI!", now: now), "Case and punctuation are not negative examples")
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: base, heard: "Manimekalai", corrected: "", now: now), "Deletion is ambiguous")
        let noEvidence = try self.context(events: [], date: now)
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: noEvidence, heard: "Manimekalai", corrected: "other", now: now), "No acoustic acceptance means no negative")
        let repeated = try self.context("Manimekalai and Manimekalai", events: [evidence], date: now)
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: repeated, heard: "Manimekalai", corrected: "other", now: now), "Repeated names are ambiguous")
        let partial = try self.context(events: [evidence], date: now, selected: "Mani")
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: partial, heard: "Mani", corrected: "other", now: now), "Partial label edit is ambiguous")
        let expired = try self.context(events: [evidence], date: now.addingTimeInterval(-121))
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: expired, heard: "Manimekalai", corrected: "other", now: now), "Expired recording rejected")
        let changed = DictionaryLearningCorrectionContext(
            recording: base.recording,
            deliveredTextBeforeEdit: "Hello Manimekalai tomorrow",
            selectedUTF16Range: NSRange(location: 6, length: 11)
        )
        XCTAssertNil(DictionaryNegativeEvidenceResolver.resolve(context: changed, heard: "Manimekalai", corrected: "other", now: now), "AI rewriting invalidates mapping")
    }

    // Turns red if the negative example store saves duplicates, mixes models or retrained words,
    // grows past its per-word or total limits, saves when expired, disabled or cleared, or lets a
    // corrupt file veto matches.
    func testNegativeExampleStore() async throws {
        let now = Date()
        let entry = UUID()
        let evidence = self.evidence(entryID: entry)
        let correction = try XCTUnwrap(DictionaryNegativeEvidenceResolver.resolve(
            context: self.context(events: [evidence], date: now),
            heard: "Manimekalai",
            corrected: "another",
            now: now
        ))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) // isolation-ok: unique folder removed in tearDown
        self.folders.append(folder)
        let url = folder.appendingPathComponent("negative.plist")
        let store = DictionaryNegativeExampleStore(url: url, collectionEnabled: { true })
        let revision = await store.revision()
        try await store.save(correction, expectedRevision: revision)
        try await store.save(correction, expectedRevision: revision)
        let saved = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v2")
        XCTAssertEqual(saved.count, 1, "Duplicate event only saved once")
        let wrongModel = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v3")
        XCTAssertTrue(wrongModel.isEmpty, "Model isolation")
        let retrained = await store.frames(entryID: entry, profileKey: "changed", modelKey: "parakeet-v2")
        XCTAssertTrue(retrained.isEmpty, "Retraining invalidates old negatives")
        for _ in 0..<10 {
            try await store.save(.init(evidence: self.evidence(entryID: entry), correctedText: "other", expiresAt: now.addingTimeInterval(120)), expectedRevision: revision)
        }
        let bounded = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v2")
        XCTAssertEqual(bounded.count, 6, "Per-word bank bounded")
        for _ in 0..<40 {
            try await store.save(.init(evidence: self.evidence(entryID: UUID()), correctedText: "other", expiresAt: now.addingTimeInterval(120)), expectedRevision: revision)
        }
        let persisted = try PropertyListDecoder().decode([DictionaryNegativeExampleStore.Example].self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.count, 32, "Global bank bounded")
        do {
            try await store.save(.init(evidence: evidence, correctedText: "other", expiresAt: .distantPast), expectedRevision: revision)
            XCTFail("Expired confirmation saved")
        } catch {}
        let disabled = DictionaryNegativeExampleStore(url: url, collectionEnabled: { false })
        do {
            try await disabled.save(correction, expectedRevision: await disabled.revision())
            XCTFail("Disabled collection wrote")
        } catch {}
        try await store.clear()
        do {
            try await store.save(correction, expectedRevision: revision)
            XCTFail("Stale save survived clear")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Clear removes store")
        try Data("broken".utf8).write(to: url)
        let corrupt = await store.frames(entryID: entry, profileKey: "profile", modelKey: "parakeet-v2")
        XCTAssertTrue(corrupt.isEmpty, "Corrupt optional bank cannot veto")
    }

    // Turns red if the production scorer drifts from the reference report for recorded clips.
    // Runs only when TEST_RUNNER_FLUID_DICTIONARY_PARITY_DIR names a folder holding
    // native-input.json and native-report.json.
    func testScorerParityWithReferenceReport() throws {
        let path = ProcessInfo.processInfo.environment["FLUID_DICTIONARY_PARITY_DIR"] ?? ""
        try XCTSkipIf(path.isEmpty, "Set TEST_RUNNER_FLUID_DICTIONARY_PARITY_DIR to run the parity check")
        struct Clip: Decodable { let id: String; let word: String; let values: [Float] }
        struct Input: Decodable { let enrollments: [Clip]; let queries: [Clip] }
        struct Decision: Decodable { let id: String; let combinedAccepted: Bool; let meanRelative: Float; let lowerRelative: Float }
        struct Report: Decodable { let decisions: [Decision] }
        let root = URL(fileURLWithPath: path)
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: root.appendingPathComponent("native-input.json")))
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: root.appendingPathComponent("native-report.json")))
        let expected = Dictionary(uniqueKeysWithValues: report.decisions.map { ($0.id, $0) })
        for query in input.queries {
            let refs = input.enrollments.filter { $0.word == query.word }.map { DictionaryMatchFrames(hiddenSize: 1024, values: $0.values) }
            let decision = try XCTUnwrap(DictionaryExperimentalMatcher.positive(query: .init(hiddenSize: 1024, values: query.values), references: refs), "Decision \(query.id)")
            let reference = try XCTUnwrap(expected[query.id], "Reference \(query.id)")
            XCTAssertEqual(decision.accepted, reference.combinedAccepted, "Production scorer parity \(query.id)")
            XCTAssertEqual(decision.meanRelative, reference.meanRelative, accuracy: 0.000_01, "Production score tolerance \(query.id)")
            XCTAssertEqual(decision.lowerRelative, reference.lowerRelative, accuracy: 0.000_01, "Production score tolerance \(query.id)")
        }
    }
}
