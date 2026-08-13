import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct MCPCompositeActionOutcomeTests {
    @Test
    @MainActor
    func `press preserves emitted units for a canonical dispatched failure`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["emitted_units"] == .int(2))
    }

    @Test
    func `press compatibility excludes setup focus from emitted units`() {
        let leafFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Chord completion unknown")
        let aggregate = PressTool.aggregateSequenceFailure(
            leafFailure,
            progress: PressSequenceProgress(),
            setupFocusCompleted: true)
        let compatibility = PressFailureCompatibility(
            progress: PressSequenceProgress(),
            leafFailure: leafFailure)

        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(compatibility.fields["emitted_units"] == .int(2))
    }

    @Test
    func `press compatibility preserves known prior units when the failing count is unknown`() {
        var progress = PressSequenceProgress()
        progress.record(outcome: .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)))
        let failure = DesktopActionFailure.indeterminate(
            delivery: nil,
            evidence: .completionUnknown,
            unitCount: nil,
            message: "Chord completion unknown")

        let compatibility = PressFailureCompatibility(
            progress: progress,
            leafFailure: failure)

        #expect(compatibility.fields["emitted_units"] == .int(1))
    }

    @Test
    func `press compatibility preserves an unknown first leaf emitted count`() {
        let failure = DesktopActionFailure.indeterminate(
            delivery: nil,
            evidence: .completionUnknown,
            unitCount: nil,
            message: "Chord completion unknown")

        let compatibility = PressFailureCompatibility(
            progress: PressSequenceProgress(),
            leafFailure: failure)

        #expect(compatibility.fields["emitted_units"] == .null)
    }

    @Test
    func `press compatibility omits setup-only dispatch from emitted units`() {
        let failure = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Chord was refused")

        let compatibility = PressFailureCompatibility(
            progress: PressSequenceProgress(),
            leafFailure: failure)

        #expect(compatibility.fields.isEmpty)
    }

    @Test
    @MainActor
    func `successful dispatched press invalidates the session implicit snapshot`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground))
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: MCPToolSnapshotOwner())
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `legacy successful press invalidates the session implicit snapshot`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: MCPToolSnapshotOwner())
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `confirmed no change press preserves the session implicit snapshot`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedNoChange()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: MCPToolSnapshotOwner())
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: nil)?.id == snapshotID)
    }

    @Test
    func `confirmed no change press does not fabricate dispatch before refusal`() {
        var progress = PressSequenceProgress()
        progress.record(outcome: .confirmedNoChange())
        let leafFailure = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Second chord was refused")

        let aggregate = PressTool.aggregateSequenceFailure(
            leafFailure,
            progress: progress,
            setupFocusCompleted: false)

        #expect(aggregate == leafFailure)
        #expect(aggregate.outcome.state == .refused)
        #expect(aggregate.outcome.dispatchState.mutationDispatched == false)
    }

    @Test
    func `non dispatched leaf does not erase prior homogeneous route and delivery`() {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .globalEvents,
            mode: .foreground)
        var progress = PressSequenceProgress()
        progress.record(outcome: .confirmedChange(
            route: .bridge,
            delivery: delivery))
        let leafFailure = DesktopActionFailure.refused(
            route: .local,
            reason: .permissionDenied,
            message: "Second chord was refused")

        let aggregate = PressTool.aggregateSequenceFailure(
            leafFailure,
            progress: progress,
            setupFocusCompleted: false)

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.route == .bridge)
        #expect(aggregate.outcome.delivery == delivery)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 1)
    }

    @Test
    func `no change press route does not erase dispatched route`() {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .globalEvents,
            mode: .foreground)
        var progress = PressSequenceProgress()
        progress.record(outcome: .confirmedNoChange(route: .bridge))
        progress.record(outcome: .confirmedChange(
            route: .local,
            delivery: delivery))

        let aggregate = progress.aggregateSuccess(setupFocusCompleted: false)

        #expect(aggregate?.state == .confirmedChange)
        #expect(aggregate?.route == .local)
        #expect(aggregate?.delivery == delivery)
        #expect(aggregate?.dispatchState.unitCount?.rawValue == 1)
    }

    @Test
    func `no change typing leaf preserves dispatched focus outcome`() {
        let focus = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background))

        let aggregate = TypeTool.aggregateTypingSuccess(
            .confirmedNoChange(route: .local),
            after: TypeFocusResult(completed: true, outcome: focus))

        #expect(aggregate == focus)
    }

    @Test
    func `heterogeneous all no change typing has no aggregate route`() {
        let aggregate = TypeTool.aggregateTypingSuccess(
            .confirmedNoChange(route: .local),
            after: TypeFocusResult(
                completed: true,
                outcome: .confirmedNoChange(route: .bridge)))

        #expect(aggregate == nil)
    }

    @Test
    func `predispatch typing refusal retains dispatched focus route`() {
        let focus = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let refusal = DesktopActionFailure.refused(
            route: .local,
            reason: .permissionDenied,
            message: "Typing was refused")

        let aggregate = TypeTool.aggregateTypingFailure(
            refusal,
            after: TypeFocusResult(completed: true, outcome: focus))

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.route == .bridge)
        #expect(aggregate.outcome.delivery == nil)
    }

    @Test
    func `unknown typing units remain unknown after dispatched focus`() {
        let focus = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let error = InputDeliveryIndeterminateError(
            operation: .type,
            emittedUnitCount: nil,
            causeDescription: "completion unknown")

        let aggregate = TypeTool.aggregateIndeterminateTypingError(
            error,
            after: TypeFocusResult(completed: true, outcome: focus))

        #expect(aggregate.emittedUnitCount == nil)
    }

    @Test
    func `unknown failed press units remain unknown after prior dispatch`() {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .globalEvents,
            mode: .foreground)
        var progress = PressSequenceProgress()
        progress.record(outcome: .confirmedChange(delivery: delivery))
        let failure = DesktopActionFailure.indeterminate(
            delivery: delivery,
            evidence: .completionUnknown,
            unitCount: nil,
            message: "Chord completion unknown")

        let aggregate = PressTool.aggregateSequenceFailure(
            failure,
            progress: progress,
            setupFocusCompleted: false)

        #expect(aggregate.outcome.dispatchState.unitCount == nil)
    }

    @Test
    func `unknown failed typing units remain unknown after focus`() {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .processTargetedEvents,
            mode: .background)
        let focus = DesktopActionOutcome.confirmedChange(delivery: delivery)
        let failure = DesktopActionFailure.indeterminate(
            delivery: delivery,
            evidence: .completionUnknown,
            unitCount: nil,
            message: "Typing completion unknown")

        let aggregate = TypeTool.aggregateTypingFailure(
            failure,
            after: TypeFocusResult(completed: true, outcome: focus))

        #expect(aggregate.outcome.dispatchState.unitCount == nil)
    }
}
