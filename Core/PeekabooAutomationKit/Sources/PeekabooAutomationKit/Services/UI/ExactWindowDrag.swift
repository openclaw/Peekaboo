import CoreGraphics
import Foundation
import PeekabooFoundation

/// One bounded linear drag inside a single capture-owned window. Coordinates are global logical points.
/// This is a separate contract from foreground drag and the fixed-point split held-pointer API.
public struct ExactWindowDragRequest: Codable, Equatable, Sendable {
    public static let durationMillisecondsRange = 1...10000
    public static let sampleCountRange = 1...96

    public let snapshotID: String
    public let target: UIAutomationTarget.ExactWindow
    public let from: CGPoint
    public let to: CGPoint
    public let durationMilliseconds: Int
    public let steps: Int
    public let button: ExactWindowHeldPointerButton

    public init(
        snapshotID: String,
        target: UIAutomationTarget.ExactWindow,
        from: CGPoint,
        to: CGPoint,
        durationMilliseconds: Int = 500,
        steps: Int = 20,
        button: ExactWindowHeldPointerButton = .left)
    {
        self.snapshotID = snapshotID
        self.target = target
        self.from = from
        self.to = to
        self.durationMilliseconds = durationMilliseconds
        self.steps = steps
        self.button = button
    }

    /// Primer, down, each drag sample, and the sole terminal up.
    public var dispatchedUnitCount: Int {
        Self.sampleCountRange.contains(self.steps) ? self.steps + 3 : 0
    }

    public func validate() throws {
        _ = try UIAutomationTarget.ExactWindow(identity: self.target.identity, bounds: self.target.bounds)
        guard SnapshotReference(rawValue: self.snapshotID) != nil,
              Self.durationMillisecondsRange.contains(self.durationMilliseconds),
              Self.sampleCountRange.contains(self.steps),
              self.target.identity.ownerProcessIdentifier > 0,
              self.target.identity.ownerProcessStartIdentity > 0,
              self.target.identity.windowID > 0, UInt32(exactly: self.target.identity.windowID) != nil,
              self.target.identity.capturedBounds == self.target.bounds,
              self.target.bounds.origin.x.isFinite, self.target.bounds.origin.y.isFinite,
              self.target.bounds.width.isFinite, self.target.bounds.height.isFinite,
              self.target.bounds.width > 0, self.target.bounds.height > 0,
              self.from.x.isFinite, self.from.y.isFinite, self.to.x.isFinite, self.to.y.isFinite,
              self.from != self.to,
              self.target.bounds.contains(self.from), self.target.bounds.contains(self.to)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Background drag requires distinct finite endpoints inside one exact snapshot window, " +
                    "a duration of 1...10000 milliseconds, and 1...96 samples.",
                hint: "Capture the exact window again; use explicit foreground mode for cross-window gestures.")
        }
    }
}

@MainActor
public protocol ExactWindowDragServiceProtocol: UIAutomationServiceProtocol {
    var supportsExactWindowDrag: Bool { get }

    func dragExactWindow(
        _ request: ExactWindowDragRequest,
        boundTo processIdentity: ApplicationProcessIdentity?) async throws -> UIAutomationActionResult<Void>
}

extension UIAutomationService: ExactWindowDragServiceProtocol {
    public var supportsExactWindowDrag: Bool {
        true
    }

    public func dragExactWindow(
        _ request: ExactWindowDragRequest,
        boundTo processIdentity: ApplicationProcessIdentity? = nil) async throws -> UIAutomationActionResult<Void>
    {
        try await self.heldPointerLifecycle.drag(request: request, boundTo: processIdentity) {
            let detection = try await self.snapshotManager.getDetectionResult(snapshotId: request.snapshotID)
            let receipt = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: request.snapshotID,
                detectionResult: detection,
                requireExactWindow: true,
                processStartIdentityProvider: self.processStartIdentityProvider,
                exactWindowIdentityValidator: self.exactWindowIdentityValidator)
            guard receipt.exactWindow == request.target else {
                throw PeekabooError.snapshotStale("Drag target differs from its capture-owned exact-window receipt")
            }
        }
    }
}
