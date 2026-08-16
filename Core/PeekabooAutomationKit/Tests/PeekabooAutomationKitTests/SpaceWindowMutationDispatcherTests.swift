import CoreGraphics
import os
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct SpaceWindowMutationDispatcherTests {
    @Test
    func `pre-cancelled move dispatches no CGS unit`() async {
        let mutations = OSAllocatedUnfairLock(initialState: [String]())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { [11] },
                    removeWindows: { _ in mutations.withLock { $0.append("remove") } },
                    addWindow: { _ in mutations.withLock { $0.append("add") } }))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(mutations.withLock { $0.isEmpty })
    }

    @Test
    func `cancellation after destination add preserves one unit and skips removal`() async throws {
        let state = OSAllocatedUnfairLock(initialState: (
            memberships: [CGSSpaceID(11)],
            mutations: [String]()))
        let task = Task {
            try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { state.withLock { $0.memberships } },
                    removeWindows: { spaces in
                        state.withLock {
                            $0.mutations.append("remove")
                            $0.memberships.removeAll { spaces.contains($0) }
                        }
                    },
                    addWindow: { space in
                        state.withLock {
                            $0.mutations.append("add")
                            $0.memberships.append(space)
                        }
                        withUnsafeCurrentTask { $0?.cancel() }
                    }))
        }

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await task.value
        }

        #expect(state.withLock { $0.mutations } == ["add"])
        #expect(state.withLock { $0.memberships } == [11, 22])
        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.dispatchState.unitCount == .one)
        #expect(failure?.targetReceipt == Self.targetReceipt)
    }

    @Test
    func `pre-cancelled Space switch dispatches no CGS unit`() async {
        let didSwitch = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpaceWindowMutationDispatcher.switchToWindowSpace(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { [22] },
                    activeSpaceID: { 11 },
                    setCurrentSpace: { _ in didSwitch.withLock { $0 = true } },
                    settle: {}))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(!didSwitch.withLock { $0 })
    }

    @Test
    func `generation flip before the first CGS dispatch refuses without mutation`() throws {
        let identity = Self.identity()
        var events: [String] = []

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: identity,
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { space in
                        events.append("destination:\(space)")
                        return true
                    },
                    validateIdentity: { candidate in
                        events.append("validate:\(candidate.ownerProcessStartIdentity)")
                        return false
                    },
                    spaceIDsForWindow: {
                        events.append("memberships")
                        return [11]
                    },
                    removeWindows: { _ in events.append("remove") },
                    addWindow: { _ in events.append("add") }))
            Issue.record("Expected the changed process generation to refuse before dispatch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(events == ["destination:22", "memberships", "validate:1234"])
    }

    @Test
    func `destination is established and verified before prior memberships are removed`() throws {
        let identity = Self.identity()
        var memberships: [CGSSpaceID] = [11]
        var events: [String] = []

        let result = try SpaceWindowMutationDispatcher.moveWindow(
            windowID: 4040,
            expectedIdentity: identity,
            targetSpaceID: 22,
            backend: .init(
                destinationExists: { space in
                    events.append("destination:\(space)")
                    return space == 22
                },
                validateIdentity: { candidate in
                    events.append("validate:\(candidate.windowID)")
                    return true
                },
                spaceIDsForWindow: {
                    events.append("memberships:\(memberships)")
                    return memberships
                },
                removeWindows: { spaces in
                    events.append("remove:\(spaces)")
                    memberships.removeAll { spaces.contains($0) }
                },
                addWindow: { space in
                    events.append("add:\(space)")
                    memberships.append(space)
                }))

        #expect(events == [
            "destination:22",
            "memberships:[11]",
            "validate:4040",
            "add:22",
            "validate:4040",
            "memberships:[11, 22]",
            "destination:22",
            "validate:4040",
            "memberships:[11, 22]",
            "destination:22",
            "remove:[11]",
            "validate:4040",
            "memberships:[22]",
        ])
        #expect(result.outcome == .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
        #expect(result.targetIdentity?.exactWindow?.identity == identity)
    }

    @Test
    func `invalid destination refuses before membership reads or CGS dispatch`() throws {
        var events: [String] = []

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in
                        events.append("destination")
                        return false
                    },
                    validateIdentity: { _ in events.append("validate"); return true },
                    spaceIDsForWindow: { events.append("memberships"); return [11] },
                    removeWindows: { _ in events.append("remove") },
                    addWindow: { _ in events.append("add") }))
            Issue.record("Expected a stale destination Space to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(events == ["destination"])
    }

    @Test
    func `unverified destination establishment never removes existing memberships`() throws {
        var events: [String] = []

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: {
                        events.append("memberships")
                        return [11]
                    },
                    removeWindows: { _ in events.append("remove") },
                    addWindow: { _ in events.append("add") }))
            Issue.record("Expected destination membership verification to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .suspectedNoop)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(events == ["memberships", "add", "memberships"])
    }

    @Test
    func `destination disappearance after establishment preserves existing memberships`() throws {
        var memberships: [CGSSpaceID] = [11]
        var destinationChecks = 0
        var removed = false

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in
                        destinationChecks += 1
                        return destinationChecks == 1
                    },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { memberships },
                    removeWindows: { _ in removed = true },
                    addWindow: { memberships.append($0) }))
            Issue.record("Expected destination disappearance to stop before removal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(!removed)
        #expect(memberships == [11, 22])
    }

    @Test
    func `destination membership disappearance at removal boundary skips destructive cleanup`() throws {
        var membershipReads = 0
        var removed = false

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: {
                        membershipReads += 1
                        switch membershipReads {
                        case 1: return [11]
                        case 2: return [11, 22]
                        default: return [11]
                        }
                    },
                    removeWindows: { _ in removed = true },
                    addWindow: { _ in }))
            Issue.record("Expected destination membership loss to stop destructive cleanup")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(membershipReads == 3)
        #expect(!removed)
    }

    @Test
    func `destination disappearance is detected even without prior memberships`() throws {
        var memberships: [CGSSpaceID] = []
        var destinationChecks = 0

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in
                        destinationChecks += 1
                        return destinationChecks == 1
                    },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { memberships },
                    removeWindows: { _ in Issue.record("No prior membership should be removed") },
                    addWindow: { memberships.append($0) }))
            Issue.record("Expected destination disappearance to invalidate the move")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(destinationChecks == 2)
        #expect(memberships == [22])
    }

    @Test
    func `failed removal reports partial only while destination remains established`() throws {
        var memberships: [CGSSpaceID] = [11]

        do {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in true },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: { memberships },
                    removeWindows: { _ in },
                    addWindow: { memberships.append($0) }))
            Issue.record("Expected stale prior membership to be reported")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }
    }

    @Test
    func `already exact destination membership is a verified no-op`() throws {
        var mutations: [String] = []
        let result = try SpaceWindowMutationDispatcher.moveWindow(
            windowID: 4040,
            expectedIdentity: Self.identity(),
            targetSpaceID: 22,
            backend: .init(
                destinationExists: { $0 == 22 },
                validateIdentity: { _ in true },
                spaceIDsForWindow: { [22] },
                removeWindows: { _ in mutations.append("remove") },
                addWindow: { _ in mutations.append("add") }))

        #expect(result.outcome == .confirmedNoChange())
        #expect(mutations.isEmpty)
    }

    @Test
    func `switch generation flip at the CGS boundary refuses without dispatch`() async throws {
        var validations = [true, true, false]
        var events: [String] = []

        do {
            _ = try await SpaceWindowMutationDispatcher.switchToWindowSpace(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                backend: .init(
                    destinationExists: { _ in events.append("destination"); return true },
                    validateIdentity: { candidate in
                        events.append("validate:\(candidate.ownerProcessStartIdentity)")
                        return validations.removeFirst()
                    },
                    spaceIDsForWindow: { events.append("memberships"); return [22] },
                    activeSpaceID: { events.append("active"); return 11 },
                    setCurrentSpace: { _ in events.append("set") },
                    settle: { events.append("settle") }))
            Issue.record("Expected final generation validation to refuse the switch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(events == [
            "memberships",
            "active",
            "destination",
            "validate:1234",
            "memberships",
            "validate:1234",
            "active",
            "destination",
            "memberships",
            "validate:1234",
        ])
    }

    @Test
    func `switch membership drift at final CGS boundary refuses without dispatch`() async throws {
        var membershipReads = 0
        var didSwitch = false

        do {
            _ = try await SpaceWindowMutationDispatcher.switchToWindowSpace(
                windowID: 4040,
                expectedIdentity: Self.identity(),
                backend: .init(
                    destinationExists: { $0 == 22 },
                    validateIdentity: { _ in true },
                    spaceIDsForWindow: {
                        membershipReads += 1
                        return membershipReads < 3 ? [22] : [33]
                    },
                    activeSpaceID: { 11 },
                    setCurrentSpace: { _ in didSwitch = true },
                    settle: {}))
            Issue.record("Expected final Space membership drift to refuse the switch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == .refused(reason: .targetUnavailable))
            #expect(failure.targetReceipt == Self.targetReceipt)
        }

        #expect(membershipReads == 3)
        #expect(!didSwitch)
    }

    @Test
    func `switch carries exact identity through the final CGS dispatch boundary`() async throws {
        let identity = Self.identity()
        var validated: [WindowMutationIdentity] = []
        var events: [String] = []

        let result = try await SpaceWindowMutationDispatcher.switchToWindowSpace(
            windowID: 4040,
            expectedIdentity: identity,
            backend: .init(
                destinationExists: { $0 == 22 },
                validateIdentity: { candidate in validated.append(candidate); return true },
                spaceIDsForWindow: { [22] },
                activeSpaceID: { 11 },
                setCurrentSpace: { events.append("set:\($0)") },
                settle: { events.append("settle") }))

        #expect(validated == [identity, identity, identity])
        #expect(events == ["set:22", "settle"])
        #expect(result.outcome == .dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one))
        #expect(result.targetIdentity?.exactWindow?.identity == identity)
    }

    @Test
    func `missing exact bounds refuses before backend reads or CGS dispatch`() throws {
        let incomplete = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234)
        var events: [String] = []

        #expect(throws: DesktopActionFailure.self) {
            _ = try SpaceWindowMutationDispatcher.moveWindow(
                windowID: 4040,
                expectedIdentity: incomplete,
                targetSpaceID: 22,
                backend: .init(
                    destinationExists: { _ in events.append("destination"); return true },
                    validateIdentity: { _ in events.append("validate"); return true },
                    spaceIDsForWindow: { events.append("memberships"); return [] },
                    removeWindows: { _ in events.append("remove") },
                    addWindow: { _ in events.append("add") }))
        }
        #expect(events.isEmpty)
    }

    private static let targetReceipt = DesktopActionTargetReceipt(
        processIdentifier: 999,
        processStartIdentity: 1234,
        windowID: 4040)

    private static func identity() -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: CGRect(x: 100, y: 100, width: 600, height: 400))
    }
}
