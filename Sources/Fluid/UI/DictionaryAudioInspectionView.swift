import AVFoundation
import Combine
import SwiftUI

@MainActor
final class DictionaryInspectionPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: String?
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func stop() {
        self.generation = UUID()
        self.task?.cancel()
        self.task = nil
        self.player?.stop()
        self.player = nil
        self.playing = nil
    }

    func play(_ audio: DictionaryAudioInspection, cut: DictionaryAudioCut?, id: String) {
        let wasPlaying = self.playing == id
        self.stop()
        guard !wasPlaying else { return }
        let generation = self.generation
        self.error = nil
        self.playing = id
        self.task = Task { [weak self] in
            do {
                let data = try await DictionaryAudioInspector.shared.wav(audio, cut: cut)
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.player = player
                guard player.play() else { throw DictionaryMatchPlaygroundError.unavailable("Couldn't play this audio.") }
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.stop()
                self.error = error.localizedDescription
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }
}

/// The dictionary audio check: one test recording compared with every take of its word.
/// Reached from Settings → Experimental through `DictionaryAudioCheckPresenter`.
struct DictionaryAudioInspectionView: View {
    let report: DictionaryMatchReport
    let recordingBusy: Bool
    var loadReference: @Sendable (UUID) async throws -> DictionaryAudioInspection = { try await PronunciationDictionaryStore.shared.inspection(for: $0) }
    var onRecordMore: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    @AppStorage("DictionaryPronunciationDebugCapture") private var retainTrainingAudio = false
    @StateObject private var playback = DictionaryInspectionPlayback()
    @State private var references: [Int: DictionaryAudioInspection] = [:]
    @State private var testCut = DictionaryAudioCut(start: 0, end: 0.08)
    @State private var testMetrics: DictionaryAudioCutMetrics?
    @State private var adjustedScores: [Float?] = []
    @State private var loadingReferences = false
    @State private var comparing = false
    @State private var loadErrors: Set<Int> = []

    private var enrollments: [PronunciationEnrollmentCapture] {
        self.report.profiles.first { $0.label.caseInsensitiveCompare(self.report.targetWord) == .orderedSame }?.enrollments ?? []
    }

    var body: some View {
        DictionaryPage(back: self.onBack) {
            RecordHeader("Audio check · “\(self.report.targetWord)”", subtitle: "Nothing here changes your saved word or how closely it must match.") {
                if let onRecordMore = self.onRecordMore {
                    Button("Record new takes") {
                        self.playback.stop()
                        onRecordMore()
                    }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlM))
                    .disabled(self.recordingBusy)
                }
            }
            Group {
                RecordLine {
                    self.marginLabel("Similarity", detail: "Your test against each take.")
                } content: {
                    HStack(alignment: .top, spacing: FWMetric.space9) {
                        ForEach(self.enrollments.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: FWMetric.space1) {
                                Text("Take \(index + 1)")
                                    .recordText(FWType.small)
                                    .foregroundStyle(FWColor.textTertiary)
                                Text(self.comparing ? "…" : self.scoreText(index))
                                    .recordText(FWType.transcript)
                                    .foregroundStyle(FWColor.textPrimary)
                            }
                        }
                    }
                }
                if let audio = self.report.inspection {
                    self.testLine(audio)
                }
                ForEach(self.enrollments.indices, id: \.self) { index in
                    self.takeLine(index)
                }
                RecordLine {
                    self.marginLabel("Keep audio", detail: "Stored on this Mac.")
                } content: {
                    HStack(spacing: FWMetric.space4) {
                        RecordSwitch("Keep audio", isOn: self.$retainTrainingAudio)
                        Text("Keep audio with new takes. Up to 10 takes per word, 15 seconds each.")
                            .recordText(FWType.detail)
                            .foregroundStyle(FWColor.textSecondary)
                    }
                }
                RecordLine(showsRule: false) {
                    EmptyView()
                } content: {
                    Text("A higher score doesn’t mean a cleaner take; extra sound around the word can raise it. Listen to the parts used before changing how matching works.")
                        .recordText(FWType.small)
                        .foregroundStyle(FWColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = self.playback.error {
                        Text(error)
                            .recordText(FWType.detailStrong)
                            .foregroundStyle(FWColor.stateAttention)
                    }
                }
            }
            .disabled(self.recordingBusy)
        }
        .task(id: self.report.recordingID) {
            self.testCut = self.initialTestCut
            self.loadingReferences = true
            for index in self.enrollments.indices {
                guard !Task.isCancelled else { return }
                guard let id = self.enrollments[index].inspectionID else { continue }
                do {
                    let audio = try await self.loadReference(id)
                    guard !Task.isCancelled else { return }
                    self.references[index] = audio
                } catch {
                    guard !Task.isCancelled else { return }
                    self.loadErrors.insert(index)
                }
            }
            self.loadingReferences = false
        }
        .task(id: "\(self.testCut)") {
            self.playback.stop()
            self.adjustedScores = []
            self.testMetrics = nil
            self.comparing = true
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let test = self.report.inspection else { self.comparing = false; return }
            let scores = await DictionaryAudioInspector.shared.scores(
                test: test,
                testCut: self.testCut,
                references: self.enrollments.indices.map { self.references[$0] },
                referenceCuts: self.enrollments.map { _ in nil },
                storedVectors: self.enrollments.map(\.values)
            )
            let metrics = await DictionaryAudioInspector.shared.metrics(test, cut: self.testCut)
            guard !Task.isCancelled else { return }
            self.adjustedScores = scores
            self.testMetrics = metrics
            self.comparing = false
        }
        .onChange(of: self.recordingBusy) { _, busy in if busy { self.playback.stop() } }
        .onDisappear { self.playback.stop() }
    }

    private func testLine(_ audio: DictionaryAudioInspection) -> some View {
        RecordLine {
            Text("Your test")
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            Text(String(format: "Full %.2f s", audio.duration))
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textTertiary)
        } content: {
            DictionaryAudioTimeline(duration: audio.duration, cut: self.$testCut, editable: true)
            Text(self.testCutSummary)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
            if !self.comparing, !self.adjustedScores.isEmpty, self.adjustedScores.allSatisfy({ $0 == nil }) {
                Text("Choose a non-empty cut within one encoder chunk (up to 14.88 seconds).")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
            HStack(spacing: FWMetric.space3) {
                self.playButton("Play full", id: "test-full") { self.playback.play(audio, cut: nil, id: "test-full") }
                self.playButton("Play cut", id: "test-cut") { self.playback.play(audio, cut: self.testCut, id: "test-cut") }
                Button("Trim quiet edges") {
                    if let suggested = self.testMetrics?.suggested { self.testCut = suggested }
                }
                .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                .disabled(self.testMetrics?.suggested == nil || self.testMetrics?.suggested == self.testCut)
                Button("Reset") { self.testCut = self.initialTestCut }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
            }
        }
    }

    private var testCutSummary: String {
        let cut = String(format: "Cut %.2f–%.2f s", self.testCut.start, self.testCut.end)
        guard let metrics = self.testMetrics else { return cut }
        return cut + String(format: " · quiet %.2f s at the start, %.2f s at the end", metrics.leadingQuiet, metrics.trailingQuiet)
    }

    private func takeLine(_ index: Int) -> some View {
        let audio = self.references[index]
        return RecordLine {
            Text("Take \(index + 1)")
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            Text(audio.map { String(format: "Full %.2f s", $0.duration) } ?? "No audio")
                .recordText(FWType.small)
                .foregroundStyle(FWColor.textTertiary)
        } content: {
            if let audio {
                let used = DictionaryAudioCut(start: audio.selectedStart, end: min(audio.duration, audio.selectedEnd))
                DictionaryAudioTimeline(duration: audio.duration, cut: .constant(used), editable: false)
                HStack(spacing: FWMetric.space3) {
                    Text(String(format: "Used for matching %.2f–%.2f s", used.start, used.end))
                        .recordText(FWType.detail)
                        .foregroundStyle(FWColor.textSecondary)
                    self.playButton("Play take", id: "original-\(index)") { self.playback.play(audio, cut: nil, id: "original-\(index)") }
                    self.playButton("Play used part", id: "trained-\(index)") { self.playback.play(audio, cut: used, id: "trained-\(index)") }
                }
            } else {
                Text(self.loadingReferences && self.enrollments[index].inspectionID != nil ? "Loading audio…" : self.loadErrors.contains(index)
                    ? "Saved audio couldn’t be loaded. Its stored voice sample is still compared."
                    : "Audio wasn’t saved for this older take. Its stored voice sample is still compared.")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func playButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(self.playback.playing == id ? "Stop" : title, action: action)
            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
    }

    private func marginLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: FWMetric.space1) {
            Text(title)
                .recordText(FWType.label)
                .foregroundStyle(FWColor.textPrimary)
            Text(detail)
                .recordText(FWType.detail)
                .foregroundStyle(FWColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scoreText(_ index: Int) -> String {
        guard self.adjustedScores.indices.contains(index), let score = self.adjustedScores[index] else { return "—" }
        return String(format: "%.2f", score)
    }

    private var initialTestCut: DictionaryAudioCut {
        let duration = self.report.inspection?.duration ?? self.report.duration
        let sample = self.report.targetSamples.max { ($0.score ?? -.infinity) < ($1.score ?? -.infinity) }
        return .init(start: min(max(0, duration - 0.08), sample?.start ?? 0), end: min(duration, sample?.end ?? duration))
    }
}

/// A recording drawn at 96 pt per second: the spoken base line and the selected section,
/// with two handles that drag its start and end when editable. Ends snap to 80 ms steps.
private struct DictionaryAudioTimeline: View {
    private static let pointsPerSecond: CGFloat = 96
    private static let step = 0.08

    let duration: Double
    @Binding var cut: DictionaryAudioCut
    let editable: Bool

    private func x(_ seconds: Double) -> CGFloat {
        CGFloat(min(max(0, seconds), self.duration)) * Self.pointsPerSecond
    }

    private func seconds(at x: CGFloat) -> Double {
        let raw = min(max(0, Double(x / Self.pointsPerSecond)), self.duration)
        return (raw / Self.step).rounded() * Self.step
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(FWColor.lineSpoken)
                    .frame(width: self.x(self.duration), height: FWMetric.lineHairline)
                Capsule()
                    .fill(FWColor.textPrimary)
                    .frame(width: max(3, self.x(self.cut.end) - self.x(self.cut.start)), height: 3)
                    .offset(x: self.x(self.cut.start))
                if self.editable {
                    self.handle("Cut start", at: self.cut.start) { self.cut.start = max(0, min($0, self.cut.end - Self.step)) }
                    self.handle("Cut end", at: self.cut.end) { self.cut.end = min(self.duration, max($0, self.cut.start + Self.step)) }
                }
            }
            .frame(width: max(4, self.x(self.duration)), height: 12, alignment: .leading)
            .padding(.horizontal, 2)
            .coordinateSpace(name: "timeline")
        }
        .accessibilityElement(children: self.editable ? .contain : .ignore)
        .accessibilityLabel(String(format: "Recording, used section %.2f to %.2f seconds", self.cut.start, self.cut.end))
    }

    private func handle(_ name: String, at seconds: Double, move: @escaping (Double) -> Void) -> some View {
        Capsule()
            .fill(FWColor.textPrimary)
            .frame(width: 4, height: 12)
            .offset(x: self.x(seconds) - 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { move(self.seconds(at: $0.location.x)) }
            )
            .accessibilityLabel(name)
            .accessibilityValue(String(format: "%.2f seconds", seconds))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(seconds + Self.step)
                case .decrement: move(seconds - Self.step)
                @unknown default: break
                }
            }
    }
}
