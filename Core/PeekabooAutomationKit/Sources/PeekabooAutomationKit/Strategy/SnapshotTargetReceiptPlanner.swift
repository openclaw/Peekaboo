import Foundation

public struct SnapshotTargetReceiptPlan: Equatable, Sendable {
    public let receipt: SnapshotTargetReceipt
    public let sourceEvidence: [DesktopTargetIdentity.Evidence]

    public var hasProcessIdentifierEvidence: Bool {
        self.sourceEvidence.contains { evidence in
            evidence.processIdentifier != nil || evidence.processIdentity != nil
        }
    }
}

/// Loads and assembles the canonical target receipt for one snapshot identifier.
public struct SnapshotTargetReceiptPlanner: Sendable {
    public enum SourceFailurePolicy: Equatable, Sendable {
        case propagate
        case omitUnavailableSources
    }

    typealias AutomationSnapshotProvider =
        @Sendable (_ snapshotID: String) async throws -> UIAutomationSnapshot?
    typealias DetectionResultProvider =
        @Sendable (_ snapshotID: String) async throws -> ElementDetectionResult?

    private enum EvidenceScope {
        case completeTarget
        case processIdentity
    }

    private let automationSnapshotProvider: AutomationSnapshotProvider
    private let detectionResultProvider: DetectionResultProvider
    private let sourceFailurePolicy: SourceFailurePolicy

    public init(
        snapshots: any SnapshotManagerProtocol,
        sourceFailurePolicy: SourceFailurePolicy = .propagate)
    {
        self.init(
            automationSnapshotProvider: { snapshotID in
                try await snapshots.getUIAutomationSnapshot(snapshotId: snapshotID)
            },
            detectionResultProvider: { snapshotID in
                try await snapshots.getDetectionResult(snapshotId: snapshotID)
            },
            sourceFailurePolicy: sourceFailurePolicy)
    }

    init(
        automationSnapshotProvider: @escaping AutomationSnapshotProvider,
        detectionResultProvider: @escaping DetectionResultProvider,
        sourceFailurePolicy: SourceFailurePolicy = .propagate)
    {
        self.automationSnapshotProvider = automationSnapshotProvider
        self.detectionResultProvider = detectionResultProvider
        self.sourceFailurePolicy = sourceFailurePolicy
    }

    public func plan(snapshotID: String) async throws -> SnapshotTargetReceiptPlan {
        try await self.plan(snapshotID: snapshotID, evidenceScope: .completeTarget)
    }

    /// Resolves only stable process identity while leaving exact-window completeness to the mutation planner.
    public func planProcessIdentity(snapshotID: String) async throws -> SnapshotTargetReceiptPlan {
        try await self.plan(snapshotID: snapshotID, evidenceScope: .processIdentity)
    }

    private func plan(
        snapshotID: String,
        evidenceScope: EvidenceScope) async throws -> SnapshotTargetReceiptPlan
    {
        try Task.checkCancellation()
        let snapshot = try await self.loadAutomationSnapshot(snapshotID: snapshotID)
        try Task.checkCancellation()
        let detectionResult = try await self.loadDetectionResult(snapshotID: snapshotID)
        try Task.checkCancellation()
        return try Self.assemble(
            snapshotID: snapshotID,
            automationSnapshot: snapshot,
            detectionResult: detectionResult,
            evidenceScope: evidenceScope)
    }

    public static func assemble(
        snapshotID: String,
        automationSnapshot: UIAutomationSnapshot? = nil,
        detectionResult: ElementDetectionResult? = nil,
        additionalEvidence: [DesktopTargetIdentity.Evidence] = [],
        targetReceiptInvalidated: Bool = false,
        applicationBundleIdentifier: String? = nil,
        applicationName: String? = nil,
        coordinateContext: CaptureCoordinateContext? = nil) throws -> SnapshotTargetReceiptPlan
    {
        try self.assemble(
            snapshotID: snapshotID,
            automationSnapshot: automationSnapshot,
            detectionResult: detectionResult,
            additionalEvidence: additionalEvidence,
            targetReceiptInvalidated: targetReceiptInvalidated,
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationName: applicationName,
            coordinateContext: coordinateContext,
            evidenceScope: .completeTarget)
    }

    /// Assembles stable process identity without promoting partial window hints to mutation authority.
    public static func assembleProcessIdentity(
        snapshotID: String,
        automationSnapshot: UIAutomationSnapshot? = nil,
        detectionResult: ElementDetectionResult? = nil,
        additionalEvidence: [DesktopTargetIdentity.Evidence] = [],
        targetReceiptInvalidated: Bool = false,
        applicationBundleIdentifier: String? = nil,
        applicationName: String? = nil,
        coordinateContext: CaptureCoordinateContext? = nil) throws -> SnapshotTargetReceiptPlan
    {
        try self.assemble(
            snapshotID: snapshotID,
            automationSnapshot: automationSnapshot,
            detectionResult: detectionResult,
            additionalEvidence: additionalEvidence,
            targetReceiptInvalidated: targetReceiptInvalidated,
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationName: applicationName,
            coordinateContext: coordinateContext,
            evidenceScope: .processIdentity)
    }

    private static func assemble(
        snapshotID: String,
        automationSnapshot: UIAutomationSnapshot?,
        detectionResult: ElementDetectionResult?,
        additionalEvidence: [DesktopTargetIdentity.Evidence] = [],
        targetReceiptInvalidated: Bool = false,
        applicationBundleIdentifier: String? = nil,
        applicationName: String? = nil,
        coordinateContext: CaptureCoordinateContext? = nil,
        evidenceScope: EvidenceScope) throws -> SnapshotTargetReceiptPlan
    {
        if let detectionResult, detectionResult.snapshotId != snapshotID {
            throw DesktopTargetIdentityError.snapshotSourceMismatch
        }
        var evidence = additionalEvidence.map { self.evidence($0, scopedTo: evidenceScope) }
        if let automationSnapshot {
            evidence.append(self.evidence(
                DesktopTargetEvidenceAdapter.evidence(snapshot: automationSnapshot),
                scopedTo: evidenceScope))
        }
        if let context = detectionResult?.metadata.windowContext {
            evidence.append(self.evidence(
                DesktopTargetEvidenceAdapter.evidence(context: context),
                scopedTo: evidenceScope))
        }
        let detectionContext = detectionResult?.metadata.windowContext
        let receipt = try SnapshotTargetReceipt(
            snapshotID: snapshotID,
            evidence: evidence,
            targetReceiptInvalidated: targetReceiptInvalidated,
            applicationBundleIdentifier: applicationBundleIdentifier ??
                detectionContext?.applicationBundleId ?? automationSnapshot?.applicationBundleId,
            applicationName: applicationName ?? detectionContext?.applicationName ?? automationSnapshot?
                .applicationName,
            coordinateContext: coordinateContext ??
                detectionResult?.metadata.captureCoordinateContext ?? automationSnapshot?.captureCoordinateContext)
        return SnapshotTargetReceiptPlan(receipt: receipt, sourceEvidence: evidence)
    }

    private static func evidence(
        _ evidence: DesktopTargetIdentity.Evidence,
        scopedTo scope: EvidenceScope) -> DesktopTargetIdentity.Evidence
    {
        switch scope {
        case .completeTarget:
            evidence
        case .processIdentity:
            .init(
                processIdentifier: evidence.processIdentifier,
                processIdentity: evidence.processIdentity)
        }
    }

    private func loadAutomationSnapshot(snapshotID: String) async throws -> UIAutomationSnapshot? {
        do {
            return try await self.automationSnapshotProvider(snapshotID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard self.sourceFailurePolicy == .omitUnavailableSources else { throw error }
            return nil
        }
    }

    private func loadDetectionResult(snapshotID: String) async throws -> ElementDetectionResult? {
        do {
            return try await self.detectionResultProvider(snapshotID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard self.sourceFailurePolicy == .omitUnavailableSources else { throw error }
            return nil
        }
    }
}
