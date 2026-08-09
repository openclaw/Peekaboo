import os.log
import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct AppToolCancellationTests {
    @Test
    @MainActor
    func `canceled running-state wait stops polling the production service`() async throws {
        let service = PollCountingApplicationService()
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolCancellation"))
        let clock = ContinuousClock()
        let start = clock.now
        let waitTask = Task { @MainActor in
            try await actions.waitForRunningState(
                identifier: "NeverRunning",
                desiredState: true,
                timeout: 10)
        }

        try await Task.sleep(for: .milliseconds(20))
        waitTask.cancel()

        #expect(try await waitTask.value == false)
        #expect(start.duration(to: clock.now) < .seconds(2))
        #expect(service.runningStateCheckCount > 0)
        #expect(service.runningStateCheckCount <= 2)
    }
}

@MainActor
private final class PollCountingApplicationService: ApplicationServiceProtocol {
    private(set) var runningStateCheckCount = 0

    func isApplicationRunning(identifier _: String) async -> Bool {
        self.runningStateCheckCount += 1
        return false
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        throw UnexpectedApplicationServiceCall()
    }

    func findApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        throw UnexpectedApplicationServiceCall()
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        throw UnexpectedApplicationServiceCall()
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        throw UnexpectedApplicationServiceCall()
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        throw UnexpectedApplicationServiceCall()
    }

    func activateApplication(identifier _: String) async throws {
        throw UnexpectedApplicationServiceCall()
    }

    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        throw UnexpectedApplicationServiceCall()
    }

    func hideApplication(identifier _: String) async throws {
        throw UnexpectedApplicationServiceCall()
    }

    func unhideApplication(identifier _: String) async throws {
        throw UnexpectedApplicationServiceCall()
    }

    func hideOtherApplications(identifier _: String) async throws {
        throw UnexpectedApplicationServiceCall()
    }

    func showAllApplications() async throws {
        throw UnexpectedApplicationServiceCall()
    }
}

private struct UnexpectedApplicationServiceCall: Error {}
