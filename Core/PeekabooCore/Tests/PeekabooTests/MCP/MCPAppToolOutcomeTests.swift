import Foundation
import os.log
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPAppToolOutcomeTests {
    @Test
    @MainActor
    func `app lifecycle responses expose lossless process target identity`() throws {
        let generation = UInt64.max - 3
        let app = ServiceApplicationInfo(
            processIdentifier: 4242,
            processStartIdentity: generation,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let actions = AppToolActions(
            service: StubApplicationService(),
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "MCPAppToolOutcome"))
        let responses = try [
            actions.buildResponse(message: "✅ Launched Fixture", app: app, startTime: Date()),
            actions.focusResponse(app: app, startTime: Date(), verb: "Focused", outcome: nil),
        ]

        for response in responses {
            let meta = try #require(response.meta?.objectValue)
            let target = try #require(meta["target_identity"]?.objectValue)
            #expect(meta["process_start_identity"] == .double(Double(generation)))
            #expect(meta["process_start_identity_decimal"] == .string(String(generation)))
            #expect(target["kind"] == .string("process"))
            #expect(target["pid"] == .int(4242))
            #expect(target["process_start_identity_decimal"] == .string(String(generation)))

            let external = MCPToolResponseMetadataProjector.externalFields(from: response.meta, toolName: "app")
            #expect(external["process_start_identity"] == nil)
            #expect(external["target_identity"] == .object(target))
        }
    }

    @Test
    @MainActor
    func `app lifecycle success renderers reject non-success canonical outcomes`() throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 4242,
            processStartIdentity: 77,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let actions = AppToolActions(
            service: StubApplicationService(),
            automation: MockAutomationService(accessibilityGranted: true),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "MCPAppToolOutcome"))
        let outcomes: [DesktopActionOutcome] = [
            .refused(reason: .targetUnavailable),
            .partial(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one),
            .suspectedNoop(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one),
            .indeterminate(evidence: .completionUnknown),
        ]

        for outcome in outcomes {
            #expect(throws: DesktopActionFailure.self) {
                _ = try actions.buildResponse(
                    message: "✅ Launched Fixture",
                    app: app,
                    startTime: Date(),
                    outcome: outcome)
            }
            #expect(throws: DesktopActionFailure.self) {
                _ = try actions.focusResponse(
                    app: app,
                    startTime: Date(),
                    verb: "Focused",
                    outcome: outcome)
            }
        }

        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        _ = try actions.buildResponse(
            message: "✅ Launched Fixture",
            app: app,
            startTime: Date(),
            outcome: dispatched)
    }

    @Test
    @MainActor
    func `app lifecycle tools return errors for non-success result payloads`() async throws {
        let outcome = DesktopActionOutcome.partial(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        let requests: [[String: Any]] = [
            ["action": "launch", "name": "StubApp"],
            ["action": "open", "name": "StubApp", "openTargets": ["https://example.com"], "foreground": true],
            ["action": "relaunch", "name": "StubApp", "foreground": true, "wait": 0.0],
            ["action": "unhide", "name": "StubApp", "foreground": true],
            ["action": "focus", "name": "StubApp"],
        ]

        for request in requests {
            let service = StubApplicationService()
            service.actionOutcome = outcome
            let context = await MCPToolTestHelpers.makeContext(applications: service)
            let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: request))

            #expect(response.isError, "Expected error for \(request["action"] ?? "unknown")")
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        }
    }

    @Test
    @MainActor
    func `single quit failure preserves the canonical suspected no-op receipt`() async throws {
        let service = NoopApplicationService()
        let outcome = DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        service.actionOutcome = outcome
        let actions = AppToolActions(
            service: service,
            automation: StubAutomationService(),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppOutcome"))
        let response = try await actions.handleQuit(request: Self.quitRequest())

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        #expect(Self.responseText(response).contains("Retry with force=true"))
    }

    @Test
    @MainActor
    func `single quit false payload with confirmed outcome is target-attributed indeterminate`() async throws {
        let service = NoopApplicationService()
        service.actionOutcome = .confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await context.execute(
            tool: AppTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "quit",
                "name": "StubApp",
            ]))
        let expected = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        let target = try #require(response.meta?.objectValue?["target_receipt"]?.objectValue)
        #expect(target["pid"] == .int(123))
        #expect(target["process_start_identity_decimal"] == .string("456"))
    }

    @Test
    @MainActor
    func `Bridge target refusal tells the caller to refresh inventory instead of force quitting`() async throws {
        let service = NoopApplicationService()
        let outcome = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)
        service.actionOutcome = outcome
        let actions = AppToolActions(
            service: service,
            automation: StubAutomationService(),
            logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppOutcome"))

        let response = try await actions.handleQuit(request: Self.quitRequest())

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        let text = Self.responseText(response)
        #expect(text.contains("Refresh the application target or inventory"))
        #expect(!text.contains("force=true"))
    }

    @Test
    @MainActor
    func `unsafe quit outcomes require observation instead of suggesting force`() async throws {
        let outcomes = [
            DesktopActionOutcome.partial(
                route: .bridge,
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one),
            DesktopActionOutcome.indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                evidence: .responseLost,
                unitCount: .one),
        ]

        for outcome in outcomes {
            let service = NoopApplicationService()
            service.actionOutcome = outcome
            let actions = AppToolActions(
                service: service,
                automation: StubAutomationService(),
                logger: Logger(subsystem: "boo.peekaboo.tests", category: "AppOutcome"))

            let response = try await actions.handleQuit(request: Self.quitRequest())

            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
            let text = Self.responseText(response)
            #expect(text.contains("Observe the application state before deciding whether to retry"))
            #expect(!text.contains("force=true"))
        }
    }

    @Test
    @MainActor
    func `named focus failure preserves canonical metadata`() async throws {
        let failure = DesktopActionFailure.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "Activation could not be verified")
        let service = ActivationFailureApplicationService(failure: failure)
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "focus",
            "name": "StubApp",
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(failure.outcome, in: response)
    }

    @Test
    @MainActor
    func `returned cycle failure does not become a successful switch`() async throws {
        let failure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Cmd-Tab completion is unknown")
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.append(failure.outcome, for: .hotkey)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "switch",
            "cycle": true,
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(failure.outcome, in: response)
    }

    @Test
    @MainActor
    func `quit all includes a thrown canonical failure in its batch metadata`() async throws {
        let failure = DesktopActionFailure.suspectedNoop(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one,
            message: "The application remained running")
        let service = QuitAllFailureApplicationService(failure: failure)
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(failure.outcome, in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["failed"] == .array([.string("QuitFailureApp")]))
    }

    @Test
    @MainActor
    func `quit all preserves compatible pre-dispatch refusals in batch metadata`() async throws {
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "The pinned application target changed")
        let service = ScriptedQuitAllApplicationService(attempts: [
            .canonicalFailure(refusal),
            .canonicalFailure(refusal),
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))
        let expected = DesktopActionOutcome.refused(route: .bridge, reason: .targetUnavailable)

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["quit_count"] == .double(0))
        #expect(meta["failed"] == .array([.string("First Quit App"), .string("Second Quit App")]))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["refusal_reason"] == .string("target_unavailable"))
    }

    @Test
    @MainActor
    func `quit all never counts payload true with a non-success outcome`() async throws {
        let suspected = DesktopActionOutcome.suspectedNoop(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let confirmed = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let service = ScriptedQuitAllApplicationService(attempts: [
            .success(suspected),
            .success(confirmed),
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["quit_count"] == .double(1))
        #expect(meta["failed"] == .array([.string("First Quit App")]))
        #expect(meta["state"] != .string("confirmed_change"))
    }

    @Test
    @MainActor
    func `quit all converts false payload with confirmed outcome into indeterminate failure`() async throws {
        let confirmed = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let service = FalsePayloadQuitAllApplicationService(outcome: confirmed)
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))
        let expected = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["quit_count"] == .double(0))
        #expect(meta["failed"] == .array([.string("False Payload App")]))
        #expect(meta["state"] != .string("confirmed_change"))
        let target = try #require(meta["target_receipt"]?.objectValue)
        #expect(target["pid"] == .int(792))
        #expect(target["process_start_identity_decimal"] == .string("992"))
    }

    @Test
    @MainActor
    func `legacy quit all false payload stays receiptless and never fabricates success`() async throws {
        let service = FalsePayloadQuitAllApplicationService(outcome: nil)
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["quit_count"] == .double(0))
        #expect(meta["failed"] == .array([.string("False Payload App")]))
        #expect(MCPToolResponseMetadataProjector.actionOutcomeKeys.allSatisfy { meta[$0] == nil })
    }

    @Test
    @MainActor
    func `quit all keeps response loss unsafe when another attempt has no receipt`() async throws {
        let responseLost = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .responseLost,
            unitCount: .one,
            message: "Quit response was lost")
        let service = ScriptedQuitAllApplicationService(attempts: [
            .canonicalFailure(responseLost),
            .receiptlessFailure,
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))
        let expected = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .responseLost,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["quit_count"] == .double(0))
        #expect(meta["failed"] == .array([.string("First Quit App"), .string("Second Quit App")]))
        #expect(Self.responseText(response).contains("Failed to quit: First Quit App, Second Quit App"))
    }

    @Test
    @MainActor
    func `legacy quit all keeps receiptless result metadata without a fabricated outcome`() async throws {
        let service = ScriptedQuitAllApplicationService(attempts: [
            .receiptlessFailure,
            .receiptlessFailure,
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["quit_count"] == .double(0))
        #expect(meta["failed"] == .array([.string("First Quit App"), .string("Second Quit App")]))
        #expect(meta["effect"] == nil)
        #expect(MCPToolResponseMetadataProjector.actionOutcomeKeys.allSatisfy { meta[$0] == nil })
        #expect(Self.responseText(response).contains("Quit 0 applications"))
        #expect(Self.responseText(response).contains("Failed to quit: First Quit App, Second Quit App"))
    }

    @Test
    @MainActor
    func `legacy partial quit all is an error without fabricating an outcome`() async throws {
        let service = ScriptedQuitAllApplicationService(attempts: [
            .success(nil),
            .receiptlessFailure,
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["quit_count"] == .double(1))
        #expect(meta["failed"] == .array([.string("Second Quit App")]))
        #expect(MCPToolResponseMetadataProjector.actionOutcomeKeys.allSatisfy { meta[$0] == nil })
    }

    @Test
    @MainActor
    func `quit all stops immediately when a legacy attempt cancels`() async throws {
        let service = ScriptedQuitAllApplicationService(attempts: [
            .cancellation,
            .receiptlessFailure,
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))

        #expect(response.isError)
        #expect(service.attemptCount == 1)
        let expected = DesktopActionOutcome.indeterminate(
            evidence: .completionUnknown,
            unitCount: .one)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
    }

    @Test
    @MainActor
    func `quit all preserves completed receipt when a later attempt cancels`() async throws {
        let outcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let service = ScriptedQuitAllApplicationService(attempts: [
            .success(outcome),
            .cancellation,
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "quit",
            "all": true,
        ]))

        #expect(response.isError)
        #expect(service.attemptCount == 2)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["cancelled"] == .bool(true))
        #expect(meta["quit_count"] == .double(1))
        let expected = DesktopActionOutcome.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
    }

    @Test
    @MainActor
    func `quit all cancellation between targets makes confirmed prefix partial`() async throws {
        let outcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        let service = ScriptedQuitAllApplicationService(attempts: [
            .successAndCancel(outcome),
            .receiptlessFailure,
        ])
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let execution = Task { @MainActor in
            try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
                "action": "quit",
                "all": true,
            ]))
        }
        let response = try await execution.value

        #expect(response.isError)
        #expect(service.attemptCount == 1)
        let expected = DesktopActionOutcome.partial(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: .one)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
    }

    @Test
    @MainActor
    func `background launch confirmed no-change reports the app was already running`() async throws {
        let service = StubApplicationService()
        let outcome = DesktopActionOutcome.confirmedNoChange(route: .local)
        service.actionOutcome = outcome
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "StubApp",
        ]))

        #expect(!response.isError)
        guard case let .text(text, _, _)? = response.content.first else {
            Issue.record("Expected launch response text")
            return
        }
        #expect(text.contains("StubApp was already running"))
        #expect(text.contains("no launch was needed"))
        #expect(!text.contains("Launched StubApp"))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
    }

    @Test
    @MainActor
    func `legacy background launch keeps no-op wording without canonical metadata`() async throws {
        let service = StubApplicationService()
        service.actionOutcome = nil
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "StubApp",
        ]))

        #expect(!response.isError)
        let text = Self.responseText(response)
        #expect(text.contains("StubApp was already running"))
        #expect(text.contains("no launch was needed"))
        #expect(!text.contains("Launched StubApp"))
        let meta = try #require(response.meta?.objectValue)
        #expect(MCPToolResponseMetadataProjector.actionOutcomeKeys.allSatisfy { meta[$0] == nil })
    }

    @Test
    @MainActor
    func `open with no dispatch does not claim targets were opened`() async throws {
        let service = StubApplicationService()
        let outcome = DesktopActionOutcome.confirmedNoChange(route: .local)
        service.actionOutcome = outcome
        let context = await MCPToolTestHelpers.makeContext(applications: service)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "open",
            "name": "StubApp",
            "openTargets": ["https://example.com"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        guard case let .text(text, _, _)? = response.content.first else {
            Issue.record("Expected open response text")
            return
        }
        #expect(text.contains("No target delivery was dispatched"))
        #expect(text.contains("0 targets were opened"))
        #expect(!text.contains("Opened 1 target"))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
    }

    private static func quitRequest() -> AppToolRequest {
        AppToolRequest(
            name: "StubApp",
            bundleId: nil,
            openTargets: [],
            foreground: false,
            force: false,
            wait: 0,
            waitUntilReady: false,
            waitForWindow: false,
            newInstance: false,
            all: false,
            except: nil,
            switchTarget: nil,
            cycle: false,
            startTime: Date())
    }

    private static func responseText(_ response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else { return "" }
        return text
    }
}

@MainActor
private final class NoopApplicationService: StubApplicationService {
    override func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        _ = try await super.quitApplication(request: request)
        return false
    }
}

@MainActor
private final class ActivationFailureApplicationService: StubApplicationService {
    private let failure: DesktopActionFailure

    init(failure: DesktopActionFailure) {
        self.failure = failure
    }

    override func activateApplicationActionResult(
        request _: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        throw self.failure
    }
}

@MainActor
private final class QuitAllFailureApplicationService: StubApplicationService {
    private let failure: DesktopActionFailure
    private let target = ServiceApplicationInfo(
        processIdentifier: 789,
        processStartIdentity: 987,
        bundleIdentifier: "dev.stub.quit-failure",
        name: "QuitFailureApp",
        isHiddenKnown: true,
        windowCount: 1,
        activationPolicy: .regular)

    init(failure: DesktopActionFailure) {
        self.failure = failure
    }

    override func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.target]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0))
    }

    override func quitApplicationActionResult(
        request _: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        throw self.failure
    }
}

@MainActor
private final class FalsePayloadQuitAllApplicationService: StubApplicationService {
    private let outcome: DesktopActionOutcome?
    private let target = ServiceApplicationInfo(
        processIdentifier: 792,
        processStartIdentity: 992,
        bundleIdentifier: "dev.stub.quit-false-payload",
        name: "False Payload App",
        isHiddenKnown: true,
        windowCount: 1,
        activationPolicy: .regular)

    init(outcome: DesktopActionOutcome?) {
        self.outcome = outcome
    }

    override func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: [self.target]),
            summary: .init(brief: "1 app", status: .success, counts: ["applications": 1]),
            metadata: .init(duration: 0))
    }

    override func quitApplicationActionResult(
        request _: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        DesktopActionResult(payload: false, outcome: self.outcome)
    }
}

@MainActor
private final class ScriptedQuitAllApplicationService: StubApplicationService {
    enum Attempt {
        case canonicalFailure(DesktopActionFailure)
        case receiptlessFailure
        case cancellation
        case success(DesktopActionOutcome?)
        case successAndCancel(DesktopActionOutcome?)
    }

    private let targets = [
        ServiceApplicationInfo(
            processIdentifier: 790,
            processStartIdentity: 990,
            bundleIdentifier: "dev.stub.quit-first",
            name: "First Quit App",
            isHiddenKnown: true,
            windowCount: 1,
            activationPolicy: .regular),
        ServiceApplicationInfo(
            processIdentifier: 791,
            processStartIdentity: 991,
            bundleIdentifier: "dev.stub.quit-second",
            name: "Second Quit App",
            isHiddenKnown: true,
            windowCount: 1,
            activationPolicy: .regular),
    ]
    private var attempts: [Attempt]
    private(set) var attemptCount = 0

    init(attempts: [Attempt]) {
        self.attempts = attempts
    }

    override func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: self.targets),
            summary: .init(brief: "2 apps", status: .success, counts: ["applications": 2]),
            metadata: .init(duration: 0))
    }

    override func quitApplicationActionResult(
        request _: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        self.attemptCount += 1
        guard !self.attempts.isEmpty else {
            Issue.record("Received more quit attempts than scripted results")
            return DesktopActionResult(payload: false, outcome: nil)
        }
        switch self.attempts.removeFirst() {
        case let .canonicalFailure(failure):
            throw failure
        case .receiptlessFailure:
            throw PeekabooError.commandFailed("Legacy quit failed without a canonical receipt")
        case .cancellation:
            throw CancellationError()
        case let .success(outcome):
            return DesktopActionResult(payload: true, outcome: outcome)
        case let .successAndCancel(outcome):
            withUnsafeCurrentTask { $0?.cancel() }
            return DesktopActionResult(payload: true, outcome: outcome)
        }
    }
}
