//
//  SpeechModelReadiness.swift
//  fluid
//
//  What the UI shows about the selected speech model (ready, downloading, loading,
//  deleting) and the preparation steps that need no audio capture. ASRService runs
//  the operations and their admission checks.
//

import Combine
import Foundation

final class SpeechModelReadiness: ObservableObject {
    @Published var isAsrReady: Bool = false
    @Published var isDownloadingModel: Bool = false
    @Published var isLoadingModel: Bool = false
    @Published var isCancellingModelPreparation: Bool = false
    @Published var modelsExistOnDisk: Bool = false
    @Published var downloadProgress: Double?
    @Published var modelPreparationPhase: ModelPreparationPhase?
    @Published var downloadingModelId: String?
    @Published var isCancellingModelDownload: Bool = false
    @Published var deletingModelID: String?

    private var modelDownloadAnalyticsStates: [UUID: ModelDownloadAnalyticsState] = [:]

    static func modelArtifactsExist(provider: TranscriptionProvider) async throws -> Bool {
        #if arch(arm64)
        if let compactProvider = provider as? FluidAudioProvider {
            return try await compactProvider.refreshModelsExistOnDiskAsync()
        }
        #endif
        return provider.modelsExistOnDisk()
    }

    func applyModelPreparationProgress(
        _ progress: ModelPreparationProgress,
        updatesActiveModelState: Bool,
        externalProgressHandler: ((Double) -> Void)?,
        analyticsOperationID: UUID? = nil,
        analyticsDescriptor: AnalyticsModelDescriptor? = nil,
        analyticsSource: AnalyticsModelDownloadSource = .automatic
    ) {
        switch progress.phase {
        case .preparingDownload:
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .downloading:
            if let analyticsOperationID, let analyticsDescriptor {
                self.beginModelDownloadAnalytics(
                    operationID: analyticsOperationID,
                    descriptor: analyticsDescriptor,
                    source: analyticsSource
                )
            }
            self.downloadProgress = progress.fractionCompleted
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
            if let fraction = progress.fractionCompleted {
                externalProgressHandler?(fraction)
            }
        case .optimizing:
            if let analyticsOperationID {
                self.finishModelDownloadAnalytics(operationID: analyticsOperationID, outcome: .succeeded)
            }
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = true
                self.isLoadingModel = false
            }
        case .loading:
            if let analyticsOperationID {
                self.finishModelDownloadAnalytics(operationID: analyticsOperationID, outcome: .succeeded)
            }
            self.downloadProgress = nil
            if updatesActiveModelState {
                self.isDownloadingModel = false
                self.isLoadingModel = true
            }
        }

        self.modelPreparationPhase = progress.phase
    }

    private struct ModelDownloadAnalyticsState {
        let descriptor: AnalyticsModelDescriptor
        let source: AnalyticsModelDownloadSource
        let startedAt: Date
    }

    private func beginModelDownloadAnalytics(
        operationID: UUID,
        descriptor: AnalyticsModelDescriptor,
        source: AnalyticsModelDownloadSource
    ) {
        guard self.modelDownloadAnalyticsStates[operationID] == nil else { return }
        self.modelDownloadAnalyticsStates[operationID] = ModelDownloadAnalyticsState(
            descriptor: descriptor,
            source: source,
            startedAt: Date()
        )
        AnalyticsService.shared.recordModelDownloadStarted(
            id: operationID,
            descriptor: descriptor,
            source: source
        )
    }

    func finishModelDownloadAnalytics(
        operationID: UUID,
        outcome: AnalyticsModelDownloadOutcome
    ) {
        guard let state = self.modelDownloadAnalyticsStates.removeValue(forKey: operationID) else { return }
        AnalyticsService.shared.recordModelDownloadFinished(
            id: operationID,
            descriptor: state.descriptor,
            source: state.source,
            outcome: outcome,
            duration: Date().timeIntervalSince(state.startedAt)
        )
    }

    static func prepareProviderWithRecovery(
        provider: TranscriptionProvider,
        modelsAlreadyCached: Bool,
        progressHandler: @escaping (ModelPreparationProgress) -> Void
    ) async throws {
        let start = Date()
        var firstError: Error?
        do {
            try await provider.prepare(progressHandler: progressHandler)
            DebugLogger.shared.info(
                "ASRService: Provider '\(provider.name)' prepared successfully in \(String(format: "%.2f", Date().timeIntervalSince(start)))s",
                source: "ASRService"
            )
            return
        } catch {
            // Staging cleanup failure must not delete a successfully published cache
            // or hide its repair path when cancellation was also requested.
            if ParakeetArchiveDownloader.isCleanupFailure(error) { throw error }
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                throw CancellationError()
            }
            if let compact = provider as? FluidAudioProvider, compact.preservesInstalledCompactWeights {
                // Repairing by deletion could silently upgrade an installed older
                // checkpoint. Explicit Update/Delete owns that choice instead.
                throw error
            }
            firstError = error
            DebugLogger.shared.error("ASRService: First prepare attempt for \(provider.name) failed after \(String(format: "%.2f", Date().timeIntervalSince(start)))s", source: "ASRService")
            DebugLogger.shared.warning(
                "ASRService: First prepare failed for \(provider.name): \(error). " +
                    "Attempting a single recovery by clearing provider cache.",
                source: "ASRService"
            )
        }

        guard modelsAlreadyCached else {
            DebugLogger.shared.error(
                "ASRService: Provider cache was empty; recovery retry disabled after first failure for \(provider.name).",
                source: "ASRService"
            )
            throw NSError(
                domain: "ASRService",
                code: -2000,
                userInfo: [NSLocalizedDescriptionKey: "Provider preparation failed: \(Self.errorSummary(from: firstError))"]
            )
        }

        try Task.checkCancellation()
        do {
            DebugLogger.shared.info("ASRService: Clearing provider cache before retry for \(provider.name)", source: "ASRService")
            try await provider.clearCache()
        } catch {
            DebugLogger.shared.warning(
                "ASRService: Provider cache clear failed for \(provider.name): \(error)",
                source: "ASRService"
            )
        }

        // One strict retry. If this fails, we let the caller handle the error.
        try Task.checkCancellation()
        do {
            try await provider.prepare(progressHandler: progressHandler)
        } catch {
            if ParakeetArchiveDownloader.isCleanupFailure(error) { throw error }
            if Task.isCancelled || Self.isModelPreparationCancellation(error) {
                throw CancellationError()
            }
            throw error
        }
        DebugLogger.shared.info(
            "ASRService: Provider '\(provider.name)' prepared successfully after cache-clear retry",
            source: "ASRService"
        )
    }

    private static func errorSummary(from error: Error?) -> String {
        if let error { return error.localizedDescription }
        return "Unknown error"
    }

    nonisolated static func isModelPreparationCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
