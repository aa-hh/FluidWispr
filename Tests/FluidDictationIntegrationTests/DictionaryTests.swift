import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class DictionaryTests: XCTestCase {
    // Turns red if replacement diagnostics report the wrong original text or range, change
    // the output, report a no-op, or let a canonical phrase be replaced again.
    func testReplacementDiagnostics() throws {
        let regex = try NSRegularExpression(pattern: "\\bbut\\b", options: .caseInsensitive)
        let input = "🙂 But wait, but don't change butter."
        var events: [(NSRange, String, String)] = []
        let output = DictionaryReplacementProtection.replacingMatches(
            in: input,
            regex: regex,
            template: "buddamthss",
            canonical: nil,
            onReplacement: { events.append(($0, $1, $2)) }
        )
        XCTAssertEqual(output, "🙂 buddamthss wait, buddamthss don't change butter.")
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Set(events.map { $0.1 }), Set(["But", "but"]))
        for event in events {
            XCTAssertEqual((input as NSString).substring(with: event.0), event.1)
            XCTAssertEqual(event.2, "buddamthss")
        }
        let unobserved = DictionaryReplacementProtection.replacingMatches(
            in: input, regex: regex, template: "buddamthss", canonical: nil
        )
        XCTAssertEqual(output, unobserved, "Diagnostics must not change output")

        let canonical = try NSRegularExpression(pattern: "\\bbut better\\b", options: .caseInsensitive)
        events.removeAll()
        let protected = DictionaryReplacementProtection.replacingMatches(
            in: "but better but",
            regex: regex,
            template: "but better",
            canonical: canonical,
            onReplacement: { events.append(($0, $1, $2)) }
        )
        XCTAssertEqual(protected, "but better but better")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.0.location, 11)

        events.removeAll()
        for text in ["but", "butter", "", "no match"] {
            XCTAssertEqual(DictionaryReplacementProtection.replacingMatches(
                in: text,
                regex: regex,
                template: "but",
                canonical: nil,
                onReplacement: { events.append(($0, $1, $2)) }
            ), text)
        }
        XCTAssertTrue(events.isEmpty, "Unchanged text must not report a replacement")

        let quoted = DictionaryReplacementDiagnostics.quoted("a\n\t\"b")
        XCTAssertFalse(quoted.contains("\n"))
        XCTAssertFalse(quoted.contains("\t"))
        XCTAssertTrue(quoted.contains("\\n"))
        XCTAssertTrue(quoted.contains("\\\""))
        XCTAssertEqual(DictionaryReplacementDiagnostics.quoted(String(repeating: "x", count: 10_000)).count, 163)
    }

    // Turns red if a match explanation names the wrong reason, a score cutoff or tuned
    // threshold is applied wrongly, or an exported report loses its embeddings or scores.
    func testPronunciationMatchReport() throws {
        var candidate = DictionaryMatchReport.Candidate(
            id: "target",
            word: "ModelOpt",
            sampleNumber: nil,
            enrollmentCount: 3,
            eligible: true,
            score: 0.699,
            start: 0,
            end: 0.5,
            heard: "model opt"
        )
        XCTAssertTrue(candidate.explanation.contains("Below cutoff"), candidate.explanation)
        candidate.score = 0.74
        XCTAssertTrue(candidate.explanation.contains("Above score cutoff"), candidate.explanation)
        candidate.competingWord = "Other"
        candidate.competingScore = 0.72
        XCTAssertTrue(candidate.explanation.contains("competing"), candidate.explanation)
        candidate.competingScore = nil
        candidate.heard = ""
        XCTAssertTrue(candidate.explanation.contains("no word overlaps"), candidate.explanation)
        let ineligible = DictionaryMatchReport.Candidate(
            id: "untrained", word: "Other", sampleNumber: nil, enrollmentCount: 1, eligible: false, score: 0.9
        )
        XCTAssertTrue(ineligible.explanation.contains("needs more"), ineligible.explanation)
        candidate.score = nil
        XCTAssertEqual(candidate.explanation, "No usable audio window")

        let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 4, modelKey: "parakeet-v2", originalAudioID: UUID(), observedText: "model opt")
        let profile = PronunciationDictionaryProfile(dictionaryEntryID: UUID(), label: "ModelOpt", modelKey: "parakeet-v2", hiddenSize: 2, enrollments: [capture])
        XCTAssertEqual(DictionaryPronunciationDecision.requiredScore(heardText: "Model opt!", profile: profile), 0.70)
        XCTAssertEqual(DictionaryPronunciationDecision.requiredScore(heardText: "other words", profile: profile), 0.85)
        XCTAssertFalse(DictionaryPronunciationDecision.accepts(score: .nan, heardText: "model opt", profile: profile))

        var tuned = profile
        tuned.matchThreshold = 0.45
        XCTAssertTrue(DictionaryPronunciationDecision.accepts(score: 0.49, heardText: "other words", profile: tuned))
        XCTAssertFalse(DictionaryPronunciationDecision.accepts(score: 0.49, heardText: "other words", profile: profile))
        XCTAssertEqual(DictionaryPronunciationDecision.minimumSearchScore(profiles: [profile, tuned]), 0.45)
        tuned.matchThreshold = .nan
        XCTAssertEqual(DictionaryPronunciationDecision.requiredScore(heardText: "other words", profile: tuned), 0.85)
        tuned.matchThreshold = 0.96
        XCTAssertEqual(DictionaryPronunciationDecision.requiredScore(heardText: "model opt", profile: tuned), 0.70)
        let legacy = try JSONDecoder().decode(PronunciationDictionaryProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertNil(legacy.matchThreshold)

        let individual = [Float(0.49), 0.83, 0.62].enumerated().map { index, score in
            DictionaryMatchReport.Candidate(
                id: "sample-\(index)",
                word: "ModelOpt",
                sampleNumber: index + 1,
                enrollmentCount: 3,
                eligible: true,
                score: score,
                heard: "sample \(index + 1)"
            )
        }
        let selected = DictionaryMatchReport.bestCandidates(from: individual)
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.score, 0.83)
        XCTAssertEqual(selected.first?.heard, "sample 2", "The decision retains the winning recording's evidence")
        XCTAssertEqual(individual.map(\.score), [0.49, 0.83, 0.62], "Display all original scores without averaging")

        let report = DictionaryMatchReport(
            createdAt: Date(),
            recordingID: UUID(),
            audioPath: "/tmp/test.wav",
            targetWord: "ModelOpt",
            modelKey: "parakeet-v2",
            duration: 1,
            rawTranscript: "model opt",
            savedTranscript: "ModelOpt",
            availableProfileCount: 1,
            candidates: [candidate],
            targetSamples: [],
            profiles: [profile]
        )
        let decoded = try JSONDecoder().decode(DictionaryMatchReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.profiles, [profile], "Export must preserve the reference embeddings")
        XCTAssertEqual(decoded.recordingID, report.recordingID)
        XCTAssertEqual(decoded.rawTranscript, "model opt")
        XCTAssertEqual(decoded.savedTranscript, "ModelOpt")
        XCTAssertNil(decoded.candidates.first?.score, "Unavailable must not become a zero score")
    }

    // Turns red if voice-training aliases accept common words or phrases, reject rare ones,
    // mishandle UTF-16 ranges, or accept anything when the lookup is unavailable or cancelled.
    func testVoiceTrainingAliasPolicy() async {
        let aliases = ["now", "right now", "fluid zqxword", "🙂 zqxword", "123", "", String(repeating: "x", count: 161)]
        let filtered = await VoiceTrainingAliasFilter.filter(aliases) { text in
            guard let regex = try? NSRegularExpression(pattern: "zqxword") else { return .unavailable }
            return .checked(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range))
        }
        XCTAssertEqual(filtered.accepted, ["fluid zqxword", "🙂 zqxword"])
        XCTAssertEqual(filtered.rejected, ["now", "right now", "123", "", String(repeating: "x", count: 161)])

        let unavailable = await VoiceTrainingAliasFilter.filter(["now", "zqxword"]) { _ in .unavailable }
        XCTAssertFalse(unavailable.lookupAvailable)
        XCTAssertTrue(unavailable.accepted.isEmpty)

        let cancelled = Task { @MainActor in
            await VoiceTrainingAliasFilter.filter(["zqxword"]) { text in
                try? await Task.sleep(for: .milliseconds(30)) // real-time-ok: lookup still running when the task is cancelled
                return .checked([NSRange(text.startIndex..., in: text)])
            }
        }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertTrue(cancelledResult.accepted.isEmpty)
    }

    // Turns red if the system spell checker stops rejecting ordinary words as aliases or
    // concurrent requests disagree. Skipped where the English word list is not installed.
    func testVoiceTrainingAliasNativeLookup() async throws {
        let ordinary = ["but", "NOW", "okay", "hello", "right now", "let’s do that"]
        let native = await VoiceTrainingAliasFilter.filter(ordinary + ["fluwidvois"])
        try XCTSkipUnless(native.lookupAvailable, "Native English word lookup is not available on this Mac")
        XCTAssertEqual(native.accepted, ["fluwidvois"])
        XCTAssertEqual(native.rejected, ordinary)

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    let result = await VoiceTrainingAliasFilter.filter(["now", "fluwidvois"])
                    return result.accepted == ["fluwidvois"]
                }
            }
            var values: [Bool] = []
            for await result in group {
                values.append(result)
            }
            return values
        }
        XCTAssertEqual(results, [true, true, true])
    }

    // Turns red if the dictionary shortcut test grades stale, unfocused or partial captures,
    // counts typing as a success, lets an old timeout cancel a new attempt, or pairs audio with
    // the wrong attempt.
    func testShortcutTestStateGradesOnlyTheCurrentFocusedAttempt() throws {
        for count in [0, 1, 2, 3] {
            XCTAssertTrue(DictionaryCaptureAction.title(active: false, failed: true, count: count) == "Record again", "Every failed capture offers retry")
            XCTAssertTrue(DictionaryCaptureAction.title(active: true, failed: true, count: count) == "Stop recording", "Active capture retains Stop")
        }
        XCTAssertTrue(DictionaryCaptureAction.title(active: false, failed: false, count: 0) == "Record", "First capture")
        XCTAssertTrue(DictionaryCaptureAction.title(active: false, failed: false, count: 1) == "Record more", "Additional successful capture")

        var test = DictionaryShortcutTestState()
        test.receive("ModelOpt", word: "ModelOpt")
        XCTAssertTrue(test.text.isEmpty && test.result == .none, "Ignore stale output on opening the page")
        for eligibility in [(false, true, false), (true, false, false), (true, true, true)] {
            test.begin(editorFocused: eligibility.0, appActive: eligibility.1, dictionaryCapture: eligibility.2)
            test.stopped()
            test.receive("ModelOpt", word: "ModelOpt")
            XCTAssertTrue(test.phase == .idle && test.result == .none && test.text.isEmpty, "Ignore unfocused, external, and training captures")
        }
        test.edit("I typed ModelOpt")
        XCTAssertTrue(test.result == .none && test.successes == 0, "Typing is not a successful speech test")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        let first = try XCTUnwrap(test.attemptID)
        test.receive("ModelOpt", word: "ModelOpt")
        XCTAssertTrue(test.phase == .recording && test.text.isEmpty, "Do not grade a partial capture")
        test.stopped()
        test.receive("I use modelopt.", word: "ModelOpt")
        XCTAssertTrue(test.result == .recognized && test.successes == 1 && test.phase == .idle, "Accept the completed focused capture")
        test.receive("Unrelated dictation", word: "ModelOpt")
        XCTAssertTrue(test.text == "I use modelopt." && test.successes == 1, "Late output cannot replace a completed test")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.expire(first)
        XCTAssertTrue(test.phase == .recording, "An old timeout cannot cancel the next attempt")
        test.stopped()
        test.receive("I use modelopt.", word: "ModelOpt")
        XCTAssertTrue(test.successes == 2, "Identical consecutive dictations each count once")

        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.receive("Model optional", word: "ModelOpt")
        XCTAssertTrue(test.result == .missed && test.successes == 2, "Only a real nonempty miss offers more examples")
        test.edit("ModelOpt")
        XCTAssertTrue(test.result == .none && test.successes == 2, "Editing clears stale feedback without counting a success")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.receive("  ", word: "ModelOpt")
        XCTAssertTrue(test.result == .empty && test.phase == .idle, "Silence is not a pronunciation mismatch")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        let expiringID = try XCTUnwrap(test.attemptID)
        test.expire(expiringID)
        XCTAssertTrue(test.phase == .idle && test.result == .empty, "Missing output has a bounded exit")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.cancel()
        test.receive("ModelOpt", word: "ModelOpt")
        XCTAssertTrue(test.phase == .idle && test.text.isEmpty && test.successes == 2, "Leaving the app ignores late output")

        let samples: [Float] = [0.1, -0.1]
        test.receiveAudio(samples)
        XCTAssertTrue(test.recording == nil, "Unowned audio cannot become the current test")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        let currentID = try XCTUnwrap(test.attemptID)
        test.stopped()
        test.receiveAudio(samples)
        test.receive("Model optional", word: "ModelOpt")
        XCTAssertTrue(test.recording?.id == currentID && test.recording?.text == test.text, "Audio must belong to the exact textbox attempt")
        XCTAssertTrue(test.recording?.samples == samples, "Automatic scoring must work without saving history")
        test.edit(test.text)
        XCTAssertTrue(test.recording?.id == currentID, "Identical binding updates preserve the current recording")
        test.edit("edited text")
        XCTAssertTrue(test.recording == nil, "Manual edits must invalidate old audio scores")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        test.stopped()
        test.receiveAudio(samples)
        test.cancel()
        test.receive("late text", word: "ModelOpt")
        XCTAssertTrue(test.recording == nil, "Cancelled audio cannot become a later score")
        let historyID = UUID()
        test.useHistory(id: historyID, text: "older sentence", url: URL(fileURLWithPath: "/tmp/old.wav"))
        XCTAssertTrue(test.recording?.id == historyID && test.text == "older sentence", "History and textbox must move together")
        test.begin(editorFocused: true, appActive: true, dictionaryCapture: false)
        XCTAssertTrue(test.recording == nil, "The next live attempt replaces history immediately")
    }

    // Turns red if the word check matches inside longer words, misses punctuation or hyphens,
    // or lets an empty target pass.
    func testShortcutWordMatchUsesWholeWords() {
        XCTAssertTrue(DictionaryWordTestResult.containsWord("C++", in: "I write C++."), "Literal punctuation")
        XCTAssertTrue(DictionaryWordTestResult.containsWord("Nemo-Gym", in: "Use nemo-gym today."), "Hyphenated words")
        XCTAssertTrue(!DictionaryWordTestResult.containsWord("cat", in: "category"), "Whole words only")
        XCTAssertTrue(!DictionaryWordTestResult.containsWord("", in: "hello"), "An empty target cannot pass")
    }
}
