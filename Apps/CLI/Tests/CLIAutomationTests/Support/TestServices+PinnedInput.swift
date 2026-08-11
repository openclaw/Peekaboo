import Foundation
import PeekabooCore
import PeekabooFoundation
@testable import PeekabooCLI

@MainActor
extension StubAutomationService {
    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws {
        self.targetedClickCalls.append(TargetedClickCall(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            targetWindowID: nil,
            expectedProcessIdentity: expectedProcessIdentity
        ))
        if let clickError {
            throw clickError
        }
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws -> TypeResult {
        self.targetedTypeActionsCalls.append(
            TargetedTypeActionsCall(
                actions: actions,
                cadence: cadence,
                snapshotId: snapshotId,
                targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
                expectedProcessIdentity: expectedProcessIdentity
            )
        )
        return try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }
}
