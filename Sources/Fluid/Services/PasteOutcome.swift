import AppKit
import Combine
import Foundation

/// What became of one paste, in the terms the recording pill shows.
enum PasteOutcome: Equatable {
    /// The read-back saw the text arrive.
    case landed
    /// The paste was sent but the field could not be read back (common in Electron apps).
    case unconfirmed
    case noFocusedTextField
    case failed(TextDeliveryFailure)
    case cancelled

    init(dispatchResult: TextDeliveryResult) {
        switch dispatchResult {
        case .commandPosted: self = .unconfirmed
        case .cancelled: self = .cancelled
        case .recoverableFailure(.noEditableTarget): self = .noFocusedTextField
        case let .recoverableFailure(failure): self = .failed(failure)
        }
    }

    init(verdict: PasteVerifier.Verdict) {
        switch verdict {
        case .confirmed: self = .landed
        case .unknown: self = .unconfirmed
        case .notLanded: self = .failed(.pasteNotLanded)
        }
    }

    var didPaste: Bool {
        self == .landed || self == .unconfirmed
    }
}

struct PasteOutcomeEvent: Equatable {
    enum Phase: Equatable {
        /// Published as soon as the paste is sent or refused.
        case dispatched
        /// Published once per paste: after the read-back when one runs (about 1.5 s later),
        /// otherwise right after `dispatched`. It can report a failure after `dispatched` said sent.
        case final
    }

    let id: UUID
    let transcript: String
    /// True for "paste last transcript", whether from the shortcut, the menu or the pill.
    let isRetry: Bool
    let phase: Phase
    let outcome: PasteOutcome
}

/// Publishes the outcome of every paste TypingService makes, and runs "paste last transcript".
@MainActor
final class PasteOutcomeCenter: ObservableObject {
    static let shared = PasteOutcomeCenter()

    @Published private(set) var latest: PasteOutcomeEvent?

    /// The final paste outcome of each History entry since launch, for its line in History. Not saved.
    @Published private(set) var pasteOutcomes: [UUID: PasteOutcome] = [:]
    /// Entries whose last paste was a retry, so a failure there reads as a failed retry.
    @Published private(set) var retriedEntryIDs: Set<UUID> = []

    /// Set by the app: pastes the newest history entry and returns its transcript and result,
    /// or nil when it pasted nothing (empty history, recording in progress, keys still held).
    var pasteLastHandler: (@MainActor () async -> (transcript: String, result: TextDeliveryResult)?)?
    /// Set by the app: pastes the given text the same way, for one History entry.
    var pasteTextHandler: (@MainActor (String) async -> (transcript: String, result: TextDeliveryResult)?)?

    private var pending: [UUID: (transcript: String, isRetry: Bool)] = [:]
    private var subscribers: [UUID: AsyncStream<PasteOutcomeEvent>.Continuation] = [:]
    private var isPasteLastInProgress = false

    @MainActor
    private final class RetryContext {
        var pasteID: UUID?
    }

    /// Set only inside the task running "paste last transcript", so a live dictation paste
    /// that starts while the retry waits for the shortcut's keys is not taken for the retry.
    @TaskLocal private static var retryContext: RetryContext?

    /// Each call returns its own stream of every later event.
    func outcomes() -> AsyncStream<PasteOutcomeEvent> {
        self.subscribe().stream
    }

    func begin(transcript: String) -> UUID {
        let id = UUID()
        let retry = Self.retryContext
        let isRetry = retry != nil && retry?.pasteID == nil
        self.pending[id] = (transcript, isRetry)
        if isRetry { retry?.pasteID = id }
        return id
    }

    func reportDispatched(_ id: UUID, result: TextDeliveryResult) {
        guard let entry = self.pending[id] else { return }
        // Nothing was there to paste, so there is nothing to show.
        guard result != .recoverableFailure(.emptyText) else {
            self.pending[id] = nil
            return
        }
        self.publish(PasteOutcomeEvent(
            id: id,
            transcript: entry.transcript,
            isRetry: entry.isRetry,
            phase: .dispatched,
            outcome: PasteOutcome(dispatchResult: result)
        ))
    }

    func reportFinal(_ id: UUID, outcome: PasteOutcome) {
        guard let entry = self.pending.removeValue(forKey: id) else { return }
        self.publish(PasteOutcomeEvent(id: id, transcript: entry.transcript, isRetry: entry.isRetry, phase: .final, outcome: outcome))
    }

    /// Pastes the newest transcript again and returns its final outcome, or nil when nothing was
    /// pasted. A second call while one is still waiting for the shortcut's keys is ignored; once
    /// the paste is sent, another call may start while this one waits for the read-back.
    func pasteLastTranscript() async -> PasteOutcome? {
        guard let handler = self.pasteLastHandler else { return nil }
        return await self.runRetry(handler)
    }

    /// Hides FluidWispr so the app that was in front gets the paste, then pastes this entry's
    /// text the way "paste last transcript" does and records the outcome on the entry.
    func paste(entry: TranscriptionHistoryEntry) async {
        guard let handler = self.pasteTextHandler, let text = entry.clipboardText, !self.isPasteLastInProgress else { return }
        NSApp.hide(nil)
        // Give the previous app a moment to become active and take focus.
        try? await Task.sleep(for: .milliseconds(250))
        guard let outcome = await self.runRetry({ await handler(text) }) else { return }
        self.record(outcome, isRetry: true, for: entry.id)
    }

    private func runRetry(
        _ handler: @MainActor () async -> (transcript: String, result: TextDeliveryResult)?
    ) async -> PasteOutcome? {
        guard !self.isPasteLastInProgress else { return nil }
        self.isPasteLastInProgress = true
        let subscription = self.subscribe()
        defer { self.subscribers.removeValue(forKey: subscription.key)?.finish() }

        let retry = RetryContext()
        let pasted = await Self.$retryContext.withValue(retry) {
            await handler()
        }
        self.isPasteLastInProgress = false
        guard let pasted else { return nil }

        guard let id = retry.pasteID else {
            // The handler stopped before handing the text to TypingService, so report it here.
            let id = UUID()
            let outcome = PasteOutcome(dispatchResult: pasted.result)
            self.pending[id] = (pasted.transcript, true)
            self.reportDispatched(id, result: pasted.result)
            self.reportFinal(id, outcome: outcome)
            return outcome
        }
        // An empty paste publishes no final event, so there is nothing to wait for.
        guard pasted.result != .recoverableFailure(.emptyText) else { return nil }
        // The stream was opened before the handler ran, so a final event published early is buffered.
        for await event in subscription.stream where event.id == id && event.phase == .final {
            return event.outcome
        }
        return PasteOutcome(dispatchResult: pasted.result)
    }

    /// The newest History entry holding this transcript. A dictation is saved before it is pasted.
    private func historyEntryID(for event: PasteOutcomeEvent) -> UUID? {
        guard event.outcome != .cancelled else { return nil }
        let transcript = event.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionHistoryStore.shared.entries.first { $0.clipboardText == transcript }?.id
    }

    private func record(_ outcome: PasteOutcome, isRetry: Bool, for entryID: UUID) {
        self.pasteOutcomes[entryID] = outcome
        if isRetry, !outcome.didPaste {
            self.retriedEntryIDs.insert(entryID)
        } else {
            self.retriedEntryIDs.remove(entryID)
        }
    }

    private func subscribe() -> (key: UUID, stream: AsyncStream<PasteOutcomeEvent>) {
        let (stream, continuation) = AsyncStream.makeStream(of: PasteOutcomeEvent.self)
        let key = UUID()
        self.subscribers[key] = continuation
        continuation.onTermination = { _ in
            Task { @MainActor [weak self] in self?.subscribers[key] = nil }
        }
        return (key, stream)
    }

    private func publish(_ event: PasteOutcomeEvent) {
        self.latest = event
        if event.phase == .final, let entryID = self.historyEntryID(for: event) {
            self.record(event.outcome, isRetry: event.isRetry, for: entryID)
        }
        for continuation in self.subscribers.values {
            continuation.yield(event)
        }
    }
}
