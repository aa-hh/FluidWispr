import Foundation

/// Audio from dictations whose transcription failed, most often because the
/// speech model was still downloading or loading when the key came up. Each
/// recording is kept on disk until the model is ready and it has been
/// transcribed into History, so a cold start or a model error never loses
/// what someone said.
///
/// Files hold raw 16 kHz mono Float32 samples. The name carries the time the
/// recording stopped and how many recovery attempts have failed:
/// `<milliseconds since 1970>-a<attempts>.f32`.
final nonisolated class UnfinishedDictationStore: @unchecked Sendable {
    struct Item: Equatable {
        let url: URL
        let recordedAt: Date
        let failedAttempts: Int
    }

    static let shared = UnfinishedDictationStore()

    /// Shorter recordings are accidental taps, not dictations worth recovering.
    static let minimumSampleCount = 8000
    /// A recording that fails this many recoveries stays on disk but is no longer retried.
    static let maxFailedAttempts = 3
    /// The oldest recordings beyond this many are deleted when a new one is kept.
    static let maxKeptRecordings = 20

    private let fileManager = FileManager.default
    private let directoryOverride: URL?

    private init() {
        self.directoryOverride = nil
    }

    /// Keeps recordings in `directory` instead of Application Support, so tests never touch real ones.
    init(directory: URL) {
        self.directoryOverride = directory
    }

    @discardableResult
    func keep(_ samples: [Float], recordedAt: Date = Date()) throws -> Item? {
        guard samples.count >= Self.minimumSampleCount else { return nil }
        let directory = try self.directory()
        let milliseconds = Int64((recordedAt.timeIntervalSince1970 * 1000).rounded())
        var url = directory.appendingPathComponent("\(milliseconds)-a0.f32", isDirectory: false)
        var suffix = 1
        while self.fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(milliseconds + Int64(suffix))-a0.f32", isDirectory: false)
            suffix += 1
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url, options: .atomic)
        self.pruneOldest()
        return Self.item(at: url)
    }

    /// Recordings still worth a recovery attempt, oldest first.
    func pending() -> [Item] {
        self.allItems().filter { $0.failedAttempts < Self.maxFailedAttempts }
    }

    func samples(of item: Item) throws -> [Float] {
        let data = try Data(contentsOf: item.url)
        var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples
    }

    func remove(_ item: Item) {
        try? self.fileManager.removeItem(at: item.url)
    }

    func recordFailedAttempt(_ item: Item) {
        let milliseconds = Int64((item.recordedAt.timeIntervalSince1970 * 1000).rounded())
        let next = item.url.deletingLastPathComponent()
            .appendingPathComponent("\(milliseconds)-a\(item.failedAttempts + 1).f32", isDirectory: false)
        try? self.fileManager.moveItem(at: item.url, to: next)
    }

    /// Kept audio starts at half a second, but some engines (whisper.cpp) refuse
    /// under one second, so recovery pads with trailing silence the same way stop() does.
    static func paddedForTranscription(_ samples: [Float]) -> [Float] {
        let minimum = 16000
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    static func item(at url: URL) -> Item? {
        guard url.pathExtension == "f32" else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count == 2, let milliseconds = Int64(parts[0]),
              parts[1].hasPrefix("a"), let attempts = Int(parts[1].dropFirst())
        else { return nil }
        return Item(url: url, recordedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000), failedAttempts: attempts)
    }

    private func allItems() -> [Item] {
        guard let directory = try? self.directory(createIfNeeded: false),
              let urls = try? self.fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.compactMap(Self.item(at:)).sorted { $0.recordedAt < $1.recordedAt }
    }

    private func pruneOldest() {
        let items = self.allItems()
        guard items.count > Self.maxKeptRecordings else { return }
        for item in items.prefix(items.count - Self.maxKeptRecordings) {
            self.remove(item)
        }
    }

    private func directory(createIfNeeded: Bool = true) throws -> URL {
        let directory: URL
        if let directoryOverride = self.directoryOverride {
            directory = directoryOverride
        } else {
            guard let base = self.fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw DictationAudioHistoryError.applicationSupportUnavailable
            }
            directory = base
                .appendingPathComponent("FluidVoice", isDirectory: true)
                .appendingPathComponent("UnfinishedDictations", isDirectory: true)
        }
        if createIfNeeded {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
