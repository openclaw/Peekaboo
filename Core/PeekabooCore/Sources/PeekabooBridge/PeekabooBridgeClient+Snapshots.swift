import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func createSnapshot() async throws -> String {
        try await self.createSnapshot(pendingAt: nil)
    }

    public func createSnapshot(pendingAt: Date?) async throws -> String {
        try await self.createSnapshot(pendingAt: pendingAt, explicitOnly: nil)
    }

    package func createExplicitSnapshot() async throws -> String {
        try await self.createSnapshot(pendingAt: nil, explicitOnly: true)
    }

    private func createSnapshot(pendingAt: Date?, explicitOnly: Bool?) async throws -> String {
        guard self.producerBoundSnapshotReferencesEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host did not negotiate producer-bound snapshot references")
        }
        let response = try await self.send(.createSnapshot(.init(
            pendingAt: pendingAt,
            explicitOnly: explicitOnly)))
        switch response {
        case let .snapshotId(id):
            guard SnapshotReference(rawValue: id) != nil else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Bridge host returned a non-canonical snapshot reference")
            }
            return id
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected createSnapshot response")
        }
    }

    public func storeDetectionResult(
        snapshotId: String,
        result: ElementDetectionResult,
        timeoutSec: TimeInterval? = nil) async throws
    {
        try await self.sendExpectOK(
            .storeDetectionResult(.init(snapshotId: snapshotId, result: result)),
            timeoutSec: timeoutSec)
    }

    public func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult {
        let response = try await self.send(.getDetectionResult(.init(snapshotId: snapshotId)))
        switch response {
        case let .detection(result): return result
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected getDetectionResult response")
        }
    }

    public func ownsSnapshot(snapshotId: String) async throws -> Bool {
        guard SnapshotReference(rawValue: snapshotId) != nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Invalid producer-bound snapshot reference")
        }
        guard self.producerBoundSnapshotReferencesEnabled else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Bridge host did not negotiate producer-bound snapshot references")
        }
        let response = try await self.send(.ownsSnapshot(.init(snapshotId: snapshotId)))
        switch response {
        case let .bool(owns): return owns
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected ownsSnapshot response")
        }
    }

    public func storeScreenshot(
        _ request: PeekabooBridgeStoreScreenshotRequest,
        timeoutSec: TimeInterval? = nil) async throws
    {
        try await self.sendExpectOK(.storeScreenshot(request), timeoutSec: timeoutSec)
    }

    public func storeObservationSnapshot(
        _ request: SnapshotObservationPublicationRequest,
        timeoutSec: TimeInterval? = nil) async throws
    {
        try await self.sendExpectOK(
            .storeObservationSnapshot(PeekabooBridgeStoreObservationSnapshotRequest(request)),
            timeoutSec: timeoutSec)
    }

    public func storeAnnotatedScreenshot(
        snapshotId: String,
        annotatedScreenshotPath: String,
        timeoutSec: TimeInterval? = nil) async throws
    {
        try await self.sendExpectOK(
            .storeAnnotatedScreenshot(
                .init(
                    snapshotId: snapshotId,
                    annotatedScreenshotPath: annotatedScreenshotPath)),
            timeoutSec: timeoutSec)
    }

    public func listSnapshots() async throws -> [SnapshotInfo] {
        let response = try await self.send(.listSnapshots)
        switch response {
        case let .snapshots(list): return list
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected listSnapshots response")
        }
    }

    public func getMostRecentSnapshot(applicationBundleId: String? = nil) async throws -> String {
        let response = try await self.send(.getMostRecentSnapshot(.init(applicationBundleId: applicationBundleId)))
        switch response {
        case let .snapshotId(id): return id
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected getMostRecentSnapshot response")
        }
    }

    public func invalidateImplicitLatestSnapshot(
        through cutoff: Date = Date(),
        preserving snapshotId: String? = nil,
        preservedAt: Date? = nil) async throws -> String?
    {
        let response = try await self.send(.invalidateImplicitLatestSnapshot(.init(
            cutoff: cutoff,
            preservingSnapshotId: snapshotId,
            preservedAt: preservedAt)))
        switch response {
        case let .snapshotId(id): return id
        case .ok: return nil
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected invalidateImplicitLatestSnapshot response")
        }
    }

    public func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        let response = try await self.send(.beginSnapshotMutation(.init(snapshotId: snapshotId)))
        switch response {
        case let .snapshotMutationLease(lease): return lease
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected beginSnapshotMutation response")
        }
    }

    public func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool) async throws
    {
        try await self.sendExpectOK(.finishSnapshotMutation(.init(
            lease: lease,
            requiresFreshObservation: requiresFreshObservation)))
    }

    public func cleanSnapshot(snapshotId: String) async throws {
        try await self.sendExpectOK(.cleanSnapshot(.init(snapshotId: snapshotId)))
    }

    public func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let response = try await self.send(.cleanSnapshotsOlderThan(.init(days: days)))
        switch response {
        case let .int(count): return count
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected cleanSnapshotsOlderThan response")
        }
    }

    public func cleanAllSnapshots() async throws -> Int {
        let response = try await self.send(.cleanAllSnapshots)
        switch response {
        case let .int(count): return count
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected cleanAllSnapshots response")
        }
    }

    @available(*, deprecated, message: "AppleScript probing is no longer supported")
    public func appleScriptProbe() async throws {
        throw PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "AppleScript probing is no longer supported; current operations use native macOS APIs")
    }
}
