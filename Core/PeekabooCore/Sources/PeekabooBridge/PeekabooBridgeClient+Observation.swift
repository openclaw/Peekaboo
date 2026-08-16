import Foundation
import PeekabooAutomationKit

extension PeekabooBridgeClient {
    public func desktopObservation(_ request: DesktopObservationRequest) async throws
        -> DesktopObservationResult
    {
        try await self.desktopObservationWithOutcome(request).payload
    }

    public func desktopObservationWithOutcome(
        _ request: DesktopObservationRequest) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        let timeout = Self.desktopObservationRequestTimeout(
            overallTimeout: request.timeout.overall,
            defaultTimeout: self.requestTimeoutSec)
        let delivered: PeekabooBridgeActionResultWithTransportProvenance<DesktopObservationResult> =
            try await self.actionResultWithTransportProvenance(
                for: .desktopObservation(request),
                expectedResponse: "desktop observation",
                timeoutSec: timeout)
            { response in
                guard case let .desktopObservation(result) = response else { return nil }
                return result
            }
        let result: UIAutomationActionResult<DesktopObservationResult> = delivered.result
        do {
            let contentRequirement: DesktopObservationContentVerificationRequirement =
                delivered.hasVerifiedOperationReceipt ? .requireDigest : .allowUnsignedLegacy
            if contentRequirement == .requireDigest, result.payload.captureContentDigest == nil {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "the signed desktop observation capture-content digest")
            }
            if result.payload.files.rawScreenshotPath != nil {
                _ = try result.payload.verifiedRawScreenshotData(requirement: contentRequirement)
            }
            if result.payload.files.annotatedScreenshotPath != nil {
                _ = try result.payload.verifiedAnnotatedScreenshotData(requirement: contentRequirement)
            }
        } catch {
            throw ObservationActionResultSemantics.preservingFailure(
                error,
                after: result.outcome,
                targetIdentity: result.targetIdentity,
                operation: "Bridge desktop observation content verification")
        }
        return result
    }

    static func desktopObservationRequestTimeout(
        overallTimeout: TimeInterval?,
        defaultTimeout: TimeInterval) -> TimeInterval?
    {
        overallTimeout.map { max(defaultTimeout, $0 + 5) }
    }
}
