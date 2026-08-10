import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime

struct AppToolLifecyclePinningTests {
    @Test
    @MainActor
    func `focus activates the exact process selected before mutation`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
            ServiceApplicationInfo(
                processIdentifier: 4071,
                processStartIdentity: 71,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        _ = try await actions.perform(
            action: "focus",
            request: Self.request(name: "PID:4071"))

        #expect(service.activationCalls == ["PID:4071"])
    }

    @Test
    @MainActor
    func `single quit pins the process resolved before mutation`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        _ = try await actions.perform(
            action: "quit",
            request: Self.request(name: "TextEdit"))

        #expect(service.quitCalls.map(\.identifier) == ["PID:4070"])
        #expect(service.quitCalls.map(\.expectedIdentity) == [
            ApplicationProcessIdentity(processIdentifier: 4070, processStartIdentity: 70),
        ])
    }

    @Test
    @MainActor
    func `quit all pins every same-bundle process independently`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
            ServiceApplicationInfo(
                processIdentifier: 4071,
                processStartIdentity: 71,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        _ = try await actions.perform(
            action: "quit",
            request: Self.request(all: true))

        #expect(service.quitCalls.map(\.identifier) == ["PID:4070", "PID:4071"])
        #expect(service.terminationCount == 2)
    }

    @Test
    @MainActor
    func `PID reuse between discovery and quit fails without terminating replacement`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        service.replaceProcessGeneration(processIdentifier: 4070, with: 71)
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        await #expect(throws: PeekabooError.self) {
            try await actions.perform(
                action: "quit",
                request: Self.request(name: "TextEdit"))
        }

        #expect(service.quitCalls.count == 1)
        #expect(service.terminationCount == 0)
    }

    private static func request(
        name: String? = nil,
        all: Bool = false) -> AppToolRequest
    {
        AppToolRequest(
            name: name,
            bundleId: nil,
            openTargets: [],
            foreground: false,
            force: false,
            wait: 0,
            waitUntilReady: false,
            waitForWindow: false,
            newInstance: false,
            all: all,
            except: nil,
            switchTarget: nil,
            cycle: false,
            startTime: Date())
    }
}

@MainActor
private final class LifecyclePinningApplicationService: ApplicationServiceProtocol {
    let applications: [ServiceApplicationInfo]
    private var currentProcessGenerations: [Int32: UInt64]
    private(set) var quitCalls: [ApplicationQuitRequest] = []
    private(set) var activationCalls: [String] = []
    private(set) var terminationCount = 0

    init(applications: [ServiceApplicationInfo]) {
        self.applications = applications
        self.currentProcessGenerations = Dictionary(uniqueKeysWithValues: applications.compactMap { application in
            application.processStartIdentity.map { (application.processIdentifier, $0) }
        })
    }

    func replaceProcessGeneration(processIdentifier: Int32, with identity: UInt64) {
        self.currentProcessGenerations[processIdentifier] = identity
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: self.applications),
            summary: .init(brief: "fixture", status: .success),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        guard let match = self.applications.first(where: {
            identifier == $0.name || identifier == $0.bundleIdentifier ||
                identifier == "PID:\($0.processIdentifier)"
        }) else {
            throw PeekabooError.appNotFound(identifier)
        }
        return match
    }

    func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        try await self.quitApplication(request: ApplicationQuitRequest(identifier: identifier, force: force))
    }

    func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        self.quitCalls.append(request)
        guard let expectedIdentity = request.expectedIdentity,
              self.currentProcessGenerations[expectedIdentity.processIdentifier] ==
              expectedIdentity.processStartIdentity
        else {
            throw PeekabooError.commandFailed("Process generation changed")
        }
        self.terminationCount += 1
        return true
    }

    func listWindows(
        for _: String,
        timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData>
    {
        throw UnexpectedLifecycleCall()
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        throw UnexpectedLifecycleCall()
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        false
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        throw UnexpectedLifecycleCall()
    }

    func activateApplication(identifier: String) async throws {
        self.activationCalls.append(identifier)
    }

    func hideApplication(identifier _: String) async throws {
        throw UnexpectedLifecycleCall()
    }

    func unhideApplication(identifier _: String) async throws {
        throw UnexpectedLifecycleCall()
    }

    func hideOtherApplications(identifier _: String) async throws {
        throw UnexpectedLifecycleCall()
    }

    func showAllApplications() async throws {
        throw UnexpectedLifecycleCall()
    }
}

private struct UnexpectedLifecycleCall: Error {}
