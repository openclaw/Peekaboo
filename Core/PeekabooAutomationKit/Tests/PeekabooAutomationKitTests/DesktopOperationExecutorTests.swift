import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DesktopOperationExecutorTests {
    @Test
    func `v4 initializer remains conservative and current result round trips`() throws {
        let legacy = UIInputExecutionResult(
            verb: .click,
            strategy: .actionFirst,
            path: .action,
            actionName: "AXPress")
        #expect(legacy.outcome.state == .indeterminate)
        #expect(legacy.outcome.retrySafety == .unsafe)

        let current = UIInputExecutionResult(
            outcome: Self.actionOutcome,
            verb: .click,
            strategy: .actionFirst,
            path: .action,
            actionName: "AXPress")
        let decoded = try JSONDecoder().decode(
            UIInputExecutionResult.self,
            from: JSONEncoder().encode(current))
        #expect(decoded == current)
    }

    @Test
    func `v4 payload without outcome decodes conservatively`() throws {
        let data = Data(#"{"verb":"click","strategy":"actionFirst","path":"action","duration":0.25}"#.utf8)

        let result = try JSONDecoder().decode(UIInputExecutionResult.self, from: data)

        #expect(result.duration == 0.25)
        #expect(result.outcome.state == .indeterminate)
        #expect(result.outcome.evidence == .completionUnknown)
        #expect(result.outcome.dispatchState == .mayHaveDispatched(unitCount: nil))
        #expect(result.outcome.retrySafety == .unsafe)
    }

    @Test
    func `action first selects action and does not inspect synthesis requirements`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = DesktopOperationExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root))
        var actionPreflightCount = 0
        var synthesisPreflightCount = 0
        let plan = try self.makePlan(
            strategy: .actionFirst,
            action: .init(
                requirements: .accessibilityAction,
                preflight: { actionPreflightCount += 1 },
                execute: {
                    UIInputExecutionResult.Action(
                        outcome: Self.actionOutcome,
                        actionName: "AXPress",
                        elementRole: "AXButton")
                }),
            synthesis: .init(
                requirements: .globalEvents,
                preflight: { synthesisPreflightCount += 1 },
                execute: { Self.synthOutcome }))

        let result = try await executor.execute(plan)

        #expect(result.path == .action)
        #expect(result.actionName == "AXPress")
        #expect(actionPreflightCount == 1)
        #expect(synthesisPreflightCount == 0)
    }

    @Test
    func `eligible action gap falls back once and preserves reason`() async throws {
        var synthesisCount = 0
        let plan = try self.makePlan(
            strategy: .actionFirst,
            action: .init(requirements: .accessibilityAction) {
                throw ActionInputError.unsupported(.actionUnsupported)
            },
            synthesis: .init(requirements: .globalEvents) {
                synthesisCount += 1
                return Self.synthOutcome
            })

        let result = try await DesktopOperationExecutor().execute(plan)

        #expect(result.path == .synth)
        #expect(result.fallbackReason == .actionUnsupported)
        #expect(synthesisCount == 1)
    }

    @Test
    func `action only and synth first never invoke the other route`() async throws {
        var actionCount = 0
        var synthesisCount = 0
        let action = DesktopOperationPlan.ActionRoute(requirements: .accessibilityAction) {
            actionCount += 1
            return UIInputExecutionResult.Action(outcome: Self.actionOutcome)
        }
        let synthesis = DesktopOperationPlan.SynthesisRoute(requirements: .globalEvents) {
            synthesisCount += 1
            return Self.synthOutcome
        }

        let actionOnly = try self.makePlan(strategy: .actionOnly, action: action, synthesis: synthesis)
        let actionResult = try await DesktopOperationExecutor().execute(actionOnly)
        #expect(actionResult.path == .action)
        #expect(actionCount == 1)
        #expect(synthesisCount == 0)

        let synthFirst = try self.makePlan(strategy: .synthFirst, action: action, synthesis: synthesis)
        let synthResult = try await DesktopOperationExecutor().execute(synthFirst)
        #expect(synthResult.path == .synth)
        #expect(actionCount == 1)
        #expect(synthesisCount == 1)
    }

    @Test
    func `permission and stale failures never fall back`() async {
        for failure in [ActionInputError.permissionDenied, .staleElement, .targetUnavailable] {
            var synthesisCount = 0
            do {
                let plan = try self.makePlan(
                    strategy: .actionFirst,
                    action: .init(requirements: .accessibilityAction) { throw failure },
                    synthesis: .init(requirements: .globalEvents) {
                        synthesisCount += 1
                        return Self.synthOutcome
                    })
                _ = try await DesktopOperationExecutor().execute(plan)
                Issue.record("Expected action failure")
            } catch let error as ActionInputError {
                #expect(error == failure)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            #expect(synthesisCount == 0)
        }
    }

    @Test
    func `post-dispatch failure is propagated without replay`() async {
        var dispatchCount = 0
        do {
            let plan = try self.makePlan(
                strategy: .synthOnly,
                action: nil,
                synthesis: .init(requirements: .globalEvents) {
                    dispatchCount += 1
                    throw DesktopActionFailure.dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        message: "Completion validation failed")
                })
            _ = try await DesktopOperationExecutor().execute(plan)
            Issue.record("Expected canonical post-dispatch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(dispatchCount == 1)
    }

    @Test
    func `postvalidation can downgrade dispatched evidence before finalization`() async {
        var dispatchCount = 0
        var finalizerCount = 0
        do {
            let plan = try self.makePlan(
                strategy: .synthOnly,
                action: nil,
                synthesis: .init(requirements: .globalEvents) {
                    dispatchCount += 1
                    return Self.synthOutcome
                },
                postvalidate: { result in
                    throw DesktopActionFailure.indeterminate(
                        delivery: result.outcome.delivery,
                        evidence: .completionUnknown,
                        message: "Post-read failed")
                },
                finalize: { finalizerCount += 1 })
            _ = try await DesktopOperationExecutor().execute(plan)
            Issue.record("Expected postvalidation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(dispatchCount == 1)
        #expect(finalizerCount == 1)
    }

    @Test
    func `executor holds exactly one lane around preparation route and validation`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let executor = DesktopOperationExecutor(laneCoordinator: coordinator)
        var phases: [String] = []
        let plan = try self.makePlan(
            strategy: .synthOnly,
            prepare: {
                phases.append("prepare")
                await #expect(throws: DesktopOperationLaneError.self) {
                    try await coordinator.run(scope: .global, access: .write) { true }
                }
            },
            action: nil,
            synthesis: .init(requirements: .globalEvents) {
                phases.append("execute")
                return Self.synthOutcome
            },
            postvalidate: { _ in
                phases.append("postvalidate")
                await #expect(throws: DesktopOperationLaneError.self) {
                    try await coordinator.run(scope: .global, access: .write) { true }
                }
            },
            finalize: {
                phases.append("finalize")
                await #expect(throws: DesktopOperationLaneError.self) {
                    try await coordinator.run(scope: .global, access: .write) { true }
                }
            })

        _ = try await executor.execute(plan)
        #expect(phases == ["prepare", "execute", "postvalidate", "finalize"])
    }

    @Test
    func `routing is resolved after lane owned preparation`() async throws {
        var preparedBundle: String?
        var actionCount = 0
        var synthesisCount = 0
        let plan = try DesktopOperationPlan(
            verb: .performAction,
            selector: .focused,
            captureReceipt: DesktopOperationPlan.CaptureReceipt(),
            deliveryIntent: .foreground,
            strategy: .actionOnly,
            prepare: { preparedBundle = "com.example.synth-only" },
            routing: {
                DesktopOperationPlan.Routing(
                    strategy: preparedBundle == nil ? .actionOnly : .synthOnly,
                    bundleIdentifier: preparedBundle)
            },
            action: .init(requirements: .accessibilityAction) {
                actionCount += 1
                return UIInputExecutionResult.Action(outcome: Self.actionOutcome)
            },
            synthesis: .init(requirements: .globalEvents) {
                synthesisCount += 1
                return Self.synthOutcome
            })

        let result = try await DesktopOperationExecutor().execute(plan)

        #expect(result.path == .synth)
        #expect(result.bundleIdentifier == "com.example.synth-only")
        #expect(actionCount == 0)
        #expect(synthesisCount == 1)
    }

    @Test
    func `finalizer runs once under the lane when preparation fails`() async {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let executor = DesktopOperationExecutor(laneCoordinator: coordinator)
        var finalizerCount = 0
        do {
            let plan = try self.makePlan(
                strategy: .synthOnly,
                prepare: { throw ActionInputError.staleElement },
                action: nil,
                synthesis: .init(requirements: .globalEvents) { Self.synthOutcome },
                finalize: {
                    finalizerCount += 1
                    await #expect(throws: DesktopOperationLaneError.self) {
                        try await coordinator.run(scope: .global, access: .write) { true }
                    }
                })
            _ = try await executor.execute(plan)
            Issue.record("Expected preparation failure")
        } catch let error as ActionInputError {
            #expect(error == .staleElement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(finalizerCount == 1)
    }

    @Test
    func `injected hotkey service resolves target through UI service lane`() async throws {
        let root = Self.temporaryRoot()
        let otherRoot = Self.temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: otherRoot)
        }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let executor = DesktopOperationExecutor(laneCoordinator: coordinator)
        let blocker = LaneBlocker()
        var resolverCount = 0
        let injected = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            runningApplicationResolver: { _ in
                resolverCount += 1
                return nil
            },
            desktopOperationExecutor: DesktopOperationExecutor(
                laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: otherRoot)))
        let service = UIAutomationService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            actionInputDriver: ActionInputDriver(),
            automationElementResolver: AutomationElementResolver(),
            hotkeyService: injected,
            operationLaneCoordinator: coordinator,
            desktopOperationExecutor: executor)
        let holder = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await blocker.hold()
                return true
            }
        }
        await blocker.waitUntilHeld()
        let operation = Task {
            try await service.hotkey(keys: "cmd,k", holdDuration: 0, targetProcessIdentifier: 999_999)
        }

        try await Task.sleep(for: .milliseconds(60))
        #expect(resolverCount == 0)
        await blocker.release()
        _ = try await holder.value
        do {
            try await operation.value
            Issue.record("Expected unavailable hotkey target")
        } catch {}
        #expect(resolverCount == 1)
    }

    @Test
    func `secure input probe runs after lane admission and returns with execution`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let executor = DesktopOperationExecutor(laneCoordinator: coordinator)
        let blocker = LaneBlocker()
        var probeCount = 0
        var feedbackPreparationCount = 0
        let service = TypeService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in
                probeCount += 1
                return true
            },
            desktopOperationExecutor: executor)
        let holder = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await blocker.hold()
                return true
            }
        }
        await blocker.waitUntilHeld()
        let operation = Task {
            try await service.typeTrackingSecureInput(
                text: "",
                target: nil,
                clearExisting: false,
                typingDelay: 0,
                snapshotId: nil,
                lanePreparation: { feedbackPreparationCount += 1 })
        }

        try await Task.sleep(for: .milliseconds(60))
        #expect(probeCount == 0)
        #expect(feedbackPreparationCount == 0)
        await blocker.release()
        _ = try await holder.value
        let summary = try await operation.value
        #expect(probeCount == 1)
        #expect(feedbackPreparationCount == 1)
        #expect(summary.typedIntoSecureField)
    }

    @Test
    func `queued click captures feedback inputs only after lane admission`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let blocker = LaneBlocker()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ClickService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: coordinator))
        var preparationCount = 0
        let holder = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await blocker.hold()
                return true
            }
        }
        await blocker.waitUntilHeld()
        let operation = Task {
            try await service.clickWithLanePreparation(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                lanePreparation: { preparationCount += 1 })
        }

        try await Task.sleep(for: .milliseconds(60))
        #expect(preparationCount == 0)
        await blocker.release()
        _ = try await holder.value
        _ = try await operation.value
        #expect(preparationCount == 1)
    }

    @Test
    func `queued hotkey captures feedback window only after lane admission`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let blocker = LaneBlocker()
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .actionOnly),
            frontmostApplicationResolver: { nil },
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: coordinator))
        var preparationCount = 0
        let holder = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await blocker.hold()
                return true
            }
        }
        await blocker.waitUntilHeld()
        let operation = Task {
            try await service.hotkeyWithLanePreparation(keys: "cmd,k", holdDuration: 0) {
                preparationCount += 1
            }
        }

        try await Task.sleep(for: .milliseconds(60))
        #expect(preparationCount == 0)
        await blocker.release()
        _ = try await holder.value
        do {
            _ = try await operation.value
            Issue.record("Expected missing foreground application")
        } catch {}
        #expect(preparationCount == 1)
    }

    @Test
    func `queued scroll captures feedback window only after lane admission`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let blocker = LaneBlocker()
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = ScrollService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: synthetic,
            desktopOperationExecutor: DesktopOperationExecutor(laneCoordinator: coordinator))
        var preparationCount = 0
        let holder = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await blocker.hold()
                return true
            }
        }
        await blocker.waitUntilHeld()
        let operation = Task {
            try await service.scrollWithLanePreparation(ScrollRequest(
                direction: .down,
                amount: 1,
                target: nil,
                smooth: false,
                delay: 0,
                foreground: true))
            {
                preparationCount += 1
            }
        }

        try await Task.sleep(for: .milliseconds(60))
        #expect(preparationCount == 0)
        await blocker.release()
        _ = try await holder.value
        _ = try await operation.value
        #expect(preparationCount == 1)
        #expect(synthetic.events.contains { event in
            if case .scroll = event {
                return true
            }
            return false
        })
    }

    @Test
    func `public v4 click adapter uses the shared executor without nested acquisition`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let executor = DesktopOperationExecutor(laneCoordinator: coordinator)
        let synthetic = ClickRecordingSyntheticInputDriver()
        let service = UIAutomationService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            actionInputDriver: ActionInputDriver(),
            syntheticInputDriver: synthetic,
            automationElementResolver: AutomationElementResolver(),
            operationLaneCoordinator: coordinator,
            desktopOperationExecutor: executor)

        try await service.click(
            target: .coordinates(CGPoint(x: 20, y: 30)),
            clickType: .single,
            snapshotId: nil)

        #expect(synthetic.events == [
            .click(point: CGPoint(x: 20, y: 30), button: .left, count: 1),
        ])
    }

    @Test
    func `different process lanes overlap while identical process lanes serialize`() async throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = DesktopOperationExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root))
        let overlap = OverlapProbe(expectedConcurrentEntries: 2)
        let firstIdentity = ApplicationProcessIdentity(processIdentifier: 501, processStartIdentity: 1)
        let secondIdentity = ApplicationProcessIdentity(processIdentifier: 502, processStartIdentity: 1)
        let first = try self.processPlan(identity: firstIdentity, probe: overlap)
        let second = try self.processPlan(identity: secondIdentity, probe: overlap)

        async let firstResult = executor.execute(first)
        async let secondResult = executor.execute(second)
        _ = try await (firstResult, secondResult)
        #expect(await overlap.maximumConcurrentEntries == 2)

        let serialized = SerialProbe()
        let sameFirst = try self.processPlan(identity: firstIdentity, serialProbe: serialized)
        let sameSecond = try self.processPlan(identity: firstIdentity, serialProbe: serialized)
        let firstTask = Task { try await executor.execute(sameFirst) }
        await serialized.waitUntilFirstEntered()
        let secondTask = Task { try await executor.execute(sameSecond) }
        try await Task.sleep(for: .milliseconds(60))
        #expect(await serialized.entryCount == 1)
        await serialized.releaseFirst()
        _ = try await (firstTask.value, secondTask.value)
        #expect(await serialized.maximumConcurrentEntries == 1)
    }

    private func makePlan(
        strategy: UIInputStrategy,
        receipt: DesktopOperationPlan.CaptureReceipt? = nil,
        prepare: @escaping @MainActor () async throws -> Void = {},
        action: DesktopOperationPlan.ActionRoute?,
        synthesis: DesktopOperationPlan.SynthesisRoute,
        postvalidate: @escaping @MainActor (UIInputExecutionResult) async throws -> Void = { _ in },
        finalize: @escaping @MainActor () async -> Void = {}) throws
        -> DesktopOperationPlan
    {
        try DesktopOperationPlan(
            verb: .click,
            selector: .focused,
            captureReceipt: receipt ?? DesktopOperationPlan.CaptureReceipt(),
            deliveryIntent: receipt?.processIdentity == nil ? .foreground : .background,
            strategy: strategy,
            prepare: prepare,
            action: action,
            synthesis: synthesis,
            postvalidate: postvalidate,
            finalize: finalize)
    }

    private func processPlan(
        identity: ApplicationProcessIdentity,
        probe: OverlapProbe? = nil,
        serialProbe: SerialProbe? = nil) throws -> DesktopOperationPlan
    {
        let receipt = try DesktopOperationPlan.CaptureReceipt(processIdentity: identity)
        return try self.makePlan(
            strategy: .synthOnly,
            receipt: receipt,
            action: nil,
            synthesis: .init(requirements: .processTargetedEvents) {
                if let probe {
                    await probe.enterAndWait()
                }
                if let serialProbe {
                    await serialProbe.enterAndWait()
                }
                return Self.synthOutcome
            })
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-operation-executor-\(UUID().uuidString)", isDirectory: true)
    }

    private static let actionOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .accessibilityAction, mode: .background),
        evidence: .deliveryAccepted)
    private static let synthOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .globalEvents, mode: .foreground),
        evidence: .deliveryAccepted)
}

private actor LaneBlocker {
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        self.held = true
        let waiters = self.heldWaiters
        self.heldWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !self.held else { return }
        await withCheckedContinuation { self.heldWaiters.append($0) }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}

private actor OverlapProbe {
    private let expectedConcurrentEntries: Int
    private var activeEntries = 0
    private var maximumEntries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(expectedConcurrentEntries: Int) {
        self.expectedConcurrentEntries = expectedConcurrentEntries
    }

    var maximumConcurrentEntries: Int {
        self.maximumEntries
    }

    func enterAndWait() async {
        self.activeEntries += 1
        self.maximumEntries = max(self.maximumEntries, self.activeEntries)
        if self.activeEntries < self.expectedConcurrentEntries {
            await withCheckedContinuation { self.waiters.append($0) }
        } else {
            let waiters = self.waiters
            self.waiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        self.activeEntries -= 1
    }
}

private actor SerialProbe {
    private var activeEntries = 0
    private var maximumEntries = 0
    private var entries = 0
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    var entryCount: Int {
        self.entries
    }

    var maximumConcurrentEntries: Int {
        self.maximumEntries
    }

    func enterAndWait() async {
        self.activeEntries += 1
        self.entries += 1
        self.maximumEntries = max(self.maximumEntries, self.activeEntries)
        if self.entries == 1 {
            let waiters = self.firstEntryWaiters
            self.firstEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { self.releaseContinuation = $0 }
        }
        self.activeEntries -= 1
    }

    func waitUntilFirstEntered() async {
        guard self.entries == 0 else { return }
        await withCheckedContinuation { self.firstEntryWaiters.append($0) }
    }

    func releaseFirst() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}
