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
                name: "TextEdit",
                activationPolicy: .regular),
            ServiceApplicationInfo(
                processIdentifier: 4071,
                processStartIdentity: 71,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit",
                activationPolicy: .regular),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        _ = try await actions.perform(
            action: "focus",
            request: Self.request(name: "PID:4071"))

        #expect(service.activationCalls == ["PID:4071"])
        #expect(service.activationRequests.first?.expectedIdentity == ApplicationProcessIdentity(
            processIdentifier: 4071,
            processStartIdentity: 71))
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
                name: "TextEdit",
                activationPolicy: .regular),
            ServiceApplicationInfo(
                processIdentifier: 4071,
                processStartIdentity: 71,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit",
                activationPolicy: .regular),
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
    func `quit all excludes accessory prohibited and incomplete application metadata`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4080,
                processStartIdentity: 80,
                bundleIdentifier: "com.example.Editor",
                name: "Editor",
                activationPolicy: .regular),
            ServiceApplicationInfo(
                processIdentifier: 4081,
                processStartIdentity: 81,
                bundleIdentifier: "com.example.MenuExtra",
                name: "Menu Extra",
                activationPolicy: .accessory),
            ServiceApplicationInfo(
                processIdentifier: 4082,
                processStartIdentity: 82,
                bundleIdentifier: "com.example.Daemon",
                name: "System Helper",
                activationPolicy: .prohibited),
            ServiceApplicationInfo(
                processIdentifier: 4083,
                processStartIdentity: 83,
                bundleIdentifier: nil,
                name: "Incomplete Helper",
                isHiddenKnown: false,
                metadataWarnings: ["metadata unavailable"]),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        _ = try await actions.perform(
            action: "quit",
            request: Self.request(all: true))

        #expect(service.quitCalls.map(\.identifier) == ["PID:4080"])
        #expect(service.terminationCount == 1)
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

    @Test
    @MainActor
    func `unsafe background lifecycle actions refuse before MCP service dispatch`() async {
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
        let cases: [(String, AppToolRequest)] = [
            ("launch", Self.request(name: "TextEdit", newInstance: true)),
            ("open", Self.request(name: "TextEdit", openTargets: ["https://example.com"])),
            ("relaunch", Self.request(name: "TextEdit")),
            ("unhide", Self.request(name: "TextEdit")),
        ]

        for (action, request) in cases {
            await #expect(throws: ApplicationLifecycleRefusalError.self) {
                _ = try await actions.perform(action: action, request: request)
            }
        }

        #expect(service.findCalls.isEmpty)
        #expect(service.launchRequests.isEmpty)
        #expect(service.activationCalls.isEmpty)
    }

    @Test
    @MainActor
    func `MCP unhide foreground consent activates the exact selected process`() async throws {
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
            action: "unhide",
            request: Self.request(name: "TextEdit", foreground: true))

        #expect(service.findCalls == ["TextEdit"])
        #expect(service.activationCalls == ["PID:4070"])
        #expect(service.activationRequests.first?.expectedIdentity == ApplicationProcessIdentity(
            processIdentifier: 4070,
            processStartIdentity: 70))
    }

    @Test
    @MainActor
    func `MCP relaunch foreground consent preserves the exact selected bundle path`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.example.TextEditCopy",
                name: "TextEdit Copy",
                bundlePath: "/tmp/TextEdit Copy.app"),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        _ = try await actions.perform(
            action: "relaunch",
            request: Self.request(name: "TextEdit Copy", foreground: true))

        let request = try #require(service.relaunchRequests.first?.launchRequest)
        #expect(request.applicationIdentifier == "/tmp/TextEdit Copy.app")
        #expect(request.applicationBundleIdentifier == nil)
    }

    private static func request(
        name: String? = nil,
        foreground: Bool = false,
        openTargets: [String] = [],
        newInstance: Bool = false,
        all: Bool = false) -> AppToolRequest
    {
        AppToolRequest(
            name: name,
            bundleId: nil,
            openTargets: openTargets,
            foreground: foreground,
            force: false,
            wait: 0,
            waitUntilReady: false,
            waitForWindow: false,
            newInstance: newInstance,
            all: all,
            except: nil,
            switchTarget: nil,
            cycle: false,
            startTime: Date())
    }
}

@MainActor
private final class LifecyclePinningApplicationService: ApplicationServiceProtocol {
    let supportsProcessGenerationPinnedApplicationActivation = true
    let applications: [ServiceApplicationInfo]
    private var currentProcessGenerations: [Int32: UInt64]
    private(set) var quitCalls: [ApplicationQuitRequest] = []
    private(set) var activationCalls: [String] = []
    private(set) var activationRequests: [ApplicationActivationRequest] = []
    private(set) var findCalls: [String] = []
    private(set) var launchRequests: [ApplicationLaunchRequest] = []
    private(set) var relaunchRequests: [ApplicationRelaunchRequest] = []
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
        self.findCalls.append(identifier)
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

    func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        self.launchRequests.append(request)
        throw UnexpectedLifecycleCall()
    }

    func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        self.relaunchRequests.append(request)
        return try #require(self.applications.first)
    }

    func activateApplication(identifier: String) async throws {
        self.activationCalls.append(identifier)
    }

    func activateApplication(request: ApplicationActivationRequest) async throws {
        self.activationRequests.append(request)
        self.activationCalls.append(request.identifier)
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
