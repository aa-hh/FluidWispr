import Accelerate
import AVFoundation
import Combine
import Darwin
import Foundation
#if arch(arm64)
import FluidAudio
#endif
import AppKit
import AudioToolbox
import CoreAudio

/// Serializes transcription operations and lets teardown cancel the real queued work.
private actor TranscriptionExecutor {
    private var lastTask: Task<Void, Never>?
    private var operationCancellations: [UUID: () -> Void] = [:]

    func run<T>(benchmarkSessionID: Int? = nil, _ operation: @escaping () async throws -> T) async throws -> T {
        logTranscriptionExecutorPhase("entered", sessionID: benchmarkSessionID)
        let previous = self.lastTask
        let operationID = UUID()
        let task = Task<T, Error> {
            logTranscriptionExecutorPhase("task_started", sessionID: benchmarkSessionID)
            _ = await previous?.result
            logTranscriptionExecutorPhase("previous_finished", sessionID: benchmarkSessionID)
            try Task.checkCancellation()
            return try await operation()
        }
        self.operationCancellations[operationID] = { task.cancel() }
        self.lastTask = Task { _ = try? await task.value }
        defer { self.operationCancellations.removeValue(forKey: operationID) }
        return try await task.value
    }

    func cancelAndAwaitPending() async {
        for cancel in self.operationCancellations.values {
            cancel()
        }
        _ = await self.lastTask?.result
        self.lastTask = nil
        self.operationCancellations.removeAll()
    }
}

private nonisolated func logTranscriptionExecutorPhase(_ phase: String, sessionID: Int?) {
    guard DebugLogger.diagnosticsEnabled, let sessionID else { return }
    let timestamp = ProcessInfo.processInfo.systemUptime
    DebugLogger.shared.debug(
        "ASR_BENCH t=\(timestamp) session=\(sessionID) final_queue_\(phase) mainThread=\(Thread.isMainThread)",
        source: "ASRBenchmark"
    )
}

private nonisolated func logStreamingProviderOperationReturn(
    sessionID: Int,
    operationID: UUID,
    route: String
) {
    guard DebugLogger.diagnosticsEnabled else { return }
    let returnedAt = ProcessInfo.processInfo.systemUptime
    DebugLogger.shared.debug(
        "ASR_BENCH t=\(returnedAt) streaming_provider_operation_return " +
            "session=\(sessionID) operation=\(operationID.uuidString) route=\(route)",
        source: "ASRBenchmark"
    )
}

/// Keeps a stop-state UI refresh from entering the main-actor queue ahead of
/// final transcription. The owner must always finish the gate; repeated finishes
/// are harmless so early-return paths can share one cleanup.
struct ASRStopUIInvalidationGate {
    private(set) var isDeferring = false
    private var hasOutputPipelineHold = false
    private var stopDidFinish = false

    mutating func holdForOutputPipeline() {
        self.isDeferring = true
        self.hasOutputPipelineHold = true
    }

    mutating func begin() {
        self.isDeferring = true
    }

    mutating func finish() -> Bool {
        guard self.isDeferring else { return false }
        self.stopDidFinish = true
        return self.completeIfReady()
    }

    mutating func releaseOutputPipelineHold() -> Bool {
        self.hasOutputPipelineHold = false
        guard self.stopDidFinish else {
            let wasDeferring = self.isDeferring
            self.isDeferring = false
            return wasDeferring
        }
        return self.completeIfReady()
    }

    mutating func forceFinish() -> Bool {
        self.hasOutputPipelineHold = false
        self.stopDidFinish = true
        return self.completeIfReady()
    }

    private mutating func completeIfReady() -> Bool {
        guard self.isDeferring, self.stopDidFinish, self.hasOutputPipelineHold == false else { return false }
        self.isDeferring = false
        self.stopDidFinish = false
        return true
    }
}

@MainActor
func scheduleDeferredMainActorOperation(
    afterNanoseconds delayNanoseconds: UInt64,
    shouldRun: @escaping @MainActor () -> Bool = { true },
    operation: @escaping @MainActor () -> Void
) -> Task<Void, Never> {
    Task { @MainActor in
        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
            return
        }
        guard Task.isCancelled == false, shouldRun() else { return }
        operation()
    }
}

/// Identifies the recording and provider generation allowed to publish a live preview.
/// Operation completion uses the narrower operation identity so stale cleanup cannot
/// clear state owned by a newer chunk.
struct StreamingTranscriptionWorkState {
    private(set) var sessionID: Int?
    private(set) var activeOperationID: UUID?
    private(set) var providerGeneration: UInt64 = 0

    mutating func beginSession(_ sessionID: Int) {
        self.sessionID = sessionID
        self.activeOperationID = nil
    }

    mutating func beginOperation(
        sessionID: Int,
        operationID: UUID
    ) -> UInt64? {
        guard self.sessionID == sessionID, self.activeOperationID == nil else { return nil }
        self.activeOperationID = operationID
        return self.providerGeneration
    }

    func ownsOperation(sessionID: Int, operationID: UUID) -> Bool {
        self.sessionID == sessionID && self.activeOperationID == operationID
    }

    func canPublish(
        sessionID: Int,
        operationID: UUID,
        providerGeneration: UInt64
    ) -> Bool {
        self.ownsOperation(sessionID: sessionID, operationID: operationID) &&
            self.providerGeneration == providerGeneration
    }

    func canPublishPreview(
        sessionID: Int,
        operationID: UUID,
        providerGeneration: UInt64,
        isRunning: Bool,
        schedulingSessionID: Int?
    ) -> Bool {
        isRunning &&
            schedulingSessionID == sessionID &&
            self.canPublish(
                sessionID: sessionID,
                operationID: operationID,
                providerGeneration: providerGeneration
            )
    }

    mutating func finishOperation(sessionID: Int, operationID: UUID) -> Bool {
        guard self.ownsOperation(sessionID: sessionID, operationID: operationID) else { return false }
        self.activeOperationID = nil
        return true
    }

    mutating func invalidateProvider() {
        self.providerGeneration &+= 1
    }

    mutating func endSession(_ sessionID: Int) {
        guard self.sessionID == sessionID, self.activeOperationID == nil else { return }
        self.sessionID = nil
    }
}

/// Blocks a new recording only while the previous recording still owns the shared PCM buffer.
/// Cancelling a pending start releases its waiter without completing the active handoff.
@MainActor
final class RecordingBufferHandoffGate {
    struct Token: Equatable {
        private let id = UUID()
    }

    private var activeToken: Token?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isRecovering = false

    var isActive: Bool { self.activeToken != nil }
    var pendingWaiterCount: Int { self.waiters.count }

    func begin() -> Token? {
        guard self.activeToken == nil else { return nil }
        let token = Token()
        self.activeToken = token
        return token
    }

    func waitUntilAvailable() async {
        guard self.activeToken != nil else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func releasePendingWaiters() {
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }

    func complete(_ token: Token) {
        guard self.activeToken == token else { return }
        self.activeToken = nil
        self.isRecovering = false
        self.releasePendingWaiters()
    }

    func markTimedOut(_ token: Token) {
        guard self.activeToken == token else { return }
        self.isRecovering = true
        // Wake starts already waiting so they fail visibly instead of hanging.
        self.releasePendingWaiters()
    }
}

/// Owns the cancellable idle delay separately from provider work. Normal recording
/// stop cancels only the delay; an active provider operation is allowed to settle.
@MainActor
final class StreamingTaskLifecycle {
    private var scheduler: (id: UUID, task: Task<Void, Never>)?
    private var active: (sessionID: Int, operationID: UUID, task: Task<Void, Never>)?
    private var drainWaiters: [UUID: (operationID: UUID, continuation: CheckedContinuation<Bool, Never>, timer: Task<Void, Never>)] = [:]

    var hasScheduledIdleWork: Bool { self.scheduler != nil }
    var hasActiveWork: Bool { self.active != nil }
    var pendingDrainCount: Int { self.drainWaiters.count }

    @discardableResult
    func schedule(
        sessionID: Int,
        delayNanoseconds: UInt64,
        operation: @escaping @MainActor (UUID) async -> Void,
        completion: @escaping @MainActor (UUID) -> Void
    ) -> Bool {
        guard self.scheduler == nil, self.active == nil else { return false }
        let schedulerID = UUID()
        let task = Task { @MainActor [weak self] in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard let self,
                  Task.isCancelled == false,
                  self.scheduler?.id == schedulerID
            else { return }

            self.scheduler = nil
            let operationID = UUID()
            let activeTask = Task { @MainActor [weak self] in
                await operation(operationID)
                guard let self,
                      self.active?.sessionID == sessionID,
                      self.active?.operationID == operationID
                else { return }
                self.active = nil
                completion(operationID)
                let completedWaiters = self.drainWaiters.filter { $0.value.operationID == operationID }
                for id in completedWaiters.keys {
                    self.finishDrain(id: id, completed: true)
                }
            }
            self.active = (sessionID, operationID, activeTask)
        }
        self.scheduler = (schedulerID, task)
        return true
    }

    @discardableResult
    func cancelScheduler() -> Bool {
        guard let scheduler = self.scheduler else { return false }
        self.scheduler = nil
        scheduler.task.cancel()
        return true
    }

    func activeTaskToDrain(sessionID: Int) -> Task<Void, Never>? {
        guard let active = self.active, active.sessionID == sessionID else { return nil }
        return active.task
    }

    /// Deadline bounds the caller only. Never cancel or release a provider still
    /// using incremental state. Completion removes the timer; timeout removes the waiter.
    func drain(sessionID: Int, timeoutNanoseconds: UInt64) async -> Bool {
        guard let active = self.active, active.sessionID == sessionID else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timer = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch { return }
                self?.finishDrain(id: id, completed: false)
            }
            self.drainWaiters[id] = (active.operationID, continuation, timer)
        }
    }

    private func finishDrain(id: UUID, completed: Bool) {
        guard let waiter = self.drainWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: completed)
    }
}

struct ShortAudioSilenceAssessment: Equatable {
    let durationMilliseconds: Int
    let isEligible: Bool
    let shouldSkipTranscription: Bool
    let peakAmplitude: Float
    let rmsAmplitude: Float
    let maximumFrameRMS: Float
}

enum AudioCaptureStartOutcome: Equatable {
    case started
    case alreadyActive
    case failed
}

enum ASRStopOutcome: Equatable {
    case success
    case empty
    case failed
}

enum ASRExclusiveActivity: String, Equatable {
    case dictation
    case fileTranscription
    case localAPI
    case meeting
    case modelMaintenance
    case settingsRestore

    var displayName: String {
        switch self {
        case .dictation:
            return "dictation"
        case .fileTranscription:
            return "file transcription"
        case .localAPI:
            return "local API transcription"
        case .meeting:
            return "meeting transcription"
        case .modelMaintenance:
            return "voice model maintenance"
        case .settingsRestore:
            return "settings import"
        }
    }
}

struct ASRActivityLease: Equatable {
    let id: UUID
    let activity: ASRExclusiveActivity
}

enum ASRActivityError: LocalizedError {
    case activityInProgress(ASRExclusiveActivity)
    case settingsRestoreUnavailable

    var errorDescription: String? {
        switch self {
        case let .activityInProgress(activity):
            return "Wait for the active \(activity.displayName) to finish."
        case .settingsRestoreUnavailable:
            return "Finish the current recording, transcription, microphone preview, or voice model operation, then import the backup again."
        }
    }
}

nonisolated enum ASRHardwareListenerPolicy {
    static func deviceListQueryCanApply(
        isTerminating: Bool,
        capturedLifecycle: UInt64,
        currentLifecycle: UInt64,
        capturedQueryGeneration: UInt64,
        currentQueryGeneration: UInt64
    ) -> Bool {
        !isTerminating
            && capturedLifecycle == currentLifecycle
            && capturedQueryGeneration == currentQueryGeneration
    }
}

// swiftlint:disable file_length type_body_length
/// A comprehensive speech recognition service that handles real-time audio transcription.
///
/// This service manages the entire ASR (Automatic Speech Recognition) pipeline including:
/// - Audio capture and processing
/// - Model downloading and management
/// - Real-time transcription
/// - Audio level visualization
/// - Text-to-speech integration
///
/// The service is designed to work seamlessly with macOS system APIs and provides
/// robust error handling and performance optimization.
///
/// ## Language Support
/// The service supports multiple models with varying language capabilities:
/// - **Parakeet TDT v3** (Default): Automatically detects and transcribes 25 European languages:
///   Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German,
///   Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian,
///   Slovak, Slovenian, Spanish, Swedish, Russian, and Ukrainian.
/// - **Parakeet TDT v2**: Specialized for high-accuracy English transcription.
/// - **Apple Speech**: Supports all system languages available on macOS.
/// - **Whisper**: Supports 99 languages.
///
/// No manual language selection is required for Parakeet models - v3 automatically detects the spoken language.
/// ## Thread Safety
/// All public methods are marked with @MainActor to ensure thread safety.
/// Audio processing happens on background threads for optimal performance.
///
/// ## Model Management
/// The service automatically downloads and manages ASR models from Hugging Face.
/// Models are cached locally to avoid repeated downloads.
@MainActor
final class ASRService: ObservableObject {
    // Below this the Transcribing status only adds a main-thread overlay re-render
    // that delays the result it is announcing; final ASR on short audio is ~40 ms.
    private static let finalTranscriptionStatusDelayNanoseconds: UInt64 = 250_000_000
    private static let streamingDrainTimeoutNanoseconds: UInt64 = 30_000_000_000

    nonisolated static func shouldAssessShortAudioSilence(
        isEnabled: Bool,
        useDictionaryTrainingPath: Bool,
        hasRecognizedStreamingPreview: Bool
    ) -> Bool {
        isEnabled && !useDictionaryTrainingPath && !hasRecognizedStreamingPreview
    }

    nonisolated static func assessShortAudioSilence(
        _ samples: [Float],
        sampleRate: Int = 16_000
    ) -> ShortAudioSilenceAssessment {
        let durationMilliseconds = sampleRate > 0
            ? Int((Double(samples.count) / Double(sampleRate) * 1000).rounded())
            : 0
        let maximumSampleCount = max(sampleRate, 0) * 4
        guard !samples.isEmpty, sampleRate > 0, samples.count <= maximumSampleCount else {
            return ShortAudioSilenceAssessment(
                durationMilliseconds: durationMilliseconds,
                isEligible: false,
                shouldSkipTranscription: false,
                peakAmplitude: 0,
                rmsAmplitude: 0,
                maximumFrameRMS: 0
            )
        }

        let frameSize = max(sampleRate / 50, 1) // 20 ms
        var peak: Float = 0
        var totalSquareSum = 0.0
        var frameSquareSum = 0.0
        var frameSampleCount = 0
        var maximumFrameRMS: Float = 0

        for sample in samples {
            guard sample.isFinite else {
                return ShortAudioSilenceAssessment(
                    durationMilliseconds: durationMilliseconds,
                    isEligible: true,
                    shouldSkipTranscription: false,
                    peakAmplitude: peak,
                    rmsAmplitude: 0,
                    maximumFrameRMS: maximumFrameRMS
                )
            }

            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            let square = Double(sample) * Double(sample)
            totalSquareSum += square
            frameSquareSum += square
            frameSampleCount += 1

            if frameSampleCount == frameSize {
                maximumFrameRMS = max(
                    maximumFrameRMS,
                    Float(sqrt(frameSquareSum / Double(frameSampleCount)))
                )
                frameSquareSum = 0
                frameSampleCount = 0
            }
        }

        if frameSampleCount > 0 {
            maximumFrameRMS = max(
                maximumFrameRMS,
                Float(sqrt(frameSquareSum / Double(frameSampleCount)))
            )
        }
        let rms = Float(sqrt(totalSquareSum / Double(samples.count)))

        // Calibrated conservatively against real FluidVoice captures. Requiring
        // all three conditions keeps quiet speech and short words on the ASR path.
        let shouldSkip = peak < 0.01 && rms < 0.002 && maximumFrameRMS < 0.0045
        return ShortAudioSilenceAssessment(
            durationMilliseconds: durationMilliseconds,
            isEligible: true,
            shouldSkipTranscription: shouldSkip,
            peakAmplitude: peak,
            rmsAmplitude: rms,
            maximumFrameRMS: maximumFrameRMS
        )
    }

    @Published var isRunning: Bool = false {
        didSet {
            if !self.isRunning {
                self.dictationMuteGeneration &+= 1
                self.clearDictationMuteIndicator()
            }
        }
    }

    @Published private(set) var isDictationMuted = false
    private(set) var dictationMuteGeneration: UInt64 = 0

    func setDictationMuted(_ muted: Bool) {
        guard self.isRunningOrStarting, !self.isDictionaryTrainingCaptureActive,
              !self.isStoppingFinalTranscription, muted != self.isDictationMuted else { return }
        self.audioCapturePipeline.setDictationMuted(muted, at: mach_absolute_time())
        self.isDictationMuted = muted
        NotchContentState.shared.isDictationMuted = muted
        if muted {
            self.audioLevelSubject.send(0)
        }
    }

    private func clearDictationMuteIndicator() {
        if self.isDictationMuted {
            self.isDictationMuted = false
        }
        if NotchContentState.shared.isDictationMuted { NotchContentState.shared.isDictationMuted = false }
    }

    @Published var finalText: String = ""
    @Published var partialTranscription: String = ""
    @Published var wordBoostStatusText: String = "Word boost: off"
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    /// Speech model state the UI shows. Its changes are forwarded as this object's changes.
    private let modelReadiness = SpeechModelReadiness()
    private var modelReadinessForwarding: AnyCancellable?
    var isAsrReady: Bool {
        get { self.modelReadiness.isAsrReady }
        set { self.modelReadiness.isAsrReady = newValue }
    }

    var isDownloadingModel: Bool {
        get { self.modelReadiness.isDownloadingModel }
        set { self.modelReadiness.isDownloadingModel = newValue }
    }

    /// True when loading a cached model into memory (not downloading).
    var isLoadingModel: Bool {
        get { self.modelReadiness.isLoadingModel }
        set { self.modelReadiness.isLoadingModel = newValue }
    }

    private(set) var isCancellingModelPreparation: Bool {
        get { self.modelReadiness.isCancellingModelPreparation }
        set { self.modelReadiness.isCancellingModelPreparation = newValue }
    }

    var modelsExistOnDisk: Bool {
        get { self.modelReadiness.modelsExistOnDisk }
        set { self.modelReadiness.modelsExistOnDisk = newValue }
    }

    var downloadProgress: Double? {
        get { self.modelReadiness.downloadProgress }
        set { self.modelReadiness.downloadProgress = newValue }
    }

    var modelPreparationPhase: ModelPreparationPhase? {
        get { self.modelReadiness.modelPreparationPhase }
        set { self.modelReadiness.modelPreparationPhase = newValue }
    }

    /// The model currently being downloaded.
    var downloadingModelId: String? {
        get { self.modelReadiness.downloadingModelId }
        set { self.modelReadiness.downloadingModelId = newValue }
    }

    private(set) var isCancellingModelDownload: Bool {
        get { self.modelReadiness.isCancellingModelDownload }
        set { self.modelReadiness.isCancellingModelDownload = newValue }
    }

    @Published private(set) var isDictionaryTrainingCaptureActive: Bool = false
    @Published private(set) var isMicrophonePreviewActive: Bool = false
    @Published private(set) var microphonePreviewError: String?
    /// Narrow lifecycle event used only by onboarding microphone preview.
    /// This must not invalidate every ASR-observing view after each capture.
    let audioCaptureStateDidSettle = PassthroughSubject<Void, Never>()
    let deferredStopUIInvalidationDidFlush = PassthroughSubject<Void, Never>()
    private var stopUIInvalidationGate = ASRStopUIInvalidationGate()
    private var stopUIInvalidationTimeoutTask: Task<Void, Never>?
    private var stopUIInvalidationHoldGeneration: UInt64 = 0
    private var activeStopUIInvalidationHold: UInt64?
    private var isStoppingFinalTranscription = false
    var defersStopUIInvalidation: Bool {
        self.stopUIInvalidationGate.isDeferring
    }

    var isFinalTranscriptionReady: Bool {
        self.isAsrReady && self.transcriptionProvider.isReady
    }

    private var microphonePreviewOperationGeneration: UInt64 = 0
    private var isMicrophonePreviewRequested = false
    private(set) var lastDictionaryTrainingResult: ASRTranscriptionResult?
    private(set) var lastStopOutcome: ASRStopOutcome = .empty
    private var lastFinalTranscriptionDurationMs: Int?
    private var lastFinalParakeetProcessingMs: Int?
    private(set) var dictionaryTrainingAudioGeneration = 0

    @Published private(set) var isStarting: Bool = false { // Guard against re-entrant start() calls
        didSet {
            if self.isStarting {
                self.dictationMuteGeneration &+= 1
            }
            if !self.isStarting, !self.isRunning {
                self.clearDictationMuteIndicator()
            }
        }
    }

    private var pendingMediaCaptureSessionID: Int?
    @Published private(set) var activeExclusiveActivity: ASRExclusiveActivity?
    private var audioCaptureStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeActivityLease: ASRActivityLease?
    private var dictationActivityLease: ASRActivityLease?
    private var providerResetPending = false
    private var meetingAudioHandoffGeneration: UInt64 = 0
    private var meetingTopologyObserverSuspension: UInt64?
    private var meetingAudioHandbackLease: ASRActivityLease?
    private var meetingAudioHandbackTask: Task<Void, Never>?
    private var meetingAudioHandbackTaskID: UUID?
    // Keep the existing descriptive state or persisted evidence field name.
    // swiftlint:disable:next identifier_name
    private var meetingHandoffShouldRestorePreparedCapture = false
    private var deferredMeetingRouteRecoveryReason: String?
    // Keep the existing descriptive state or persisted evidence field name.
    // swiftlint:disable:next identifier_name
    private var deferredMeetingRouteRecoveryRequiresPrewarm = false
    // Keep the existing descriptive state or persisted evidence field name.
    // swiftlint:disable:next identifier_name
    private var deferredMeetingRouteRecoveryReconcilesInput = false
    private struct MeetingASRScope {
        let id: UUID
        let lease: ASRActivityLease
        var cancelBody: (() -> Void)?
        var awaitBodyCompletion: (() async -> Void)?
    }

    private var meetingASRPreparationOwner: MeetingASRPreparationOwner?
    private var activeMeetingASRScope: MeetingASRScope?
    private var deferredMeetingActivityLeaseRelease: ASRActivityLease?
    #if DEBUG
    /// Test seam replacing the lazily wired production owner so scope tests use fake providers.
    var meetingASRPreparationOwnerForTesting: MeetingASRPreparationOwner?
    #endif
    var isRunningOrStarting: Bool {
        self.isRunning || self.isStarting
    }

    /// Change only the output mode of our existing capture, never another activity's audio.
    var canSwitchOwnedDictationCaptureMode: Bool {
        guard let lease = self.dictationActivityLease else { return false }
        return lease.activity == .dictation && self.activeActivityLease == lease
            && self.isRunning && !self.isStarting && !self.isStoppingFinalTranscription
            && !self.isTerminating && !self.isDictionaryTrainingCaptureActive
            && !self.recordingBufferHandoffGate.isActive && !self.recordingBufferHandoffGate.isRecovering
    }

    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        guard let activeActivityLease = self.activeActivityLease else {
            DictionaryAudioLearningService.shared.cancelForRecording()
            let lease = ASRActivityLease(id: UUID(), activity: activity)
            self.activeActivityLease = lease
            self.activeExclusiveActivity = activity
            return lease
        }
        throw ASRActivityError.activityInProgress(activeActivityLease.activity)
    }

    /// Reject before any backup writes, then reserve admission across its actor hop.
    /// Keep the whole import together instead of changing the current capture's settings.
    func beginSettingsBackupRestore() throws -> ASRActivityLease {
        try Task.checkCancellation()
        guard !self.isTerminating, self.activeActivityLease == nil,
              !self.isRunning, !self.isStarting, !self.isStoppingFinalTranscription,
              !self.recordingBufferHandoffGate.isRecovering,
              !self.isMicrophonePreviewRequested, !self.isMicrophonePreviewActive,
              !self.hasActiveModelDownload, !self.hasActiveModelPreparation,
              self.deletingModelID == nil, self.providerResetDrain == nil,
              !self.isCancellingModelPreparation, !self.isCancellingModelDownload,
              !self.meetingModelResidency.isExclusive,
              self.isAsrReady || (!self.isDownloadingModel && !self.isLoadingModel)
        else { throw ASRActivityError.settingsRestoreUnavailable }
        return try self.acquireExclusiveActivity(.settingsRestore)
    }

    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        guard self.activeActivityLease == lease else { return }
        if self.isMeetingASRClaimBlocking(lease: lease) {
            // The exact lease is released by the scope's joined drain, never mid-scope.
            self.deferredMeetingActivityLeaseRelease = lease
            return
        }
        #if DEBUG
        AudioTopologyDiagnostics.record(.phaseBegin, owner: .asrActivityLease, queueRole: .mainControl, phase: .activityLease)
        defer { AudioTopologyDiagnostics.record(.phaseEnd, owner: .asrActivityLease, queueRole: .mainControl, phase: .activityLease) }
        #endif
        self.activeActivityLease = nil
        self.activeExclusiveActivity = nil
        DictionaryAudioLearningService.shared.activityDidEnd()

        guard self.providerResetPending else { return }
        self.providerResetPending = false
        self.resetTranscriptionProvider()
    }

    func prepareMeetingAudioHandoff(_ lease: ASRActivityLease) async throws {
        guard self.activeActivityLease == lease, lease.activity == .meeting,
              self.isRunning == false, self.isStarting == false,
              self.isTerminating == false
        else { throw ASRActivityError.activityInProgress(self.activeExclusiveActivity ?? .meeting) }

        self.meetingAudioHandoffGeneration &+= 1
        let generation = self.meetingAudioHandoffGeneration
        self.meetingHandoffShouldRestorePreparedCapture = self.hasPreparedAudioCapture

        let observerSuspension = await AppServices.shared.audioObserver.suspendTopologyReconciliation()
        guard self.activeActivityLease == lease,
              self.meetingAudioHandoffGeneration == generation
        else {
            await AppServices.shared.audioObserver.resumeTopologyReconciliation(observerSuspension)
            throw CancellationError()
        }
        self.meetingTopologyObserverSuspension = observerSuspension

        // Preview owns DirectCoreAudio without an exclusive activity lease. Stopping it
        // advances its operation generation, clears requested/active state and monitoring,
        // and drains its direct-capture stop before the meeting backend may materialize.
        await self.stopMicrophonePreview(retainPreparedCapture: false)
        await self.cancelAudioRouteRecoveryAndWait()
        await self.directAudioLifecycleController.invalidate(reason: "meeting_audio_handoff")
        self.activeAudioCaptureBackend = .none

        guard self.activeActivityLease == lease,
              self.meetingAudioHandoffGeneration == generation,
              self.isRunning == false, self.isStarting == false,
              self.isTerminating == false,
              self.hasPreparedAudioCapture == false
        else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func completeMeetingAudioHandback(_ lease: ASRActivityLease) async {
        if self.meetingAudioHandbackLease == lease,
           let handbackTask = self.meetingAudioHandbackTask
        {
            await handbackTask.value
            return
        }
        guard self.activeActivityLease == lease, lease.activity == .meeting else { return }

        let taskID = UUID()
        let handbackTask = Task { @MainActor [weak self] () in
            guard let self else { return }
            await self.performMeetingAudioHandback(lease)
        }
        self.meetingAudioHandbackLease = lease
        self.meetingAudioHandbackTask = handbackTask
        self.meetingAudioHandbackTaskID = taskID
        await handbackTask.value
        if self.meetingAudioHandbackTaskID == taskID {
            self.meetingAudioHandbackLease = nil
            self.meetingAudioHandbackTask = nil
            self.meetingAudioHandbackTaskID = nil
        }
    }

    private func performMeetingAudioHandback(_ lease: ASRActivityLease) async {
        guard self.activeActivityLease == lease, lease.activity == .meeting else { return }
        self.meetingAudioHandoffGeneration &+= 1
        let generation = self.meetingAudioHandoffGeneration

        await self.cancelAudioRouteRecoveryAndWait()
        await self.directAudioLifecycleController.invalidate(reason: "meeting_audio_handback")
        self.activeAudioCaptureBackend = .none
        let snapshot = await AudioTopologyListenerExecution.perform {
            (
                AudioDevice.listInputDevicesRefreshingLiveness(diagnosticsOwner: .asrService),
                AudioDevice.getDefaultInputDevice()?.uid
            )
        }

        guard self.activeActivityLease == lease,
              self.meetingAudioHandoffGeneration == generation
        else { return }

        guard self.isTerminating == false else {
            if let observerSuspension = self.meetingTopologyObserverSuspension {
                await AppServices.shared.audioObserver.resumeTopologyReconciliation(observerSuspension)
                guard self.activeActivityLease == lease,
                      self.meetingAudioHandoffGeneration == generation
                else { return }
                if self.meetingTopologyObserverSuspension == observerSuspension {
                    self.meetingTopologyObserverSuspension = nil
                }
            }
            guard self.activeActivityLease == lease,
                  self.meetingAudioHandoffGeneration == generation
            else { return }
            self.meetingHandoffShouldRestorePreparedCapture = false
            self.deferredMeetingRouteRecoveryReason = nil
            self.deferredMeetingRouteRecoveryRequiresPrewarm = false
            self.deferredMeetingRouteRecoveryReconcilesInput = false
            self.releaseExclusiveActivity(lease)
            return
        }

        AppServices.shared.microphonePreferenceCoordinator.reconcileMicrophoneSelection(
            availableInputs: snapshot.0,
            defaultInputUID: snapshot.1
        )
        self.cacheCurrentDeviceList(snapshot.0)

        if let observerSuspension = self.meetingTopologyObserverSuspension {
            await AppServices.shared.audioObserver.resumeTopologyReconciliation(observerSuspension)
            guard self.activeActivityLease == lease,
                  self.meetingAudioHandoffGeneration == generation
            else { return }
            if self.meetingTopologyObserverSuspension == observerSuspension {
                self.meetingTopologyObserverSuspension = nil
            }
        }

        // Observer resume can deliver coalesced topology events while this meeting
        // lease is still held. Read and clear the deferred aggregate only after that
        // drain so no handback event is stranded behind the lease release.
        guard self.activeActivityLease == lease,
              self.meetingAudioHandoffGeneration == generation
        else { return }
        let deferredReason = self.deferredMeetingRouteRecoveryReason
        let shouldPrewarm = self.meetingHandoffShouldRestorePreparedCapture ||
            self.deferredMeetingRouteRecoveryRequiresPrewarm
        let shouldReconcile = self.deferredMeetingRouteRecoveryReconcilesInput
        self.meetingHandoffShouldRestorePreparedCapture = false
        self.deferredMeetingRouteRecoveryReason = nil
        self.deferredMeetingRouteRecoveryRequiresPrewarm = false
        self.deferredMeetingRouteRecoveryReconcilesInput = false
        self.releaseExclusiveActivity(lease)

        if shouldPrewarm || deferredReason != nil {
            self.scheduleAudioRouteRecovery(
                reason: deferredReason ?? "meeting audio handback",
                requiresIdlePrewarm: shouldPrewarm,
                reconcilesInputSelection: shouldReconcile
            )
        }
    }

    private func releaseDictationActivityIfNeeded() {
        guard let lease = self.dictationActivityLease else { return }
        self.dictationActivityLease = nil
        self.releaseExclusiveActivity(lease)
    }

    private let audioCaptureReadinessGate = AudioCaptureReadinessGate()
    private let firstPCMTimeoutNanoseconds: UInt64 = 2_000_000_000
    private var audioCaptureStartGeneration: UInt64 = 0
    private var isPronunciationTrainingStart = false
    private var pronunciationTrainingStartGeneration: String?
    private var isPronunciationTrainingStartCurrent: Bool {
        !self.isPronunciationTrainingStart || (DictionaryMatcherExperiment.sharedFeaturesEnabled &&
            self.pronunciationTrainingStartGeneration == DictionaryMatcherExperiment.generation)
    }

    private var pendingAudioCaptureBackendStart: Task<Void, Error>?
    private var mediaPlaybackService = MediaPlaybackService.shared
    private var audioCaptureAttemptID: UInt64 = 0
    private var isTerminating = false
    private var hasCompletedFirstTranscription: Bool = false // Track if model has warmed up with first transcription
    private var lastBoostHitTerm: String?
    private var hasPendingParakeetVocabularyReload: Bool = false
    private var vocabularyChangeObserver: NSObjectProtocol?
    private var clamshellStateChangeObserver: NSObjectProtocol?
    private var inputDeviceAvailabilityChangeObserver: NSObjectProtocol?

    // MARK: - Error Handling

    @Published var errorTitle: String = "Error"
    @Published var errorMessage: String = ""
    @Published var showError: Bool = false
    let audioCaptureFailurePresented = PassthroughSubject<Void, Never>()

    private func presentAudioCaptureFailure(title: String, message: String) {
        self.errorTitle = title
        self.errorMessage = message
        self.showError = true
        self.audioCaptureFailurePresented.send()
    }

    #if DEBUG
    /// Exercise the real recovery coordinator with fake hardware, without
    /// initializing a model, recording a physical microphone, or changing defaults.
    var recoveryPacketHandlerForTesting: DirectCoreAudioPacketHandler {
        let pipeline = self.audioCapturePipeline
        return { samples, frames, rate, hostTime, sampleTime in
            pipeline.handle(
                samples: samples,
                frameCount: frames,
                sampleRate: rate,
                inputHostTime: hostTime,
                inputSampleTime: sampleTime
            )
        }
    }

    func configureAudioRouteRecoveryForTesting(
        controller: DirectCoreAudioLifecycleController,
        devices: [AudioDevice.Device],
        initialSamples: [Float]
    ) {
        precondition(self.isRunning == false && self.isStarting == false)
        self.directAudioControllerEpoch &+= 1
        self.directAudioLifecycleController = controller
        self.currentDirectAudioController.value = controller
        self.cacheCurrentDeviceList(devices)
        self.benchmarkSessionID = 987_654
        self.audioCaptureStartGeneration &+= 1
        self.audioCaptureAttemptID &+= 1
        self.activeAudioCaptureBackend = .directCoreAudio
        self.audioBuffer.append(initialSamples)
        self.audioCapturePipeline.setRecordingEnabled(
            true, sessionID: self.benchmarkSessionID, attemptID: self.audioCaptureAttemptID
        )
        self.isRunning = true
    }

    func directCoreAudioDeviceSelectionForTesting(
        controller: DirectCoreAudioLifecycleController
    ) async throws -> DirectCoreAudioDeviceSelection? {
        precondition(self.isRunning == false && self.isStarting == false)
        self.directAudioControllerEpoch &+= 1
        self.directAudioLifecycleController = controller
        self.currentDirectAudioController.value = controller
        return try await self.directCoreAudioDeviceSelection()
    }

    func triggerAudioRouteRecoveryForTesting() {
        self.scheduleAudioRouteRecovery(
            reason: "injected input change", requiresIdlePrewarm: true, reconcilesInputSelection: true
        )
    }

    func useMediaPlaybackForTesting(_ service: MediaPlaybackService) {
        self.mediaPlaybackService = service
    }

    func failAudioRouteRecoveryForTesting(stale: Bool = false) async {
        await self.finishAudioRouteRecoveryFailure(AudioRouteRecoveryRequest(
            generation: stale ? self.audioRouteRecoveryGeneration &- 1 : self.audioRouteRecoveryGeneration,
            reason: "injected recovery failure",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: false
        ), error: BoundedAudioHardwareQueue.Failure.recovering)
    }

    var audioRouteRecoveryStateForTesting: (pending: Bool, recovering: Bool, acceptingPCM: Bool, samples: [Float]) {
        (
            self.pendingAudioRouteRecovery != nil,
            self.isRecoveringAudioRoute,
            self.audioCapturePipeline.isRecordingEnabledForTesting,
            self.audioBuffer.getAll()
        )
    }

    func configureDictationModeSwitchForTesting(
        ownedLease: ASRActivityLease?,
        starting: Bool = false,
        finalizing: Bool = false,
        dictionaryTraining: Bool = false
    ) {
        self.dictationActivityLease = ownedLease
        self.isStarting = starting
        self.isStoppingFinalTranscription = finalizing
        self.isDictionaryTrainingCaptureActive = dictionaryTraining
    }

    func beginDictationBufferDrainForTesting(recovering: Bool = false) -> (() -> Void)? {
        guard let token = self.recordingBufferHandoffGate.begin() else { return nil }
        if recovering { self.recordingBufferHandoffGate.markTimedOut(token) }
        return { self.recordingBufferHandoffGate.complete(token) }
    }

    func finishAudioRouteRecoveryTest() async {
        await self.cancelAudioRouteRecoveryAndWait()
        self.isRunning = false
        self.audioCapturePipeline.setRecordingEnabled(false)
        await self.directAudioLifecycleController.shutdown(reason: "test_complete")
        self.audioBuffer.clear()
    }
    #endif

    /// Returns a user-friendly status message for model loading state
    var modelStatusMessage: String {
        if self.isAsrReady { return "Model ready" }
        if self.isCancellingModelPreparation { return "Cancelling model preparation..." }
        if self.isCancellingModelDownload { return "Cancelling model download..." }
        if self.downloadingModelId != nil || self.isDownloadingModel || self.isLoadingModel {
            return self.modelPreparationStatusText
        }
        if self.modelsExistOnDisk { return "Model cached, needs loading" }
        return "Model not downloaded"
    }

    var modelPreparationStatusText: String {
        switch self.modelPreparationPhase {
        case .preparingDownload:
            return "Preparing download..."
        case .downloading:
            if let progress = self.downloadProgress {
                return "Downloading \(Int(progress * 100))%"
            }
            return "Downloading model..."
        case .optimizing:
            return "Optimizing model..."
        case .loading:
            return "Loading voice engine..."
        case nil:
            if self.isDownloadingModel { return "Preparing model..." }
            if self.isLoadingModel { return "Loading voice engine..." }
            return "Preparing model..."
        }
    }

    // MARK: - Transcription Provider (Settable)

    private let providerCache = SpeechProviderCache()

    /// Prevent concurrent provider.prepare() calls (download/load) from overlapping.
    /// Subsequent callers await the in-flight task.
    private var ensureReadyTask: Task<Void, Error>?
    private var ensureReadyTaskID: UUID?
    private var residentDictationModelID: String?
    private var ensureReadyProviderKey: String?
    private var ensureReadyOperationID: UUID?
    private var modelDownloadTask: Task<Void, Error>?
    private var modelDownloadOperationID: UUID?
    private var modelExistenceCheckID: UUID?

    private(set) var deletingModelID: String? {
        get { self.modelReadiness.deletingModelID }
        set { self.modelReadiness.deletingModelID = newValue }
    }

    #if DEBUG
    var modelProvidersForTesting: [SpeechModel: TranscriptionProvider] = [:]

    func prepareProviderRecoveryForTesting(_ provider: TranscriptionProvider, modelsAlreadyCached: Bool) async throws {
        try await SpeechModelReadiness.prepareProviderWithRecovery(provider: provider, modelsAlreadyCached: modelsAlreadyCached, progressHandler: { _ in })
    }

    #endif

    var hasActiveModelPreparation: Bool {
        self.ensureReadyTask != nil
    }

    var hasActiveModelDownload: Bool {
        self.modelDownloadTask != nil
    }

    func cancelModelPreparation() {
        guard let task = self.ensureReadyTask else { return }

        DebugLogger.shared.info("Cancelling ASR model preparation", source: "ASRService")
        self.isCancellingModelPreparation = true
        task.cancel()
    }

    func cancelModelDownload() {
        guard let task = self.modelDownloadTask else { return }
        self.isCancellingModelDownload = true
        task.cancel()
    }

    func shutdownForTermination() async {
        self.meetingModelResidency.beginTermination()
        self.isTerminating = true
        // Give media restoration the same quit window as audio cleanup.
        self.mediaPlaybackService.beginShutdown()
        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "app_termination")
        }
        let routeRecoveryShutdownStartedAt = Date().timeIntervalSince1970
        await self.cancelAudioRouteRecoveryAndWait()
        self.benchmarkLog(
            "route_recovery_shutdown elapsedMs=\(self.elapsedMilliseconds(since: routeRecoveryShutdownStartedAt))"
        )
        if self.isRunning {
            await self.stopWithoutTranscription()
        }
        let directCaptureShutdownStartedAt = Date().timeIntervalSince1970
        await self.directAudioLifecycleController.shutdown(reason: "app_termination")
        // A controller still blocked in native code refuses this immediately.
        for controller in self.quarantinedDirectAudioControllers {
            await controller.shutdown(reason: "app_termination")
        }
        self.benchmarkLog(
            "direct_capture_shutdown phase=\(self.directAudioLifecycleController.snapshot.phase.rawValue) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: directCaptureShutdownStartedAt))"
        )

        let preparationTask = self.ensureReadyTask
        let downloadTask = self.modelDownloadTask
        preparationTask?.cancel()
        downloadTask?.cancel()
        _ = await preparationTask?.result
        _ = await downloadTask?.result
        await self.providerResetDrain?.task.value
        self.streamingWorkState.invalidateProvider()
        // The scope body is independently owned because a future backend may suspend
        // outside the CoreML executor. Termination must join that work before releasing
        // its provider claim or the meeting activity lease.
        if let scope = self.activeMeetingASRScope {
            scope.cancelBody?()
            if let awaitBodyCompletion = scope.awaitBodyCompletion {
                await awaitBodyCompletion()
            }
        }
        if let meetingOwner = self.activeMeetingASRPreparationOwner,
           let claimToken = meetingOwner.currentClaimToken,
           meetingOwner.isClaimed || meetingOwner.isDraining
        {
            await meetingOwner.release(claimToken)
        }
        await self.meetingTranscriptionExecutor.cancelAndAwaitPending()
        self.flushDeferredMeetingLeaseReleaseIfReady()
        await self.transcriptionExecutor.cancelAndAwaitPending()

        self.providerCache.releaseAll()
        self.isAsrReady = false
        self.isLoadingModel = false
        self.isDownloadingModel = false
        await self.mediaPlaybackService.shutdown()
    }

    /// The transcription provider, selected based on the unified SpeechModel setting.
    /// Uses the new SettingsStore.selectedSpeechModel instead of old TranscriptionProviderOption.
    private var transcriptionProvider: TranscriptionProvider {
        let model = SettingsStore.shared.selectedSpeechModel
        #if DEBUG
        if let injected = self.modelProvidersForTesting[model] { return injected }
        #endif
        return self.providerCache.provider(for: model)
    }

    /// Returns the user-friendly name of the currently selected speech model
    var activeProviderName: String {
        SettingsStore.shared.selectedSpeechModel.displayName
    }

    /// Exposes the transcription provider for file transcription (MeetingTranscriptionService)
    /// This allows file transcription to work with any provider (Parakeet, Whisper, etc.)
    var fileTranscriptionProvider: TranscriptionProvider {
        self.transcriptionProvider
    }

    private func currentTranscriptionAnalyticsDimensions() -> (provider: String, model: String) {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return (
            provider: selectedModel.provider.rawValue.lowercased(),
            model: selectedModel.rawValue
        )
    }

    private func elapsedMilliseconds(since start: TimeInterval?) -> Int {
        guard let start else { return -1 }
        return Int(((Date().timeIntervalSince1970 - start) * 1000).rounded())
    }

    private func benchmarkLog(_ message: @autoclosure () -> String) {
        DebugLogger.shared.benchmark("ASR_BENCH", message: "session=\(self.benchmarkSessionID) \(message())", source: "ASRBenchmark")
    }

    /// Gets a provider for a specific model (without changing the active selection)
    /// Used for downloading models without switching the active model.
    private func getProvider(for model: SpeechModel, updateWeights: Bool = false) -> TranscriptionProvider {
        #if DEBUG
        if let injected = self.modelProvidersForTesting[model] { return injected }
        #endif
        return SpeechProviderCache.makeStandaloneProvider(for: model, updateWeights: updateWeights)
    }

    /// Downloads a specific model without changing the active selection.
    /// - Parameters:
    ///   - model: The model to download
    ///   - progressHandler: Optional callback for download progress (0.0 to 1.0)
    func downloadModel(
        _ model: SpeechModel,
        source: AnalyticsModelDownloadSource = .settings,
        updateWeights: Bool = false,
        progressHandler: ((Double) -> Void)?
    ) async throws {
        try Task.checkCancellation()
        let updateLease: ASRActivityLease?
        if updateWeights {
            guard model == .fluidParakeetMini || model == .fluidParakeetPico else {
                throw NSError(domain: "ASRService", code: -2003, userInfo: [NSLocalizedDescriptionKey: "Only Mini and Pico support weight updates."])
            }
            guard !self.isTerminating, !self.isRunning, !self.isStarting, !self.isStoppingFinalTranscription,
                  !self.recordingBufferHandoffGate.isActive, !self.recordingBufferHandoffGate.isRecovering,
                  !self.isMicrophonePreviewRequested, !self.isMicrophonePreviewActive, !self.isDictionaryTrainingCaptureActive,
                  self.providerResetDrain == nil, !self.isCancellingModelPreparation, !self.isCancellingModelDownload,
                  !self.meetingModelResidency.isExclusive
            else {
                throw ASRActivityError.activityInProgress(self.activeExclusiveActivity ?? .modelMaintenance)
            }
            updateLease = try self.acquireExclusiveActivity(.modelMaintenance)
        } else {
            updateLease = nil
        }
        defer { if let updateLease { self.releaseExclusiveActivity(updateLease) } }
        guard self.activeExclusiveActivity != .settingsRestore else {
            throw ASRActivityError.activityInProgress(.settingsRestore)
        }
        let admission = try self.meetingModelResidency.beginOperation(owner: "speech", modelID: model.id)
        defer { self.meetingModelResidency.endOperation(admission) }
        if self.isMeetingASRPreparationClaimed {
            throw MeetingASRPreparationError.preparationInProgress
        }
        guard self.deletingModelID == nil, self.modelDownloadTask == nil, self.ensureReadyTask == nil else {
            throw NSError(
                domain: "ASRService",
                code: -2001,
                userInfo: [NSLocalizedDescriptionKey: "Another model operation is already in progress."]
            )
        }

        let operationID = UUID()
        let provider = self.getProvider(for: model, updateWeights: updateWeights)
        self.modelDownloadOperationID = operationID
        self.downloadingModelId = model.id
        self.downloadProgress = nil
        self.modelPreparationPhase = .preparingDownload
        self.isCancellingModelDownload = false

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                DebugLogger.shared.info("Downloading model: \(model.displayName) (without changing active selection)", source: "ASRService")
                try await provider.prepare(progressHandler: { progress in
                    Task { @MainActor in
                        guard
                            self.modelDownloadOperationID == operationID,
                            !self.isCancellingModelDownload
                        else {
                            return
                        }
                        self.modelReadiness.applyModelPreparationProgress(
                            progress,
                            updatesActiveModelState: false,
                            externalProgressHandler: progressHandler,
                            analyticsOperationID: operationID,
                            analyticsDescriptor: model.analyticsDescriptor,
                            analyticsSource: source
                        )
                    }
                })
                if !updateWeights { try Task.checkCancellation() }
                DebugLogger.shared.info("Model download completed: \(model.displayName)", source: "ASRService")
            } catch {
                if ParakeetArchiveDownloader.isCleanupFailure(error) { throw error }
                let wasCancelled = Task.isCancelled || SpeechModelReadiness.isModelPreparationCancellation(error)
                if wasCancelled, !updateWeights,
                   provider.shouldClearCacheAfterCancellation,
                   provider.modelsExistOnDisk() == false
                {
                    try? await provider.clearCache()
                }
                if wasCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }
        self.modelDownloadTask = task

        defer {
            if self.modelDownloadOperationID == operationID {
                self.modelDownloadTask = nil
                self.modelDownloadOperationID = nil
                self.downloadingModelId = nil
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
                self.isCancellingModelDownload = false
                SpeechModelInstallationSnapshot.shared.refresh()
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if updateWeights, SettingsStore.shared.selectedSpeechModel == model {
                // Release the update lease only after progress and operation cleanup;
                // the normal deferred reset then retires the old active checkpoint.
                self.providerResetPending = true
            }
            self.modelReadiness.finishModelDownloadAnalytics(operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            self.modelReadiness.finishModelDownloadAnalytics(operationID: operationID, outcome: .cancelled)
            throw CancellationError()
        } catch {
            if updateWeights, SettingsStore.shared.selectedSpeechModel == model,
               let failure = error as? ParakeetArchiveDownloader.DownloadError,
               case .replacementCleanupFailed = failure
            {
                self.providerResetPending = true
            }
            self.modelReadiness.finishModelDownloadAnalytics(operationID: operationID, outcome: .failed)
            throw error
        }
    }

    /// Call this when the transcription provider setting changes to reset state
    func resetTranscriptionProvider() {
        self.meetingModelResidency.vetoRestoration(owner: "speech")
        guard !self.recordingBufferHandoffGate.isRecovering else {
            self.resetProviderAfterStreamingRecovery = true
            return
        }

        guard self.activeActivityLease == nil else {
            self.providerResetPending = true
            DebugLogger.shared.info(
                "ASRService: Deferring provider reset until \(self.activeExclusiveActivity?.displayName ?? "active work") finishes",
                source: "ASRService"
            )
            return
        }

        guard let resetLease = try? self.acquireExclusiveActivity(.modelMaintenance) else {
            self.providerResetPending = true
            return
        }
        let newModel = SettingsStore.shared.selectedSpeechModel
        DebugLogger.shared.info("ASRService: Switching to '\(newModel.displayName)', resetting provider state...", source: "ASRService")

        // Any in-flight preview belongs to the provider being retired. Its operation
        // still drains through the executor, but must not publish into this session.
        self.streamingWorkState.invalidateProvider()
        self.isAsrReady = false
        self.modelsExistOnDisk = false
        self.isLoadingModel = false
        self.isDownloadingModel = false
        if !self.hasActiveModelDownload {
            self.downloadProgress = nil
            self.modelPreparationPhase = nil
        }
        self.hasCompletedFirstTranscription = false // Reset warm-up state when switching models
        let retiringTask = self.ensureReadyTask
        if let task = retiringTask {
            self.isCancellingModelPreparation = true
            task.cancel()
        }
        let resetDrainID = UUID()
        let executor = self.transcriptionExecutor
        let resetDrainTask = Task { @MainActor [weak self] in
            await executor.cancelAndAwaitPending()
            // A completed handle must not leave future imports permanently busy.
            if self?.providerResetDrain?.id == resetDrainID {
                self?.providerResetDrain = nil
            }
        }
        self.providerResetDrain = (resetDrainID, resetDrainTask)
        // ensureAsrReady joins this executor drain. The retiring preparation task
        // separately remains retained until its provider cancellation cleanup finishes.
        self.ensureReadyProviderKey = nil
        self.ensureReadyOperationID = nil
        self.lastBoostHitTerm = nil
        self.wordBoostStatusText = "Word boost: off"

        // Reset cached providers to force re-initialization with new settings
        self.providerCache.resetAfterModelChange()

        // CRITICAL FIX: Check if the NEW model's files exist on disk
        // This prevents UI from showing "Download" when model is already downloaded
        // Use Task for async check to support providers like AppleSpeechAnalyzerProvider
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.releaseExclusiveActivity(resetLease) }
            _ = await retiringTask?.result
            guard SettingsStore.shared.selectedSpeechModel == newModel else { return }
            await self.checkIfModelsExistAsync()
            await MainActor.run {
                self.refreshWordBoostStatus()
            }
            DebugLogger.shared.info("ASRService: Provider reset complete, will initialize '\(newModel.displayName)' on next use", source: "ASRService")
        }
    }

    private enum AudioCaptureBackend {
        case none
        case directCoreAudio
    }

    private struct AudioRouteRecoveryRequest {
        let generation: UInt64
        let reason: String
        let requiresIdlePrewarm: Bool
        let reconcilesInputSelection: Bool
    }

    private lazy var directAudioLifecycleController: DirectCoreAudioLifecycleController =
        self.makeDirectAudioLifecycleController()
    /// HAL callbacks run off the main actor; they reach the current controller here.
    private let currentDirectAudioController = CurrentDirectAudioController()
    private var directAudioControllerEpoch: UInt64 = 0
    /// Controllers whose serialized queue is stuck inside a native Core Audio
    /// call. The blocked call itself keeps each one alive; this list lets them
    /// be shut down once that call returns, or at quit.
    private var quarantinedDirectAudioControllers: [DirectCoreAudioLifecycleController] = []
    /// Built-in microphone starts finish in under 0.5 s; the ones that hang
    /// never return (AA-180). Other inputs (Bluetooth, USB, Continuity) can be
    /// legitimately slow, so they get a longer deadline.
    private let builtInDirectCaptureStartTimeout: TimeInterval = 3
    private let externalDirectCaptureStartTimeout: TimeInterval = 10
    /// Matches the controller's own recovery deadline: ordinary serialized
    /// cleanup gets this long before its controller is treated as blocked.
    private let directCaptureRecoveryGracePeriod: TimeInterval = 5

    private func makeDirectAudioLifecycleController() -> DirectCoreAudioLifecycleController {
        let pipeline = self.audioCapturePipeline
        self.directAudioControllerEpoch &+= 1
        let epoch = self.directAudioControllerEpoch
        let controller = DirectCoreAudioLifecycleController(
            packetHandler: { samples, frameCount, sampleRate, inputHostTime, inputSampleTime in
                pipeline.handle(
                    samples: samples,
                    frameCount: frameCount,
                    sampleRate: sampleRate,
                    inputHostTime: inputHostTime,
                    inputSampleTime: inputSampleTime
                )
            },
            onFormatInvalidated: { [weak self] invalidation in
                Task { @MainActor [weak self] in
                    // A quarantined controller keeps its listeners, and its
                    // generations can collide with the replacement's.
                    guard let self, self.directAudioControllerEpoch == epoch else { return }
                    await self.handleDirectCaptureFormatInvalidation(invalidation)
                }
            }
        )
        self.currentDirectAudioController.value = controller
        return controller
    }

    /// AudioDeviceStart can block indefinitely after audio device churn. The
    /// controller's serialized queue then never drains, and every later start
    /// fails with `recovering` until the app restarts. Leave that controller
    /// behind and continue on a fresh one. Returns whether capture is usable.
    private func replaceDirectAudioLifecycleControllerIfBlocked(
        reason: String,
        gracePeriod: TimeInterval? = nil
    ) async -> Bool {
        let controller = self.directAudioLifecycleController
        guard controller.isRecoveringHardware else { return true }
        if await controller.waitForHardwareAvailability(
            timeout: gracePeriod ?? self.directCaptureRecoveryGracePeriod
        ) {
            return true
        }
        // A cancelled wait says nothing about the controller; it may still be
        // draining ordinary cleanup.
        guard Task.isCancelled == false else { return false }
        guard self.directAudioLifecycleController === controller else {
            // Another caller replaced it while this one waited.
            return self.directAudioLifecycleController.isRecoveringHardware == false
        }
        guard self.isTerminating == false else { return false }
        self.releaseRecoveredQuarantinedDirectAudioControllers()
        self.quarantinedDirectAudioControllers.append(controller)
        self.directAudioLifecycleController = self.makeDirectAudioLifecycleController()
        if self.activeAudioCaptureBackend == .directCoreAudio {
            self.activeAudioCaptureBackend = .none
        }
        DebugLogger.shared.warning(
            "Direct capture blocked in a native Core Audio call; continuing on a fresh controller " +
                "(reason=\(reason), quarantined=\(self.quarantinedDirectAudioControllers.count))",
            source: "ASRService"
        )
        return true
    }

    /// A quarantined controller whose native call has since returned has
    /// drained its own recovery. Shut it down off the main actor, so its HAL
    /// listeners go away, and free its slot.
    private func releaseRecoveredQuarantinedDirectAudioControllers() {
        let recovered = self.quarantinedDirectAudioControllers.filter { $0.isRecoveringHardware == false }
        guard recovered.isEmpty == false else { return }
        self.quarantinedDirectAudioControllers.removeAll { $0.isRecoveringHardware == false }
        for controller in recovered {
            Task.detached {
                await controller.shutdown(reason: "quarantine_released")
            }
        }
    }

    private var activeAudioCaptureBackend: AudioCaptureBackend = .none
    private var audioStartAttemptInputUID: String?
    private var audioStartAttemptInputName: String?
    private var audioStartAttemptIsBluetooth = false
    private var audioStartAttemptIsInternalMicrophone = false
    private var deferredBluetoothStartupRouteRecovery =
        AudioCaptureIdlePolicy.DeferredBluetoothRouteRecovery()
    private var silentPCMRecoveryWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()

    private var hasPreparedAudioCapture: Bool {
        self.directAudioLifecycleController.snapshot.isPrepared
    }

    private func prewarmConfiguredAudioCaptureIfPossible(
        reason: String,
        allowDuringRouteRecovery: Bool = false
    ) async {
        guard self.isTerminating == false else {
            DebugLogger.shared.debug("Audio capture prewarm skipped - app is terminating", source: "ASRService")
            return
        }
        guard self.activeExclusiveActivity != .meeting else {
            DebugLogger.shared.debug("Audio capture prewarm deferred - meeting owns audio topology", source: "ASRService")
            self.meetingHandoffShouldRestorePreparedCapture = true
            return
        }
        let handoffGeneration = self.meetingAudioHandoffGeneration
        guard self.micStatus == .authorized else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - mic not authorized", source: "ASRService")
            return
        }
        guard self.isRunning == false,
              self.isStarting == false || allowDuringRouteRecovery
        else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - capture active", source: "ASRService")
            return
        }
        guard allowDuringRouteRecovery || self.isRecoveringAudioRoute == false else {
            DebugLogger.shared.debug("Audio engine prewarm skipped - route recovery active", source: "ASRService")
            return
        }
        guard self.hasPreparedAudioCapture == false else {
            DebugLogger.shared.debug("Audio capture prewarm skipped - backend already prepared", source: "ASRService")
            return
        }

        let startedAt = Date().timeIntervalSince1970
        do {
            _ = try await self.prepareDirectAudioInput(reason: reason)
            guard self.activeExclusiveActivity != .meeting,
                  self.meetingAudioHandoffGeneration == handoffGeneration,
                  self.isTerminating == false
            else {
                await self.directAudioLifecycleController.invalidate(reason: "stale_prewarm_after_meeting_handoff")
                self.activeAudioCaptureBackend = .none
                return
            }
            self.benchmarkLog("direct_audio_prewarm reason=\(reason) elapsedMs=\(self.elapsedMilliseconds(since: startedAt))")
        } catch {
            DebugLogger.shared.warning(
                "Direct Core Audio prewarm failed: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    private func resolvedInputDeviceForCapture(
        availableInputs: [AudioDevice.Device],
        defaultInputUID: String?,
        excluding excludedUIDs: Set<String> = []
    ) -> AudioDevice.Device? {
        return AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture(
            availableInputs: availableInputs,
            defaultInputUID: defaultInputUID,
            excluding: excludedUIDs
        )
    }

    /// Reads devices on the controller's bounded idle device queue, never on the
    /// main actor: a stalled coreaudiod would otherwise freeze the app during
    /// prewarm. The recording start path keeps its own queue, so a stuck
    /// prewarm query cannot hold up the next recording.
    private func directCoreAudioDeviceSelection(
        excluding excludedUIDs: Set<String> = []
    ) async throws -> DirectCoreAudioDeviceSelection? {
        let snapshot = try await self.directAudioLifecycleController.readDeviceSnapshot()
        if let inputUID = self.resolvedInputDeviceForCapture(
            availableInputs: snapshot.devices.filter(\.hasInput),
            defaultInputUID: snapshot.defaultInputUID,
            excluding: excludedUIDs
        )?.uid {
            return .preferredUID(inputUID)
        }
        return nil
    }

    /// Prepares the direct device callback without starting hardware IO. This
    /// keeps the default idle state privacy-friendly while removing device and
    /// ring allocation from the hotkey path.
    private func prepareDirectAudioInput(
        reason: String
    ) async throws -> DirectCoreAudioLifecycleController.Snapshot {
        guard self.micStatus == .authorized else {
            throw NSError(
                domain: "ASRService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access is not authorized."]
            )
        }
        guard let selection = try await self.directCoreAudioDeviceSelection() else {
            throw NSError(
                domain: "ASRService",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "No usable microphone is available."]
            )
        }
        let device = try await self.directAudioLifecycleController.resolveDevice(
            selection: selection,
            reason: "prepare:\(reason)"
        )
        let snapshot = try await self.directAudioLifecycleController.prepare(
            deviceID: device.id,
            deviceName: device.name,
            reason: reason
        )
        DebugLogger.shared.info(
            "Prepared direct Core Audio input '\(device.name)' " +
                "(\(Int((snapshot.sampleRate ?? 0).rounded()))Hz, " +
                "\(snapshot.bufferFrameSize ?? 0) frames, generation=\(snapshot.generation), " +
                "reason=\(reason))",
            source: "ASRService"
        )
        return snapshot
    }

    /// Bridge the app's Cancel action to the actual backend task. The task's
    /// cancellation handler also covers cancellation before queue admission.
    private func startCancellableAudioCapture(
        excluding excludedInputUIDs: Set<String>,
        forcingInputUID: String?,
        onInputSnapshotRead: @escaping @MainActor (Int) -> Void
    ) async throws {
        let task = Task {
            try await self.startConfiguredAudioCapture(
                excluding: excludedInputUIDs,
                forcingInputUID: forcingInputUID,
                onInputSnapshotRead: onInputSnapshotRead
            )
        }
        self.pendingAudioCaptureBackendStart = task
        defer { self.pendingAudioCaptureBackendStart = nil }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func startConfiguredAudioCapture(
        excluding excludedInputUIDs: Set<String> = [],
        forcingInputUID: String? = nil,
        retriesBlockedStart: Bool = true,
        onInputSnapshotRead: @MainActor (Int) -> Void = { _ in }
    ) async throws {
        let startGeneration = self.audioCaptureStartGeneration
        let previousAttemptIdentity = self.audioStartAttemptInputUID.map {
            AudioCaptureIdlePolicy.CaptureAttemptIdentity(
                uid: $0,
                name: self.audioStartAttemptInputName,
                isBluetooth: self.audioStartAttemptIsBluetooth,
                isInternalMicrophone: self.audioStartAttemptIsInternalMicrophone
            )
        }
        self.audioStartAttemptInputUID = nil
        self.audioStartAttemptInputName = nil
        self.audioStartAttemptIsBluetooth = false
        self.audioStartAttemptIsInternalMicrophone = false
        do {
            try self.checkCaptureStartGeneration(startGeneration)
            if self.directAudioLifecycleController.isRecoveringHardware {
                let available = await self.replaceDirectAudioLifecycleControllerIfBlocked(reason: "recording_start")
                try self.checkCaptureStartGeneration(startGeneration)
                guard available else { throw BoundedAudioHardwareQueue.Failure.recovering }
            }
            let deviceSnapshot = try await self.directAudioLifecycleController.readCaptureDeviceSnapshot()
            try self.checkCaptureStartGeneration(startGeneration)
            let allDevices = deviceSnapshot.devices
            let availableInputs = allDevices.filter(\.hasInput)
            onInputSnapshotRead(availableInputs.count)
            let selectedInput: AudioDevice.Device?
            if let forcingInputUID {
                selectedInput = availableInputs.first { $0.uid == forcingInputUID }
            } else {
                let resolvedInput = self.resolvedInputDeviceForCapture(
                    availableInputs: availableInputs,
                    defaultInputUID: deviceSnapshot.defaultInputUID,
                    excluding: excludedInputUIDs
                )
                selectedInput = AudioCaptureIdlePolicy.bluetoothInputAwaitingAvailability(
                    priorityInputUIDs: SettingsStore.shared.microphonePriority.map(\.uid),
                    preferredInputUID: SettingsStore.shared.preferredInputDeviceUID,
                    resolvedInputUID: resolvedInput?.uid,
                    allDevices: allDevices,
                    excluding: excludedInputUIDs
                ) ?? resolvedInput
            }
            guard let attemptIdentity = AudioCaptureIdlePolicy.CaptureAttemptIdentity.resolve(
                selectedInput: selectedInput,
                forcingInputUID: forcingInputUID,
                previous: previousAttemptIdentity
            ) else {
                throw NSError(
                    domain: "ASRService",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "No remaining microphone is available."]
                )
            }
            let selection = DirectCoreAudioDeviceSelection.preferredUID(attemptIdentity.uid)
            // Preserve the selected endpoint's identity before the async UID
            // resolution, where Bluetooth topology churn can make it vanish.
            self.audioStartAttemptInputUID = attemptIdentity.uid
            self.audioStartAttemptInputName = attemptIdentity.name
            self.audioStartAttemptIsBluetooth = attemptIdentity.isBluetooth
            self.audioStartAttemptIsInternalMicrophone = attemptIdentity.isInternalMicrophone
            let device = try await self.directAudioLifecycleController.resolveDevice(
                selection: selection,
                reason: "recording_start"
            )
            try self.checkCaptureStartGeneration(startGeneration)
            self.audioStartAttemptInputUID = device.uid
            self.audioStartAttemptInputName = device.name
            self.audioStartAttemptIsBluetooth = device.isBluetooth
            self.audioStartAttemptIsInternalMicrophone = device.isUnavailableWhenClamshellClosed
            AppServices.shared.microphonePreferenceCoordinator.reportResolvedSelection(
                uid: device.uid,
                name: device.name
            )
            let snapshot = try await self.directAudioLifecycleController.start(
                deviceID: device.id,
                deviceName: device.name,
                reason: "recording_start",
                timeout: device.isUnavailableWhenClamshellClosed
                    ? self.builtInDirectCaptureStartTimeout
                    : self.externalDirectCaptureStartTimeout
            )
            try self.checkCaptureStartGeneration(startGeneration)
            self.activeAudioCaptureBackend = .directCoreAudio
            let callbackDurationMilliseconds =
                Double(snapshot.bufferFrameSize ?? 0) /
                max(snapshot.sampleRate ?? 0, 1) * 1000
            let callbackMs = Int(callbackDurationMilliseconds.rounded())
            self.benchmarkLog(
                "audio_backend kind=direct_core_audio device=\(snapshot.deviceID ?? 0) " +
                    "generation=\(snapshot.generation) frames=\(snapshot.bufferFrameSize ?? 0) " +
                    "sampleRate=\(Int((snapshot.sampleRate ?? 0).rounded())) callbackMs=\(callbackMs)"
            )
            return
        } catch {
            await self.directAudioLifecycleController.invalidate(reason: "recording_start_failed")
            DebugLogger.shared.error(
                "Direct Core Audio capture failed: \(error.localizedDescription)",
                source: "ASRService"
            )
            // A timed-out start is still blocked in native code, so its
            // controller cannot run another operation until that call
            // returns. Move to a fresh controller now and retry once.
            if (error as? BoundedAudioHardwareQueue.Failure) == .timedOut,
               await self.replaceDirectAudioLifecycleControllerIfBlocked(
                   reason: "recording_start_timeout",
                   gracePeriod: 0
               ),
               retriesBlockedStart
            {
                try self.checkCaptureStartGeneration(startGeneration)
                try await self.startConfiguredAudioCapture(
                    excluding: excludedInputUIDs,
                    forcingInputUID: forcingInputUID,
                    retriesBlockedStart: false,
                    onInputSnapshotRead: onInputSnapshotRead
                )
                return
            }
            throw error
        }
    }

    private func checkCaptureStartGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == self.audioCaptureStartGeneration, self.isTerminating == false,
              self.isPronunciationTrainingStartCurrent
        else {
            throw CancellationError()
        }
    }

    private func stopActiveAudioCapture(
        retainDirectPreparedCapture: Bool = true,
        reason: String
    ) async {
        switch self.activeAudioCaptureBackend {
        case .directCoreAudio:
            let captureAwaitStartedAt = ProcessInfo.processInfo.systemUptime
            let report = await self.directAudioLifecycleController.stop(
                retainPrepared: retainDirectPreparedCapture,
                reason: reason,
                recoveringRoute: self.isRecoveringAudioRoute
            )
            DebugLogger.shared.debug(
                "CLOSE_DETAIL audioCallerResumed uptime=\(ProcessInfo.processInfo.systemUptime) awaitMs=\((ProcessInfo.processInfo.systemUptime - captureAwaitStartedAt) * 1000)",
                source: "StopTiming"
            )
            if report.status != noErr {
                DebugLogger.shared.warning(
                    "Direct Core Audio stop returned OSStatus \(report.status)",
                    source: "ASRService"
                )
            }
            if report.droppedPackets > 0 {
                DebugLogger.shared.warning(
                    "Direct Core Audio dropped \(report.droppedPackets) packet(s)",
                    source: "ASRService"
                )
            }
        case .none:
            break
        }
        self.activeAudioCaptureBackend = .none
    }

    private var micPermissionGranted = false
    private var isRequestingMicrophoneAccess = false

    // Internal access for MeetingTranscriptionService to share models
    // Note: Only available when using FluidAudioProvider (Apple Silicon)
    #if arch(arm64)
    var asrManager: AsrManager? {
        (self.transcriptionProvider as? FluidAudioProvider)?.underlyingManager
    }
    #else
    var asrManager: Any? {
        nil
    }
    #endif

    // Thread-safe buffer to prevent "Array mutation while enumerating" and memory corruption crashes
    // during long sessions where reallocation occurs frequently.
    private let audioBuffer = ThreadSafeAudioBuffer()
    // Transient, read-only audio for a focused dictionary test. No history setting or disk write.
    private let dictionaryTestAudioSubject = PassthroughSubject<[Float], Never>()
    var dictionaryTestAudioPublisher: AnyPublisher<[Float], Never> {
        self.dictionaryTestAudioSubject.eraseToAnyPublisher()
    }

    private var lastCompletedAudioSnapshot: DictationAudioSnapshot?
    private var lastDictionaryLearningRecording: DictionaryLearningRecording?
    private var dictionaryLearningExpiryTask: Task<Void, Never>?

    // Streaming transcription state (no VAD)
    private let streamingTaskLifecycle = StreamingTaskLifecycle()
    private var streamingWorkState = StreamingTranscriptionWorkState()
    private var streamingSchedulingSessionID: Int?
    private let recordingBufferHandoffGate = RecordingBufferHandoffGate()
    private var timedOutStreamingHandoff: (sessionID: Int, token: RecordingBufferHandoffGate.Token)?
    private var resetProviderAfterStreamingRecovery = false
    private var streamingHealthCheckCount: Int = 0
    private var streamingHealthLastBufferCount: Int = 0
    private var lastProcessedSampleCount: Int = 0
    private var isProcessingChunk: Bool = false
    private var skipNextChunk: Bool = false
    private var previousFullTranscription: String = ""
    private var benchmarkSessionID: Int = 0
    private var benchmarkRecordingStartedAt: TimeInterval?
    private var benchmarkStreamingChunkIndex: Int = 0
    private var benchmarkCompletedStreamingChunks: Int = 0
    private var benchmarkLastChunkSampleCount: Int = 0
    private let transcriptionExecutor = TranscriptionExecutor() // Serializes all CoreML access
    /// Scoped meeting ASR work; drained independently of the shared legacy executor.
    private let meetingTranscriptionExecutor = TranscriptionExecutor()
    private var providerResetDrain: (id: UUID, task: Task<Void, Never>)?
    private var audioRouteRecoveryTask: Task<Void, Never>?
    private let audioRouteRecoveryDelayNanoseconds: UInt64 = 300_000_000
    private var audioRouteRecoveryGeneration: UInt64 = 0
    private var pendingAudioRouteRecovery: AudioRouteRecoveryRequest?
    private var isRecoveringAudioRoute = false

    private var audioLevelSubject = PassthroughSubject<CGFloat, Never>()
    var audioLevelPublisher: AnyPublisher<CGFloat, Never> {
        self.audioLevelSubject.eraseToAnyPublisher()
    }

    private var lastAudioLevelSentAt: TimeInterval = 0

    private func retainDictionaryLearningRecording(_ recording: DictionaryLearningRecording?) {
        self.dictionaryLearningExpiryTask?.cancel()
        self.dictionaryLearningExpiryTask = nil
        self.lastDictionaryLearningRecording = recording
        guard let id = recording?.id else { return }
        self.dictionaryLearningExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DictionaryLearningRecording.lifetime))
            guard !Task.isCancelled, let self, self.lastDictionaryLearningRecording?.id == id else { return }
            self.lastDictionaryLearningRecording = nil
            self.dictionaryLearningExpiryTask = nil
        }
    }

    func originalAudioEnrollment(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture {
        try await self.meetingModelResidency.withBackgroundOperation(owner: "speech", modelID: evidence.modelKey) {
            try await self.performOriginalAudioEnrollment(evidence)
        }
    }

    private func performOriginalAudioEnrollment(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture {
        let generation = DictionaryMatcherExperiment.generation
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { throw CancellationError() }
        try Task.checkCancellation()
        guard self.activeExclusiveActivity == nil else { throw CancellationError() }
        #if arch(arm64)
        if let provider = self.providerCache.fluidAudioProvider,
           let capture = try await provider.originalAudioEnrollment(evidence)
        {
            try Task.checkCancellation()
            guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
                  DictionaryMatcherExperiment.generation == generation else { throw CancellationError() }
            return capture
        }
        #endif
        try Task.checkCancellation()
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
              DictionaryMatcherExperiment.generation == generation,
              self.activeExclusiveActivity == nil else { throw CancellationError() }
        let capture = try await OriginalAudioEmbeddingExtractor.extract(evidence)
        try Task.checkCancellation()
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
              DictionaryMatcherExperiment.generation == generation else { throw CancellationError() }
        return capture
    }

    func consumeDictionaryLearningRecording() -> DictionaryLearningRecording? {
        defer { self.retainDictionaryLearningRecording(nil) }
        return self.lastDictionaryLearningRecording
    }

    func consumeLastCompletedAudioSnapshot() -> DictationAudioSnapshot? {
        let snapshot = self.lastCompletedAudioSnapshot
        self.lastCompletedAudioSnapshot = nil
        return snapshot
    }

    func consumeLastFinalTranscriptionDurationMs() -> Int? {
        let duration = self.lastFinalTranscriptionDurationMs
        self.lastFinalTranscriptionDurationMs = nil
        return duration
    }

    /// FluidAudio's own Parakeet time for the last final pass; nil for every other engine.
    func consumeLastFinalParakeetProcessingMs() -> Int? {
        let duration = self.lastFinalParakeetProcessingMs
        self.lastFinalParakeetProcessingMs = nil
        return duration
    }

    func dictionaryTrainingAudioChunk(at offset: Int, count: Int) -> [Float] {
        self.audioBuffer.getRange(startingAt: offset, count: count)
    }

    private var streamingChunkDurationSeconds: Double {
        let selectedModel = SettingsStore.shared.selectedSpeechModel
        return selectedModel.streamingPreviewIntervalSeconds
    }

    private var minimumStreamingPreviewSamples: Int {
        Int(SettingsStore.shared.selectedSpeechModel.minimumStreamingPreviewSeconds * 16_000)
    }

    /// Processes captured audio off the @MainActor to avoid touching main-actor state
    /// from CoreAudio's realtime callback thread.
    private lazy var audioCapturePipeline: AudioCapturePipeline = {
        let readinessGate = self.audioCaptureReadinessGate
        return AudioCapturePipeline(
            audioBuffer: self.audioBuffer,
            onFirstAudio: { sessionID, attemptID, sampleCount, frameLength, sampleRate, acquisitionMs, elapsedMs in
                Task {
                    readinessGate.signalFirstPCM(
                        sessionID: sessionID,
                        attemptID: attemptID
                    )
                }
                DispatchQueue.main.async {
                    let bufferMs = Int((Double(frameLength) / sampleRate * 1000).rounded())
                    DebugLogger.shared.benchmark(
                        "ASR_BENCH",
                        message: "session=\(sessionID) attempt=\(attemptID) " +
                            "first_audio sampleCount=\(sampleCount) frameLength=\(frameLength) " +
                            "sampleRate=\(Int(sampleRate.rounded())) bufferMs=\(bufferMs) " +
                            "acquisitionMs=\(acquisitionMs) elapsedMs=\(elapsedMs)",
                        source: "ASRBenchmark"
                    )
                }
            },
            onLevel: { [weak self] level in
                // Keep Combine sends on the main queue.
                DispatchQueue.main.async { [weak self] in
                    self?.audioLevelSubject.send(level)
                }
            },
            onCaptureHealth: { [weak self] sessionID, attemptID, audioMs, sampleCount, rms, peak in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard sessionID == self.benchmarkSessionID,
                          self.isRunning,
                          self.isStoppingFinalTranscription == false
                    else { return }
                    let silent = rms < 0.002 && peak < 0.01
                    self.benchmarkLog(
                        "capture_health attempt=\(attemptID) audioMs=\(audioMs) " +
                            "samples=\(sampleCount) rms=\(String(format: "%.6f", rms)) " +
                            "peak=\(String(format: "%.6f", peak)) silent=\(silent) " +
                            "inputUID=\(self.audioStartAttemptInputUID ?? "unknown")"
                    )
                    if self.silentPCMRecoveryWatchdog.shouldRecover(
                        isInternalMicrophone: self.audioStartAttemptIsInternalMicrophone,
                        isDirectCapture: self.activeAudioCaptureBackend == .directCoreAudio,
                        rms: rms,
                        peak: peak
                    ) {
                        self.benchmarkLog(
                            "capture_health_recovery_triggered attempt=\(attemptID) " +
                                "audioMs=\(audioMs) rms=\(String(format: "%.6f", rms)) " +
                                "peak=\(String(format: "%.6f", peak))"
                        )
                        self.scheduleAudioRouteRecovery(reason: "sustained silent PCM")
                    }
                }
            }
        )
    }()

    private let meetingModelResidency: MeetingModelResidencyCoordinator

    init(meetingModelResidency: MeetingModelResidencyCoordinator = .shared) {
        self.meetingModelResidency = meetingModelResidency
        // CRITICAL FIX: Do NOT call any framework-triggering APIs here!
        // This includes:
        // - AVCaptureDevice.authorizationStatus (triggers AVFCapture/CoreAudio)
        // - checkIfModelsExist() (accesses transcriptionProvider, can trigger FluidAudio/CoreML)
        //
        // All such calls are deferred to initialize() which runs 1.5 seconds after
        // SwiftUI's view graph is stable, preventing race conditions with AttributeGraph.
        //
        // Default values are set in the property declarations:
        // - micStatus = .notDetermined
        // - micPermissionGranted = false
        // - modelsExistOnDisk = false
        self.vocabularyChangeObserver = NotificationCenter.default.addObserver(
            forName: .parakeetVocabularyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleParakeetVocabularyDidChange()
            }
        }
        self.clamshellStateChangeObserver = NotificationCenter.default.addObserver(
            forName: .clamshellStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let isClosed = notification.userInfo?["isClosed"] as? Bool ?? ClamshellState.isClosed
            Task { @MainActor [weak self] in
                self?.handleClamshellStateChanged(isClosed: isClosed)
            }
        }
        self.inputDeviceAvailabilityChangeObserver = NotificationCenter.default.addObserver(
            forName: .inputDeviceAvailabilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let deviceID = notification.userInfo?["deviceID"] as? AudioObjectID
            Task { @MainActor [weak self] in
                self?.handleInputDeviceAvailabilityChanged(deviceID: deviceID)
            }
        }
        self.modelReadinessForwarding = self.modelReadiness.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let observer = self.vocabularyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.clamshellStateChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = self.inputDeviceAvailabilityChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleClamshellStateChanged(isClosed: Bool) {
        DebugLogger.shared.info(
            "Clamshell \(isClosed ? "closed" : "opened"); refreshing microphone availability",
            source: "ASRService"
        )
        self.scheduleAudioRouteRecovery(
            reason: isClosed ? "clamshell closed" : "clamshell opened",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: true
        )
    }

    private func handleInputDeviceAvailabilityChanged(deviceID: AudioObjectID?) {
        let resolvedInput = AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture()
        let preparedDeviceID = self.directAudioLifecycleController.snapshot.deviceID
        let confirmedUID = AppServices.shared.microphonePreferenceCoordinator.confirmedActiveInputUID
        let activeSelectionChanged = self.isRunning && resolvedInput?.uid != confirmedUID
        let preparedSelectionChanged = self.hasPreparedAudioCapture && resolvedInput?.id != preparedDeviceID
        guard activeSelectionChanged || preparedSelectionChanged else { return }

        self.scheduleAudioRouteRecovery(
            reason: "input availability changed:\(deviceID ?? 0)",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: true
        )
    }

    @MainActor
    func handleSettingsBackupDidRestore() {
        // BackupService calls this synchronously while settingsRestore holds admission.
        // Its release consumes the pending reset before a new capture can enter.
        // Downloaded model files remain intact.
        self.resetTranscriptionProvider()
        SpeechModelInstallationSnapshot.shared.refresh()
        self.scheduleAudioRouteRecovery(
            reason: "settings backup restored",
            requiresIdlePrewarm: true,
            reconcilesInputSelection: true
        )
    }

    @MainActor
    private func handleParakeetVocabularyDidChange() {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary else { return }
        guard self.isRunning == false else {
            self.hasPendingParakeetVocabularyReload = true
            DebugLogger.shared.info(
                "ASRService: Vocabulary changed while recording; queued reload for when recording stops.",
                source: "ASRService"
            )
            return
        }
        self.hasPendingParakeetVocabularyReload = false
        self.resetTranscriptionProvider()
    }

    @MainActor
    private func applyPendingParakeetVocabularyReloadIfNeeded() {
        guard self.hasPendingParakeetVocabularyReload else { return }

        self.hasPendingParakeetVocabularyReload = false
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary else { return }

        DebugLogger.shared.info(
            "ASRService: Applying queued vocabulary reload after recording stopped.",
            source: "ASRService"
        )
        self.resetTranscriptionProvider()
    }

    private func refreshWordBoostStatus() {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary,
              let provider = self.providerCache.fluidAudioProvider,
              provider.isReady
        else {
            self.wordBoostStatusText = "Word boost: off"
            return
        }

        if provider.isWordBoostingActive {
            let count = provider.boostedVocabularyTermsCount
            if let lastHit = self.lastBoostHitTerm, !lastHit.isEmpty {
                self.wordBoostStatusText = "Word boost: ON (\(count) terms) • last hit: \(lastHit)"
            } else {
                self.wordBoostStatusText = "Word boost: ON (\(count) terms) • no hit yet"
            }
        } else {
            self.wordBoostStatusText = "Word boost: ON (0 terms loaded)"
        }
    }

    private func recordWordBoostHitIfAny(transcribedText: String) {
        let model = SettingsStore.shared.selectedSpeechModel
        guard model.supportsCustomVocabulary,
              let provider = self.providerCache.fluidAudioProvider,
              provider.isWordBoostingActive
        else { return }

        let hits = provider.detectBoostedTerms(in: transcribedText, limit: 1)
        guard let hit = hits.first else { return }
        if hit != self.lastBoostHitTerm {
            self.lastBoostHitTerm = hit
            DebugLogger.shared.info("BOOST_HIT: '\(hit)'", source: "ASRService")
        }
        self.refreshWordBoostStatus()
    }

    /// Call this AFTER the app has finished launching to complete ASR initialization.
    /// This must be called from onAppear or later, never during init.
    func initialize() async {
        let warmupGeneration = self.meetingModelResidency.warmupGeneration
        await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        await AudioStartupGate.shared.waitUntilOpen()
        guard self.isTerminating == false else { return }

        // Check microphone permission (deferred from init to avoid AVFCapture race condition)
        self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.micPermissionGranted = (self.micStatus == .authorized)

        let initialInputSnapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness(diagnosticsOwner: .asrService)
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard self.isTerminating == false else { return }

        let microphonePreferenceCoordinator = AppServices.shared.microphonePreferenceCoordinator
        microphonePreferenceCoordinator.reconcileMicrophoneSelection(
            availableInputs: initialInputSnapshot.0,
            defaultInputUID: initialInputSnapshot.1
        )

        self.subscribeToAudioHardwareChanges()

        // Initialize device list cache
        self.cacheCurrentDeviceList(initialInputSnapshot.0)
        if microphonePreferenceCoordinator.needsMicrophonePriorityMigration {
            self.scheduleAudioRouteRecovery(
                reason: "app microphone migration pending",
                requiresIdlePrewarm: true,
                reconcilesInputSelection: true
            )
        }

        // Register the input callback and allocate its fixed ring now. This
        // does not start the device or show the microphone privacy indicator.
        await self.prewarmConfiguredAudioCaptureIfPossible(reason: "startup")

        // Check if models exist on disk and auto-load if present
        // This is done in a Task to support async model detection (e.g., AppleSpeechAnalyzerProvider)
        Task { [weak self] in
            guard let self = self else { return }

            // Use async check to accurately detect models (especially for Apple Speech Analyzer)
            await self.checkIfModelsExistAsync()

            // Auto-load models if they exist on disk to avoid "Downloaded but not loaded" state
            if self.modelsExistOnDisk, self.meetingModelResidency.canRunWarmup(warmupGeneration) {
                DebugLogger.shared.info("Models found on disk, auto-loading...", source: "ASRService")
                do {
                    try await self.ensureAsrReady()
                    DebugLogger.shared.info("Models auto-loaded successfully on startup", source: "ASRService")
                    await self.prewarmConfiguredAudioCaptureIfPossible(reason: "startup")
                } catch {
                    DebugLogger.shared.error("Failed to auto-load models on startup: \(error)", source: "ASRService")
                }
            }
        }
    }

    /// Check if models exist on disk without loading them (synchronous).
    ///
    /// **Note**: For `AppleSpeechAnalyzerProvider`, this returns a cached value that may be stale.
    /// Use `checkIfModelsExistAsync()` for an up-to-date result.
    func checkIfModelsExist() {
        self.modelExistenceCheckID = UUID()
        self.modelsExistOnDisk = self.transcriptionProvider.modelsExistOnDisk()
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    /// Check if models exist on disk without loading them (async).
    ///
    /// This method performs an accurate async check for providers that require it
    /// (e.g., `AppleSpeechAnalyzerProvider` uses `SpeechTranscriber.installedLocales`).
    func checkIfModelsExistAsync() async {
        let model = SettingsStore.shared.selectedSpeechModel
        let checkID = UUID()
        self.modelExistenceCheckID = checkID
        let exists: Bool

        // For Apple Speech Analyzer, use the async refresh method
        if model == .appleSpeechAnalyzer {
            if #available(macOS 26.0, *) {
                let provider = self.providerCache.appleSpeechAnalyzerProvider()
                exists = await provider.refreshModelsExistOnDiskAsync()
            } else {
                exists = self.providerCache.appleSpeechProvider().modelsExistOnDisk()
            }
        } else if model == .fluidParakeetMini || model == .fluidParakeetPico {
            exists = (try? await SpeechModelReadiness.modelArtifactsExist(provider: self.transcriptionProvider)) ?? false
        } else {
            exists = model.isInstalled
        }

        guard
            self.modelExistenceCheckID == checkID,
            SettingsStore.shared.selectedSpeechModel == model
        else {
            return
        }
        self.modelsExistOnDisk = exists
        DebugLogger.shared.debug("Models exist on disk: \(self.modelsExistOnDisk)", source: "ASRService")
    }

    func requestMicAccess() {
        guard self.isRequestingMicrophoneAccess == false else { return }
        self.isRequestingMicrophoneAccess = true
        Task { @MainActor [weak self] in
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
            await AudioStartupGate.shared.waitUntilOpen()
            guard let self else { return }
            guard self.isTerminating == false else {
                self.isRequestingMicrophoneAccess = false
                return
            }

            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                Task { @MainActor in
                    self.isRequestingMicrophoneAccess = false
                    self.micPermissionGranted = granted
                    self.micStatus = granted ? .authorized : .denied
                    if granted {
                        await self.prewarmConfiguredAudioCaptureIfPossible(reason: "permission_granted")
                    }
                }
            }
        }
    }

    func startMicrophonePreview() async {
        guard self.micStatus == .authorized,
              self.isRunning == false,
              self.isStarting == false,
              self.activeExclusiveActivity != .meeting,
              self.activeExclusiveActivity != .settingsRestore,
              self.isTerminating == false
        else { return }

        self.microphonePreviewOperationGeneration &+= 1
        let operationGeneration = self.microphonePreviewOperationGeneration
        self.isMicrophonePreviewRequested = true

        if self.isMicrophonePreviewActive || self.audioCapturePipeline.isLevelMonitoringEnabled {
            self.audioCapturePipeline.setLevelMonitoringEnabled(false)
            _ = await self.directAudioLifecycleController.stop(
                retainPrepared: false,
                reason: "onboarding_microphone_preview_restart"
            )
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isMicrophonePreviewRequested,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.activeExclusiveActivity != .meeting,
                  self.activeExclusiveActivity != .settingsRestore,
                  self.isTerminating == false,
                  Task.isCancelled == false
            else {
                self.abandonMicrophonePreviewRequestIfOwned(operationGeneration)
                return
            }
            self.activeAudioCaptureBackend = .none
            self.isMicrophonePreviewActive = false
            self.audioLevelSubject.send(0)
        }

        guard operationGeneration == self.microphonePreviewOperationGeneration,
              self.isMicrophonePreviewRequested,
              self.isRunning == false,
              self.isStarting == false,
              self.activeExclusiveActivity != .meeting,
              self.activeExclusiveActivity != .settingsRestore,
              self.isTerminating == false,
              Task.isCancelled == false
        else {
            self.abandonMicrophonePreviewRequestIfOwned(operationGeneration)
            return
        }
        self.microphonePreviewError = nil
        self.audioCapturePipeline.setLevelMonitoringEnabled(true)

        do {
            guard let selection = try await self.directCoreAudioDeviceSelection() else {
                throw NSError(
                    domain: "ASRService",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "No usable microphone is available."]
                )
            }
            let device = try await self.directAudioLifecycleController.resolveDevice(
                selection: selection,
                reason: "onboarding_microphone_preview"
            )
            try Task.checkCancellation()
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.activeExclusiveActivity != .meeting,
                  self.activeExclusiveActivity != .settingsRestore,
                  self.isTerminating == false
            else { throw CancellationError() }
            _ = try await self.directAudioLifecycleController.start(
                deviceID: device.id,
                deviceName: device.name,
                reason: "onboarding_microphone_preview"
            )
            try Task.checkCancellation()
            guard operationGeneration == self.microphonePreviewOperationGeneration,
                  self.isRunning == false,
                  self.isStarting == false,
                  self.activeExclusiveActivity != .meeting,
                  self.activeExclusiveActivity != .settingsRestore,
                  self.isTerminating == false
            else { throw CancellationError() }
            self.activeAudioCaptureBackend = .directCoreAudio
            self.isMicrophonePreviewActive = true
            DebugLogger.shared.info(
                "Started onboarding microphone preview with '\(device.name)'",
                source: "ASRService"
            )
        } catch {
            // A newer preview, page-exit stop, or dictation start owns cleanup
            // after invalidating this operation. Do not tear down its capture.
            guard operationGeneration == self.microphonePreviewOperationGeneration else {
                return
            }
            self.audioCapturePipeline.setLevelMonitoringEnabled(false)
            await self.directAudioLifecycleController.invalidate(
                reason: "onboarding_microphone_preview_failed"
            )
            self.activeAudioCaptureBackend = .none
            self.isMicrophonePreviewActive = false
            self.isMicrophonePreviewRequested = false
            self.microphonePreviewError = error is CancellationError ? nil : error.localizedDescription
            guard error is CancellationError == false else { return }
            DebugLogger.shared.warning(
                "Onboarding microphone preview failed: \(error.localizedDescription)",
                source: "ASRService"
            )
        }
    }

    func stopMicrophonePreview(retainPreparedCapture: Bool = true) async {
        self.microphonePreviewOperationGeneration &+= 1
        let operationGeneration = self.microphonePreviewOperationGeneration
        self.isMicrophonePreviewRequested = false
        self.microphonePreviewError = nil
        guard self.isMicrophonePreviewActive || self.audioCapturePipeline.isLevelMonitoringEnabled else {
            return
        }

        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        _ = await self.directAudioLifecycleController.stop(
            retainPrepared: retainPreparedCapture,
            reason: "onboarding_microphone_preview_stop"
        )
        guard operationGeneration == self.microphonePreviewOperationGeneration else { return }
        self.activeAudioCaptureBackend = .none
        self.isMicrophonePreviewActive = false
        self.audioLevelSubject.send(0)
    }

    private func abandonMicrophonePreviewRequestIfOwned(_ operationGeneration: UInt64) {
        guard operationGeneration == self.microphonePreviewOperationGeneration else { return }
        self.isMicrophonePreviewRequested = false
        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        self.activeAudioCaptureBackend = .none
        self.isMicrophonePreviewActive = false
        self.microphonePreviewError = nil
        self.audioLevelSubject.send(0)
    }

    private func handOffMicrophonePreviewToCaptureStartIfNeeded() -> Bool {
        guard self.isMicrophonePreviewRequested ||
            self.isMicrophonePreviewActive ||
            self.audioCapturePipeline.isLevelMonitoringEnabled
        else { return false }

        // Invalidate preview ownership without stopping Core Audio. The direct
        // lifecycle serializes any in-flight preview start, and recording can
        // reuse the already-running input without losing opening PCM.
        self.microphonePreviewOperationGeneration &+= 1
        self.isMicrophonePreviewRequested = false
        self.audioCapturePipeline.setLevelMonitoringEnabled(false)
        self.isMicrophonePreviewActive = false
        self.microphonePreviewError = nil
        self.audioLevelSubject.send(0)
        return true
    }

    private func stopHandedOffMicrophonePreviewAfterCancelledStart() async {
        self.audioCapturePipeline.setRecordingEnabled(false)
        _ = await self.directAudioLifecycleController.stop(
            retainPrepared: true,
            reason: "cancelled_microphone_preview_handoff"
        )
        self.activeAudioCaptureBackend = .none
        self.audioLevelSubject.send(0)
    }

    func openSystemSettingsForMic() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts the speech recognition session.
    ///
    /// This method initiates audio capture and real-time processing. The service will:
    /// - Begin capturing audio from the default input device
    /// - Process audio in real-time for transcription
    /// - Provide audio level feedback for visualization
    ///
    /// ## Requirements
    /// - Microphone permission must be granted
    /// - ASR models must be available (will download if needed)
    /// - No existing recording session should be active
    ///
    /// ## Postconditions
    /// - `isRunning` will be `true`
    /// - Audio processing will begin immediately
    /// - Audio level updates will be published via `audioLevelPublisher`
    ///
    /// ## Errors
    /// If audio session configuration fails, the method will silently fail
    /// and `isRunning` will remain `false`. Check the debug logs for details.
    @discardableResult
    func start(
        forDictionaryTraining: Bool = false,
        requiresPronunciation: Bool = true,
        onCaptureStarted: (@MainActor () -> Void)? = nil
    ) async -> AudioCaptureStartOutcome {
        guard !forDictionaryTraining || !requiresPronunciation || DictionaryMatcherExperiment.sharedFeaturesEnabled else { return .failed }
        DebugLogger.shared.info("🎤 START() called - beginning recording session", source: "ASRService")

        guard self.micStatus == .authorized else {
            DebugLogger.shared.error("❌ START() blocked - mic not authorized", source: "ASRService")
            return .failed
        }
        guard !self.recordingBufferHandoffGate.isRecovering else {
            self.presentStreamingRecoveryError()
            return .failed
        }
        guard self.isRunning == false, self.isStarting == false else {
            DebugLogger.shared.warning("⚠️ START() blocked - already running (started: \(self.isRunning), starting: \(self.isStarting))", source: "ASRService")
            return .alreadyActive
        }
        guard self.isTerminating == false else {
            DebugLogger.shared.warning("START() blocked - app is terminating", source: "ASRService")
            return .failed
        }
        do {
            self.dictationActivityLease = try self.acquireExclusiveActivity(.dictation)
        } catch {
            let message = error.localizedDescription
            self.errorTitle = "Dictation Unavailable"
            self.errorMessage = message
            self.showError = true
            DebugLogger.shared.warning("START() blocked - \(message)", source: "ASRService")
            return .failed
        }
        self.retainDictionaryLearningRecording(nil)
        self.audioCaptureStartGeneration &+= 1
        let startGeneration = self.audioCaptureStartGeneration
        self.isStarting = true
        // Spelling-only training owns the same isolated capture, without requiring voice matching.
        self.isPronunciationTrainingStart = forDictionaryTraining && requiresPronunciation
        self.pronunciationTrainingStartGeneration = self.isPronunciationTrainingStart ? DictionaryMatcherExperiment.generation : nil
        defer {
            self.pronunciationTrainingStartGeneration = nil
            self.isPronunciationTrainingStart = false
            self.finishAudioCaptureStart()
        }

        // A prior stop may already have disabled capture while its final live-preview
        // operation still owns the shared PCM buffer. Reserve this start immediately,
        // but do not clear or enable the buffer until that bounded handoff completes.
        while self.recordingBufferHandoffGate.isActive {
            await self.recordingBufferHandoffGate.waitUntilAvailable()
            guard !self.recordingBufferHandoffGate.isRecovering else {
                self.presentStreamingRecoveryError()
                return .failed
            }
            guard startGeneration == self.audioCaptureStartGeneration,
                  self.isTerminating == false,
                  self.isPronunciationTrainingStartCurrent
            else {
                DebugLogger.shared.debug(
                    "Audio capture start cancelled while waiting for the previous buffer handoff",
                    source: "ASRService"
                )
                return .failed
            }
        }

        self.audioCapturePipeline.resetDictationMute()
        self.audioCapturePipeline.setDictationMuted(self.isDictationMuted, at: mach_absolute_time())

        // Reserve the start before relinquishing preview ownership so a
        // press-and-hold release can cancel the handoff. Keep the running input
        // alive; startConfiguredAudioCapture reuses it for zero-stop first PCM.
        let handedOffMicrophonePreview = self.handOffMicrophonePreviewToCaptureStartIfNeeded()

        await self.waitForPendingAudioRouteRecoveryBeforeStart()
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false,
              self.isPronunciationTrainingStartCurrent
        else {
            if handedOffMicrophonePreview {
                await self.stopHandedOffMicrophonePreviewAfterCancelledStart()
            }
            DebugLogger.shared.debug(
                "Audio capture start cancelled during route handoff generation=\(startGeneration)",
                source: "ASRService"
            )
            self.releaseDictationActivityIfNeeded()
            return .failed
        }

        DebugLogger.shared.debug("🧹 Clearing buffers and state", source: "ASRService")
        self.finalText.removeAll()
        self.audioBuffer.clear(keepingCapacity: true) // specific optimization for restart
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastBoostHitTerm = nil
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.benchmarkSessionID += 1
        self.streamingWorkState.beginSession(self.benchmarkSessionID)
        self.streamingHealthCheckCount = 0
        self.streamingHealthLastBufferCount = 0
        self.silentPCMRecoveryWatchdog = AudioCaptureIdlePolicy.SilentPCMRecoveryWatchdog()
        let captureSessionID = self.benchmarkSessionID
        // Start media work alongside microphone startup; never await it on the
        // capture path. Track only this start so cancelling a buffer-handoff wait
        // cannot finish the previous session's still-running transcription.
        self.pendingMediaCaptureSessionID = captureSessionID
        defer { self.pendingMediaCaptureSessionID = nil }
        self.mediaPlaybackService.recordingStarted(
            sessionID: captureSessionID,
            enabled: SettingsStore.shared.pauseMediaDuringTranscription
        )
        self.audioCaptureAttemptID &+= 1
        var readinessAttemptID = self.audioCaptureAttemptID
        self.audioCaptureReadinessGate.arm(
            sessionID: captureSessionID,
            attemptID: readinessAttemptID
        )
        self.benchmarkRecordingStartedAt = Date().timeIntervalSince1970
        self.benchmarkStreamingChunkIndex = 0
        self.benchmarkCompletedStreamingChunks = 0
        self.benchmarkLastChunkSampleCount = 0
        (self.transcriptionProvider as? FluidAudioProvider)?.resetStreamingPreviewCache()
        self.audioCapturePipeline.setRecordingEnabled(
            true,
            sessionID: captureSessionID,
            attemptID: readinessAttemptID,
            startHostTime: mach_absolute_time()
        )
        self.refreshWordBoostStatus()
        let dims = self.currentTranscriptionAnalyticsDimensions()
        self.benchmarkLog("recording_start model=\(dims.model) provider=\(dims.provider) supportsStreaming=\(SettingsStore.shared.selectedSpeechModel.supportsStreaming)")
        DebugLogger.shared.debug("✅ Buffers cleared", source: "ASRService")

        self.isDictionaryTrainingCaptureActive = false

        do {
            var maximumStartAttempts = 1
            var hasReadInputSnapshot = false
            var startAttempt = 1
            var fallbackAttempt = 1
            var failedInputUIDs = Set<String>()
            var immediatelyRetriedInputUID: String?
            var bluetoothStabilization = AudioCaptureIdlePolicy.BluetoothInputStabilization()
            var forcedInputUID: String?
            self.audioStartAttemptInputUID = nil
            while true {
                try self.checkCaptureStartGeneration(startGeneration)
                let routeGenerationAtStart = self.audioRouteRecoveryGeneration
                do {
                    try await self.startCancellableAudioCapture(
                        excluding: failedInputUIDs,
                        forcingInputUID: forcedInputUID,
                        onInputSnapshotRead: { inputCount in
                            guard hasReadInputSnapshot == false else { return }
                            // Freeze a bounded budget from the same fresh snapshot
                            // that selected the first input, including one retry.
                            hasReadInputSnapshot = true
                            maximumStartAttempts = max(inputCount, 1) + 1
                        }
                    )
                } catch {
                    try self.checkCaptureStartGeneration(startGeneration)
                    guard error is BoundedAudioHardwareQueue.Failure == false,
                          error is CancellationError == false,
                          self.directAudioLifecycleController.isRecoveringHardware == false
                    else { throw error }
                    guard let failedUID = self.audioStartAttemptInputUID else { throw error }
                    let now = ProcessInfo.processInfo.systemUptime
                    let retryBluetoothInput = bluetoothStabilization.shouldRetry(
                        inputUID: failedUID,
                        isBluetoothInput: self.audioStartAttemptIsBluetooth,
                        now: now
                    )
                    let retrySameInput = retryBluetoothInput || immediatelyRetriedInputUID == nil
                    if retryBluetoothInput {
                        forcedInputUID = failedUID
                        immediatelyRetriedInputUID = failedUID
                        self.logBluetoothStartupRetry(
                            uid: failedUID,
                            attempt: startAttempt + 1,
                            elapsed: bluetoothStabilization.elapsed(at: now),
                            reason: error.localizedDescription
                        )
                    } else {
                        forcedInputUID = nil
                        if bluetoothStabilization.inputUID == failedUID {
                            self.logBluetoothStartupStabilizationEnded(
                                uid: failedUID,
                                elapsed: bluetoothStabilization.elapsed(at: now),
                                outcome: "budget_exhausted"
                            )
                        }
                        if immediatelyRetriedInputUID == nil {
                            immediatelyRetriedInputUID = failedUID
                        } else {
                            failedInputUIDs.insert(failedUID)
                        }
                        fallbackAttempt += 1
                    }
                    guard retryBluetoothInput || fallbackAttempt <= maximumStartAttempts,
                          startGeneration == self.audioCaptureStartGeneration,
                          self.isTerminating == false,
                          self.isPronunciationTrainingStartCurrent
                    else {
                        throw error
                    }
                    readinessAttemptID = try await self.prepareAudioCaptureStartRetry(
                        sessionID: captureSessionID,
                        startGeneration: startGeneration,
                        completedAttempt: startAttempt,
                        reason: "backend_start_error:\(error.localizedDescription)",
                        waitForTopologyQuiet: retryBluetoothInput || retrySameInput == false
                    )
                    startAttempt += 1
                    continue
                }
                try self.checkCaptureStartGeneration(startGeneration)
                self.benchmarkLog(
                    "first_pcm_wait_begin attempt=\(startAttempt) " +
                        "attemptID=\(readinessAttemptID) " +
                        "timeoutMs=\(self.firstPCMTimeoutNanoseconds / 1_000_000) " +
                        "routeGeneration=\(routeGenerationAtStart) " +
                        "captureGeneration=\(self.directAudioLifecycleController.snapshot.generation)"
                )
                let readiness = await self.audioCaptureReadinessGate.wait(
                    sessionID: captureSessionID,
                    attemptID: readinessAttemptID,
                    timeoutNanoseconds: self.firstPCMTimeoutNanoseconds
                )
                try self.checkCaptureStartGeneration(startGeneration)
                let routeStayedStable =
                    routeGenerationAtStart == self.audioRouteRecoveryGeneration &&
                    self.pendingAudioRouteRecovery == nil &&
                    self.isRecoveringAudioRoute == false
                if readiness == .ready, routeStayedStable {
                    if let stabilizedUID = bluetoothStabilization.inputUID {
                        self.logBluetoothStartupStabilizationEnded(
                            uid: stabilizedUID,
                            elapsed: bluetoothStabilization.elapsed(
                                at: ProcessInfo.processInfo.systemUptime
                            ),
                            outcome: "first_pcm"
                        )
                    }
                    AppServices.shared.microphonePreferenceCoordinator.confirmActiveSelection(
                        uid: self.audioStartAttemptInputUID,
                        name: self.audioStartAttemptInputName
                    )
                    self.benchmarkLog(
                        "first_pcm_wait_end result=ready attempt=\(startAttempt) " +
                            "attemptID=\(readinessAttemptID) " +
                            "bufferedSamples=\(self.audioBuffer.count)"
                    )
                    break
                }

                self.benchmarkLog(
                    "first_pcm_wait_end result=\(readiness) attempt=\(startAttempt) " +
                        "attemptID=\(readinessAttemptID) " +
                        "routeStable=\(routeStayedStable)"
                )
                if readiness == .cancelled {
                    throw CancellationError()
                }
                var retrySameInput = false
                var retryBluetoothInput = false
                if let failedUID = self.audioStartAttemptInputUID {
                    let now = ProcessInfo.processInfo.systemUptime
                    retryBluetoothInput = bluetoothStabilization.shouldRetry(
                        inputUID: failedUID,
                        isBluetoothInput: self.audioStartAttemptIsBluetooth,
                        now: now
                    )
                    retrySameInput = retryBluetoothInput || (
                        readiness == .formatInvalidated && immediatelyRetriedInputUID == nil
                    )
                    if retryBluetoothInput {
                        forcedInputUID = failedUID
                        immediatelyRetriedInputUID = failedUID
                        self.logBluetoothStartupRetry(
                            uid: failedUID,
                            attempt: startAttempt + 1,
                            elapsed: bluetoothStabilization.elapsed(at: now),
                            reason: "readiness_\(readiness)"
                        )
                    } else {
                        forcedInputUID = nil
                        if bluetoothStabilization.inputUID == failedUID {
                            self.logBluetoothStartupStabilizationEnded(
                                uid: failedUID,
                                elapsed: bluetoothStabilization.elapsed(at: now),
                                outcome: "budget_exhausted"
                            )
                        }
                        if retrySameInput {
                            immediatelyRetriedInputUID = failedUID
                        } else {
                            failedInputUIDs.insert(failedUID)
                            fallbackAttempt += 1
                        }
                    }
                }
                guard retryBluetoothInput || fallbackAttempt <= maximumStartAttempts else {
                    let message: String
                    switch readiness {
                    case .timedOut:
                        message = "The selected microphone started but did not deliver audio."
                    case .formatInvalidated:
                        message = "The microphone format did not stabilize after reconnecting."
                    case .staleSession:
                        message = "Audio capture was replaced before the microphone became ready."
                    case .cancelled:
                        message = "Audio capture was cancelled."
                    case .ready:
                        message = "The microphone route changed before capture became stable."
                    }
                    throw NSError(
                        domain: "ASRService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                }

                readinessAttemptID = try await self.prepareAudioCaptureStartRetry(
                    sessionID: captureSessionID,
                    startGeneration: startGeneration,
                    completedAttempt: startAttempt,
                    reason: "readiness_\(readiness)_routeStable_\(routeStayedStable)",
                    waitForTopologyQuiet: retryBluetoothInput || retrySameInput == false
                )
                startAttempt += 1
            }
            self.isDictionaryTrainingCaptureActive = forDictionaryTraining
            self.isRunning = true
            DebugLogger.shared.info(
                "✅ Audio capture running after first PCM (session=\(captureSessionID))",
                source: "ASRService"
            )
            onCaptureStarted?()

            // Only start streaming for models that support it (large Whisper models are too slow)
            let model = SettingsStore.shared.selectedSpeechModel
            if model.supportsStreaming, !forDictionaryTraining {
                DebugLogger.shared.debug("📡 Starting streaming transcription...", source: "ASRService")
                self.benchmarkLog("streaming_timer_start intervalMs=\(Int((self.streamingChunkDurationSeconds * 1000).rounded())) minSamples=\(self.minimumStreamingPreviewSamples)")
                self.startStreamingTranscription()
            } else if forDictionaryTraining {
                DebugLogger.shared.debug("⏸️ Skipping streaming for dictionary training sample", source: "ASRService")
            } else {
                DebugLogger.shared.debug("⏸️ Skipping streaming - model '\(model.displayName)' does not support real-time chunk processing", source: "ASRService")
            }
            DebugLogger.shared.info("✅ START() completed successfully", source: "ASRService")
            return .started
        } catch {
            self.mediaPlaybackService.sessionFinished(sessionID: captureSessionID)
            self.releaseDictationActivityIfNeeded()
            await self.audioCaptureReadinessGate.cancel(
                sessionID: captureSessionID,
                attemptID: readinessAttemptID
            )
            self.isDictionaryTrainingCaptureActive = false
            self.audioCapturePipeline.setRecordingEnabled(false)
            self.isRunning = false
            await self.stopActiveAudioCapture(
                retainDirectPreparedCapture: false,
                reason: "start_failed"
            )
            let wasCancelled =
                error is CancellationError ||
                startGeneration != self.audioCaptureStartGeneration ||
                self.isTerminating
            if wasCancelled {
                DebugLogger.shared.info(
                    "Audio capture start cancelled generation=\(startGeneration)",
                    source: "ASRService"
                )
            } else {
                DebugLogger.shared.error("Failed to start ASR session: \(error)", source: "ASRService")
            }

            guard wasCancelled == false else { return .failed }
            AppServices.shared.microphonePreferenceCoordinator.markActiveSelectionUnavailable()

            // Provide user-friendly error feedback
            let nsError = error as NSError
            let noUsableMicrophone = nsError.domain == "ASRService" && nsError.code == -4
            let errorMessage: String
            if nsError.domain == "ASRService" {
                if noUsableMicrophone {
                    errorMessage = "No usable microphone is available. Open your MacBook or connect a microphone, then try again."
                } else if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    // Extract useful info from AVFoundation error
                    if underlyingError.domain == AVFoundationErrorDomain || underlyingError.domain == NSOSStatusErrorDomain {
                        errorMessage = "Failed to start audio recording. The audio device may be in use by another application or unavailable. Please check your audio settings and try again."
                    } else {
                        errorMessage = "Failed to start audio recording: \(underlyingError.localizedDescription)"
                    }
                } else {
                    errorMessage = "Failed to start audio recording after multiple attempts. Please check your audio device and try again."
                }
            } else {
                errorMessage = "Failed to start audio recording: \(error.localizedDescription)"
            }

            self.presentAudioCaptureFailure(
                title: noUsableMicrophone ? "Microphone Unavailable" : "Recording Error",
                message: errorMessage
            )
            return .failed
        }
    }

    func waitForPendingStart() async {
        guard self.isStarting else { return }
        await withCheckedContinuation { continuation in
            if self.isStarting {
                self.audioCaptureStartWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func prepareAudioCaptureStartRetry(
        sessionID: Int,
        startGeneration: UInt64,
        completedAttempt: Int,
        reason: String,
        waitForTopologyQuiet: Bool = true
    ) async throws -> UInt64 {
        self.audioCapturePipeline.setRecordingEnabled(false)
        await self.directAudioLifecycleController.invalidate(
            reason: "start_retry_attempt_\(completedAttempt):\(reason)"
        )
        // Invalidation retires the packet gate and drains accepted packets, so
        // this clear cannot be followed by late PCM from the failed attempt.
        self.audioBuffer.clear(keepingCapacity: true)
        let routeRecoveryWasPending = self.audioRouteRecoveryTask != nil
        await self.waitForPendingAudioRouteRecoveryBeforeStart()
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            throw CancellationError()
        }
        if routeRecoveryWasPending == false, waitForTopologyQuiet {
            try await Task.sleep(nanoseconds: self.audioRouteRecoveryDelayNanoseconds)
        }
        guard startGeneration == self.audioCaptureStartGeneration,
              self.isTerminating == false
        else {
            throw CancellationError()
        }

        try self.checkCaptureStartGeneration(startGeneration)
        self.audioCaptureAttemptID &+= 1
        let attemptID = self.audioCaptureAttemptID
        self.audioCaptureReadinessGate.arm(
            sessionID: sessionID,
            attemptID: attemptID
        )
        self.audioCapturePipeline.setRecordingEnabled(
            true,
            sessionID: sessionID,
            attemptID: attemptID,
            startHostTime: mach_absolute_time()
        )
        DebugLogger.shared.info(
            "Retrying direct audio startup in the same session after \(reason) " +
                "(nextAttempt=\(completedAttempt + 1))",
            source: "ASRService"
        )
        return attemptID
    }

    private func logBluetoothStartupRetry(
        uid: String,
        attempt: Int,
        elapsed: TimeInterval,
        reason: String
    ) {
        let elapsedMilliseconds = Int((elapsed * 1000).rounded())
        let admissionWindowMilliseconds = Int(
            (AudioCaptureIdlePolicy.BluetoothInputStabilization.retryAdmissionWindow * 1000).rounded()
        )
        self.benchmarkLog(
            "bluetooth_start_retry uid=\(uid) attempt=\(attempt) " +
                "elapsedMs=\(elapsedMilliseconds) " +
                "admissionWindowMs=\(admissionWindowMilliseconds) reason=\(reason)"
        )
    }

    private func logBluetoothStartupStabilizationEnded(
        uid: String,
        elapsed: TimeInterval,
        outcome: String
    ) {
        self.benchmarkLog(
            "bluetooth_start_stabilization_end uid=\(uid) outcome=\(outcome) " +
                "elapsedMs=\(Int((elapsed * 1000).rounded()))"
        )
    }

    /// Recovery can be awaited by startup, so it must interrupt without waiting
    /// for startup to finish. Keep task cancellation and media release together.
    private func interruptPendingAudioCaptureStart() {
        self.audioCaptureStartGeneration &+= 1
        self.pendingAudioCaptureBackendStart?.cancel()
        self.audioCapturePipeline.setRecordingEnabled(false)
        self.directAudioLifecycleController.cancelPendingStartup()
        if let sessionID = self.pendingMediaCaptureSessionID {
            self.mediaPlaybackService.sessionFinished(sessionID: sessionID)
        }
        // A start waiting for the previous session's PCM handoff must wake to
        // observe the generation change; the old stop keeps ownership of the gate.
        self.recordingBufferHandoffGate.releasePendingWaiters()
    }

    func cancelPendingPronunciationTrainingStart() async {
        guard self.isPronunciationTrainingStart else { return }
        await self.cancelPendingAudioCaptureStart(reason: "pronunciation_disabled")
    }

    func cancelPendingAudioCaptureStart(reason: String) async {
        guard self.isStarting, self.isRunning == false else { return }
        self.interruptPendingAudioCaptureStart()
        let cancelledSessionID = self.benchmarkSessionID
        self.benchmarkLog(
            "capture_start_cancel reason=\(reason) session=\(cancelledSessionID) " +
                "generation=\(self.audioCaptureStartGeneration)"
        )
        await self.audioCaptureReadinessGate.cancel(
            sessionID: cancelledSessionID,
            attemptID: self.audioCaptureAttemptID
        )
        await self.waitForPendingStart()
    }

    private func finishAudioCaptureStart() {
        self.isStarting = false
        let deferredRecovery = self.deferredBluetoothStartupRouteRecovery.take()
        self.audioCaptureStateDidSettle.send()
        let waiters = self.audioCaptureStartWaiters
        self.audioCaptureStartWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }

        if let deferredRecovery {
            Task { @MainActor [weak self] in
                await self?.processDeferredBluetoothStartupRouteRecovery(deferredRecovery)
            }
        }
    }

    private func processDeferredBluetoothStartupRouteRecovery(
        _ request: AudioCaptureIdlePolicy.DeferredBluetoothRouteRecovery.Request
    ) async {
        do {
            try await Task.sleep(nanoseconds: self.audioRouteRecoveryDelayNanoseconds)
        } catch {
            return
        }
        guard self.isTerminating == false else { return }

        let snapshot = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let devices = AudioDevice.listInputDevicesRefreshingLiveness(diagnosticsOwner: .asrService)
                let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
                continuation.resume(returning: (devices, defaultInputUID))
            }
        }
        guard self.isTerminating == false else { return }
        if self.isStarting {
            self.deferredBluetoothStartupRouteRecovery.preserve(
                reason: request.reason,
                requiresIdlePrewarm: request.requiresIdlePrewarm,
                reconcilesInputSelection: request.reconcilesInputSelection
            )
            return
        }

        let microphonePreferenceCoordinator = AppServices.shared.microphonePreferenceCoordinator
        let resolvedInput: AudioDevice.Device?
        if request.reconcilesInputSelection {
            resolvedInput = microphonePreferenceCoordinator.reconcileMicrophoneSelection(
                availableInputs: snapshot.0,
                defaultInputUID: snapshot.1
            )
        } else {
            resolvedInput = microphonePreferenceCoordinator.inputDeviceForCapture(
                availableInputs: snapshot.0,
                defaultInputUID: snapshot.1
            )
        }
        self.cacheCurrentDeviceList(snapshot.0)

        let activeSnapshot = self.directAudioLifecycleController.snapshot
        let shouldRecover = AudioCaptureIdlePolicy.shouldRecoverAfterDeferredBluetoothReconciliation(
            isRunning: self.isRunning,
            confirmedInputUID: microphonePreferenceCoordinator.confirmedActiveInputUID,
            activeDeviceID: activeSnapshot.deviceID,
            resolvedInputUID: resolvedInput?.uid,
            resolvedDeviceID: resolvedInput?.id,
            hasPreparedCapture: self.hasPreparedAudioCapture,
            requiresIdlePrewarm: request.requiresIdlePrewarm
        )
        guard shouldRecover else {
            self.benchmarkLog(
                "bluetooth_deferred_reconciliation_noop event=\(request.reason) " +
                    "resolvedUID=\(resolvedInput?.uid ?? "none")"
            )
            return
        }

        self.scheduleAudioRouteRecovery(
            reason: "deferred after Bluetooth startup: \(request.reason)",
            requiresIdlePrewarm: request.requiresIdlePrewarm,
            reconcilesInputSelection: false
        )
    }

    /// Identifies the protected dictionary capture so a dismissed test cannot stop a newer recording.
    var dictionaryCaptureToken: Int? { self.isDictionaryTrainingCaptureActive ? self.benchmarkSessionID : nil }

    /// Stops the recording session and returns the transcribed text.
    ///
    /// This method performs the complete transcription process:
    /// 1. Stops audio capture and processing
    /// 2. Ensures ASR models are ready
    /// 3. Transcribes all recorded audio
    /// 4. Returns the final transcribed text
    ///
    /// ## Process
    /// - Stops audio capture
    /// - Validates that ASR models are available and ready
    /// - Processes all recorded audio through the ASR pipeline
    /// - Returns the transcribed text for use by the caller
    ///
    /// ## Returns
    /// The transcribed text from the entire recording session, or an empty string if transcription fails.
    ///
    /// ## Note
    /// This method does not update `finalText` property to avoid UI conflicts.
    /// Callers should handle the returned text as needed.
    ///
    /// ## Errors
    /// Returns empty string if:
    /// - No recording was in progress
    /// - ASR models are not available
    /// - Transcription process fails
    /// Check debug logs for detailed error information.
    /// - Parameter onCaptureStopped: Optional callback fired on the main actor
    ///   after audio capture has stopped but before the (potentially slow)
    ///   final transcription pass. Use this for immediate stop cues that
    ///   shouldn't wait on finalization. Only invoked when capture was actually
    ///   running (i.e. not when `stop()` early-returns because `isRunning` is false).
    /// - Parameter onFinalTranscriptionStarted: Optional main-actor callback
    ///   shown only when final transcription outlives the short status delay.
    ///   Fast finalization proceeds without queuing transient UI work ahead of its result.
    func stop(
        onCaptureStopped: (@MainActor () -> Void)? = nil,
        onFinalTranscriptionStarted: (@MainActor () -> Void)? = nil,
        forDictionaryTraining: Bool = false,
        captureDictionaryPronunciation: Bool? = nil,
        forDictionaryTesting: Bool = false
    ) async -> String {
        guard !forDictionaryTesting || self.isDictionaryTrainingCaptureActive else { return "" }
        DebugLogger.shared.info("🛑 STOP() called - beginning shutdown sequence", source: "ASRService")
        self.lastStopOutcome = .empty
        self.lastFinalTranscriptionDurationMs = nil
        self.lastFinalParakeetProcessingMs = nil
        if forDictionaryTraining || self.isDictionaryTrainingCaptureActive {
            self.lastDictionaryTrainingResult = nil
        }
        self.lastCompletedAudioSnapshot = nil
        self.retainDictionaryLearningRecording(nil)
        let stopStartedAt = Date().timeIntervalSince1970
        let traceStartedAt = ProcessInfo.processInfo.systemUptime
        var tracePreviousAt = traceStartedAt
        func traceStop(_ phase: String) {
            let now = ProcessInfo.processInfo.systemUptime
            DebugLogger.shared.debug(
                "STOP_TRACE phase=\(phase) deltaMs=\(Int((now - tracePreviousAt) * 1000)) totalMs=\(Int((now - traceStartedAt) * 1000))",
                source: "StopTiming"
            )
            tracePreviousAt = now
        }
        defer { traceStop("stop_return") }
        self.benchmarkLog("stop_start ageMs=\(self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)) bufferedSamples=\(self.audioBuffer.count)")

        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "recording_stop")
        }
        guard self.isRunning else {
            self.isDictionaryTrainingCaptureActive = false
            self.releaseDictationActivityIfNeeded()
            DebugLogger.shared.warning("⚠️ STOP() - not running, returning empty string", source: "ASRService")
            return ""
        }
        let stoppingSessionID = self.benchmarkSessionID
        guard let bufferHandoffToken = self.recordingBufferHandoffGate.begin() else {
            DebugLogger.shared.warning("STOP() ignored - recording buffer handoff already active", source: "ASRService")
            return ""
        }
        self.mediaPlaybackService.recordingStopped(sessionID: stoppingSessionID)
        defer { self.mediaPlaybackService.sessionFinished(sessionID: stoppingSessionID) }
        self.isStoppingFinalTranscription = true
        var completedBufferHandoff = false
        defer {
            if completedBufferHandoff == false {
                self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            }
            self.publishStoppedState(for: stoppingSessionID)
            self.finishDeferredStopUIInvalidation()
            if self.benchmarkSessionID == stoppingSessionID {
                self.isStoppingFinalTranscription = false
            }
        }
        self.stopStreamingScheduler(sessionID: stoppingSessionID)
        let isolatedDictionaryCapture = forDictionaryTraining || self.isDictionaryTrainingCaptureActive
        // Tests use normal recognition and saved corrections, but never enroll or retain learning audio.
        let useDictionaryTrainingPath = isolatedDictionaryCapture && !forDictionaryTesting
        defer {
            self.applyPendingParakeetVocabularyReloadIfNeeded()
            self.isDictionaryTrainingCaptureActive = false
            self.releaseDictationActivityIfNeeded()
        }

        traceStop("route_cleanup_begin")
        await self.cancelAudioRouteRecoveryAndWait()
        traceStop("route_cleanup_end")
        guard self.isRunning, self.benchmarkSessionID == stoppingSessionID else {
            self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            completedBufferHandoff = true
            return ""
        }

        DebugLogger.shared.debug("📍 Preparing final transcription", source: "ASRService")

        // Freeze an exact acquisition boundary before stopping hardware. The
        // direct IOProc is synchronously drained and the pipeline trims the
        // final hardware packet to this host time, preserving the last phoneme
        // without appending audio from the next session.
        self.audioCapturePipeline.markRecordingEnd(atHostTime: mach_absolute_time())

        self.benchmarkLog("capture_stop_await_begin")
        traceStop("capture_stop_begin")
        await self.stopActiveAudioCapture(reason: "recording_stop")
        traceStop("capture_stop_end")
        self.benchmarkLog("capture_stop_await_return")
        self.audioCapturePipeline.finishRecording()
        self.benchmarkLog("capture_pipeline_finished")

        // A prepared direct IOProc owns only fixed memory and registration; it
        // does not run hardware, show the mic indicator, or hold Bluetooth in
        // headset mode. Keep it prepared across idle periods.
        if self.directAudioLifecycleController.snapshot.isPrepared {
            DebugLogger.shared.debug("♻️ Direct audio capture remains prepared", source: "ASRService")
        }

        // Capture has fully ended — invoke the callback so callers can play a
        // stop cue or release capture-dependent UI without waiting on the
        // (potentially slow) final transcription pass.
        self.benchmarkLog("capture_stopped_callback_request")
        // stop() is MainActor-isolated; calling directly avoids needlessly
        // yielding and re-enqueuing this callback behind unrelated UI work.
        self.benchmarkLog("capture_stopped_callback_begin")
        onCaptureStopped?()
        self.benchmarkLog("capture_stopped_callback_end")
        self.benchmarkLog("capture_stopped_callback_return")

        let directCaptureSnapshot = self.directAudioLifecycleController.snapshot
        self.benchmarkLog(
            "audio_capture_prepared retained=\(directCaptureSnapshot.isPrepared) " +
                "phase=\(directCaptureSnapshot.phase.rawValue) generation=\(directCaptureSnapshot.generation)"
        )

        // The idle scheduler was cancelled before teardown. Only real provider work
        // can still own the PCM buffer here, so drain that operation without sending
        // cancellation into incremental provider state.
        DebugLogger.shared.debug("⏳ Awaiting active streaming work...", source: "ASRService")
        let streamingStopStartedAt = Date().timeIntervalSince1970
        traceStop("streaming_drain_begin")
        guard await self.drainActiveStreamingWork(sessionID: stoppingSessionID) else {
            self.beginStreamingDrainRecovery(sessionID: stoppingSessionID, token: bufferHandoffToken)
            completedBufferHandoff = true // Recovery owns the PCM handoff until real work ends.
            self.lastStopOutcome = .failed
            self.benchmarkLog("stop_end result=error reason=streaming_drain_timeout")
            return ""
        }
        self.benchmarkLog("stop_streaming_wait elapsedMs=\(self.elapsedMilliseconds(since: streamingStopStartedAt))")
        traceStop("streaming_drain_end")
        DebugLogger.shared.debug("✅ Active streaming work completed", source: "ASRService")

        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.previousFullTranscription.removeAll()

        // NOW it's safe to access the buffer - all pending tasks have completed
        // Thread-safe copy of recorded audio
        var pcm = self.audioBuffer.getAll()
        self.audioBuffer.clear()
        let capturedPCM = pcm
        traceStop("buffer_copied")
        let hasRecognizedStreamingPreview = !self.partialTranscription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        self.streamingWorkState.endSession(stoppingSessionID)
        self.recordingBufferHandoffGate.complete(bufferHandoffToken)
        completedBufferHandoff = true
        self.benchmarkLog("stop_audio_drained samples=\(pcm.count) audioMs=\(Int((Double(pcm.count) / 16_000.0 * 1000).rounded()))")

        // Drop recordings with no audio at all — nothing to transcribe.
        guard !pcm.isEmpty else {
            DebugLogger.shared.debug(
                "stop(): no audio captured, skipping transcription",
                source: "ASRService"
            )
            DebugLogger.shared.info(
                "Final ASR result | provider=\(self.transcriptionProvider.name) | samples=0 | textChars=0 | confidence=nil | reason=no_audio",
                source: "ASRService"
            )
            self.benchmarkLog("stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=no_audio")
            return ""
        }

        if Self.shouldAssessShortAudioSilence(
            isEnabled: SettingsStore.shared.skipSilentRecordingsEnabled,
            useDictionaryTrainingPath: useDictionaryTrainingPath,
            hasRecognizedStreamingPreview: hasRecognizedStreamingPreview
        ) {
            let silenceGateStartedAt = ProcessInfo.processInfo.systemUptime
            let silenceAssessment = Self.assessShortAudioSilence(pcm)
            let silenceGateMicroseconds = Int(
                ((ProcessInfo.processInfo.systemUptime - silenceGateStartedAt) * 1_000_000).rounded()
            )
            self.benchmarkLog(
                "silence_gate eligible=\(silenceAssessment.isEligible) skip=\(silenceAssessment.shouldSkipTranscription) " +
                    "audioMs=\(silenceAssessment.durationMilliseconds) analysisUs=\(silenceGateMicroseconds) " +
                    "peak=\(String(format: "%.6f", silenceAssessment.peakAmplitude)) " +
                    "rms=\(String(format: "%.6f", silenceAssessment.rmsAmplitude)) " +
                    "maxFrameRms=\(String(format: "%.6f", silenceAssessment.maximumFrameRMS))"
            )

            if silenceAssessment.shouldSkipTranscription {
                traceStop("silence_skipped")
                DebugLogger.shared.info(
                    "Final ASR result | provider=\(self.transcriptionProvider.name) | samples=\(pcm.count) | textChars=0 | confidence=nil | reason=short_silence",
                    source: "ASRService"
                )
                self.benchmarkLog(
                    "stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=short_silence"
                )
                return ""
            }
        } else if hasRecognizedStreamingPreview {
            self.benchmarkLog("silence_gate eligible=false skip=false reason=streaming_preview")
        }

        // Pad sub-1s buffers with trailing silence so short utterances (e.g.
        // "yes", "stop") still transcribe. whisper.cpp asserts on buffers
        // shorter than 1s; every other provider handles silence padding
        // without issue, so we pad unconditionally rather than branching per
        // provider.
        let minSamples = 16_000
        if pcm.count < minSamples {
            let originalCount = pcm.count
            pcm.append(contentsOf: repeatElement(0.0, count: minSamples - pcm.count))
            DebugLogger.shared.debug(
                "stop(): padded short audio with silence (\(originalCount) → \(pcm.count) samples)",
                source: "ASRService"
            )
        }

        do {
            traceStop("readiness_begin")
            var provider = self.transcriptionProvider
            let ensureStartedAt = Date().timeIntervalSince1970
            if self.isAsrReady, provider.isReady {
                self.benchmarkLog("stop_ensure_ready skipped=true elapsedMs=0")
            } else {
                // TODO: Investigate rapid restart while this cold-provider stop is pending (PR #950).
                // A new recording may replace output context still read by the previous transcript.
                // Not reproduced in-app; defer changes for now and preserve responsive restarts.
                self.publishStoppedState(for: stoppingSessionID)
                DebugLogger.shared.debug("🔍 Calling ensureAsrReady()...", source: "ASRService")
                try await self.ensureAsrReady()
                provider = self.transcriptionProvider
                self.benchmarkLog("stop_ensure_ready skipped=false elapsedMs=\(self.elapsedMilliseconds(since: ensureStartedAt))")
                DebugLogger.shared.debug("✅ ensureAsrReady() completed", source: "ASRService")
            }

            guard provider.isReady else {
                DebugLogger.shared.error("Transcription provider is not ready", source: "ASRService")
                self.lastStopOutcome = .failed
                self.benchmarkLog("stop_end result=empty totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) reason=provider_not_ready")
                return ""
            }

            DebugLogger.shared.debug("Starting transcription with \(pcm.count) samples (\(Float(pcm.count) / 16_000.0) seconds)", source: "ASRService")
            let finalStartedAt = Date().timeIntervalSince1970
            traceStop("final_asr_begin")
            let result: ASRTranscriptionResult
            let finalSource: String
            if useDictionaryTrainingPath {
                result = try await self.transcriptionExecutor.run { [provider] in
                    self.publishStoppedState(for: stoppingSessionID)
                    if let captureDictionaryPronunciation {
                        return try await provider.transcribeDictionaryTraining(pcm, capturePronunciation: captureDictionaryPronunciation)
                    }
                    return try await provider.transcribeDictionaryTraining(pcm)
                }
                var enrollment = result.pronunciationEnrollment
                // Preserve the unpadded boundary alongside the exact model input.
                enrollment?.pendingInspection?.recordedSampleCount = capturedPCM.count
                self.lastDictionaryTrainingResult = ASRTranscriptionResult(
                    text: result.text,
                    confidence: result.confidence,
                    pronunciationEnrollment: enrollment,
                    dictionaryLearningAlignment: result.dictionaryLearningAlignment
                )
                finalSource = "dictionaryTraining"
            } else {
                let vocabularyProvider = provider as? FluidAudioProvider
                self.benchmarkLog(
                    "final_executor_request model=\(SettingsStore.shared.selectedSpeechModel.rawValue) " +
                        "samples=\(pcm.count) vocabEnabled=\(vocabularyProvider?.isWordBoostingActive == true) " +
                        "vocabTerms=\(vocabularyProvider?.boostedVocabularyTermsCount ?? 0)"
                )
                let delayedFinalStatusTask = scheduleDeferredMainActorOperation(
                    afterNanoseconds: Self.finalTranscriptionStatusDelayNanoseconds,
                    shouldRun: { [weak self] in self?.benchmarkSessionID == stoppingSessionID }
                ) { [weak self] in
                    guard let self else { return }
                    self.publishStoppedState(for: stoppingSessionID)
                    if let onFinalTranscriptionStarted {
                        self.benchmarkLog("final_started_callback_begin trigger=delayed_status")
                        onFinalTranscriptionStarted()
                        self.benchmarkLog("final_started_callback_end trigger=delayed_status")
                    }
                }
                defer { delayedFinalStatusTask.cancel() }
                result = try await self.transcriptionExecutor.run(benchmarkSessionID: self.benchmarkSessionID) { [provider] in
                    // The executor closure inherits main-actor isolation, so inference
                    // and every await hop would otherwise run on or wait for the main
                    // thread. Detach so the UI stays responsive during final ASR.
                    try await Task.detached(priority: .userInitiated) {
                        let executionStartedAt = ProcessInfo.processInfo.systemUptime
                        DebugLogger.shared.debug("ASR_BENCH t=\(executionStartedAt) final_executor_begin mainThread=\(Thread.isMainThread)", source: "ASRBenchmark")
                        defer {
                            // Cancel here, not after the main-actor hop: the status
                            // would otherwise fire while the result waits for main.
                            delayedFinalStatusTask.cancel()
                            DebugLogger.shared.debug("ASR_BENCH t=\(ProcessInfo.processInfo.systemUptime) final_executor_end", source: "ASRBenchmark")
                        }
                        return try await provider.transcribeFinal(pcm)
                    }.value
                }
                delayedFinalStatusTask.cancel()
                self.publishStoppedState(for: stoppingSessionID)
                self.benchmarkLog("final_executor_return")
                finalSource = "full"
            }
            let finalElapsedMs = self.elapsedMilliseconds(since: finalStartedAt)
            traceStop("final_asr_end")
            if !useDictionaryTrainingPath {
                self.lastFinalTranscriptionDurationMs = finalElapsedMs
                self.lastFinalParakeetProcessingMs = result.parakeetProcessingDurationMilliseconds
            }
            let finalAudioSeconds = Double(pcm.count) / 16_000.0
            let finalRTF = finalAudioSeconds > 0 ? (Double(finalElapsedMs) / 1000.0) / finalAudioSeconds : 0
            DebugLogger.shared.debug("stop(): final transcription finished source=\(finalSource)", source: "ASRService")
            DebugLogger.shared.debug(
                "Transcription completed: '\(result.text)' (confidence: \(result.confidence))",
                source: "ASRService"
            )
            DebugLogger.shared.info(
                "Final ASR result | provider=\(provider.name) | samples=\(pcm.count) | textChars=\(result.text.trimmingCharacters(in: .whitespacesAndNewlines).count) | confidence=\(result.confidence)",
                source: "ASRService"
            )
            self.benchmarkLog(
                "final_done elapsedMs=\(finalElapsedMs) samples=\(pcm.count) audioMs=\(Int((finalAudioSeconds * 1000).rounded())) " +
                    "textChars=\(result.text.trimmingCharacters(in: .whitespacesAndNewlines).count) rtf=\(String(format: "%.3f", finalRTF)) streamedChunks=\(self.benchmarkCompletedStreamingChunks) source=\(finalSource)"
            )

            // Mark first transcription as complete to clear loading state
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                DispatchQueue.main.async {
                    self.isLoadingModel = false
                    self.modelPreparationPhase = nil
                    DebugLogger.shared.info("✅ Model warmed up - first transcription completed", source: "ASRService")
                }
            }

            // Do not update self.finalText here to avoid instant binding insert in playground
            if !isolatedDictionaryCapture, SettingsStore.shared.automaticDictionaryLearningEnabled || DictionaryMatcherExperiment.collectNegatives,
               let alignment = result.dictionaryLearningAlignment
            {
                self.retainDictionaryLearningRecording(DictionaryLearningRecording(
                    alignment: alignment,
                    samples: capturedPCM,
                    retainAudio: SettingsStore.shared.automaticDictionaryLearningEnabled
                ))
            }

            let textWithoutFillers = ASRService.removeFillerWords(result.text)
            let dictionaryText = useDictionaryTrainingPath
                ? textWithoutFillers
                : ASRService.applyCustomDictionary(textWithoutFillers)
            let outputText = useDictionaryTrainingPath
                ? dictionaryText
                : ASRService.applySpokenPunctuationFormatting(dictionaryText)
            if !isolatedDictionaryCapture {
                self.recordWordBoostHitIfAny(transcribedText: outputText)
            }
            DebugLogger.shared.debug("After post-processing: '\(outputText)'", source: "ASRService")
            self
                .benchmarkLog(
                    "stop_end result=success totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) recordingAgeMs=\(self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)) cleanedChars=\(outputText.count)"
                )
            if !isolatedDictionaryCapture,
               SettingsStore.shared.saveTranscriptionHistory,
               SettingsStore.shared.saveAudioWithTranscriptionHistory,
               !capturedPCM.isEmpty
            {
                self.lastCompletedAudioSnapshot = DictationAudioSnapshot(
                    samples: capturedPCM,
                    sampleRate: 16_000,
                    channels: 1
                )
            }

            if !isolatedDictionaryCapture, capturedPCM.count <= 16_000 * 120 {
                self.dictionaryTestAudioSubject.send(capturedPCM)
            }

            self.lastStopOutcome = outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .empty
                : .success
            return outputText
        } catch {
            self.lastStopOutcome = .failed
            DebugLogger.shared.error("ASR transcription failed: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            let nsError = error as NSError
            DebugLogger.shared.error("Error domain: \(nsError.domain), code: \(nsError.code)", source: "ASRService")
            DebugLogger.shared.error("Error userInfo: \(nsError.userInfo)", source: "ASRService")

            // Clear loading state if this was the first transcription attempt
            // This ensures the UI doesn't show a perpetual loading state on error
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                DispatchQueue.main.async {
                    self.isLoadingModel = false
                    self.modelPreparationPhase = nil
                    DebugLogger.shared.info("⚠️ First transcription failed - clearing loading state", source: "ASRService")
                }
            }

            // Note: We intentionally do NOT show an error popup here.
            // Common errors like "audio too short" are expected during normal use
            // (e.g., accidental hotkey press) and would disrupt the user's workflow.
            // Errors are logged for debugging purposes.

            self.benchmarkLog("stop_end result=error totalMs=\(self.elapsedMilliseconds(since: stopStartedAt)) error=\(error.localizedDescription)")
            return ""
        }
    }

    private func beginDeferredStopUIInvalidation() {
        self.stopUIInvalidationGate.begin()
        self.stopUIInvalidationTimeoutTask?.cancel()
        self.stopUIInvalidationTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard Task.isCancelled == false else { return }
            self?.forceFinishDeferredStopUIInvalidation()
        }
    }

    /// Keeps whole-view invalidation from rebuilding SwiftUI between final ASR
    /// and output dispatch. The generation makes stale pipeline cleanup harmless.
    func holdStopUIInvalidationForOutputPipeline() -> UInt64 {
        self.stopUIInvalidationHoldGeneration &+= 1
        let generation = self.stopUIInvalidationHoldGeneration
        self.activeStopUIInvalidationHold = generation
        self.stopUIInvalidationGate.holdForOutputPipeline()
        return generation
    }

    func releaseStopUIInvalidationForOutputPipeline(_ generation: UInt64) {
        guard self.activeStopUIInvalidationHold == generation else { return }
        self.activeStopUIInvalidationHold = nil
        self.flushDeferredStopUIInvalidation(
            shouldFlush: self.stopUIInvalidationGate.releaseOutputPipelineHold()
        )
    }

    /// Publishes the stopped state only after final ASR has entered its
    /// executor. Streaming ownership is revoked earlier by the scheduler and
    /// buffer handoff gates, so this keeps SwiftUI work off hardware teardown.
    private func publishStoppedState(for sessionID: Int) {
        guard self.benchmarkSessionID == sessionID, self.isRunning else { return }
        DebugLogger.shared.debug("🚫 Publishing isRunning = false...", source: "ASRService")
        self.beginDeferredStopUIInvalidation()
        self.isRunning = false
        self.isStoppingFinalTranscription = false
        DebugLogger.shared.debug("✅ isRunning disabled", source: "ASRService")
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.benchmarkSessionID == sessionID,
                  self.isRunning == false
            else { return }
            self.audioCaptureStateDidSettle.send()
        }
    }

    private func finishDeferredStopUIInvalidation() {
        self.flushDeferredStopUIInvalidation(shouldFlush: self.stopUIInvalidationGate.finish())
    }

    private func forceFinishDeferredStopUIInvalidation() {
        self.activeStopUIInvalidationHold = nil
        self.flushDeferredStopUIInvalidation(shouldFlush: self.stopUIInvalidationGate.forceFinish())
    }

    private func flushDeferredStopUIInvalidation(shouldFlush: Bool) {
        guard shouldFlush else { return }
        self.stopUIInvalidationTimeoutTask?.cancel()
        self.stopUIInvalidationTimeoutTask = nil
        self.objectWillChange.send()
        self.deferredStopUIInvalidationDidFlush.send()
    }

    func transcribeSamplesForAPI(_ inputSamples: [Float]) async throws -> ASRTranscriptionResult {
        let lease = try self.acquireExclusiveActivity(.localAPI)
        defer { self.releaseExclusiveActivity(lease) }
        return try await self.transcribeSamplesForAPIWithLease(inputSamples)
    }

    private func transcribeSamplesForAPIWithLease(_ inputSamples: [Float]) async throws -> ASRTranscriptionResult {
        var samples = inputSamples
        guard !samples.isEmpty else {
            return ASRTranscriptionResult(text: "", confidence: 0)
        }

        let minSamples = 16_000
        if samples.count < minSamples {
            samples.append(contentsOf: repeatElement(0.0, count: minSamples - samples.count))
        }

        try await self.ensureAsrReady()
        guard self.transcriptionProvider.isReady else {
            throw NSError(
                domain: "ASRService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Transcription provider is not ready."]
            )
        }

        let result = try await transcriptionExecutor.run { [provider = self.transcriptionProvider] in
            try await provider.transcribeFinal(samples)
        }

        if !self.hasCompletedFirstTranscription {
            self.hasCompletedFirstTranscription = true
            self.isLoadingModel = false
            self.modelPreparationPhase = nil
        }

        let cleanedText = DictationTextFormatter.clean(result.text, settings: .currentForClean)
        self.recordWordBoostHitIfAny(transcribedText: cleanedText)
        return ASRTranscriptionResult(text: cleanedText, confidence: result.confidence)
    }

    func transcribeFileForAPI(_ fileURL: URL) async throws -> (result: ASRTranscriptionResult, sampleCount: Int) {
        let lease = try self.acquireExclusiveActivity(.localAPI)
        defer { self.releaseExclusiveActivity(lease) }
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw NSError(
                domain: "ASRService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Audio file is not readable."]
            )
        }

        let estimatedSamples = try LocalAPIAudioDecoder.estimatedSampleCount(for: fileURL)

        try await self.ensureAsrReady()
        let provider = self.transcriptionProvider
        guard provider.isReady else {
            throw NSError(
                domain: "ASRService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Transcription provider is not ready."]
            )
        }

        if provider.prefersNativeFileTranscription,
           estimatedSamples > 0,
           estimatedSamples < 16_000
        {
            let reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: fileURL)
            let samples = try await reader.nextSamples()
            let result = try await self.transcribeSamplesForAPIWithLease(samples)
            return (result, sampleCount: estimatedSamples)
        }

        guard provider.prefersNativeFileTranscription else {
            let reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: fileURL)
            let (combinedText, confidence, processedSampleCount) = try await transcriptionExecutor.run { [provider] in
                var textParts: [String] = []
                var weightedConfidence = 0.0
                var processedSampleCount = 0

                while true {
                    var samples = try await reader.nextSamples()
                    let sampleCount = samples.count
                    guard sampleCount > 0 else { break }
                    if sampleCount < 16_000 {
                        samples.append(contentsOf: repeatElement(0.0, count: 16_000 - sampleCount))
                    }

                    let result = try await provider.transcribeFinal(samples)
                    if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        textParts.append(result.text)
                    }
                    weightedConfidence += Double(result.confidence) * Double(sampleCount)
                    processedSampleCount += sampleCount
                }

                let confidence = processedSampleCount > 0
                    ? Float(weightedConfidence / Double(processedSampleCount))
                    : 0
                return (textParts.joined(separator: " "), confidence, processedSampleCount)
            }

            guard processedSampleCount > 0 else {
                return (ASRTranscriptionResult(text: "", confidence: 0), sampleCount: 0)
            }

            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                self.isLoadingModel = false
                self.modelPreparationPhase = nil
            }

            let cleanedText = DictationTextFormatter.clean(combinedText, settings: .currentForClean)
            self.recordWordBoostHitIfAny(transcribedText: cleanedText)
            return (
                ASRTranscriptionResult(text: cleanedText, confidence: confidence),
                sampleCount: estimatedSamples
            )
        }

        let result = try await transcriptionExecutor.run { [provider] in
            try await provider.transcribeFile(at: fileURL)
        }

        if !self.hasCompletedFirstTranscription {
            self.hasCompletedFirstTranscription = true
            self.isLoadingModel = false
            self.modelPreparationPhase = nil
        }

        let cleanedText = DictationTextFormatter.clean(result.text, settings: .currentForClean)
        self.recordWordBoostHitIfAny(transcribedText: cleanedText)
        return (ASRTranscriptionResult(text: cleanedText, confidence: result.confidence), estimatedSamples)
    }

    // MARK: - Exclusive model residency

    func meetingResidencyParticipant() -> MeetingModelParticipant {
        MeetingModelParticipant(
            owner: "speech",
            snapshot: { [weak self] in
                guard let self else { throw CancellationError() }
                guard !self.hasActiveModelDownload, !self.hasActiveModelPreparation,
                      self.activeExclusiveActivity == .meeting else { throw MeetingModelResidencyError.busy }
                guard self.isAsrReady, let id = self.residentDictationModelID else { return nil }
                return MeetingResidentModel(id: id, configuration: id)
            },
            suspend: { [weak self] in
                guard let self, let lease = self.activeActivityLease else { throw CancellationError() }
                try await self.retireDictationASRResourcesForMeeting(lease: lease)
            },
            restore: { [weak self] model in
                guard let self, !self.isTerminating,
                      SettingsStore.shared.selectedSpeechModel.id == model.id else { return }
                // Never download a missing model just to restore residency.
                guard try await SpeechModelReadiness.modelArtifactsExist(provider: self.transcriptionProvider),
                      !self.isTerminating, SettingsStore.shared.selectedSpeechModel.id == model.id else { return }
                try await self.ensureAsrReady()
                if SettingsStore.shared.selectedSpeechModel.id != model.id,
                   let lease = self.activeActivityLease
                {
                    try await self.retireDictationASRResourcesForMeeting(lease: lease)
                }
            }
        )
    }

    func withMeetingModelResidency<T>(attemptID: UUID, acceptsCompletedCancellation: (T) -> Bool = { _ in false }, work: () async throws -> T) async throws -> T {
        try await self.meetingModelResidency.withExclusive(
            attemptID: attemptID,
            participants: [
                self.meetingResidencyParticipant(),
                PrivateAIIntegrationService.meetingResidencyParticipant(),
                DictionaryTrainingEndpointMonitor.shared.meetingResidencyParticipant(),
            ],
            acceptsCompletedCancellation: acceptsCompletedCancellation,
            work: work
        )
    }

    // MARK: - Scoped Meeting ASR Preparation

    private var activeMeetingASRPreparationOwner: MeetingASRPreparationOwner? {
        #if DEBUG
        if let injected = self.meetingASRPreparationOwnerForTesting { return injected }
        #endif
        return self.meetingASRPreparationOwner
    }

    private var isMeetingASRPreparationClaimed: Bool {
        guard let owner = self.activeMeetingASRPreparationOwner else { return false }
        return owner.isClaimed || owner.isDraining
    }

    private func meetingASROwner() -> MeetingASRPreparationOwner {
        #if DEBUG
        if let injected = self.meetingASRPreparationOwnerForTesting { return injected }
        #endif
        if let existing = self.meetingASRPreparationOwner { return existing }
        let owner = MeetingASRPreparationOwner(
            isActiveLease: { [weak self] lease in
                self?.activeActivityLease == lease
            },
            isUserDownloadInProgress: { [weak self] in
                self?.hasActiveModelDownload ?? false
            },
            retireDictationResources: { [weak self] lease in
                guard let self else { throw CancellationError() }
                try await self.retireDictationASRResourcesForMeeting(lease: lease)
            },
            makeProvider: { configuration in
                // Language selects the pinned Parakeet v2/v3 model; never reads selectedSpeechModel.
                try FluidAudioProvider(meetingConfiguration: configuration)
            },
            prepareProvider: { provider, _, progress in
                try await provider.prepare(progressHandler: progress)
            },
            drainExecutor: { [weak self] _ in
                await self?.meetingTranscriptionExecutor.cancelAndAwaitPending()
            }
        )
        self.meetingASRPreparationOwner = owner
        return owner
    }

    /// Drops cached dictation providers and drains the legacy executor for a claimed meeting
    /// preparation. On-disk model caches are never deleted.
    func retireDictationASRResourcesForMeeting(lease: ASRActivityLease) async throws {
        guard self.activeActivityLease == lease, lease.activity == .meeting else {
            throw CancellationError()
        }
        guard !self.hasActiveModelDownload else {
            throw MeetingASRPreparationError.userModelDownloadInProgress
        }

        if let retiringTask = self.ensureReadyTask {
            self.isCancellingModelPreparation = true
            retiringTask.cancel()
            _ = await retiringTask.result
        }
        await self.transcriptionExecutor.cancelAndAwaitPending()

        guard self.activeActivityLease == lease else { throw CancellationError() }
        self.providerCache.releaseAll()
        self.residentDictationModelID = nil
        self.isAsrReady = false
    }

    private func isMeetingASRClaimBlocking(lease: ASRActivityLease) -> Bool {
        guard lease.activity == .meeting else { return false }
        if let scope = self.activeMeetingASRScope, scope.lease == lease { return true }
        if let owner = self.activeMeetingASRPreparationOwner,
           owner.currentClaimToken?.lease == lease,
           owner.isClaimed || owner.isDraining
        {
            return true
        }
        return false
    }

    private func executorForMeetingTranscription() -> TranscriptionExecutor {
        if self.activeMeetingASRScope != nil || self.isMeetingASRPreparationClaimed {
            return self.meetingTranscriptionExecutor
        }
        return self.transcriptionExecutor
    }

    /// Runs `body` with the dedicated fixed-configuration meeting ASR provider. Requires the
    /// active meeting lease; one scope at a time. Release/drain is awaited on success, error,
    /// and cancellation before the scope clears and any deferred lease release flushes.
    @discardableResult
    func withPreparedMeetingASR<Result>(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: @escaping (any TranscriptionProvider) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard let lease = self.activeActivityLease, lease.activity == .meeting else {
            throw MeetingASRPreparationError.invalidActivityLease
        }
        guard self.activeMeetingASRScope == nil else {
            throw MeetingASRPreparationError.preparationInProgress
        }
        let scopeID = UUID()
        self.activeMeetingASRScope = MeetingASRScope(
            id: scopeID,
            lease: lease,
            cancelBody: nil,
            awaitBodyCompletion: nil
        )

        let owner = self.meetingASROwner()
        let provider: any TranscriptionProvider
        do {
            provider = try await owner.prepare(lease: lease, attemptID: attemptID, configuration: configuration)
        } catch {
            // The owner already drained the failed preparation.
            self.finishMeetingASRScope(scopeID: scopeID)
            throw error
        }
        guard self.activeActivityLease == lease,
              let token = owner.currentClaimToken, token.lease == lease
        else {
            if let token = owner.currentClaimToken { await owner.release(token) }
            self.finishMeetingASRScope(scopeID: scopeID)
            throw CancellationError()
        }

        do {
            let bodyTask = Task { @MainActor in
                try await body(provider)
            }
            guard self.activeMeetingASRScope?.id == scopeID else {
                bodyTask.cancel()
                _ = await bodyTask.result
                throw CancellationError()
            }
            self.activeMeetingASRScope?.cancelBody = {
                bodyTask.cancel()
            }
            self.activeMeetingASRScope?.awaitBodyCompletion = {
                _ = await bodyTask.result
            }
            let result = try await withTaskCancellationHandler {
                try await bodyTask.value
            } onCancel: {
                bodyTask.cancel()
            }
            // A provider/model call may not observe cooperative cancellation until it
            // returns. Never publish that late success after the enclosing attempt was
            // cancelled; teardown still runs below before cancellation escapes.
            if bodyTask.isCancelled { throw CancellationError() }
            try Task.checkCancellation()
            await owner.release(token)
            self.finishMeetingASRScope(scopeID: scopeID)
            return result
        } catch {
            await owner.release(token)
            self.finishMeetingASRScope(scopeID: scopeID)
            throw error
        }
    }

    private func finishMeetingASRScope(scopeID: UUID) {
        if self.activeMeetingASRScope?.id == scopeID {
            self.activeMeetingASRScope = nil
        }
        self.flushDeferredMeetingLeaseReleaseIfReady()
    }

    private func flushDeferredMeetingLeaseReleaseIfReady() {
        guard let lease = self.deferredMeetingActivityLeaseRelease,
              !self.isMeetingASRClaimBlocking(lease: lease)
        else { return }
        self.deferredMeetingActivityLeaseRelease = nil
        guard self.activeActivityLease == lease else { return }
        let reason = self.deferredMeetingRouteRecoveryReason
        let requiresPrewarm = self.deferredMeetingRouteRecoveryRequiresPrewarm
        let reconcilesInput = self.deferredMeetingRouteRecoveryReconcilesInput
        self.deferredMeetingRouteRecoveryReason = nil
        self.deferredMeetingRouteRecoveryRequiresPrewarm = false
        self.deferredMeetingRouteRecoveryReconcilesInput = false
        self.releaseExclusiveActivity(lease)
        if requiresPrewarm || reason != nil {
            self.scheduleAudioRouteRecovery(
                reason: reason ?? "meeting audio handback",
                requiresIdlePrewarm: requiresPrewarm,
                reconcilesInputSelection: reconcilesInput
            )
        }
    }

    func transcribeMeetingSamples(
        _ samples: [Float],
        provider: any TranscriptionProvider,
        languageCode: String
    ) async throws -> ASRTranscriptionResult {
        guard self.activeExclusiveActivity == .meeting else {
            throw ASRActivityError.activityInProgress(self.activeExclusiveActivity ?? .meeting)
        }
        return try await self.executorForMeetingTranscription().run { [provider] in
            if let whisperProvider = provider as? WhisperProvider {
                return try await whisperProvider.transcribe(samples, languageCode: languageCode)
            }
            return try await provider.transcribe(samples)
        }
    }

    func transcribeMeetingSamplesWithTimings(
        _ samples: [Float],
        provider: any TranscriptionProvider
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        guard self.activeExclusiveActivity == .meeting else {
            throw ASRActivityError.activityInProgress(self.activeExclusiveActivity ?? .meeting)
        }
        return try await self.executorForMeetingTranscription().run { [provider] in
            try await provider.transcribeWithWordTimings(samples)
        }
    }

    func transcribeMeetingFile(
        at fileURL: URL,
        provider: any TranscriptionProvider
    ) async throws -> ASRTranscriptionResult {
        guard self.activeExclusiveActivity == .meeting else {
            throw ASRActivityError.activityInProgress(self.activeExclusiveActivity ?? .meeting)
        }
        return try await self.executorForMeetingTranscription().run { [provider] in
            try await provider.transcribeFile(at: fileURL)
        }
    }

    func stopWithoutTranscription() async {
        await self.stopWithoutTranscription(finishingRecovery: false)
    }

    private func stopWithoutTranscription(finishingRecovery: Bool) async {
        if self.isStarting, self.isRunning == false {
            await self.cancelPendingAudioCaptureStart(reason: "stop_without_transcription")
        }
        guard self.isRunning else {
            self.releaseDictationActivityIfNeeded()
            return
        }
        let stoppingSessionID = self.benchmarkSessionID
        guard let bufferHandoffToken = self.recordingBufferHandoffGate.begin() else { return }
        self.mediaPlaybackService.recordingStopped(sessionID: stoppingSessionID)
        defer { self.mediaPlaybackService.sessionFinished(sessionID: stoppingSessionID) }
        var completedBufferHandoff = false
        defer {
            if completedBufferHandoff == false {
                self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            }
        }
        self.stopStreamingScheduler(sessionID: stoppingSessionID)
        defer {
            self.applyPendingParakeetVocabularyReloadIfNeeded()
            self.isDictionaryTrainingCaptureActive = false
            self.releaseDictationActivityIfNeeded()
        }

        if finishingRecovery == false {
            await self.cancelAudioRouteRecoveryAndWait()
        }
        guard self.isRunning, self.benchmarkSessionID == stoppingSessionID else {
            self.recordingBufferHandoffGate.complete(bufferHandoffToken)
            completedBufferHandoff = true
            return
        }

        DebugLogger.shared.info("🛑 Stopping recording - releasing audio devices", source: "ASRService")

        // CRITICAL: Set isRunning to false FIRST to signal any in-flight chunks to abort early
        self.isRunning = false
        self.audioCapturePipeline.setRecordingEnabled(false)

        await self.stopActiveAudioCapture(
            retainDirectPreparedCapture: false,
            reason: "stop_without_transcription"
        )
        DebugLogger.shared.debug("Audio capture stopped", source: "ASRService")

        self.audioCaptureStateDidSettle.send()

        guard await self.drainActiveStreamingWork(sessionID: stoppingSessionID) else {
            self.beginStreamingDrainRecovery(sessionID: stoppingSessionID, token: bufferHandoffToken)
            completedBufferHandoff = true
            return
        }

        // NOW it's safe to clear the buffer
        self.audioBuffer.clear()
        self.streamingWorkState.endSession(stoppingSessionID)
        self.recordingBufferHandoffGate.complete(bufferHandoffToken)
        completedBufferHandoff = true
        self.partialTranscription.removeAll()
        self.previousFullTranscription.removeAll()
        self.lastBoostHitTerm = nil
        self.lastProcessedSampleCount = 0
        self.isProcessingChunk = false
        self.skipNextChunk = false
        self.refreshWordBoostStatus()
    }

    private func scheduleAudioRouteRecovery(
        reason: String,
        requiresIdlePrewarm: Bool = false,
        reconcilesInputSelection: Bool = false,
        invalidatesCurrentStart: Bool = false
    ) {
        guard self.isTerminating == false else {
            self.benchmarkLog("route_recovery_ignored reason=app_terminating event=\(reason)")
            return
        }
        if self.activeExclusiveActivity == .meeting {
            self.deferredMeetingRouteRecoveryReason = reason
            self.deferredMeetingRouteRecoveryRequiresPrewarm =
                self.deferredMeetingRouteRecoveryRequiresPrewarm || requiresIdlePrewarm
            self.deferredMeetingRouteRecoveryReconcilesInput =
                self.deferredMeetingRouteRecoveryReconcilesInput || reconcilesInputSelection
            self.benchmarkLog("route_recovery_deferred reason=meeting_owns_topology event=\(reason)")
            return
        }
        if AudioCaptureIdlePolicy.shouldDeferRouteRecoveryToBluetoothStart(
            isStarting: self.isStarting,
            isRunning: self.isRunning,
            attemptedInputIsBluetooth: self.audioStartAttemptIsBluetooth
        ) {
            // AirPods and other Bluetooth inputs can replace their streams more
            // than once while entering microphone mode. The active start owns
            // its bounded retry loop; a second recovery owner would exclude the
            // same healthy device before the Bluetooth route settles.
            let disposition = AudioCaptureIdlePolicy.bluetoothStartupRouteChangeDisposition(
                invalidatesCurrentStart: invalidatesCurrentStart,
                requiresIdlePrewarm: requiresIdlePrewarm,
                reconcilesInputSelection: reconcilesInputSelection
            )
            if disposition == .retryCurrentStart {
                // Make routeStayedStable false even if first PCM won the
                // readiness-gate race. The startup loop then retries the same
                // Bluetooth input without handing it to active-route recovery.
                self.audioRouteRecoveryGeneration &+= 1
                self.benchmarkLog(
                    "bluetooth_start_route_invalidation_retry event=\(reason) " +
                        "routeGeneration=\(self.audioRouteRecoveryGeneration)"
                )
                return
            }
            if disposition == .preserveDeferredWork {
                self.deferredBluetoothStartupRouteRecovery.preserve(
                    reason: reason,
                    requiresIdlePrewarm: requiresIdlePrewarm,
                    reconcilesInputSelection: reconcilesInputSelection
                )
            }
            self.benchmarkLog(
                "bluetooth_start_route_change_deferred event=\(reason) " +
                    "disposition=\(disposition)"
            )
            return
        }
        self.audioRouteRecoveryGeneration &+= 1
        let requiresPrewarmAfterRecovery =
            requiresIdlePrewarm || self.pendingAudioRouteRecovery?.requiresIdlePrewarm == true
        let reconcilesInputAfterRecovery =
            reconcilesInputSelection || self.pendingAudioRouteRecovery?.reconcilesInputSelection == true
        let request = AudioRouteRecoveryRequest(
            generation: self.audioRouteRecoveryGeneration,
            reason: reason,
            requiresIdlePrewarm: requiresPrewarmAfterRecovery,
            reconcilesInputSelection: reconcilesInputAfterRecovery
        )
        self.pendingAudioRouteRecovery = request
        #if DEBUG
        AudioTopologyDiagnostics.record(
            .recoveryScheduled,
            owner: .asrDeviceList,
            queueRole: .mainControl,
            phase: .recovery,
            generation: request.generation
        )
        #endif

        self.audioLevelSubject.send(0.0)
        if self.isRunning || self.isStarting {
            // Stop accepting samples immediately, but do not touch capture hardware
            // until Core Audio has been quiet for the debounce interval.
            self.audioCapturePipeline.setRecordingEnabled(false)
            DebugLogger.shared.warning(
                "Audio route changed during capture; waiting for topology quiet " +
                    "(\(reason), generation=\(request.generation), " +
                    "isStarting=\(self.isStarting), isRunning=\(self.isRunning))",
                source: "ASRService"
            )
        } else {
            DebugLogger.shared.debug(
                "Audio route changed while idle; waiting for topology quiet (\(reason), generation=\(request.generation))",
                source: "ASRService"
            )
        }

        self.audioRouteRecoveryTask?.cancel()
        guard self.isRecoveringAudioRoute == false else {
            // The in-flight recovery observes cancellation after its next await,
            // and finishAudioRouteRecovery arms the latest generation.
            return
        }

        self.armAudioRouteRecovery(request)
    }

    private func armAudioRouteRecovery(_ request: AudioRouteRecoveryRequest) {
        let recoveryDelayNanoseconds = self.audioRouteRecoveryDelayNanoseconds
        self.audioRouteRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: recoveryDelayNanoseconds)
            } catch {
                return
            }
            await self?.performAudioRouteRecovery(request)
        }
    }

    /// Cancels a sleeping or active recovery and waits for it to finish.
    private func cancelAudioRouteRecoveryAndWait() async {
        self.audioRouteRecoveryGeneration &+= 1
        #if DEBUG
        AudioTopologyDiagnostics.record(
            .recoveryCancel,
            owner: .asrDeviceList,
            queueRole: .mainControl,
            phase: .recovery,
            generation: self.audioRouteRecoveryGeneration
        )
        #endif
        self.pendingAudioRouteRecovery = nil
        let task = self.audioRouteRecoveryTask
        task?.cancel()
        _ = await task?.result
        self.audioRouteRecoveryTask = nil
        self.isRecoveringAudioRoute = false
    }

    /// Recording startup must let an already-scheduled route rebuild finish.
    /// Cancelling it here can preserve the stale prepared generation that the
    /// route event was meant to retire.
    private func waitForPendingAudioRouteRecoveryBeforeStart() async {
        let startedAt = Date().timeIntervalSince1970
        var waitedGenerations: [UInt64] = []
        while let task = self.audioRouteRecoveryTask {
            let generation = self.audioRouteRecoveryGeneration
            waitedGenerations.append(generation)
            self.benchmarkLog("route_recovery_handoff_wait generation=\(generation)")
            _ = await task.result
            if self.pendingAudioRouteRecovery == nil,
               self.isRecoveringAudioRoute == false
            {
                self.audioRouteRecoveryTask = nil
                break
            }
        }
        self.benchmarkLog(
            "route_recovery_handoff_end generations=\(waitedGenerations) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) " +
                "capturePhase=\(self.directAudioLifecycleController.snapshot.phase.rawValue)"
        )
    }

    private func performAudioRouteRecovery(_ request: AudioRouteRecoveryRequest) async {
        guard self.isTerminating == false,
              request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false
        else { return }
        guard self.isRecoveringAudioRoute == false else { return }

        self.isRecoveringAudioRoute = true
        #if DEBUG
        AudioTopologyDiagnostics.record(
            .recoveryBegin,
            owner: .asrDeviceList,
            queueRole: .mainControl,
            phase: .recovery,
            generation: request.generation
        )
        #endif
        defer {
            self.finishAudioRouteRecovery(request)
        }

        let hardwareAvailable = await self.replaceDirectAudioLifecycleControllerIfBlocked(reason: "route_recovery")
        guard request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false, self.isTerminating == false else { return }
        guard hardwareAvailable else {
            await self.finishAudioRouteRecoveryFailure(request, error: BoundedAudioHardwareQueue.Failure.recovering)
            return
        }

        if request.reconcilesInputSelection,
           await self.reconcileInputSelectionAfterTopologySettles(request) == false
        {
            return
        }

        if self.isRunning {
            await self.recoverActiveAudioRoute(request)
        } else {
            await self.recoverIdleAudioRoute(request)
        }
    }

    private func finishAudioRouteRecovery(_ completedRequest: AudioRouteRecoveryRequest) {
        #if DEBUG
        AudioTopologyDiagnostics.record(
            .recoveryEnd,
            owner: .asrDeviceList,
            queueRole: .mainControl,
            phase: .recovery,
            status: Task.isCancelled ? -1 : noErr,
            generation: completedRequest.generation
        )
        #endif
        self.isRecoveringAudioRoute = false

        guard let pendingRequest = self.pendingAudioRouteRecovery else {
            self.audioRouteRecoveryTask = nil
            return
        }
        guard pendingRequest.generation != completedRequest.generation else {
            self.pendingAudioRouteRecovery = nil
            self.audioRouteRecoveryTask = nil
            return
        }

        self.armAudioRouteRecovery(pendingRequest)
    }

    private func reconcileInputSelectionAfterTopologySettles(
        _ request: AudioRouteRecoveryRequest
    ) async -> Bool {
        var resolvedSnapshot: DirectCoreAudioLifecycleController.DeviceSnapshot?
        var queryError: Error = BoundedAudioHardwareQueue.Failure.recovering
        // One bounded retry covers transient HAL queries without leaving a
        // recording paused after its recovery request has been consumed.
        for _ in 0..<2 {
            let available = await self.directAudioLifecycleController.waitForDeviceQueryAvailability()
            guard request.generation == self.audioRouteRecoveryGeneration,
                  Task.isCancelled == false, self.isTerminating == false else { return false }
            guard available else { break }
            do {
                resolvedSnapshot = try await self.directAudioLifecycleController.readDeviceSnapshot(refreshLiveness: true)
                break
            } catch {
                queryError = error
            }
        }
        guard request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false, self.isTerminating == false else { return false }
        guard let devices = resolvedSnapshot else {
            await self.finishAudioRouteRecoveryFailure(request, error: queryError)
            return false
        }
        let snapshot = (devices.devices, devices.defaultInputUID)

        let currentUIDs = Set(snapshot.0.map(\.uid))
        guard currentUIDs == self.cachedDeviceUIDs else {
            self.cacheCurrentDeviceList(snapshot.0)
            self.scheduleAudioRouteRecovery(
                reason: "input topology still settling",
                requiresIdlePrewarm: request.requiresIdlePrewarm,
                reconcilesInputSelection: true
            )
            return false
        }

        AppServices.shared.microphonePreferenceCoordinator.reconcileMicrophoneSelection(
            availableInputs: snapshot.0,
            defaultInputUID: snapshot.1
        )
        return true
    }

    private func recoverIdleAudioRoute(_ request: AudioRouteRecoveryRequest) async {
        let shouldRebuild = self.hasPreparedAudioCapture || request.requiresIdlePrewarm
        guard shouldRebuild else { return }
        let shouldRestoreMicrophonePreview = self.isMicrophonePreviewRequested
        let microphonePreviewGeneration = self.microphonePreviewOperationGeneration

        // If another event arrives while direct capture is invalidating, the next
        // generation still needs to restore the prepared capture backend.
        self.pendingAudioRouteRecovery = AudioRouteRecoveryRequest(
            generation: request.generation,
            reason: request.reason,
            requiresIdlePrewarm: true,
            reconcilesInputSelection: request.reconcilesInputSelection
        )
        await self.directAudioLifecycleController.invalidate(
            reason: "idle_route_change:\(request.reason)",
            recoveringRoute: true
        )
        self.activeAudioCaptureBackend = .none

        guard request.generation == self.audioRouteRecoveryGeneration, Task.isCancelled == false else { return }
        if shouldRestoreMicrophonePreview,
           self.isMicrophonePreviewRequested,
           microphonePreviewGeneration == self.microphonePreviewOperationGeneration
        {
            await self.startMicrophonePreview()
        } else {
            await self.prewarmConfiguredAudioCaptureIfPossible(
                reason: "idle_route_change",
                allowDuringRouteRecovery: true
            )
        }
    }

    private func recoverActiveAudioRoute(_ request: AudioRouteRecoveryRequest) async {
        guard self.isRunning else { return }

        DebugLogger.shared.info(
            "Recovering audio route after \(request.reason) (generation=\(request.generation))",
            source: "ASRService"
        )
        self.audioCapturePipeline.setRecordingEnabled(false)
        await self.stopActiveAudioCapture(
            retainDirectPreparedCapture: false,
            reason: "active_route_recovery"
        )
        let hardwareAvailable = await self.replaceDirectAudioLifecycleControllerIfBlocked(
            reason: "active_route_recovery"
        )
        guard request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false, self.isTerminating == false else { return }

        do {
            guard hardwareAvailable else { throw BoundedAudioHardwareQueue.Failure.recovering }
            var maximumStartAttempts = 1
            var hasReadInputSnapshot = false
            var failedInputUIDs = Set<String>()
            var immediatelyRetriedInputUID: String?
            var completedAttempts = 0

            while completedAttempts < maximumStartAttempts {
                completedAttempts += 1
                self.audioCaptureAttemptID &+= 1
                let readinessAttemptID = self.audioCaptureAttemptID
                self.audioCaptureReadinessGate.arm(
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID
                )
                self.audioCapturePipeline.setRecordingEnabled(
                    true,
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID,
                    startHostTime: mach_absolute_time()
                )

                do {
                    try await self.startConfiguredAudioCapture(
                        excluding: failedInputUIDs,
                        onInputSnapshotRead: { inputCount in
                            guard hasReadInputSnapshot == false else { return }
                            hasReadInputSnapshot = true
                            maximumStartAttempts = max(inputCount, 1) + 1
                        }
                    )
                } catch {
                    guard error is BoundedAudioHardwareQueue.Failure == false,
                          error is CancellationError == false
                    else { throw error }
                    if let failedUID = self.audioStartAttemptInputUID {
                        let retrySameInput = immediatelyRetriedInputUID == nil
                        if retrySameInput {
                            immediatelyRetriedInputUID = failedUID
                        }
                        if retrySameInput == false {
                            failedInputUIDs.insert(failedUID)
                        }
                    }
                    guard completedAttempts < maximumStartAttempts else { throw error }
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "active_route_recovery_start_retry"
                    )
                    continue
                }

                guard request.generation == self.audioRouteRecoveryGeneration,
                      Task.isCancelled == false
                else {
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "superseded_route_recovery_start"
                    )
                    return
                }
                let readiness = await self.audioCaptureReadinessGate.wait(
                    sessionID: self.benchmarkSessionID,
                    attemptID: readinessAttemptID,
                    timeoutNanoseconds: self.firstPCMTimeoutNanoseconds
                )
                guard request.generation == self.audioRouteRecoveryGeneration,
                      Task.isCancelled == false
                else {
                    self.audioCapturePipeline.setRecordingEnabled(false)
                    await self.stopActiveAudioCapture(
                        retainDirectPreparedCapture: false,
                        reason: "superseded_route_recovery_readiness"
                    )
                    return
                }
                if readiness == .ready {
                    AppServices.shared.microphonePreferenceCoordinator.confirmActiveSelection(
                        uid: self.audioStartAttemptInputUID,
                        name: self.audioStartAttemptInputName
                    )
                    self.benchmarkLog(
                        "route_recovery_first_pcm generation=\(request.generation) " +
                            "attempt=\(completedAttempts) attemptID=\(readinessAttemptID) " +
                            "bufferedSamples=\(self.audioBuffer.count)"
                    )

                    DebugLogger.shared.info(
                        "Audio route recovery succeeded (generation=\(request.generation), " +
                            "attempt=\(completedAttempts))",
                        source: "ASRService"
                    )
                    return
                }

                if let failedUID = self.audioStartAttemptInputUID {
                    let retrySameInput = readiness == .formatInvalidated &&
                        immediatelyRetriedInputUID == nil
                    if retrySameInput {
                        immediatelyRetriedInputUID = failedUID
                    }
                    if retrySameInput == false {
                        failedInputUIDs.insert(failedUID)
                    }
                }
                guard completedAttempts < maximumStartAttempts else {
                    throw NSError(
                        domain: "ASRService",
                        code: -3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "No replacement microphone delivered audio (\(readiness)).",
                        ]
                    )
                }
                self.audioCapturePipeline.setRecordingEnabled(false)
                await self.stopActiveAudioCapture(
                    retainDirectPreparedCapture: false,
                    reason: "active_route_recovery_readiness_retry"
                )
            }
            throw NSError(
                domain: "ASRService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No replacement microphone is available."]
            )
        } catch {
            await self.finishAudioRouteRecoveryFailure(request, error: error)
        }
    }

    private func finishAudioRouteRecoveryFailure(_ request: AudioRouteRecoveryRequest, error: Error) async {
        guard request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false, self.isTerminating == false else { return }
        DebugLogger.shared.error("Audio route recovery failed: \(error)", source: "ASRService")
        AppServices.shared.microphonePreferenceCoordinator.markActiveSelectionUnavailable()
        let failedSessionID = self.benchmarkSessionID
        var expectedStartGeneration = self.audioCaptureStartGeneration
        let wasCapturing = self.isRunning || self.isStarting
        if self.isRunning {
            // This task keeps recovery ownership until its defer runs. User Stop
            // may cancel and await it, but it must never await itself here.
            await self.stopWithoutTranscription(finishingRecovery: true)
        } else if self.isStarting {
            // Startup may itself be awaiting this recovery. Invalidate it without
            // awaiting its completion, so it can unwind after this task returns.
            self.interruptPendingAudioCaptureStart()
            expectedStartGeneration = self.audioCaptureStartGeneration
            await self.audioCaptureReadinessGate.cancel(
                sessionID: failedSessionID, attemptID: self.audioCaptureAttemptID
            )
        }
        guard wasCapturing, self.benchmarkSessionID == failedSessionID,
              self.audioCaptureStartGeneration == expectedStartGeneration,
              request.generation == self.audioRouteRecoveryGeneration,
              Task.isCancelled == false, self.isTerminating == false else { return }
        self.presentAudioCaptureFailure(
            title: "Recording Stopped",
            message: "The microphone could not recover after the audio device changed. \(error.localizedDescription)"
        )
    }

    private func handleDirectCaptureFormatInvalidation(
        _ invalidation: DirectCoreAudioLifecycleController.FormatInvalidation
    ) async {
        let captureSnapshot = self.directAudioLifecycleController.snapshot
        guard invalidation.generation == captureSnapshot.generation else {
            self.benchmarkLog(
                "direct_format_invalidation_ignored staleGeneration=\(invalidation.generation) " +
                    "currentGeneration=\(captureSnapshot.generation) property=\(invalidation.reason)"
            )
            return
        }
        let sessionID = self.benchmarkSessionID
        self.audioCapturePipeline.setRecordingEnabled(false)
        if self.isStarting, self.isRunning == false {
            await self.audioCaptureReadinessGate.signalFormatInvalidation(
                sessionID: sessionID,
                attemptID: self.audioCaptureAttemptID
            )
        }
        self.benchmarkLog(
            "direct_format_invalidation generation=\(invalidation.generation) " +
                "device=\(invalidation.deviceID) property=\(invalidation.reason) " +
                "wasRunning=\(invalidation.wasRunning) isStarting=\(self.isStarting)"
        )
        AppServices.shared.audioObserver.signalInputAvailabilityChanged()
        if invalidation.reason == "audio_service_restarted" {
            // Drops device-list queries that started before the reset.
            self.audioServiceResetGeneration &+= 1
            AppServices.shared.audioObserver.restartObservingAfterAudioServiceReset()
        }
        DebugLogger.shared.warning(
            "Direct capture generation \(invalidation.generation) invalidated by " +
                "\(invalidation.reason); scheduling serialized route recovery",
            source: "ASRService"
        )
        self.scheduleAudioRouteRecovery(
            reason: "direct format changed: \(invalidation.reason)",
            requiresIdlePrewarm: true,
            invalidatesCurrentStart: true
        )
    }

    private func handleDefaultOutputChanged() {
        // Input-only direct capture has no output device dependency.
        if self.directAudioLifecycleController.snapshot.isPrepared {
            return
        }

        self.scheduleAudioRouteRecovery(reason: "default output changed")
    }

    private var audioServiceResetGeneration: UInt64 = 0
    private var hasSubscribedToAudioHardwareChanges = false

    /// AudioHardwareObserver owns the Core Audio hardware listeners; ASRService only
    /// reacts to what it reports. ASRService watches no default-input change:
    /// microphone priority is app-owned, so a macOS default-input change never moves
    /// or restarts FluidVoice's selected microphone.
    private func subscribeToAudioHardwareChanges() {
        guard self.hasSubscribedToAudioHardwareChanges == false else { return }
        self.hasSubscribedToAudioHardwareChanges = true

        _ = self.directAudioLifecycleController
        let currentController = self.currentDirectAudioController
        let observer = AppServices.shared.audioObserver
        // Invalidate cached capture topology on the callback thread, before any
        // capture start that is already queued on the main thread can use it.
        observer.deviceListCallbackHook.set {
            currentController.value?.noteHardwareTopologyChanged()
        }
        observer.addChangeHandler { [weak self] change in
            guard let self, self.isTerminating == false else { return }
            switch change {
            case .deviceList:
                self.handleDeviceListChanged()
            case .defaultOutput:
                self.handleDefaultOutputChanged()
            }
        }
        observer.startObserving()
    }

    // MARK: - Device Monitoring (Bluetooth Auto-Switch & Disconnect Handling)

    private var deviceListQueryGeneration: UInt64 = 0

    /// Handles device list changes (new device connected or device removed)
    private func handleDeviceListChanged() {
        DebugLogger.shared.info("🔄 Device list changed - checking for new/removed devices", source: "ASRService")

        // Every request gets an identity before leaving MainActor. Results are last-request-wins:
        // an older HAL snapshot must not mutate dictation state after a newer topology event,
        // a Core Audio service restart, or termination.
        self.deviceListQueryGeneration &+= 1
        let queryGeneration = self.deviceListQueryGeneration
        let lifecycleGeneration = self.audioServiceResetGeneration
        Task { @MainActor [weak self] in
            let snapshot = await AudioTopologyListenerExecution.perform {
                (
                    AudioDevice.listInputDevicesRefreshingLiveness(diagnosticsOwner: .asrService),
                    AudioDevice.getDefaultInputDevice()?.uid
                )
            }

            guard let self,
                  ASRHardwareListenerPolicy.deviceListQueryCanApply(
                      isTerminating: self.isTerminating,
                      capturedLifecycle: lifecycleGeneration,
                      currentLifecycle: self.audioServiceResetGeneration,
                      capturedQueryGeneration: queryGeneration,
                      currentQueryGeneration: self.deviceListQueryGeneration
                  )
            else { return }

            let (currentDevices, defaultInputUID) = snapshot
            let cachedUIDs = self.cachedDeviceUIDs
            let cachedDeviceIDsByUID = self.cachedInputDeviceIDsByUID
            let cachedLivenessByUID = self.cachedInputLivenessByUID
            let currentUIDs = Set(currentDevices.map(\.uid))
            let currentDeviceIDsByUID = Dictionary(
                currentDevices.map { ($0.uid, $0.id) },
                uniquingKeysWith: { current, _ in current }
            )
            let currentLivenessByUID = Dictionary(
                currentDevices.map { ($0.uid, $0.isAlive) },
                uniquingKeysWith: { current, _ in current }
            )

            DebugLogger.shared.debug("Current input devices: \(currentDevices.map { $0.name }.joined(separator: ", "))", source: "ASRService")

            if currentUIDs != cachedUIDs ||
                currentDeviceIDsByUID != cachedDeviceIDsByUID ||
                currentLivenessByUID != cachedLivenessByUID
            {
                let microphonePreferenceCoordinator =
                    AppServices.shared.microphonePreferenceCoordinator
                let migrationPending = microphonePreferenceCoordinator.needsMicrophonePriorityMigration
                let resolvedInput = microphonePreferenceCoordinator.reconcileMicrophoneSelection(
                    availableInputs: currentDevices,
                    defaultInputUID: defaultInputUID
                )
                let priorityUIDs = SettingsStore.shared.microphonePriority.map(\.uid)
                let livenessRequiresRecovery =
                    (
                        self.isRunning &&
                            resolvedInput?.uid != microphonePreferenceCoordinator.confirmedActiveInputUID
                    ) ||
                    (
                        self.hasPreparedAudioCapture &&
                            resolvedInput?.id != self.directAudioLifecycleController.snapshot.deviceID
                    )
                let shouldReconcileInputSelection = AudioCaptureIdlePolicy.shouldReconcileInputSelection(
                    priorityInputUIDs: priorityUIDs,
                    migrationPending: migrationPending,
                    previousInputUIDs: cachedUIDs,
                    currentInputUIDs: currentUIDs
                ) || AudioCaptureIdlePolicy.didResolvedPriorityInputIdentityChange(
                    priorityInputUIDs: priorityUIDs,
                    previousInputDeviceIDsByUID: cachedDeviceIDsByUID,
                    currentInputDeviceIDsByUID: currentDeviceIDsByUID
                ) || livenessRequiresRecovery
                if shouldReconcileInputSelection {
                    self.scheduleAudioRouteRecovery(
                        reason: "app microphone availability changed",
                        requiresIdlePrewarm: true,
                        reconcilesInputSelection: true
                    )
                }
            }

            self.cacheCurrentDeviceList(currentDevices)
        }
    }

    /// Device caching for change detection
    private var cachedDeviceUIDs: Set<String> = []
    private var cachedInputDeviceIDsByUID: [String: AudioObjectID] = [:]
    private var cachedInputLivenessByUID: [String: Bool] = [:]

    private func cacheCurrentDeviceList(_ devices: [AudioDevice.Device]) {
        self.cachedDeviceUIDs = Set(devices.map { $0.uid })
        self.cachedInputDeviceIDsByUID = Dictionary(
            devices.map { ($0.uid, $0.id) },
            uniquingKeysWith: { current, _ in current }
        )
        self.cachedInputLivenessByUID = Dictionary(
            devices.map { ($0.uid, $0.isAlive) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    // Audio tap processing is handled by AudioCapturePipeline (thread-safe).

    func ensureAsrReady() async throws {
        try await self.ensureAsrReady(source: .automatic, progressHandler: nil)
    }

    func ensureAsrReady(progressHandler: ((Double) -> Void)?) async throws {
        try await self.ensureAsrReady(source: .automatic, progressHandler: progressHandler)
    }

    func ensureAsrReady(
        source: AnalyticsModelDownloadSource,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        guard self.activeExclusiveActivity != .settingsRestore else {
            throw ASRActivityError.activityInProgress(.settingsRestore)
        }
        let admission = try self.meetingModelResidency.beginOperation(
            owner: "speech", modelID: SettingsStore.shared.selectedSpeechModel.id
        )
        defer { self.meetingModelResidency.endOperation(admission) }
        try self.requireStreamingProviderAvailable()
        guard self.deletingModelID == nil, self.modelDownloadTask == nil else {
            throw NSError(
                domain: "ASRService",
                code: -2001,
                userInfo: [NSLocalizedDescriptionKey: "Another model download is already in progress."]
            )
        }
        if let drain = self.providerResetDrain {
            await drain.task.value
            if self.providerResetDrain?.id == drain.id {
                self.providerResetDrain = nil
            }
        }
        // Unclaimed behavior is unchanged; a claimed scope blocks re-seeding retired caches.
        if self.isMeetingASRPreparationClaimed {
            throw MeetingASRPreparationError.preparationInProgress
        }
        let provider = self.transcriptionProvider
        let model = SettingsStore.shared.selectedSpeechModel
        let providerKey = "\(model.id):\(type(of: provider)):\(provider.name)"
        DebugLogger.shared.info(
            "ensureAsrReady() requested for model=\(model.id) [supportsStreaming=\(model.supportsStreaming)] provider=\(providerKey)",
            source: "ASRService"
        )

        // Single-flight for the same model. A reset invalidates the provider key but retains
        // the retiring task so replacements can wait for cache cleanup before starting.
        while let existingTask = self.ensureReadyTask {
            let existingTaskID = self.ensureReadyTaskID
            if self.ensureReadyProviderKey == providerKey,
               self.ensureReadyOperationID == existingTaskID,
               !self.isCancellingModelPreparation
            {
                try await existingTask.value
                return
            }

            self.isCancellingModelPreparation = true
            existingTask.cancel()
            _ = await existingTask.result
            if self.ensureReadyTaskID == existingTaskID {
                self.ensureReadyTask = nil
                self.ensureReadyTaskID = nil
                self.ensureReadyProviderKey = nil
                self.isCancellingModelPreparation = false
            }
        }

        guard self.activeExclusiveActivity != .settingsRestore else {
            throw ASRActivityError.activityInProgress(.settingsRestore)
        }
        guard self.deletingModelID == nil, SettingsStore.shared.selectedSpeechModel == model else {
            throw CancellationError()
        }

        let operationID = UUID()
        let task = Task { @MainActor in
            try await self.performEnsureAsrReady(
                provider: provider,
                operationID: operationID,
                analyticsSource: source,
                externalProgressHandler: progressHandler
            )
        }
        self.ensureReadyTask = task
        self.ensureReadyTaskID = operationID
        self.ensureReadyProviderKey = providerKey
        self.ensureReadyOperationID = operationID
        self.isCancellingModelPreparation = false

        defer {
            if ensureReadyTaskID == operationID {
                ensureReadyTask = nil
                ensureReadyTaskID = nil
                ensureReadyProviderKey = nil
                if ensureReadyOperationID == operationID {
                    ensureReadyOperationID = nil
                }
                isCancellingModelPreparation = false
            }
        }

        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if self.isAsrReady, SettingsStore.shared.selectedSpeechModel == model {
            self.residentDictationModelID = model.id
        }
    }

    private func performEnsureAsrReady(
        provider: TranscriptionProvider,
        operationID: UUID,
        analyticsSource: AnalyticsModelDownloadSource,
        externalProgressHandler: ((Double) -> Void)? = nil
    ) async throws {
        guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
        self.isCancellingModelPreparation = false
        DebugLogger.shared.debug(
            "ensureAsrReady(begin): provider=\(provider.name), providerReady=\(provider.isReady), isAsrReady=\(self.isAsrReady), isRunning=\(self.isRunning)",
            source: "ASRService"
        )

        // Check if already ready
        if self.isAsrReady, provider.isReady {
            DebugLogger.shared.debug("ASR already ready with loaded models, skipping initialization", source: "ASRService")
            self.refreshWordBoostStatus()
            return
        }

        defer { SpeechModelInstallationSnapshot.shared.refresh() }

        // If the flag is set but provider isn't ready (e.g., provider switch without reset), re-init.
        if self.isAsrReady, !provider.isReady {
            DebugLogger.shared.debug("ASR marked ready but provider not ready; re-initializing", source: "ASRService")
        }

        self.isAsrReady = false
        let modelsAlreadyCached = try await SpeechModelReadiness.modelArtifactsExist(provider: provider)
        try Task.checkCancellation()
        guard self.ensureReadyOperationID == operationID else { throw CancellationError() }

        let totalStartTime = Date()
        do {
            let initializationStart = Date()
            DebugLogger.shared.info("=== ASR INITIALIZATION START ===", source: "ASRService")
            DebugLogger.shared.info("Using provider: \(provider.name) [providerReady=\(provider.isReady)]", source: "ASRService")

            DebugLogger.shared.info("Models already cached on disk: \(modelsAlreadyCached)", source: "ASRService")
            DebugLogger.shared.debug("Model cache lookup complete in \(String(format: "%.3f", Date().timeIntervalSince(totalStartTime)))s", source: "ASRService")

            // Suppress stderr noise during model loading (ALWAYS restore, even on failure).
            let originalStderr = dup(STDERR_FILENO)
            var didRedirectStderr = false
            if originalStderr != -1 {
                let devNull = open("/dev/null", O_WRONLY)
                if devNull != -1 {
                    dup2(devNull, STDERR_FILENO)
                    close(devNull)
                    didRedirectStderr = true
                }
            }

            defer {
                // Only restore if we actually redirected stderr.
                if didRedirectStderr, originalStderr != -1 {
                    dup2(originalStderr, STDERR_FILENO)
                }
                if originalStderr != -1 {
                    close(originalStderr)
                }
            }

            // Set correct loading state based on whether models are cached.
            try Task.checkCancellation()
            guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
            if modelsAlreadyCached {
                self.isLoadingModel = true
                self.isDownloadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = .loading
                DebugLogger.shared.info("📦 LOADING cached model into memory...", source: "ASRService")
            } else {
                self.isDownloadingModel = true
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = .preparingDownload
                DebugLogger.shared.info("⬇️ DOWNLOADING model...", source: "ASRService")
            }

            // Use the transcription provider to prepare models
            let downloadStartTime = Date()
            DebugLogger.shared.info("Calling transcriptionProvider.prepare()...", source: "ASRService")
            try await SpeechModelReadiness.prepareProviderWithRecovery(
                provider: provider,
                modelsAlreadyCached: modelsAlreadyCached,
                progressHandler: { [weak self] progress in
                    DispatchQueue.main.async {
                        guard
                            let self,
                            self.ensureReadyOperationID == operationID,
                            !self.isCancellingModelPreparation
                        else {
                            return
                        }
                        self.modelReadiness.applyModelPreparationProgress(
                            progress,
                            updatesActiveModelState: true,
                            externalProgressHandler: externalProgressHandler,
                            analyticsOperationID: operationID,
                            analyticsDescriptor: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor,
                            analyticsSource: analyticsSource
                        )
                    }
                }
            )
            try Task.checkCancellation()
            guard self.ensureReadyOperationID == operationID else { throw CancellationError() }
            let downloadDuration = Date().timeIntervalSince(downloadStartTime)
            DebugLogger.shared.info("✓ Provider preparation completed in \(String(format: "%.1f", downloadDuration)) seconds", source: "ASRService")

            self.isDownloadingModel = false
            // Keep isLoadingModel true until first transcription completes (for large models that need warm-up)
            if !self.hasCompletedFirstTranscription {
                self.isLoadingModel = true
                self.modelPreparationPhase = .loading
                DebugLogger.shared.info("⏳ Model loaded, waiting for first transcription to complete...", source: "ASRService")
            } else {
                self.isLoadingModel = false
                self.modelPreparationPhase = nil
            }
            self.downloadProgress = nil
            self.modelsExistOnDisk = true

            let totalDuration = Date().timeIntervalSince(initializationStart)
            DebugLogger.shared.info("=== ASR INITIALIZATION COMPLETE ===", source: "ASRService")
            DebugLogger.shared.info("Total initialization time: \(String(format: "%.1f", totalDuration)) seconds", source: "ASRService")

            self.isAsrReady = true
            if !SettingsStore.shared.onboardingCompleted,
               SettingsStore.shared.analyticsOnboardingOrigin == .firstRun
            {
                DebugLogger.shared.info("Voice model ready; requesting FI prefetch", source: "OnboardingAI")
                OnboardingAISetupController.live.prefetch()
            }
            self.isCancellingModelPreparation = false
            self.refreshWordBoostStatus()
            self.modelReadiness.finishModelDownloadAnalytics(operationID: operationID, outcome: .succeeded)
        } catch is CancellationError {
            self.modelReadiness.finishModelDownloadAnalytics(operationID: operationID, outcome: .cancelled)
            DebugLogger.shared.info("ASR initialization cancelled", source: "ASRService")
            if provider.shouldClearCacheAfterCancellation,
               provider.modelsExistOnDisk() == false
            {
                do {
                    try await provider.clearCache()
                } catch {
                    DebugLogger.shared.warning(
                        "Failed to clear incomplete model cache after cancellation: \(error)",
                        source: "ASRService"
                    )
                }
            }
            if self.ensureReadyOperationID == operationID {
                self.isDownloadingModel = false
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
                self.modelsExistOnDisk = provider.modelsExistOnDisk()
                self.isCancellingModelPreparation = false
            }
            throw CancellationError()
        } catch {
            if !ParakeetArchiveDownloader.isCleanupFailure(error), Task.isCancelled || SpeechModelReadiness.isModelPreparationCancellation(error) {
                self.modelReadiness.finishModelDownloadAnalytics(operationID: operationID, outcome: .cancelled)
                if provider.shouldClearCacheAfterCancellation,
                   provider.modelsExistOnDisk() == false
                {
                    try? await provider.clearCache()
                }
                if self.ensureReadyOperationID == operationID {
                    self.isDownloadingModel = false
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.modelPreparationPhase = nil
                    self.modelsExistOnDisk = provider.modelsExistOnDisk()
                    self.isCancellingModelPreparation = false
                }
                throw CancellationError()
            }
            self.modelReadiness.finishModelDownloadAnalytics(operationID: operationID, outcome: .failed)
            DebugLogger.shared.error("ASR initialization failed with error: \(error)", source: "ASRService")
            DebugLogger.shared.error("Error details: \(error.localizedDescription)", source: "ASRService")
            if self.ensureReadyOperationID == operationID {
                self.isDownloadingModel = false
                self.isLoadingModel = false
                self.downloadProgress = nil
                self.modelPreparationPhase = nil
            }
            throw error
        }
    }

    // MARK: - Cache management

    func clearModelCache() async throws {
        try await self.clearModelCache(for: SettingsStore.shared.selectedSpeechModel)
    }

    func clearModelCache(for requestedModel: SpeechModel) async throws {
        // The legacy Streaming320 name shares Streaming's files and active provider.
        let model = requestedModel == .nemotronStreaming320 ? .nemotronStreaming : requestedModel
        try self.requireStreamingProviderAvailable()
        guard self.deletingModelID == nil, !self.hasActiveModelDownload, !self.hasActiveModelPreparation,
              !self.isMeetingASRPreparationClaimed
        else {
            throw NSError(domain: "ASRService", code: -2001, userInfo: [
                NSLocalizedDescriptionKey: "Another model operation is already in progress. Try deleting again when it finishes.",
            ])
        }
        guard !model.usesAppleLogo, model != .qwen3Asr else {
            throw NSError(domain: "ASRService", code: -2003, userInfo: [
                NSLocalizedDescriptionKey: "This model cannot be deleted from FluidVoice.",
            ])
        }
        let activityLease = try self.acquireExclusiveActivity(.modelMaintenance)
        self.deletingModelID = model.id
        let isActive = SettingsStore.shared.selectedSpeechModel == model
        defer {
            self.deletingModelID = nil
            SpeechModelInstallationSnapshot.shared.refresh()
            self.releaseExclusiveActivity(activityLease)
        }
        DebugLogger.shared.debug("Clearing model cache for \(model.displayName)", source: "ASRService")
        let provider = isActive ? self.transcriptionProvider : self.cachedDeletionProvider(for: model)
        if isActive {
            self.streamingWorkState.invalidateProvider()
            self.isAsrReady = false
            self.providerResetPending = true
            await self.transcriptionExecutor.cancelAndAwaitPending()
        }
        try Task.checkCancellation()
        guard !isActive || SettingsStore.shared.selectedSpeechModel == model else { throw CancellationError() }
        try await provider.clearCache()
        if model.requiresExternalArtifacts {
            SettingsStore.shared.setExternalCoreMLArtifactsDirectory(nil, for: model)
        }
        if isActive { self.modelsExistOnDisk = false }
    }

    private func cachedDeletionProvider(for model: SpeechModel) -> TranscriptionProvider {
        // Nemotron keeps providers for both modes; retire the target's existing instance.
        if model == .nemotronOffline || model == .nemotronStreaming || model == .nemotronStreaming320,
           let cached = self.providerCache.cachedNemotronProvider(mode: model.nemotronProviderMode)
        {
            return cached
        }
        return self.getProvider(for: model)
    }

    // MARK: - Timer-based Streaming Transcription (No VAD)

    private func startStreamingTranscription() {
        self.streamingSchedulingSessionID = nil
        _ = self.streamingTaskLifecycle.cancelScheduler()
        guard self.isAsrReady else { return }
        self.streamingSchedulingSessionID = self.benchmarkSessionID

        DebugLogger.shared.debug(
            "Starting streaming transcription task (interval: \(self.streamingChunkDurationSeconds)s, minSamples: \(self.minimumStreamingPreviewSamples))",
            source: "ASRService"
        )
        self.scheduleNextStreamingChunk(sessionID: self.benchmarkSessionID, delayNanoseconds: 0)
    }

    private func scheduleNextStreamingChunk(sessionID: Int, delayNanoseconds: UInt64) {
        guard self.isRunning,
              self.benchmarkSessionID == sessionID,
              self.streamingSchedulingSessionID == sessionID
        else { return }
        self.streamingTaskLifecycle.schedule(
            sessionID: sessionID,
            delayNanoseconds: delayNanoseconds
        ) { [weak self] operationID in
            await self?.processStreamingChunk(sessionID: sessionID, operationID: operationID)
            self?.benchmarkLog(
                "streaming_active_exit session=\(sessionID) operation=\(operationID.uuidString)"
            )
        } completion: { [weak self] operationID in
            let isLateCompletion = self?.isRunning == false || self?.streamingSchedulingSessionID != sessionID
            if isLateCompletion {
                self?.benchmarkLog(
                    "streaming_active_cleanup_begin session=\(sessionID) operation=\(operationID.uuidString)"
                )
            }
            self?.streamingChunkDidFinish(sessionID: sessionID, operationID: operationID)
            if isLateCompletion {
                self?.benchmarkLog(
                    "streaming_active_cleanup_end session=\(sessionID) operation=\(operationID.uuidString)"
                )
            }
        }
    }

    private func streamingChunkDidFinish(sessionID: Int, operationID: UUID) {
        guard self.streamingWorkState.finishOperation(
            sessionID: sessionID,
            operationID: operationID
        ) else { return }
        self.isProcessingChunk = false
        self.finishStreamingDrainRecovery(sessionID: sessionID)
        guard self.isRunning,
              self.benchmarkSessionID == sessionID,
              self.streamingSchedulingSessionID == sessionID
        else { return }

        self.streamingHealthCheckCount += 1
        if self.streamingHealthCheckCount >= 3 {
            let currentBufferCount = self.audioBuffer.count
            if !self.isDictationMuted,
               currentBufferCount == self.streamingHealthLastBufferCount,
               currentBufferCount < 16_000
            {
                DebugLogger.shared.warning(
                    "Audio buffer not growing after three streaming intervals (count: \(currentBufferCount)). " +
                        "Audio capture may have failed. Check the Direct Core Audio capture logs.",
                    source: "ASRService"
                )
            }
            self.streamingHealthLastBufferCount = currentBufferCount
            self.streamingHealthCheckCount = 0
        }

        self.scheduleNextStreamingChunk(
            sessionID: sessionID,
            delayNanoseconds: UInt64(self.streamingChunkDurationSeconds * 1_000_000_000)
        )
    }

    private func processStreamingChunk(sessionID: Int, operationID: UUID) async {
        guard self.isRunning,
              self.benchmarkSessionID == sessionID,
              self.streamingSchedulingSessionID == sessionID,
              let providerGeneration = self.streamingWorkState.beginOperation(
                  sessionID: sessionID,
                  operationID: operationID
              )
        else { return }
        guard !self.isDictationMuted else { return }
        self.benchmarkStreamingChunkIndex += 1
        let chunkIndex = self.benchmarkStreamingChunkIndex
        let chunkAgeMs = self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)

        // Skip if already processing to prevent queue buildup
        guard !self.isProcessingChunk else {
            DebugLogger.shared.debug("⚠️ Skipping chunk - previous transcription still in progress", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=busy ageMs=\(chunkAgeMs)")
            self.skipNextChunk = true
            return
        }

        if self.skipNextChunk {
            DebugLogger.shared.debug("⚠️ Skipping chunk for ANE recovery", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=recovery ageMs=\(chunkAgeMs)")
            self.skipNextChunk = false
            return
        }

        guard self.isAsrReady, self.transcriptionProvider.isReady else {
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=not_ready ageMs=\(chunkAgeMs) isAsrReady=\(self.isAsrReady) providerReady=\(self.transcriptionProvider.isReady)")
            return
        }

        // Thread-safe count check
        let currentSampleCount = self.audioBuffer.count
        // Most ASR models require at least 1 second of 16kHz audio (16,000 samples) to transcribe
        let minSamples = self.minimumStreamingPreviewSamples
        guard currentSampleCount >= minSamples else {
            // Only log once per recording session to avoid spam
            if currentSampleCount > 0, self.lastProcessedSampleCount == 0 {
                DebugLogger.shared.debug(
                    "Waiting for more audio data (\(currentSampleCount)/\(minSamples) samples)",
                    source: "ASRService"
                )
                self.benchmarkLog("chunk_wait index=\(chunkIndex) ageMs=\(chunkAgeMs) samples=\(currentSampleCount) minSamples=\(minSamples)")
            }
            return
        }

        // Once FluidAudio has an incremental session, copy only newly captured PCM.
        // Other providers and the first incremental preview still receive the full prefix.
        #if arch(arm64)
        let incrementalProvider = self.transcriptionProvider as? FluidAudioProvider
        let incrementalDeltaStart = incrementalProvider?.incrementalPreviewDeltaStart(
            totalSampleCount: currentSampleCount
        )
        #else
        let incrementalDeltaStart: Int? = nil
        #endif
        let chunk: [Float]
        if let incrementalDeltaStart {
            chunk = self.audioBuffer.getRange(
                startingAt: incrementalDeltaStart,
                count: currentSampleCount - incrementalDeltaStart
            )
        } else {
            chunk = self.audioBuffer.getPrefix(currentSampleCount)
        }

        // Validate chunk is not empty (defensive check)
        guard !chunk.isEmpty else {
            DebugLogger.shared.warning("Audio buffer returned empty chunk despite count > 0. Skipping transcription.", source: "ASRService")
            self.benchmarkLog("chunk_skip index=\(chunkIndex) reason=empty ageMs=\(chunkAgeMs)")
            return
        }

        self.isProcessingChunk = true

        let startTime = Date()
        let startedAt = startTime.timeIntervalSince1970
        let newSamples = max(0, currentSampleCount - self.benchmarkLastChunkSampleCount)
        self.benchmarkLastChunkSampleCount = currentSampleCount
        let audioMilliseconds = Int((Double(currentSampleCount) / 16_000.0 * 1000).rounded())
        self.benchmarkLog(
            "chunk_start index=\(chunkIndex) ageMs=\(chunkAgeMs) samples=\(currentSampleCount) " +
                "inputSamples=\(chunk.count) newSamples=\(newSamples) audioMs=\(audioMilliseconds) " +
                "provider=\(self.transcriptionProvider.name)"
        )

        do {
            DebugLogger.shared.debug("Streaming chunk starting transcription (samples: \(currentSampleCount), input: \(chunk.count)) using \(self.transcriptionProvider.name)", source: "ASRService")
            let result: ASRTranscriptionResult
            #if arch(arm64)
            if incrementalDeltaStart != nil, let incrementalProvider {
                do {
                    result = try await self.transcriptionExecutor.run {
                        let result = try await incrementalProvider.transcribeStreamingDelta(
                            chunk,
                            totalSampleCount: currentSampleCount
                        )
                        logStreamingProviderOperationReturn(
                            sessionID: sessionID,
                            operationID: operationID,
                            route: "incremental_delta"
                        )
                        return result
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        throw CancellationError()
                    }
                    guard self.streamingWorkState.canPublishPreview(
                        sessionID: sessionID,
                        operationID: operationID,
                        providerGeneration: providerGeneration,
                        isRunning: self.isRunning,
                        schedulingSessionID: self.streamingSchedulingSessionID
                    ) else { return }
                    DebugLogger.shared.warning(
                        "Incremental delta preview failed; retrying with the full prefix",
                        source: "ASRService"
                    )
                    let fullPrefix = self.audioBuffer.getPrefix(currentSampleCount)
                    result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                        let result = try await provider.transcribeStreaming(fullPrefix)
                        logStreamingProviderOperationReturn(
                            sessionID: sessionID,
                            operationID: operationID,
                            route: "incremental_fallback_full"
                        )
                        return result
                    }
                }
            } else {
                result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                    let result = try await provider.transcribeStreaming(chunk)
                    logStreamingProviderOperationReturn(
                        sessionID: sessionID,
                        operationID: operationID,
                        route: "full_prefix"
                    )
                    return result
                }
            }
            #else
            result = try await self.transcriptionExecutor.run { [provider = self.transcriptionProvider] in
                let result = try await provider.transcribeStreaming(chunk)
                logStreamingProviderOperationReturn(
                    sessionID: sessionID,
                    operationID: operationID,
                    route: "full_prefix"
                )
                return result
            }
            #endif

            let canPublishPreview = self.streamingWorkState.canPublishPreview(
                sessionID: sessionID,
                operationID: operationID,
                providerGeneration: providerGeneration,
                isRunning: self.isRunning,
                schedulingSessionID: self.streamingSchedulingSessionID
            )
            if canPublishPreview == false {
                let scheduledSession = self.streamingSchedulingSessionID.map(String.init) ?? "none"
                self.benchmarkLog(
                    "streaming_executor_return publish=false index=\(chunkIndex) session=\(sessionID) " +
                        "operation=\(operationID.uuidString) running=\(self.isRunning) " +
                        "scheduledSession=\(scheduledSession)"
                )
                return
            }

            let duration = Date().timeIntervalSince(startTime)
            DebugLogger.shared.debug(
                "Streaming chunk transcription finished in \(String(format: "%.2f", duration))s",
                source: "ASRService"
            )
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let newText = DictationTextFormatter.clean(rawText, settings: .currentForClean)
            self.recordWordBoostHitIfAny(transcribedText: newText)
            self.benchmarkCompletedStreamingChunks += 1
            self.lastProcessedSampleCount = currentSampleCount

            // Mark first transcription as complete to clear loading state
            if !self.hasCompletedFirstTranscription {
                self.hasCompletedFirstTranscription = true
                self.isLoadingModel = false
                self.modelPreparationPhase = nil
                DebugLogger.shared.info("✅ Model warmed up - first streaming transcription completed", source: "ASRService")
            }

            if !newText.isEmpty {
                // Smart diff: only show truly new words
                let updatedText = self.smartDiffUpdate(previous: self.previousFullTranscription, current: newText)
                self.partialTranscription = updatedText
                self.previousFullTranscription = newText

                DebugLogger.shared.debug("✅ Streaming: '\(updatedText)' (\(String(format: "%.2f", duration))s)", source: "ASRService")
            }
            let rtf = duration / (Double(currentSampleCount) / 16_000.0)
            let chunkDoneAgeMs = self.elapsedMilliseconds(since: self.benchmarkRecordingStartedAt)
            self.benchmarkLog(
                "chunk_done index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) ageMs=\(chunkDoneAgeMs) " +
                    "samples=\(currentSampleCount) inputSamples=\(chunk.count) rawChars=\(rawText.count) cleanedChars=\(newText.count) rtf=\(String(format: "%.3f", rtf))"
            )

            // If transcription takes longer than the interval, skip next to prevent queue buildup
            // This allows slower machines to still work without overwhelming the system
            if duration > self.streamingChunkDurationSeconds {
                DebugLogger.shared.debug(
                    "⚠️ Transcription slow (\(String(format: "%.2f", duration))s > \(self.streamingChunkDurationSeconds)s), skipping next chunk",
                    source: "ASRService"
                )
                self.skipNextChunk = true
            }
        } catch where self.streamingWorkState.canPublishPreview(
            sessionID: sessionID,
            operationID: operationID,
            providerGeneration: providerGeneration,
            isRunning: self.isRunning,
            schedulingSessionID: self.streamingSchedulingSessionID
        ) {
            DebugLogger.shared.error("❌ Streaming failed: \(error)", source: "ASRService")
            self
                .benchmarkLog(
                    "chunk_fail index=\(chunkIndex) elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) samples=\(currentSampleCount) inputSamples=\(chunk.count) error=\(error.localizedDescription)"
                )
            self.skipNextChunk = true
        } catch {
            self.benchmarkLog(
                "chunk_stale_failure index=\(chunkIndex) session=\(sessionID) operation=\(operationID.uuidString)"
            )
        }
    }

    /// Smart diff to prevent text from jumping around
    private func smartDiffUpdate(previous: String, current: String) -> String {
        guard !previous.isEmpty else { return current }
        guard !current.isEmpty else { return previous }

        let prevWords = previous.split(separator: " ").map(String.init)
        let currWords = current.split(separator: " ").map(String.init)

        // Find longest common prefix
        var commonPrefixLength = 0
        for i in 0..<min(prevWords.count, currWords.count) {
            if prevWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters) ==
                currWords[i].lowercased().trimmingCharacters(in: .punctuationCharacters)
            {
                commonPrefixLength = i + 1
            } else {
                break
            }
        }

        // If >50% overlap, keep stable prefix and add new words
        if commonPrefixLength > prevWords.count / 2 {
            let stableWords = Array(currWords[0..<min(commonPrefixLength, currWords.count)])
            let newWords = currWords.count > commonPrefixLength ? Array(currWords[commonPrefixLength...]) : []
            return (stableWords + newWords).joined(separator: " ")
        } else {
            return current // Significant change
        }
    }

    private let typingService = TypingService() // Reuse instance to avoid conflicts

    @MainActor
    func typeTextToActiveField(_ text: String) async -> TextDeliveryResult {
        await self.typeTextToActiveField(text, preferredTargetPID: nil, textReadyAt: nil)
    }

    @MainActor
    func typeTextToActiveField(
        _ text: String,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval? = nil,
        preserveTranscriptOnClipboard: Bool = false,
        isOutputValid: @escaping @MainActor () -> Bool = { true }
    ) async -> TextDeliveryResult {
        await self.typeOutputPlanToActiveField(
            .plain(text),
            preferredTargetPID: preferredTargetPID,
            textReadyAt: textReadyAt,
            preserveTranscriptOnClipboard: preserveTranscriptOnClipboard,
            isOutputValid: isOutputValid
        )
    }

    @MainActor
    func typeOutputPlanToActiveField(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval? = nil,
        toggleStopRequestedAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false,
        preserveTranscriptOnClipboard: Bool = false,
        isOutputValid: @escaping @MainActor () -> Bool = { true }
    ) async -> TextDeliveryResult {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let textReadyAge = textReadyAt.map { Int(((requestedAt - $0) * 1000).rounded()) }
        let text = plan.plainText
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")",
            source: "TypingBenchmark"
        )
        let result = await self.typingService.typeOutputPlanInstantly(
            plan,
            preferredTargetPID: preferredTargetPID,
            textReadyAt: textReadyAt,
            toggleStopRequestedAt: toggleStopRequestedAt,
            tracksDictionaryCorrections: tracksDictionaryCorrections,
            preserveTranscriptOnClipboard: preserveTranscriptOnClipboard,
            isOutputValid: isOutputValid
        )
        let dispatchedAt = ProcessInfo.processInfo.systemUptime
        let textReadyToDispatchMs = textReadyAt.map {
            String(Int(((dispatchedAt - $0) * 1000).rounded()))
        } ?? "nil"
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_dispatched chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") result=\(String(describing: result)) textReadyToDispatchMs=\(textReadyToDispatchMs)",
            source: "TypingBenchmark"
        )
        if case .commandPosted = result {
            let scheduledAt = ProcessInfo.processInfo.systemUptime
            let pipelineID = DebugLogger.pipelineID
            // One queued timestamp per output. No polling, AX queries or delivery waits.
            DispatchQueue.main.async {
                DebugLogger.$pipelineID.withValue(pipelineID) {
                    DebugLogger.shared.benchmark(
                        "APP_BENCH",
                        message: "dispatch_main_queue_probe scheduledAt=\(scheduledAt)",
                        source: "AppBenchmark"
                    )
                }
            }
        }
        return result
    }

    func typeOutputPlanToActiveFieldAndWait(
        _ plan: DictationLiteralOutputPlan,
        preferredTargetPID: pid_t?,
        textReadyAt: TimeInterval? = nil,
        toggleStopRequestedAt: TimeInterval? = nil,
        tracksDictionaryCorrections: Bool = false,
        postInsertionKey: SettingsStore.SpokenSendKey? = nil,
        requiredFocusTarget: TypingService.CapturedFocusTarget? = nil,
        preserveTranscriptOnClipboard: Bool = false,
        isOutputValid: @escaping @MainActor () -> Bool = { true }
    ) async -> TypingService.DeliveryOutcome {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let textReadyAge = textReadyAt.map { Int(((requestedAt - $0) * 1000).rounded()) }
        let text = plan.plainText
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyAgeMs=\(textReadyAge.map { String($0) } ?? "nil")",
            source: "TypingBenchmark"
        )
        let outcome = await withCheckedContinuation { continuation in
            self.typingService.typeOutputPlanInstantly(
                plan,
                preferredTargetPID: preferredTargetPID,
                textReadyAt: textReadyAt,
                toggleStopRequestedAt: toggleStopRequestedAt,
                tracksDictionaryCorrections: tracksDictionaryCorrections,
                postInsertionKey: postInsertionKey,
                requiredFocusTarget: requiredFocusTarget,
                preserveTranscriptOnClipboard: preserveTranscriptOnClipboard,
                isOutputValid: isOutputValid
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
        let dispatchedAt = ProcessInfo.processInfo.systemUptime
        let textReadyToDispatchMs = textReadyAt.map {
            String(Int(((dispatchedAt - $0) * 1000).rounded()))
        } ?? "nil"
        DebugLogger.shared.benchmark(
            "TYPING_BENCH",
            message: "asr_type_dispatched chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil") textReadyToDispatchMs=\(textReadyToDispatchMs)",
            source: "TypingBenchmark"
        )
        return outcome
    }

    // The formatting steps live in DictationTextFormatter. These names stay until the call sites
    // move to its clean and finalize passes (AA-224).

    static func removeFillerWords(_ text: String) -> String {
        let store = SettingsStore.shared
        guard store.removeFillerWordsEnabled else { return text }
        return DictationTextFormatter.removeFillerWords(
            text,
            settings: .init(removesFillerWords: true, fillerWords: store.fillerWords)
        )
    }

    static func invalidateDictionaryCache() {
        DictationTextFormatter.invalidateDictionaryCache()
    }

    static func applyCustomDictionary(_ text: String) -> String {
        DictationTextFormatter.applyCustomDictionary(
            text,
            settings: .init(customDictionaryEntries: SettingsStore.shared.customDictionaryEntries)
        )
    }

    static func applyGAAVFormatting(_ text: String) -> String {
        let store = SettingsStore.shared
        return DictationTextFormatter.applyGAAVFormatting(
            text,
            settings: .init(
                gaavRemovesTrailingPeriod: store.gaavRemoveTrailingPeriodEnabled,
                gaavLowercasesFirstLetter: store.gaavLowercaseFirstLetterEnabled
            )
        )
    }

    static func applyContinuousDictationFormatting(_ text: String, precedingText: String) -> String {
        let store = SettingsStore.shared
        return DictationTextFormatter.applyContinuousDictationFormatting(
            text,
            precedingText: precedingText,
            settings: .init(
                addsContinuousDictationSpacing: store.continuousDictationSpacingEnabled,
                capitalizesFromContext: store.contextAwareCapitalizationEnabled
            )
        )
    }
}

// swiftlint:enable type_body_length

private extension ASRService {
    /// Cancels only the idle delay. Active provider work is intentionally not
    /// cancelled because incremental providers use cancellation to discard state
    /// needed by the final pass.
    func stopStreamingScheduler(sessionID: Int) {
        let startedAt = Date().timeIntervalSince1970
        if self.streamingSchedulingSessionID == sessionID {
            self.streamingSchedulingSessionID = nil
        }
        let cancelled = self.streamingTaskLifecycle.cancelScheduler()
        self.benchmarkLog(
            "streaming_scheduler_cancel session=\(sessionID) hadIdleTask=\(cancelled) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: startedAt))"
        )
    }

    /// Drains only real in-flight provider work before the shared PCM buffer is
    /// handed off. An idle scheduler never participates in this await.
    func drainActiveStreamingWork(sessionID: Int) async -> Bool {
        let startedAt = Date().timeIntervalSince1970
        guard self.streamingTaskLifecycle.activeTaskToDrain(sessionID: sessionID) != nil else {
            self.benchmarkLog(
                "streaming_timer_stop begin phase=idle session=\(sessionID)"
            )
            self.benchmarkLog(
                "streaming_timer_stop end phase=idle session=\(sessionID) elapsedMs=0 " +
                    "completedChunks=\(self.benchmarkCompletedStreamingChunks)"
            )
            return true
        }
        self.benchmarkLog(
            "streaming_timer_stop begin phase=active session=\(sessionID)"
        )
        // Keep the idle fast path synchronous; only real work gets a deadline.
        let completed = await self.streamingTaskLifecycle.drain(
            sessionID: sessionID,
            timeoutNanoseconds: Self.streamingDrainTimeoutNanoseconds
        )
        self.benchmarkLog(
            "streaming_active_drain_resume session=\(sessionID)"
        )
        self.benchmarkLog(
            "streaming_timer_stop end phase=active session=\(sessionID) completed=\(completed) " +
                "elapsedMs=\(self.elapsedMilliseconds(since: startedAt)) " +
                "completedChunks=\(self.benchmarkCompletedStreamingChunks)"
        )
        return completed
    }

    static var streamingRecoveryMessage: String {
        "Speech recognition took too long to finish. This recording could not be transcribed. " +
            "Wait for the model to recover, or restart FluidVoice before recording again."
    }

    func presentStreamingRecoveryError() {
        self.errorTitle = "Speech recognition needs recovery"
        self.errorMessage = Self.streamingRecoveryMessage
        self.showError = true
    }

    func requireStreamingProviderAvailable() throws {
        guard self.recordingBufferHandoffGate.isRecovering else { return }
        throw NSError(domain: "ASRService", code: -2002, userInfo: [
            NSLocalizedDescriptionKey: Self.streamingRecoveryMessage,
        ])
    }

    func beginStreamingDrainRecovery(sessionID: Int, token: RecordingBufferHandoffGate.Token) {
        self.timedOutStreamingHandoff = (sessionID, token)
        self.recordingBufferHandoffGate.markTimedOut(token)
        self.presentStreamingRecoveryError()
        // Completion may have won the main-actor turn after the deadline fired.
        if self.streamingTaskLifecycle.activeTaskToDrain(sessionID: sessionID) == nil {
            self.finishStreamingDrainRecovery(sessionID: sessionID)
        }
    }

    func finishStreamingDrainRecovery(sessionID: Int) {
        guard let recovery = self.timedOutStreamingHandoff, recovery.sessionID == sessionID else { return }
        self.timedOutStreamingHandoff = nil
        // The provider has actually returned. Only now may its PCM and state be retired.
        if self.benchmarkSessionID == sessionID {
            self.audioBuffer.clear()
            self.streamingWorkState.endSession(sessionID)
            self.partialTranscription = ""
            self.previousFullTranscription = ""
            self.isProcessingChunk = false
            self.skipNextChunk = false
        }
        self.recordingBufferHandoffGate.complete(recovery.token)
        if self.resetProviderAfterStreamingRecovery {
            self.resetProviderAfterStreamingRecovery = false
            self.resetTranscriptionProvider()
        }
        if self.errorMessage == Self.streamingRecoveryMessage {
            self.errorMessage = "The speech model has recovered. Please record your dictation again."
        }
        self.benchmarkLog("streaming_drain_recovered session=\(sessionID)")
    }
}

// MARK: - Audio capture pipeline

//
// Audio callbacks are not main-actor isolated. Direct Core Audio arrives through
// a lock-free C ring. This pipeline owns timestamp trimming, 16 kHz
// conversion, levels, and session-safe delivery without touching ASRService from
// a realtime callback.

final nonisolated class AudioCapturePipeline: @unchecked Sendable {
    private let audioBuffer: ThreadSafeAudioBuffer
    private let onFirstAudio: (Int, UInt64, Int, Int, Double, Int, Int) -> Void
    private let onLevel: (CGFloat) -> Void
    private let onCaptureHealth: (Int, UInt64, Int, Int, Float, Float) -> Void

    private let lock = NSLock()
    private var recordingEnabled: Bool = false
    private var muteTimeline = DictationMuteTimeline()
    private var needsMuteSeparation = false
    private var levelMonitoringEnabled: Bool = false
    private var firstAudioReported: Bool = false
    private var recordingSessionID: Int = 0
    private var recordingAttemptID: UInt64 = 0
    private var recordingStartHostTime: UInt64 = 0
    private var recordingStopHostTime: UInt64?
    private var resampleSourceRate: Double = 0
    private var resampleSourceFrameCursor: Int64 = 0
    private var resampleNextSourcePosition: Double = 0
    private var resamplePreviousSample: Float?
    private var lastInputSampleEnd: Int64?
    private var captureHealthSampleCount: Int = 0
    private var captureHealthTotalSampleCount: Int = 0
    private var captureHealthSquareSum: Double = 0
    private var captureHealthPeak: Float = 0

    // Smoothing state (kept off ASRService/@MainActor)
    private var levelHistory: [CGFloat] = []
    private var smoothedLevel: CGFloat = 0.0
    private let historySize: Int = 2
    private let silenceThreshold: CGFloat = 0.04

    private static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0 else { return 1_000_000_000 }
        return 1_000_000_000.0 * Double(info.denom) / Double(info.numer)
    }()

    init(
        audioBuffer: ThreadSafeAudioBuffer,
        onFirstAudio: @escaping (Int, UInt64, Int, Int, Double, Int, Int) -> Void,
        onLevel: @escaping (CGFloat) -> Void,
        onCaptureHealth: @escaping (Int, UInt64, Int, Int, Float, Float) -> Void
    ) {
        self.audioBuffer = audioBuffer
        self.onFirstAudio = onFirstAudio
        self.onLevel = onLevel
        self.onCaptureHealth = onCaptureHealth
    }

    func setRecordingEnabled(
        _ enabled: Bool,
        sessionID: Int = 0,
        attemptID: UInt64 = 0,
        startHostTime: UInt64 = 0
    ) {
        self.lock.lock()
        if enabled {
            self.firstAudioReported = false
            self.recordingSessionID = sessionID
            self.recordingAttemptID = attemptID
            self.recordingStartHostTime = startHostTime == 0 ? mach_absolute_time() : startHostTime
            self.recordingStopHostTime = nil
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.resetCaptureHealthLocked()
            self.recordingEnabled = true
        }
        if enabled == false {
            self.recordingEnabled = false
            self.recordingSessionID = 0
            self.recordingAttemptID = 0
            self.recordingStartHostTime = 0
            self.recordingStopHostTime = nil
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
            self.resetCaptureHealthLocked()
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0.0
        }
        self.lock.unlock()
    }

    func setDictationMuted(_ muted: Bool, at hostTime: UInt64) {
        self.lock.withLock { self.muteTimeline.setMuted(muted, at: hostTime) }
    }

    /// Reset only between logical recordings, not during an audio-route retry.
    func resetDictationMute() {
        self.lock.withLock {
            self.muteTimeline = DictationMuteTimeline()
            self.needsMuteSeparation = false
        }
    }

    var isLevelMonitoringEnabled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.levelMonitoringEnabled
    }

    #if DEBUG
    var isRecordingEnabledForTesting: Bool { self.lock.withLock { self.recordingEnabled } }
    #endif

    func setLevelMonitoringEnabled(_ enabled: Bool) {
        self.lock.lock()
        self.levelMonitoringEnabled = enabled
        if enabled == false, self.recordingEnabled == false {
            self.levelHistory.removeAll(keepingCapacity: true)
            self.smoothedLevel = 0
        }
        self.lock.unlock()
        if enabled == false {
            self.onLevel(0)
        }
    }

    /// Sets the exact last acquisition time accepted for the current session.
    /// Capture remains enabled until the backend has stopped and drained.
    func markRecordingEnd(atHostTime hostTime: UInt64) {
        self.lock.lock()
        if self.recordingEnabled {
            self.recordingStopHostTime = hostTime
        }
        self.lock.unlock()
    }

    func finishRecording() {
        self.setRecordingEnabled(false)
        self.onLevel(0.0)
    }

    func handle(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64
    ) {
        guard frameCount > 0 else { return }
        self.handleMonoSamples(
            Array(UnsafeBufferPointer(start: samples, count: frameCount)),
            sampleRate: sampleRate,
            inputHostTime: inputHostTime,
            inputSampleTime: inputSampleTime,
            originalFrameCount: frameCount
        )
    }

    private func handleMonoSamples(
        _ samples: [Float],
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64,
        originalFrameCount: Int
    ) {
        guard samples.isEmpty == false, sampleRate > 0 else {
            self.onLevel(0.0)
            return
        }

        self.lock.lock()
        let recordingEnabled = self.recordingEnabled
        let levelMonitoringEnabled = self.levelMonitoringEnabled
        guard recordingEnabled || levelMonitoringEnabled else {
            self.lock.unlock()
            return
        }
        if recordingEnabled == false {
            self.lock.unlock()
            AudioSpectrumMeter.shared.ingest(samples)
            self.onLevel(self.measureAudioLevel(samples).level)
            return
        }
        let startHostTime = self.recordingStartHostTime
        let stopHostTime = self.recordingStopHostTime
        let recordingSessionID = self.recordingSessionID
        let recordingAttemptID = self.recordingAttemptID
        self.lock.unlock()

        guard let acceptedRange = Self.acceptedFrameRange(
            frameCount: samples.count,
            sampleRate: sampleRate,
            packetHostTime: inputHostTime,
            startHostTime: startHostTime,
            stopHostTime: stopHostTime
        ) else {
            return
        }

        self.lock.lock()
        guard self.recordingEnabled,
              self.recordingSessionID == recordingSessionID,
              self.recordingAttemptID == recordingAttemptID
        else {
            self.lock.unlock()
            return
        }
        let mono16k = self.resampleAudibleRangesLocked(
            samples,
            acceptedRange: acceptedRange,
            sampleRate: sampleRate,
            inputHostTime: inputHostTime,
            inputSampleTime: inputSampleTime
        )
        guard !mono16k.isEmpty || self.muteTimeline.hasExclusions else {
            self.lock.unlock()
            return
        }
        let shouldReportFirstAudio = self.firstAudioReported == false
        if shouldReportFirstAudio {
            self.firstAudioReported = true
        }

        // Keep append and first-audio attribution inside the capture lock.
        // Disabling an attempt therefore returns only after every accepted
        // callback has committed its PCM and queued its attempt-scoped signal.
        self.audioBuffer.append(mono16k)
        if shouldReportFirstAudio {
            let acceptedHostTime = Self.hostTime(
                inputHostTime,
                advancedByFrames: acceptedRange.lowerBound,
                sampleRate: sampleRate
            )
            let acquisitionMs = Self.elapsedMilliseconds(
                from: startHostTime,
                to: acceptedHostTime
            )
            let deliveryMs = Self.elapsedMilliseconds(
                from: startHostTime,
                to: mach_absolute_time()
            )
            self.onFirstAudio(
                recordingSessionID,
                recordingAttemptID,
                Int(mono16k.count),
                originalFrameCount,
                sampleRate,
                acquisitionMs,
                deliveryMs
            )
        }
        self.lock.unlock()
        guard !mono16k.isEmpty else {
            self.onLevel(0)
            return
        }
        let measurement = self.measureAudioLevel(mono16k)
        AudioSpectrumMeter.shared.ingest(mono16k)
        self.onLevel(measurement.level)
        if let health = self.captureHealthDiagnostic(
            sampleCount: mono16k.count,
            rms: measurement.rms,
            peak: measurement.peak,
            sessionID: recordingSessionID,
            attemptID: recordingAttemptID
        ) {
            self.onCaptureHealth(
                recordingSessionID,
                recordingAttemptID,
                health.audioMs,
                health.sampleCount,
                health.rms,
                health.peak
            )
        }
    }

    private static func acceptedFrameRange(
        frameCount: Int,
        sampleRate: Double,
        packetHostTime: UInt64,
        startHostTime: UInt64,
        stopHostTime: UInt64?
    ) -> Range<Int>? {
        guard frameCount > 0 else { return nil }
        // A callback without host time cannot be trimmed, so accept all of it.
        guard packetHostTime > 0, startHostTime > 0 else { return 0..<frameCount }

        var lowerBound = 0
        if packetHostTime < startHostTime {
            let framesBeforeStart = Int(ceil(
                Double(startHostTime - packetHostTime) /
                    Self.hostTicksPerSecond * sampleRate
            ))
            lowerBound = min(max(framesBeforeStart, 0), frameCount)
        }

        var upperBound = frameCount
        if let stopHostTime {
            if stopHostTime <= packetHostTime {
                return nil
            }
            let framesBeforeStop = Int(floor(
                Double(stopHostTime - packetHostTime) /
                    Self.hostTicksPerSecond * sampleRate
            ))
            upperBound = min(max(framesBeforeStop, 0), frameCount)
        }

        guard lowerBound < upperBound else { return nil }
        return lowerBound..<upperBound
    }

    private static func hostTime(
        _ hostTime: UInt64,
        advancedByFrames frames: Int,
        sampleRate: Double
    ) -> UInt64 {
        guard hostTime > 0, frames > 0, sampleRate > 0 else { return hostTime }
        let ticks = Double(frames) / sampleRate * Self.hostTicksPerSecond
        return hostTime &+ UInt64(max(ticks.rounded(), 0))
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Int {
        guard start > 0, end >= start else { return 0 }
        return Int((Double(end - start) / self.hostTicksPerSecond * 1000).rounded())
    }

    private func resetResamplerLocked() {
        self.resampleSourceRate = 0
        self.resampleSourceFrameCursor = 0
        self.resampleNextSourcePosition = 0
        self.resamplePreviousSample = nil
    }

    /// Remove muted samples before resampling, streaming, or history storage. Reset
    /// interpolation at every excluded range so a muted sample cannot cross a seam.
    private func resampleAudibleRangesLocked(
        _ samples: [Float],
        acceptedRange: Range<Int>,
        sampleRate: Double,
        inputHostTime: UInt64,
        inputSampleTime: Int64
    ) -> [Float] {
        if !self.muteTimeline.hasExclusions {
            return self.resampleCapturedRangeLocked(samples, range: acceptedRange, sampleRate: sampleRate, inputSampleTime: inputSampleTime)
        }
        let ranges = self.muteTimeline.audibleRanges(
            in: acceptedRange,
            packetHostTime: inputHostTime,
            sampleRate: sampleRate,
            hostTicksPerSecond: Self.hostTicksPerSecond
        )
        var output: [Float] = []
        var cursor = acceptedRange.lowerBound
        for range in ranges {
            if range.lowerBound > cursor {
                self.needsMuteSeparation = true
            }
            if self.needsMuteSeparation { self.resetResamplerLocked() }
            if self.needsMuteSeparation {
                // Keep a short word boundary, without accumulating minutes of silence.
                if !self.audioBuffer.isEmpty || !output.isEmpty {
                    output.append(contentsOf: repeatElement(0, count: 1600))
                }
                self.needsMuteSeparation = false
            }
            output.append(contentsOf: self.resampleCapturedRangeLocked(samples, range: range, sampleRate: sampleRate, inputSampleTime: inputSampleTime))
            cursor = range.upperBound
        }
        if cursor < acceptedRange.upperBound {
            self.needsMuteSeparation = true
            self.resetResamplerLocked()
            self.lastInputSampleEnd = nil
        }
        return output
    }

    private func resampleCapturedRangeLocked(_ samples: [Float], range: Range<Int>, sampleRate: Double, inputSampleTime: Int64) -> [Float] {
        if inputSampleTime >= 0 {
            let sampleStart = inputSampleTime + Int64(range.lowerBound)
            if let lastInputSampleEnd = self.lastInputSampleEnd, lastInputSampleEnd != sampleStart {
                self.resetResamplerLocked()
            }
            self.lastInputSampleEnd = inputSampleTime + Int64(range.upperBound)
        }
        let acceptedSamples = range == samples.indices ? samples : Array(samples[range])
        return self.resampleTo16kLocked(acceptedSamples, sourceSampleRate: sampleRate)
    }

    private func resetCaptureHealthLocked() {
        self.captureHealthSampleCount = 0
        self.captureHealthTotalSampleCount = 0
        self.captureHealthSquareSum = 0
        self.captureHealthPeak = 0
    }

    /// Stateful linear resampling keeps fractional phase across small hardware
    /// callbacks. Stateless per-packet conversion silently shortens 44.1 kHz
    /// recordings and introduces a discontinuity at every device cycle.
    private func resampleTo16kLocked(
        _ samples: [Float],
        sourceSampleRate: Double
    ) -> [Float] {
        guard samples.isEmpty == false else { return [] }
        if abs(self.resampleSourceRate - sourceSampleRate) > 0.5 {
            self.resetResamplerLocked()
            self.resampleSourceRate = sourceSampleRate
        }
        if sourceSampleRate == 16_000.0 {
            return samples
        }

        let chunkStart = Double(self.resampleSourceFrameCursor)
        let chunkEnd = chunkStart + Double(samples.count)
        let step = sourceSampleRate / 16_000.0
        var output: [Float] = []
        output.reserveCapacity(Int(ceil(Double(samples.count) / step)) + 1)

        while self.resampleNextSourcePosition < chunkEnd {
            let lowerFrame = Int64(floor(self.resampleNextSourcePosition))
            let fraction = Float(self.resampleNextSourcePosition - Double(lowerFrame))
            let localLower = lowerFrame - self.resampleSourceFrameCursor

            let lowerSample: Float
            let upperSample: Float
            if localLower < 0 {
                guard localLower == -1,
                      let previousSample = self.resamplePreviousSample
                else { break }
                lowerSample = previousSample
                upperSample = samples[0]
            } else {
                let index = Int(localLower)
                guard index < samples.count else { break }
                lowerSample = samples[index]
                if fraction == 0 {
                    upperSample = lowerSample
                } else {
                    guard index + 1 < samples.count else { break }
                    upperSample = samples[index + 1]
                }
            }

            output.append(lowerSample + (upperSample - lowerSample) * fraction)
            self.resampleNextSourcePosition += step
        }

        self.resampleSourceFrameCursor += Int64(samples.count)
        self.resamplePreviousSample = samples.last
        return output
    }

    private func measureAudioLevel(_ samples: [Float]) -> (level: CGFloat, rms: Float, peak: Float) {
        guard samples.isEmpty == false else { return (0, 0, 0) }

        var sum: Float = 0.0
        vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
        let rms = sqrt(sum / Float(samples.count))
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))

        // Noise gate
        if rms < 0.002 {
            return (self.applySmoothingAndThreshold(0), rms, peak)
        }

        // dB -> normalized [0, 1]
        let dbLevel = 20 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0, min(1, (dbLevel + 55) / 55))
        return (self.applySmoothingAndThreshold(CGFloat(normalizedLevel)), rms, peak)
    }

    private func captureHealthDiagnostic(
        sampleCount: Int,
        rms: Float,
        peak: Float,
        sessionID: Int,
        attemptID: UInt64
    ) -> (audioMs: Int, sampleCount: Int, rms: Float, peak: Float)? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.recordingEnabled,
              self.recordingSessionID == sessionID,
              self.recordingAttemptID == attemptID
        else { return nil }

        self.captureHealthSampleCount += sampleCount
        self.captureHealthTotalSampleCount += sampleCount
        self.captureHealthSquareSum += Double(rms * rms) * Double(sampleCount)
        self.captureHealthPeak = max(self.captureHealthPeak, peak)
        guard self.captureHealthSampleCount >= 16_000 else { return nil }

        let windowSampleCount = self.captureHealthSampleCount
        let windowRMS = Float(sqrt(self.captureHealthSquareSum / Double(windowSampleCount)))
        let result = (
            audioMs: Int((Double(self.captureHealthTotalSampleCount) / 16_000 * 1000).rounded()),
            sampleCount: windowSampleCount,
            rms: windowRMS,
            peak: self.captureHealthPeak
        )
        self.captureHealthSampleCount = 0
        self.captureHealthSquareSum = 0
        self.captureHealthPeak = 0
        return result
    }

    private func applySmoothingAndThreshold(_ newLevel: CGFloat) -> CGFloat {
        self.lock.lock()
        defer { self.lock.unlock() }

        self.levelHistory.append(newLevel)
        if self.levelHistory.count > self.historySize {
            self.levelHistory.removeFirst()
        }

        let average = self.levelHistory.reduce(0, +) / CGFloat(self.levelHistory.count)
        let smoothingFactor: CGFloat = 0.7
        self.smoothedLevel = (smoothingFactor * newLevel) + ((1 - smoothingFactor) * average)

        if self.smoothedLevel < self.silenceThreshold {
            return 0.0
        }

        return self.smoothedLevel
    }
}
