import ApplicationServices
import AXorcist
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct DetachedAXActionRunnerTests {
    @Test
    func `fast success reports accepted but unverified dispatch`() async throws {
        let outcome = try await DetachedAXActionRunner.run(gracePeriod: 1.0) {
            AXError.success
        }
        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.evidence == .deliveryAccepted)
        #expect(outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(outcome.retrySafety == .unsafe)
    }

    @Test
    func `fast failure throws the AX error`() async {
        do {
            _ = try await DetachedAXActionRunner.run(gracePeriod: 1.0) {
                AXError.actionUnsupported
            }
            Issue.record("Expected the accessibility error")
        } catch let error as AccessibilitySystemError {
            #expect(error.axError == .actionUnsupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `blocking action resolves promptly as dispatched but unverified`() async throws {
        // Regression: a right-click whose AXShowMenu blocks in the menu tracking runloop must not
        // block the caller until the bridge client times out. The runner has to resolve at the
        // grace period even though the operation is still running.
        let started = Date()
        let outcome = try await DetachedAXActionRunner.run(gracePeriod: 0.2) {
            Thread.sleep(forTimeInterval: 5.0)
            return AXError.success
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.evidence == .operationStillRunning)
        #expect(!outcome.isConfirmed)
        #expect(elapsed < 2.0, "runner blocked for \(elapsed)s instead of resolving at the grace period")
    }

    @Test
    @MainActor
    func `main actor stays responsive while a blocking action runs`() async throws {
        // The bridge server handles every request on the main actor; verify another main-actor
        // task can run to completion while a blocking AX action is still in flight.
        let blockedTask = Task { @MainActor in
            try await DetachedAXActionRunner.run(gracePeriod: 0.3) {
                Thread.sleep(forTimeInterval: 3.0)
                return AXError.success
            }
        }

        let started = Date()
        let sideTask = Task { @MainActor in
            Date().timeIntervalSince(started)
        }
        let sideElapsed = await sideTask.value
        #expect(sideElapsed < 1.0, "main actor was blocked for \(sideElapsed)s")

        let outcome = try await blockedTask.value
        #expect(outcome.evidence == .operationStillRunning)
        #expect(!outcome.isConfirmed)
    }
}
