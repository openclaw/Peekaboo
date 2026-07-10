import ApplicationServices
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct DetachedAXActionRunnerTests {
    @Test
    func `fast success completes with the AX result`() async {
        let outcome = await DetachedAXActionRunner.run(gracePeriod: 1.0) {
            AXError.success
        }
        #expect(outcome == .completed(.success))
    }

    @Test
    func `fast failure completes with the AX error`() async {
        let outcome = await DetachedAXActionRunner.run(gracePeriod: 1.0) {
            AXError.actionUnsupported
        }
        #expect(outcome == .completed(.actionUnsupported))
    }

    @Test
    func `blocking action resolves promptly as still running`() async {
        // Regression: a right-click whose AXShowMenu blocks in the menu tracking runloop must not
        // block the caller until the bridge client times out. The runner has to resolve at the
        // grace period even though the operation is still running.
        let started = Date()
        let outcome = await DetachedAXActionRunner.run(gracePeriod: 0.2) {
            Thread.sleep(forTimeInterval: 5.0)
            return AXError.success
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(outcome == .stillRunning)
        #expect(elapsed < 2.0, "runner blocked for \(elapsed)s instead of resolving at the grace period")
    }

    @Test
    @MainActor
    func `main actor stays responsive while a blocking action runs`() async {
        // The bridge server handles every request on the main actor; verify another main-actor
        // task can run to completion while a blocking AX action is still in flight.
        let blockedTask = Task { @MainActor in
            await DetachedAXActionRunner.run(gracePeriod: 0.3) {
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

        let outcome = await blockedTask.value
        #expect(outcome == .stillRunning)
    }
}
