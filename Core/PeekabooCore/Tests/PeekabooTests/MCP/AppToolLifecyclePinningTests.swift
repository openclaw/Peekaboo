import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct AppToolLifecyclePinningTests {
    @Test(arguments: ["quit", "hide"])
    @MainActor
    func `background app mutations retain the authorized generation through dispatch`(
        action: String) async throws
    {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        let context = await MCPToolTestHelpers.makeContext(
            applications: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: AppTool(context: context),
            arguments: ToolArguments(raw: [
                "action": action,
                "name": "TextEdit",
            ]))

        #expect(!response.isError)
        if action == "quit" {
            #expect(service.quitCalls.first?.expectedIdentity == ApplicationProcessIdentity(
                processIdentifier: 4070,
                processStartIdentity: 70))
        } else {
            #expect(service.hideRequests.first?.expectedIdentity == ApplicationProcessIdentity(
                processIdentifier: 4070,
                processStartIdentity: 70))
        }
    }

    @Test
    @MainActor
    func `background quit and hide reject a generation flip after authorization without dispatch`() async throws {
        for action in ["quit", "hide"] {
            let service = LifecyclePinningApplicationService(applications: [
                ServiceApplicationInfo(
                    processIdentifier: 4070,
                    processStartIdentity: 70,
                    bundleIdentifier: "com.apple.TextEdit",
                    name: "TextEdit"),
            ])
            service.replaceProcessGeneration(processIdentifier: 4070, with: 71)
            service.reportProcessGeneration(71, startingWithFindCall: 3)
            let context = await MCPToolTestHelpers.makeContext(
                applications: service,
                executionPolicy: .backgroundOnly)

            let response = try await context.execute(
                tool: AppTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": action,
                    "name": "TextEdit",
                ]))

            #expect(response.isError, "Expected \(action) to reject the replacement generation")
            #expect(service.quitCalls.isEmpty)
            #expect(service.hideRequests.isEmpty)
            #expect(service.terminationCount == 0)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }
    }

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
        let generation = UInt64.max - 4
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: generation,
                bundleIdentifier: "com.example.TextEditCopy",
                name: "TextEdit Copy",
                bundlePath: "/tmp/TextEdit Copy.app"),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        let response = try await actions.perform(
            action: "relaunch",
            request: Self.request(name: "TextEdit Copy", foreground: true))

        let request = try #require(service.relaunchRequests.first?.launchRequest)
        #expect(request.applicationIdentifier == "/tmp/TextEdit Copy.app")
        #expect(request.applicationBundleIdentifier == nil)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["new_process_start_identity"] == .double(Double(generation)))
        #expect(meta["new_process_start_identity_decimal"] == .string(String(generation)))
        #expect(meta["target_identity"]?.objectValue?["process_start_identity_decimal"] ==
            .string(String(generation)))
    }

    @Test
    @MainActor
    func `MCP hide dispatches the exact preflight process and publishes its target identity`() async throws {
        let processStartIdentity: UInt64 = 9_007_199_254_740_993
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: processStartIdentity,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        let response = try await actions.perform(
            action: "hide",
            request: Self.request(name: "TextEdit"))

        #expect(service.findCalls == ["TextEdit"])
        #expect(service.hideCalls == ["PID:4070"])
        #expect(try service.hideRequests == [ApplicationHideRequest(
            identifier: "PID:4070",
            expectedIdentity: .init(
                processIdentifier: 4070,
                processStartIdentity: processStartIdentity))])
        let metadata = try #require(response.meta?.objectValue)
        let target = try #require(metadata["target_identity"]?.objectValue)
        #expect(target["kind"] == .string("process"))
        #expect(target["pid"] == .int(4070))
        #expect(target["process_start_identity_decimal"] == .string(String(processStartIdentity)))
        #expect(metadata["state"] == .string("confirmed_change"))
        #expect(metadata["process_start_identity_decimal"] == .string(String(processStartIdentity)))
    }

    @Test
    @MainActor
    func `MCP hide refuses a returned target from another process generation`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        service.hideReturnedIdentity = ApplicationProcessIdentity(
            processIdentifier: 4070,
            processStartIdentity: 71)
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        do {
            _ = try await actions.perform(
                action: "hide",
                request: Self.request(name: "TextEdit"))
            Issue.record("Expected exact-target validation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
        }

        #expect(service.hideCalls == ["PID:4070"])
    }

    @Test
    @MainActor
    func `MCP hide preserves a targetless pre-dispatch refusal`() async throws {
        let refusal = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        service.hideOutcome = refusal
        service.hideOmitsTarget = true
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        do {
            _ = try await actions.perform(
                action: "hide",
                request: Self.request(name: "TextEdit"))
            Issue.record("Expected targetless refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == refusal)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    @Test
    @MainActor
    func `MCP hide returned failure publishes selected process receipt`() async throws {
        let identity = ApplicationProcessIdentity(
            processIdentifier: 4070,
            processStartIdentity: 9_007_199_254_740_993)
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        service.hideOutcome = .indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await context.execute(
            tool: AppTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "hide",
                "name": "TextEdit",
            ]))

        #expect(response.isError)
        let target = try #require(response.meta?.objectValue?["target_receipt"]?.objectValue)
        #expect(target["pid"] == .int(4070))
        #expect(target["process_start_identity_decimal"] == .string(String(identity.processStartIdentity)))
        #expect(target["window_id"] == nil)
    }

    @Test
    @MainActor
    func `MCP hide admits dispatched result with canonical outcome and verified process target`() async throws {
        let service = LifecyclePinningApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 4070,
                processStartIdentity: 70,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
        ])
        service.hideOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let actions = AppToolActions(
            service: service,
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppToolLifecyclePinning"))

        let response = try await actions.perform(
            action: "hide",
            request: Self.request(name: "TextEdit"))

        #expect(!response.isError)
        let metadata = try #require(response.meta?.objectValue)
        let target = try #require(metadata["target_identity"]?.objectValue)
        #expect(metadata["state"] == .string("dispatched_unverified"))
        #expect(metadata["route"] == .string("bridge"))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(target["kind"] == .string("process"))
        #expect(target["pid"] == .int(4070))
        #expect(target["process_start_identity_decimal"] == .string("70"))
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
private final class LifecyclePinningApplicationService: ApplicationServiceProtocol,
    ApplicationServiceActionResultProviding,
    ApplicationServiceTargetedActionResultProviding
{
    let supportsProcessGenerationPinnedApplicationActivation = true
    let applications: [ServiceApplicationInfo]
    private var currentProcessGenerations: [Int32: UInt64]
    private(set) var quitCalls: [ApplicationQuitRequest] = []
    private(set) var activationCalls: [String] = []
    private(set) var activationRequests: [ApplicationActivationRequest] = []
    private(set) var findCalls: [String] = []
    private(set) var launchRequests: [ApplicationLaunchRequest] = []
    private(set) var relaunchRequests: [ApplicationRelaunchRequest] = []
    private(set) var hideCalls: [String] = []
    private(set) var hideRequests: [ApplicationHideRequest] = []
    private(set) var terminationCount = 0
    private var reportedGenerationAfterFindCall: (call: Int, generation: UInt64)?
    var hideReturnedIdentity: ApplicationProcessIdentity?
    var hideOmitsTarget = false
    var hideFailure: DesktopActionFailure?
    var hideOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one)

    init(applications: [ServiceApplicationInfo]) {
        self.applications = applications
        self.currentProcessGenerations = Dictionary(uniqueKeysWithValues: applications.compactMap { application in
            application.processStartIdentity.map { (application.processIdentifier, $0) }
        })
    }

    func replaceProcessGeneration(processIdentifier: Int32, with identity: UInt64) {
        self.currentProcessGenerations[processIdentifier] = identity
    }

    func reportProcessGeneration(_ generation: UInt64, startingWithFindCall call: Int) {
        self.reportedGenerationAfterFindCall = (call, generation)
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
        if let replacement = self.reportedGenerationAfterFindCall,
           self.findCalls.count >= replacement.call
        {
            return ServiceApplicationInfo(
                processIdentifier: match.processIdentifier,
                processStartIdentity: replacement.generation,
                bundleIdentifier: match.bundleIdentifier,
                name: match.name,
                bundlePath: match.bundlePath,
                isActive: match.isActive,
                isHidden: match.isHidden,
                isHiddenKnown: match.isHiddenKnown,
                windowCount: match.windowCount,
                windowIDs: match.windowIDs,
                activationPolicy: match.activationPolicy,
                isFinishedLaunching: match.isFinishedLaunching,
                metadataWarnings: match.metadataWarnings)
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

    func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.activateApplication(request: request)
        guard let identity = request.expectedIdentity else {
            throw UnexpectedLifecycleCall()
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(processIdentity: identity))
    }

    func hideApplicationTargetedActionResult(identifier: String) async throws -> UIAutomationActionResult<Void> {
        throw UnexpectedLifecycleCall()
    }

    func hideApplicationTargetedActionResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        self.hideCalls.append(request.identifier)
        self.hideRequests.append(request)
        if let hideFailure {
            throw hideFailure
        }
        guard let application = self.applications.first(where: {
            request.identifier == "PID:\($0.processIdentifier)"
        }), application.processIdentity == request.expectedIdentity else {
            throw UnexpectedLifecycleCall()
        }
        let identity = self.hideReturnedIdentity ?? request.expectedIdentity
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.hideOutcome,
            targetIdentity: self.hideOmitsTarget ? nil : DesktopTargetIdentity(processIdentity: identity))
    }

    func hideOtherApplicationsActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        DesktopActionResult(outcome: .confirmedNoChange())
    }

    func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void> {
        DesktopActionResult(outcome: .confirmedNoChange())
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

    func launchApplicationActionResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        try await DesktopActionResult(
            payload: self.launchApplication(request: request),
            outcome: .confirmedChange(
                delivery: .init(
                    mechanism: .nativeFramework,
                    mode: request.activates ? .foreground : .background),
                unitCount: .one))
    }

    func relaunchApplicationActionResult(
        request: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        try await DesktopActionResult(
            payload: self.relaunchApplication(request: request),
            outcome: .confirmedChange(
                delivery: .init(
                    mechanism: .nativeFramework,
                    mode: request.launchRequest.activates ? .foreground : .background),
                unitCount: .one))
    }

    func activateApplicationActionResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        try await self.activateApplication(request: request)
        return DesktopActionResult(outcome: .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one))
    }

    func quitApplicationActionResult(
        request: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        try await DesktopActionResult(
            payload: self.quitApplication(request: request),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one))
    }

    func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideApplication(identifier: identifier)
        return DesktopActionResult(outcome: .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one))
    }

    func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.unhideApplication(identifier: identifier)
        return DesktopActionResult(outcome: .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one))
    }
}

private struct UnexpectedLifecycleCall: Error {}
