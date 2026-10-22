import AVFoundation
import SwiftUI

/// The player row of a selected History entry: Play or Pause, a position line that seeks
/// on click or drag, and the time. Playback belongs only to this entry, never to dictation capture.
struct HistoryInlineAudioView: View {
    static var goneMessage: String {
        "The recording is gone. It may have been removed to free space. The words are kept."
    }

    let entry: TranscriptionHistoryEntry
    /// Raised by the page when Space is pressed on the selected entry.
    let toggleRequest: Int
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var elapsed: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isSeeking = false
    @State private var timeObserver: Any?

    var body: some View {
        Group {
            if self.failed {
                Text(Self.goneMessage)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let player {
                HStack(spacing: FWMetric.space4) {
                    Button(self.isPlaying ? "Pause" : "Play") {
                        self.togglePlayback(player)
                    }
                    .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
                    self.positionLine(player)
                    Text("\(Self.timeLabel(self.elapsed)) of \(Self.timeLabel(self.duration))")
                        .recordText(FWType.small)
                        .foregroundStyle(FWColor.textTertiary)
                        .fixedSize()
                }
            } else {
                Text("Loading recording…")
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textSecondary)
            }
        }
        .task(id: self.entry.id) {
            do {
                let entry = self.entry
                // Resolve the saved path off the main thread, only on an explicit Play.
                let url = await Task.detached(priority: .userInitiated) {
                    DictationAudioHistoryStore.shared.audioFileURL(for: entry)
                }.value
                try Task.checkCancellation()
                guard let url else { throw DictationAudioHistoryError.audioMissing }
                let asset = AVURLAsset(url: url)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    asset.cancelLoading()
                }
                defer { deadline.cancel() }
                let (playable, mediaDuration) = try await withTaskCancellationHandler {
                    try await asset.load(.isPlayable, .duration)
                } onCancel: {
                    asset.cancelLoading()
                }
                guard playable else { throw DictationAudioHistoryError.audioMissing }
                try Task.checkCancellation()
                guard mediaDuration.seconds.isFinite, mediaDuration.seconds > 0 else { throw DictationAudioHistoryError.audioMissing }
                self.duration = mediaDuration.seconds
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                self.player = player
                self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak player] time in
                    Task { @MainActor in
                        guard let player, self.player === player, !self.isSeeking, time.seconds.isFinite else { return }
                        self.elapsed = min(max(time.seconds, 0), self.duration)
                    }
                }
                player.play()
                self.isPlaying = true
            } catch {
                // Disappearance is silent; a load cancelled by the deadline is a visible failure.
                guard !Task.isCancelled else { return }
                self.failed = true
            }
        }
        .onChange(of: self.toggleRequest) { _, _ in
            if let player { self.togglePlayback(player) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === self.player?.currentItem else { return }
            self.isPlaying = false
            self.elapsed = self.duration
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === self.player?.currentItem else { return }
            self.player?.pause()
            self.isPlaying = false
            self.failed = true
        }
        .onDisappear {
            self.player?.pause()
            if let timeObserver { self.player?.removeTimeObserver(timeObserver) }
            self.timeObserver = nil
            self.player?.replaceCurrentItem(with: nil)
            self.player = nil
            self.isPlaying = false
        }
    }

    /// Played part in primary text, an ink dot at the position, the rest in the spoken-line colour.
    private func positionLine(_ player: AVPlayer) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let progress = self.duration > 0 ? min(max(self.elapsed / self.duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(FWColor.lineSpoken).frame(height: 2)
                Capsule().fill(FWColor.textPrimary).frame(width: width * progress, height: 2)
                Circle().fill(FWColor.ink).frame(width: 10, height: 10)
                    .offset(x: width * progress - 5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    self.isSeeking = true
                    self.elapsed = min(max(value.location.x / width, 0), 1) * self.duration
                }
                .onEnded { _ in
                    player.seek(to: CMTime(seconds: self.elapsed, preferredTimescale: 600))
                    self.isSeeking = false
                })
        }
        .frame(height: FWMetric.sizeControlS)
        .accessibilityElement()
        .accessibilityLabel("Recording position")
        .accessibilityValue("\(Self.timeLabel(self.elapsed)) of \(Self.timeLabel(self.duration))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 5.0 : -5.0
            self.elapsed = min(max(self.elapsed + step, 0), self.duration)
            player.seek(to: CMTime(seconds: self.elapsed, preferredTimescale: 600))
        }
    }

    private func togglePlayback(_ player: AVPlayer) {
        if self.isPlaying {
            player.pause()
            self.isPlaying = false
        } else {
            if self.elapsed >= self.duration - 0.1 {
                player.seek(to: .zero)
                self.elapsed = 0
            }
            player.play()
            self.isPlaying = true
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        let value = Int(max(seconds, 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
