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
        XCTAssertEqual(output, DictionaryReplacementProtection.replacingMatches(
            in: input, regex: regex, template: "buddamthss", canonical: nil
        ), "Diagnostics must not change output")

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
}
