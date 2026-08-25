import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension ClickCommand {
    func resolveSnapshotBackedWindowSelection(
        observation: InteractionObservationContext
    ) async throws -> InteractionWindowResolution {
        let snapshotID = try observation.requireSnapshot()
        let detection = try await observation.requireDetectionResult(using: self.services.snapshots)
        let context = detection.metadata.windowContext
        guard let requestedWindowID = self.target.windowId,
              let snapshotWindowID = context?.windowID
        else {
            throw ValidationError(
                "Snapshot '\(snapshotID)' does not identify an exact window; " +
                    "capture a fresh snapshot for the selected window"
            )
        }
        guard let snapshotBounds = context?.windowBounds,
              let snapshotIdentity = context?.windowMutationIdentity,
              snapshotIdentity.windowID == snapshotWindowID,
              snapshotIdentity.ownerProcessIdentifier == context?.applicationProcessId,
              snapshotIdentity.capturedBounds == snapshotBounds
        else {
            throw ValidationError(
                "Snapshot '\(snapshotID)' has no capture-time process-generation receipt for window " +
                    "\(snapshotWindowID)."
            )
        }
        guard requestedWindowID == snapshotWindowID else {
            throw ValidationError(
                "Snapshot '\(snapshotID)' belongs to window \(snapshotWindowID), but the explicit selector " +
                    "requested window \(requestedWindowID)"
            )
        }

        let targetApplication: ServiceApplicationInfo? = if let identifier = try self.target
            .resolveApplicationIdentifierOptional() {
            try await self.services.applications.findApplication(identifier: identifier)
        } else {
            nil
        }
        if let targetApplication,
           targetApplication.processIdentifier != snapshotIdentity.ownerProcessIdentifier {
            throw ValidationError(
                "Snapshot '\(snapshotID)' belongs to PID \(snapshotIdentity.ownerProcessIdentifier), but " +
                    "the explicit application selector resolved PID \(targetApplication.processIdentifier)"
            )
        }

        return InteractionWindowResolution(
            windowInfo: ServiceWindowInfo(
                windowID: snapshotWindowID,
                title: context?.windowTitle ?? "",
                bounds: snapshotBounds,
                mutationIdentity: snapshotIdentity
            ),
            targetApplication: targetApplication
        )
    }
}
