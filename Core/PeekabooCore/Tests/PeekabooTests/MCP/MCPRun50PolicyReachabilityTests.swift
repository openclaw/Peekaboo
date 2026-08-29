import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct MCPRun50PolicyReachabilityTests {
    private static let application = ServiceApplicationInfo(
        processIdentifier: 89,
        processStartIdentity: 890,
        bundleIdentifier: "com.apple.TextEdit",
        name: "TextEdit")

    @Test
    @MainActor
    func `background policy reaches only generation-pinned direct text paste`() async throws {
        let automation = Run50PasteAutomationService()
        let applications = MockApplicationService(applications: [Self.application])
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: PasteTool(context: context),
            arguments: ToolArguments(raw: [
                "app": "TextEdit",
                "text": "background text",
            ]))

        #expect(!response.isError)
        #expect(automation.targetedTypeActionsCalls.count == 1)
        #expect(automation.targetedTypeActionsCalls.first?.expectedProcessIdentity == Self.application.processIdentity)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string(DesktopActionOutcome.State.confirmedChange.rawValue))
        #expect(meta["delivery_mode"] == .string(DesktopActionOutcome.Delivery.Mode.background.rawValue))
        #expect(meta["target_pid"] == .int(Int(Self.application.processIdentifier)))
        #expect(meta["target_receipt"] != nil)

        let refusedCases: [(arguments: [String: Any], errorCode: String)] = [
            (["text": "targetless"], MCPToolExecutionPolicy.refusalErrorCode),
            (["app": "TextEdit"], MCPToolExecutionPolicy.refusalErrorCode),
            (["app": "TextEdit", "dataBase64": "eA==", "uti": "public.data"], "VALIDATION_ERROR"),
            (["app": "TextEdit", "text": "foreground", "foreground": true], "VALIDATION_ERROR"),
        ]
        for refusedCase in refusedCases {
            let refused = try await context.execute(
                tool: PasteTool(context: context),
                arguments: ToolArguments(raw: refusedCase.arguments))
            #expect(refused.isError)
            let refusalMeta = try #require(refused.meta?.objectValue)
            #expect(refusalMeta["error_code"] == .string(refusedCase.errorCode))
            #expect(refusalMeta["mutation_dispatched"] == .bool(false))
            #expect(refusalMeta["retry_safe"] == .bool(true))
        }
        #expect(automation.targetedTypeActionsCalls.count == 1)
        #expect(automation.lastHotkeyKeys == nil)
        #expect(automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    @MainActor
    func `background text paste missing outcome preserves canonical delivery and receipt`() async throws {
        let automation = Run50PasteAutomationService()
        automation.uiAutomationOutcomeScript.setDefaultOutcome(nil)
        let applications = MockApplicationService(applications: [Self.application])
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: PasteTool(context: context),
            arguments: ToolArguments(raw: [
                "app": "TextEdit",
                "text": "missing outcome",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string(DesktopActionOutcome.State.indeterminate.rawValue))
        #expect(meta["delivery_mechanism"] == .string(
            DesktopActionOutcome.Delivery.Mechanism.processTargetedEvents.rawValue))
        #expect(meta["delivery_mode"] == .string(DesktopActionOutcome.Delivery.Mode.background.rawValue))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["target_receipt"]?.objectValue?["pid"] == .int(Int(Self.application.processIdentifier)))
        #expect(meta["target_receipt"]?.objectValue?["process_start_identity_decimal"] == .string("890"))
        guard case let .text(message, _, _)? = response.content.first else {
            Issue.record("Expected missing outcome failure")
            return
        }
        #expect(message.contains("without a canonical outcome"))
    }

    @Test
    @MainActor
    func `background text paste rejects foreground delivery with canonical receipt`() async throws {
        let automation = Run50PasteAutomationService()
        automation.uiAutomationOutcomeScript.setDefaultOutcome(.confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one))
        let applications = MockApplicationService(applications: [Self.application])
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: PasteTool(context: context),
            arguments: ToolArguments(raw: [
                "app": "TextEdit",
                "text": "wrong delivery",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string(DesktopActionOutcome.State.indeterminate.rawValue))
        #expect(meta["delivery_mechanism"] == .string(DesktopActionOutcome.Delivery.Mechanism.globalEvents.rawValue))
        #expect(meta["delivery_mode"] == .string(DesktopActionOutcome.Delivery.Mode.foreground.rawValue))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["target_receipt"]?.objectValue?["pid"] == .int(Int(Self.application.processIdentifier)))
        guard case let .text(message, _, _)? = response.content.first else {
            Issue.record("Expected delivery rejection failure")
            return
        }
        #expect(message.contains("reported foreground delivery"))
    }

    @Test
    @MainActor
    func `background final gate rejects foreground-delivered confirmed no change`() async throws {
        let counter = Run50InvocationCounter()
        let automation = Run50PasteAutomationService()
        let applications = MockApplicationService(applications: [Self.application])
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            executionPolicy: .backgroundOnly)
        var forgedFields = try MCPToolResponseMetadataProjector.fields(
            for: DesktopActionOutcome.confirmedNoChange().projection)
        forgedFields["delivery_mechanism"] = .string(DesktopActionOutcome.Delivery.Mechanism.globalEvents.rawValue)
        forgedFields["delivery_mode"] = .string(DesktopActionOutcome.Delivery.Mode.foreground.rawValue)
        let response = try await context.execute(
            tool: Run50OutcomeProbeTool(
                name: "paste",
                counter: counter,
                outcome: nil,
                metaOverride: .object(forgedFields)),
            arguments: ToolArguments(raw: [
                "app": "TextEdit",
                "text": "probe",
            ]))

        #expect(await counter.value == 1)
        #expect(response.isError)
        guard case let .text(message, _, _)? = response.content.first,
              case let .object(meta)? = response.meta
        else {
            Issue.record("Expected canonical background-delivery rejection")
            return
        }
        #expect(message.contains("without valid canonical result semantics"))
        #expect(meta["state"] == Value.string(DesktopActionOutcome.State.indeterminate.rawValue))
        #expect(meta["delivery_mode"] == nil)
        #expect(meta["mutation_dispatched"] == Value.bool(true))
        #expect(meta["retry_safe"] == Value.bool(false))
    }

    @Test
    @MainActor
    func `background text paste rejects conflicts and retains authorized target attribution`() async throws {
        let automation = Run50PasteAutomationService()
        automation.outcomeTargetIdentity = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 90,
            processStartIdentity: 900))
        automation.allowsContradictoryOutcomeTargetIdentityForTesting = true
        let applications = MockApplicationService(applications: [Self.application])
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: PasteTool(context: context),
            arguments: ToolArguments(raw: [
                "app": "TextEdit",
                "text": "conflicting target",
            ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string(DesktopActionOutcome.State.indeterminate.rawValue))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(automation.targetedTypeActionsCalls.count == 1)
        #expect(automation.targetedTypeActionsCalls.first?.expectedProcessIdentity == Self.application.processIdentity)
        let authorizedIdentity = try DesktopTargetIdentity(processIdentity: #require(Self.application.processIdentity))
        let authorizedReceipt = try Value(authorizedIdentity.actionTargetReceipt)
        let conflictingReceipt = try Value(#require(automation.outcomeTargetIdentity).actionTargetReceipt)
        // Failure attribution retains request authority, not proof of delivery to the reported target.
        #expect(meta["target_receipt"] == authorizedReceipt)
        #expect(meta["target_receipt"] != conflictingReceipt)
        #expect(meta["target_identity"] == nil)
        guard case let .text(message, _, _)? = response.content.first else {
            Issue.record("Expected conflicting paste target error")
            return
        }
        #expect(message.contains("target different from its authorization"))
    }

    @Test
    @MainActor
    func `safe background application readiness cancels conditional mutation preparation`() async throws {
        let applications = Run50SafeLaunchApplicationService(application: Self.application)
        let coordinator = Run50MutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            snapshotMutationCoordinator: coordinator,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: AppTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "launch",
                "name": "TextEdit",
            ]))

        #expect(!response.isError)
        #expect(applications.recordedLaunchRequests.map(\.applicationIdentifier) == ["PID:89"])
        #expect(coordinator.prepareCount == 1)
        #expect(coordinator.cancelCount == 1)
        #expect(coordinator.completeCount == 0)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string(DesktopActionOutcome.State.confirmedNoChange.rawValue))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["target_identity"]?.objectValue?["pid"] == .int(89))
    }

    @Test
    @MainActor
    func `contradictory background readiness dispatch invalidates snapshots`() async throws {
        let applications = Run50SafeLaunchApplicationService(
            application: Self.application,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one))
        let coordinator = Run50MutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            snapshotMutationCoordinator: coordinator,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: AppTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "launch",
                "name": "TextEdit",
            ]))

        #expect(response.isError)
        #expect(coordinator.prepareCount == 1)
        #expect(coordinator.cancelCount == 0)
        #expect(coordinator.completeCount == 1)
        #expect(coordinator.completionSucceeded == [false])
        let projection = try #require(
            MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta).projection)
        #expect(projection.state == DesktopActionOutcome.State.indeterminate)
        #expect(projection.dispatchState.mutationDispatched)
        #expect(projection.retrySafety == DesktopActionOutcome.RetrySafety.unsafe)
    }

    @Test
    @MainActor
    func `nested Agent is classified only for background authority`() async throws {
        let counter = Run50InvocationCounter()
        let backgroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let allowed = try await backgroundContext.execute(
            tool: Run50OutcomeProbeTool(name: "agent", counter: counter, outcome: nil),
            arguments: ToolArguments(raw: [:]))
        #expect(!allowed.isError)
        #expect(await counter.value == 1)

        let foregroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let invalidBeforePolicy = try await foregroundContext.execute(
            tool: MCPAgentTool(context: foregroundContext),
            arguments: ToolArguments(raw: [
                "task": "invalid budget",
                "max_steps": 0,
            ]))
        #expect(invalidBeforePolicy.isError)
        #expect(invalidBeforePolicy.meta == nil)
        guard case let .text(invalidMessage, _, _)? = invalidBeforePolicy.content.first else {
            Issue.record("Expected nested Agent validation error")
            return
        }
        #expect(invalidMessage.contains("max_steps must be between"))

        let refused = try await foregroundContext.execute(
            tool: Run50OutcomeProbeTool(name: "agent", counter: counter, outcome: nil),
            arguments: ToolArguments(raw: [:]))
        #expect(refused.isError)
        #expect(await counter.value == 1)
        #expect(refused.meta?.objectValue?["error_code"] == .string(MCPToolExecutionPolicy.refusalErrorCode))

        let unrestrictedContext = await MCPToolTestHelpers.makeContext(executionPolicy: .unrestricted)
        let leafRefusal = try await unrestrictedContext.execute(
            tool: MCPAgentTool(context: unrestrictedContext),
            arguments: ToolArguments(raw: ["listSessions": true]))
        #expect(leafRefusal.isError)
        #expect(leafRefusal.meta?.objectValue?["error_code"] == .string(MCPToolExecutionPolicy.refusalErrorCode))
    }
}

@MainActor
private final class Run50PasteAutomationService: MockAutomationService,
    ScriptedUIAutomationActionOutcomeProviding
{
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(defaultResponse: .outcome(
        .confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: .one)))
    var outcomeTargetIdentity: DesktopTargetIdentity?
    var allowsContradictoryOutcomeTargetIdentityForTesting = false

    var uiAutomationOutcomeTargetIdentity: DesktopTargetIdentity? {
        self.outcomeTargetIdentity
    }

    init() {
        super.init(accessibilityGranted: true)
    }
}

private struct Run50OutcomeProbeTool: MCPTool {
    let name: String
    let counter: Run50InvocationCounter
    let outcome: DesktopActionOutcome?
    let metaOverride: Value?
    let description = "Run50 policy probe"

    init(
        name: String,
        counter: Run50InvocationCounter,
        outcome: DesktopActionOutcome?,
        metaOverride: Value? = nil)
    {
        self.name = name
        self.counter = counter
        self.outcome = outcome
        self.metaOverride = metaOverride
    }

    var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "app": SchemaBuilder.string(),
                "text": SchemaBuilder.string(),
            ],
            required: [])
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.counter.increment()
        if let metaOverride {
            return ToolResponse.text("invoked", meta: metaOverride)
        }
        guard let outcome else { return ToolResponse.text("invoked") }
        return try ToolResponse.text(
            "invoked",
            meta: MCPToolResponseMetadataProjector.metadata(outcome: outcome))
    }
}

private actor Run50InvocationCounter {
    private(set) var value = 0

    func increment() {
        self.value += 1
    }
}

@MainActor
private final class Run50SafeLaunchApplicationService: MockApplicationService,
    ApplicationServiceActionResultProviding
{
    private let application: ServiceApplicationInfo
    private let outcome: DesktopActionOutcome?
    private(set) var recordedLaunchRequests: [ApplicationLaunchRequest] = []

    init(
        application: ServiceApplicationInfo,
        outcome: DesktopActionOutcome? = .confirmedNoChange())
    {
        self.application = application
        self.outcome = outcome
        super.init(applications: [application])
    }

    func launchApplicationActionResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        self.recordedLaunchRequests.append(request)
        return DesktopActionResult(
            payload: self.application,
            outcome: self.outcome)
    }

    func relaunchApplicationActionResult(
        request _: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        throw PeekabooError.notImplemented("Run50 relaunch")
    }

    func activateApplicationActionResult(
        request _: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        throw PeekabooError.notImplemented("Run50 activate")
    }

    func quitApplicationActionResult(
        request _: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        throw PeekabooError.notImplemented("Run50 quit")
    }

    func hideApplicationActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        throw PeekabooError.notImplemented("Run50 hide")
    }

    func unhideApplicationActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        throw PeekabooError.notImplemented("Run50 unhide")
    }
}

@MainActor
private final class Run50MutationCoordinator: MCPToolSnapshotMutationCoordinating {
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private(set) var completeCount = 0
    private(set) var completionSucceeded: [Bool] = []

    func prepareMutation(_: MCPToolSnapshotMutationScope) throws {
        self.prepareCount += 1
    }

    func cancelMutation(_: MCPToolSnapshotMutationScope) async -> Bool {
        self.cancelCount += 1
        return true
    }

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded: Bool) async -> Bool {
        self.completeCount += 1
        self.completionSucceeded.append(succeeded)
        return true
    }
}
