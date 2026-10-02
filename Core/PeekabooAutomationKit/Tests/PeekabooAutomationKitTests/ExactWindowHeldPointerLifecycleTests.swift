import CoreGraphics
import Foundation
import os
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct ExactWindowHeldPointerLifecycleTests {
    @Test
    func `release and revoke race performs exactly one cleanup`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)

        async let release = fixture.lifecycle.release(owner: owner, receipt: started.payload)
        async let revoke = fixture.lifecycle.revoke(owner: owner, receipt: started.payload)
        let (releaseResult, revokeResult) = try await (release, revoke)

        #expect(releaseResult == revokeResult)
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(releaseResult.cleanupOutcome.dispatchState.unitCount?.rawValue == 1)
        #expect(releaseResult.lifecycleDispatchedUnitCount == 3)
    }

    @Test
    func `terminal retry returns the retained result without another cleanup`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)

        let first = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        let retry = try await fixture.lifecycle.revoke(owner: owner, receipt: started.payload)

        #expect(retry == first)
        #expect(fixture.lifecycle.retainedHoldCountForTesting == 1)
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @Test
    func `terminal retention evicts oldest completed holds at capacity`() async throws {
        let fixture = self.makeFixture(terminalRetentionCapacity: 2)
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        var receipts: [ExactWindowHeldPointerReceipt] = []
        for _ in 0..<3 {
            let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
            receipts.append(started.payload)
            _ = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
            fixture.state.now = fixture.state.now.addingTimeInterval(1)
        }

        #expect(fixture.lifecycle.retainedHoldCountForTesting == 2)
        await #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try await fixture.lifecycle.release(owner: owner, receipt: receipts[0])
        }
        _ = try await fixture.lifecycle.release(owner: owner, receipt: receipts[2])
        #expect(fixture.state.postedTypes.filter { $0 == .leftMouseUp }.count == 3)
    }

    @Test
    func `terminal retention expires without affecting active owners`() async throws {
        let fixture = self.makeFixture(terminalRetentionDuration: 1)
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        _ = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        fixture.state.now = fixture.state.now.addingTimeInterval(2)

        await #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        }
        #expect(fixture.lifecycle.retainedHoldCountForTesting == 0)
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 1)
    }

    @Test
    func `held pointer excludes another writer from the same window lane`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        let probe = MainActorFlag()
        let contender = Task { @MainActor in
            try await fixture.coordinator.run(scope: .window(fixture.identity), access: .write) {
                probe.set()
            }
        }

        try await Task.sleep(for: .milliseconds(30))
        #expect(!probe.value)
        _ = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        try await contender.value
        #expect(probe.value)
    }

    @Test
    func `wrong owner refuses without dispatch`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let wrongOwner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)

        await #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try await fixture.lifecycle.release(owner: wrongOwner, receipt: started.payload)
        }
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown])
        _ = try await fixture.lifecycle.revoke(owner: owner, receipt: started.payload)
    }

    @Test
    func `wrong hold token refuses without dispatch`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        let forged = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: fixture.request,
            expiresAt: started.payload.expiresAt)

        await #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try await fixture.lifecycle.release(owner: owner, receipt: forged)
        }
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown])
        _ = try await fixture.lifecycle.revoke(owner: owner, receipt: started.payload)
    }

    @Test
    func `watchdog expiry releases once and retains terminal result`() async throws {
        let fixture = self.makeFixture(expiresAfter: 0.05)
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        fixture.state.now = fixture.state.now.addingTimeInterval(-3600)
        fixture.state.monotonicNow = fixture.state.monotonicNow.advanced(by: .seconds(1))

        await self.waitForEventCount(3, state: fixture.state)
        let terminal = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        #expect(terminal.reason == .expired)
        #expect(terminal.lifecycleDispatchedUnitCount == 3)
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @Test
    func `window drift triggers one generation-bound cleanup`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        fixture.state.routeIsCurrent = false

        await self.waitForEventCount(3, state: fixture.state)
        let terminal = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        #expect(terminal.reason == .windowChanged)
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @Test
    func `process generation drift never sends cleanup to recycled PID`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        fixture.state.processGenerationIsCurrent = false

        await self.waitForTerminalSignal(fixture)
        do {
            _ = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
            Issue.record("Expected terminal cleanup failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.causeDescription?.contains("recycled PID") == true)
        }
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown])
    }

    @Test
    func `explicit owner disconnect releases active hold once`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)

        let terminal = try #require(try await fixture.lifecycle.disconnect(owner: owner))
        #expect(terminal.reason == .ownerDisconnected)
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(try await fixture.lifecycle.release(owner: owner, receipt: started.payload) == terminal)
        #expect(fixture.lifecycle.retainedHoldCountForTesting == 1)
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
        await #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try await fixture.lifecycle.disconnect(owner: owner)
        }
    }

    @Test
    func `disconnect closes an idle owner and releases owner capacity`() async throws {
        let fixture = self.makeFixture(ownerCapacity: 1)
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 1)

        let terminal = try await fixture.lifecycle.disconnect(owner: owner)
        #expect(terminal == nil)
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
        _ = try fixture.lifecycle.createOwner(boundTo: nil)
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 1)
    }

    @Test
    func `owner capacity fails closed instead of growing without bound`() throws {
        let fixture = self.makeFixture(ownerCapacity: 1)
        _ = try fixture.lifecycle.createOwner(boundTo: nil)

        #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try fixture.lifecycle.createOwner(boundTo: nil)
        }
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 1)
    }

    @Test
    func `bound owner process exit is treated as disconnect`() async throws {
        let fixture = self.makeFixture()
        let client = ApplicationProcessIdentity(
            processIdentifier: 55001,
            processStartIdentity: 9)
        fixture.state.clientGeneration = 9
        let owner = try fixture.lifecycle.createOwner(boundTo: client)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        fixture.state.clientGeneration = 10

        await self.waitForEventCount(3, state: fixture.state)
        let terminal = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        #expect(terminal.reason == .ownerDisconnected)
    }

    @Test
    func `owner disconnect queued behind lane resolves zero dispatch terminal`() async throws {
        let fixture = self.makeFixture()
        let blockerEntered = MainActorFlag()
        let unblock = MainActorGate()
        let blocker = Task { @MainActor in
            try await fixture.coordinator.run(scope: .window(fixture.identity), access: .write) {
                blockerEntered.set()
                await unblock.wait()
            }
        }
        while !blockerEntered.value {
            await Task.yield()
        }

        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let begin = Task { @MainActor in
            try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        }
        while fixture.lifecycle.retainedHoldCountForTesting == 0 {
            await Task.yield()
        }
        let disconnect = Task { @MainActor in
            try await fixture.lifecycle.disconnect(owner: owner)
        }
        await Task.yield()
        unblock.open()
        try await blocker.value

        await #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try await begin.value
        }
        let terminal = try #require(try await disconnect.value)
        #expect(terminal.reason == .ownerDisconnected)
        #expect(terminal.cleanupOutcome == .confirmedNoChange())
        #expect(terminal.lifecycleDispatchedUnitCount == 0)
        #expect(fixture.state.postedTypes.isEmpty)
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
        #expect(fixture.lifecycle.retainedHoldCountForTesting == 1)
        #expect(try await fixture.lifecycle.release(owner: owner, receipt: terminal.receipt) == terminal)
    }

    @Test
    func `cancelled begin queued behind lane emits nothing`() async throws {
        let fixture = self.makeFixture()
        let blockerEntered = MainActorFlag()
        let unblock = MainActorGate()
        let blocker = Task { @MainActor in
            try await fixture.coordinator.run(scope: .window(fixture.identity), access: .write) {
                blockerEntered.set()
                await unblock.wait()
            }
        }
        while !blockerEntered.value {
            await Task.yield()
        }

        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let begin = Task { @MainActor in
            try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        }
        begin.cancel()
        unblock.open()
        try await blocker.value

        await #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            _ = try await begin.value
        }
        #expect(fixture.state.postedTypes.isEmpty)
        #expect(fixture.lifecycle.retainedHoldCountForTesting == 1)
        fixture.state.now = fixture.state.now.addingTimeInterval(61)
        _ = try fixture.lifecycle.createOwner(boundTo: nil)
        #expect(fixture.lifecycle.retainedHoldCountForTesting == 0)
    }

    @Test
    func `cancelled begin after mouse down waits for terminal cleanup and returns no live receipt`() async throws {
        let hookEntered = MainActorFlag()
        let resumeBegin = MainActorGate()
        let fixture = self.makeFixture(beginResolutionHook: {
            hookEntered.set()
            await resumeBegin.wait()
        })
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let begin = Task { @MainActor in
            try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        }
        while !hookEntered.value {
            await Task.yield()
        }

        begin.cancel()
        resumeBegin.open()
        do {
            _ = try await begin.value
            Issue.record("Expected cancellation after mouse-down to refuse a live receipt")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
            #expect(failure.causeDescription?.contains("callerCancelled") == true)
        }
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    private func makeFixture(
        expiresAfter: TimeInterval = 10,
        beginResolutionHook: @escaping @MainActor @Sendable () async -> Void = {},
        dragSleeper: @escaping @MainActor @Sendable (Duration) async throws -> Void = { _ in },
        ownerCapacity: Int = 1024,
        terminalRetentionCapacity: Int = 256,
        terminalRetentionDuration: TimeInterval = 60) -> Fixture
    {
        let state = PointerState()
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 88,
            ownerProcessIdentifier: 44001,
            ownerProcessStartIdentity: 77,
            capturedBounds: bounds)
        let route = WindowRoutedPointerDriver.RouteReceipt(
            identity: identity,
            bounds: bounds,
            screenPoint: CGPoint(x: 80, y: 90))
        let driver = WindowRoutedPointerDriver(
            hasPostEventAccess: { state.hasPostEventAccess },
            resolveRoute: { _, _, _ in route },
            routeIsCurrent: { _ in state.routeIsCurrent },
            processGenerationIsCurrent: { _ in state.processGenerationIsCurrent },
            makeEvent: { specification, point in
                if specification.type == .leftMouseDragged || specification.type == .rightMouseDragged {
                    state.dragAttempts += 1
                    if state.dragAttempts == state.failDragSample {
                        return nil
                    }
                }
                let event = CGEvent(
                    mouseEventSource: nil,
                    mouseType: specification.type,
                    mouseCursorPosition: point,
                    mouseButton: specification.button)
                event?.flags = .maskShift
                return event
            },
            stampWindowLocation: { _, _ in true },
            postSkyLight: { _, _ in false },
            postPublic: { event, pid in
                state.postedTypes.append(event.type)
                state.postedPoints.append(event.location)
                state.postedPIDs.append(pid)
                state.postedFlags.append(event.flags)
                state.postedWindows.append(event.getIntegerValueField(CGEventField(rawValue: 91)!))
                state.afterPost?()
            },
            resolveTransport: { _ in .publicCGEvent },
            sleep: { _ in })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-pointer-tests-\(UUID().uuidString)", isDirectory: true)
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let lifecycle = ExactWindowHeldPointerLifecycle(
            laneCoordinator: coordinator,
            pointerDriver: driver,
            processStartIdentityProvider: { pid in state.generation(for: pid) },
            now: { state.now },
            monotonicNow: { state.monotonicNow },
            watchdogSleeper: { try await Task.sleep(for: .milliseconds(2)) },
            beginResolutionHook: beginResolutionHook,
            dragSleeper: dragSleeper,
            ownerCapacity: ownerCapacity,
            terminalRetentionCapacity: terminalRetentionCapacity,
            terminalRetentionDuration: terminalRetentionDuration)
        return Fixture(
            state: state,
            coordinator: coordinator,
            lifecycle: lifecycle,
            identity: identity,
            request: ExactWindowHeldPointerRequest(
                point: route.screenPoint,
                windowIdentity: identity,
                windowBounds: bounds,
                button: .left,
                expiresAfterSeconds: expiresAfter))
    }

    private func waitForEventCount(_ count: Int, state: PointerState) async {
        for _ in 0..<500 where state.postedTypes.count < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(state.postedTypes.count >= count)
    }

    private func waitForTerminalSignal(_ fixture: Fixture) async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class PointerState {
    private struct Generations: Sendable {
        var targetIsCurrent = true
        var client: UInt64? = 9
    }

    private nonisolated let generations = OSAllocatedUnfairLock(initialState: Generations())
    var postedTypes: [CGEventType] = []
    var postedPoints: [CGPoint] = []
    var postedPIDs: [pid_t] = []
    var postedFlags: [CGEventFlags] = []
    var postedWindows: [Int64] = []
    var hasPostEventAccess = true
    var dragAttempts = 0
    var failDragSample: Int?
    var afterPost: (@MainActor () -> Void)?
    var routeIsCurrent = true
    var processGenerationIsCurrent: Bool {
        get { self.generations.withLock { $0.targetIsCurrent } }
        set { self.generations.withLock { $0.targetIsCurrent = newValue } }
    }

    var clientGeneration: UInt64? {
        get { self.generations.withLock { $0.client } }
        set { self.generations.withLock { $0.client = newValue } }
    }

    var now = Date(timeIntervalSinceReferenceDate: 10000)
    var monotonicNow = ContinuousClock.now

    nonisolated func generation(for pid: pid_t) -> UInt64? {
        self.generations.withLock { generations in
            pid == 55001 ? generations.client : (generations.targetIsCurrent ? 77 : 78)
        }
    }
}

@MainActor
private final class MainActorFlag {
    private(set) var value = false
    func set() {
        self.value = true
    }
}

@MainActor
private final class MainActorGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
private struct Fixture {
    let state: PointerState
    let coordinator: DesktopOperationLaneCoordinator
    let lifecycle: ExactWindowHeldPointerLifecycle
    let identity: WindowMutationIdentity
    let request: ExactWindowHeldPointerRequest

    func dragRequest(
        steps: Int = 5,
        to: CGPoint = CGPoint(x: 180, y: 190),
        button: ExactWindowHeldPointerButton = .left) throws -> ExactWindowDragRequest
    {
        try ExactWindowDragRequest(
            snapshotID: "ps1_0123456789abcdef0123456789abcdef",
            target: UIAutomationTarget.ExactWindow(identity: self.identity, bounds: self.request.windowBounds),
            from: self.request.point,
            to: to,
            durationMilliseconds: 100,
            steps: steps,
            button: button)
    }
}

extension ExactWindowHeldPointerLifecycleTests {
    @Test(arguments: ["release", "revoke", "disconnect", "expiry"])
    func `movement racing terminal retains one current cleanup`(reason: String) async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        let firstPoint = CGPoint(x: 100, y: 110)
        let racingPoint = CGPoint(x: 120, y: 130)
        try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: firstPoint)
        let terminal = Task { @MainActor in
            switch reason {
            case "disconnect":
                return try #require(try await fixture.lifecycle.disconnect(owner: owner))
            case "revoke":
                return try await fixture.lifecycle.revoke(owner: owner, receipt: started.payload)
            case "expiry":
                fixture.state.monotonicNow = fixture.state.monotonicNow.advanced(by: .seconds(20))
                #expect(throws: (any Error).self) {
                    try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: racingPoint)
                }
                return try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
            default:
                return try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
            }
        }
        let move = Task { @MainActor in
            try? fixture.lifecycle.move(owner: owner, receipt: started.payload, to: racingPoint)
        }
        await move.value
        let result = try await terminal.value
        let dragPoints = zip(fixture.state.postedTypes, fixture.state.postedPoints)
            .filter { $0.0 == .leftMouseDragged }.map(\.1)
        #expect(fixture.state.postedPoints.last == dragPoints.last)
        #expect(fixture.state.postedTypes.filter { $0 == .leftMouseUp }.count == 1)
        #expect(result.lifecycleDispatchedUnitCount == fixture.state.postedTypes.count)
        #expect(fixture.state.postedTypes.last == .leftMouseUp)
    }

    @Test(arguments: [0, 97, Int.max])
    func `unbounded drag requests refuse before owner allocation`(steps: Int) async throws {
        let fixture = self.makeFixture()
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await fixture.lifecycle.drag(request: fixture.dragRequest(steps: steps), boundTo: nil)
        }
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
        #expect(fixture.state.postedTypes.isEmpty)
    }

    @Test(arguments: [ExactWindowHeldPointerButton.left, .right])
    func `one shot drag uses one route with exact primer down samples up count`(
        button: ExactWindowHeldPointerButton) async throws
    {
        let fixture = self.makeFixture()
        let request = try fixture.dragRequest(button: button)
        let result = try await fixture.lifecycle.drag(request: request, boundTo: nil)
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let move: CGEventType = button == .left ? .leftMouseDragged : .rightMouseDragged
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        #expect(fixture.state.postedTypes == [.mouseMoved, down] + Array(repeating: move, count: 5) + [up])
        let samplePoints = (1...5).map { CGPoint(x: 80 + $0 * 20, y: 90 + $0 * 20) }
        let expectedPoints = [request.from, request.from] + samplePoints + [request.to]
        #expect(fixture.state.postedPoints == expectedPoints)
        #expect(Set(fixture.state.postedPIDs) == [fixture.identity.ownerProcessIdentifier])
        #expect(fixture.state.postedFlags.allSatisfy { $0.rawValue == 0 })
        #expect(Set(fixture.state.postedWindows) == [Int64(fixture.identity.windowID)])
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 8)
        #expect(result.targetIdentity == DesktopTargetIdentity(exactWindow: request.target))
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
    }

    @Test(arguments: 1...5)
    func `every failing drag sample cleans up at the last accepted point`(sample: Int) async throws {
        let fixture = self.makeFixture()
        fixture.state.failDragSample = sample
        do {
            _ = try await fixture.lifecycle.drag(request: fixture.dragRequest(), boundTo: nil)
            Issue.record("Expected sample failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == sample + 2)
            #expect(failure.targetReceipt != nil)
        }
        #expect(fixture.state.postedTypes.filter { $0 == .leftMouseUp }.count == 1)
        #expect(fixture.state.postedPoints.last == CGPoint(x: 80 + (sample - 1) * 20, y: 90 + (sample - 1) * 20))
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
    }

    @Test
    func `drag cancellation waits for sole cleanup while another window makes progress`() async throws {
        let gate = MainActorGate()
        let entered = MainActorFlag()
        let fixture = self.makeFixture(dragSleeper: { _ in entered.set(); await gate.wait() })
        let request = try fixture.dragRequest()
        let task = Task { try await fixture.lifecycle.drag(request: request, boundTo: nil) }
        while !entered.value {
            await Task.yield()
        }
        let other = WindowMutationIdentity(
            windowID: 89,
            ownerProcessIdentifier: fixture.identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: fixture.identity.ownerProcessStartIdentity,
            capturedBounds: request.target.bounds)
        let independent = MainActorFlag()
        let sameWindow = MainActorFlag()
        let queued = Task { @MainActor in
            try await fixture.coordinator.run(scope: .window(fixture.identity), access: .write) { sameWindow.set() }
        }
        try await fixture.coordinator.run(scope: .window(other), access: .write) { independent.set() }
        #expect(independent.value)
        #expect(!sameWindow.value)
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            Issue.record("Expected cancelled drag")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
        }
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
        try await queued.value
        #expect(sameWindow.value)
    }

    @Test
    func `snapshot validation and invalid endpoints fail before any pointer dispatch`() async throws {
        let fixture = self.makeFixture()
        for point in [CGPoint(x: CGFloat.nan, y: 90), CGPoint(x: CGFloat.infinity, y: 90), CGPoint(x: 1000, y: 90)] {
            await #expect(throws: DesktopActionFailure.self) {
                _ = try await fixture.lifecycle.drag(request: fixture.dragRequest(to: point), boundTo: nil)
            }
        }
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await fixture.lifecycle.drag(request: fixture.dragRequest(), boundTo: nil) {
                throw DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable, message: "Stale capture")
            }
        }
        #expect(fixture.state.postedTypes.isEmpty)
        #expect(fixture.lifecycle.registeredOwnerCountForTesting == 0)
    }

    @Test
    func `one shot cancellation before begin resolves retains unverified prefix evidence`() async throws {
        let entered = MainActorFlag()
        let gate = MainActorGate()
        let fixture = self.makeFixture(beginResolutionHook: { entered.set(); await gate.wait() })
        let task = Task { try await fixture.lifecycle.drag(request: fixture.dragRequest(), boundTo: nil) }
        while !entered.value {
            await Task.yield()
        }
        task.cancel()
        gate.open()
        do {
            _ = try await task.value
            Issue.record("Expected cancelled drag")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
        }
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @Test(arguments: [true, false])
    func `one shot drag drift never claims a verified primary effect`(recycled: Bool) async throws {
        let fixture = self.makeFixture()
        fixture.state.afterPost = {
            if fixture.state.postedTypes.last == .leftMouseDragged {
                fixture.state.routeIsCurrent = false
                fixture.state.processGenerationIsCurrent = !recycled
            }
        }
        do {
            _ = try await fixture.lifecycle.drag(request: fixture.dragRequest(), boundTo: nil)
            Issue.record("Expected interrupted drag")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == (recycled ? 3 : 4))
            #expect(failure.outcome.projection.retrySafe == false)
        }
        #expect(fixture.state.postedTypes.filter { $0 == .leftMouseUp }.count == (recycled ? 0 : 1))
        fixture.state.afterPost = nil
    }

    @Test(arguments: [true, false])
    func `movement after route drift cleans original generation at last accepted point`(recycled: Bool) async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        let accepted = CGPoint(x: 100, y: 110)
        try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: accepted)
        fixture.state.routeIsCurrent = false
        fixture.state.processGenerationIsCurrent = !recycled
        #expect(throws: (any Error).self) {
            try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: CGPoint(x: 120, y: 130))
        }
        do {
            let terminal = try await fixture.lifecycle.revoke(owner: owner, receipt: started.payload)
            #expect(!recycled)
            #expect(terminal.lifecycleDispatchedUnitCount == 4)
            #expect(fixture.state.postedPoints.last == accepted)
        } catch let failure as DesktopActionFailure {
            #expect(recycled)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
        }
        #expect(fixture.state.postedTypes.filter { $0 == .leftMouseUp }.count == (recycled ? 0 : 1))
    }

    @Test
    func `owner forgery invalid coordinates and terminal movement dispatch nothing`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let other = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            try fixture.lifecycle.move(owner: other, receipt: started.payload, to: CGPoint(x: 100, y: 100))
        }
        for point in [CGPoint(x: CGFloat.nan, y: 90), CGPoint(x: CGFloat.infinity, y: 90), CGPoint(x: 1000, y: 90)] {
            #expect(throws: (any Error).self) {
                try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: point)
            }
        }
        let terminal = try await fixture.lifecycle.release(owner: owner, receipt: started.payload)
        #expect(terminal.lifecycleDispatchedUnitCount == 3)
        #expect(throws: ExactWindowHeldPointerLifecycleError.self) {
            try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: CGPoint(x: 100, y: 100))
        }
        #expect(fixture.state.postedTypes == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    @Test
    func `permission loss refuses another sample and retains prior cleanup point`() async throws {
        let fixture = self.makeFixture()
        let owner = try fixture.lifecycle.createOwner(boundTo: nil)
        let started = try await fixture.lifecycle.begin(owner: owner, request: fixture.request)
        try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: CGPoint(x: 100, y: 100))
        fixture.state.hasPostEventAccess = false
        #expect(throws: PeekabooError.self) {
            try fixture.lifecycle.move(owner: owner, receipt: started.payload, to: CGPoint(x: 120, y: 120))
        }
        let terminal = try await fixture.lifecycle.revoke(owner: owner, receipt: started.payload)
        #expect(terminal.lifecycleDispatchedUnitCount == 4)
        #expect(fixture.state.postedPoints.last == CGPoint(x: 100, y: 100))
    }
}
