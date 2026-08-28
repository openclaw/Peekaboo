import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct WindowFocusReadbackTests {
    @Test
    func `geometry-only catalog lacks focus but native readback retains exact evidence`() async throws {
        let fixture = FocusReadbackFixture()
        let geometry = try #require(fixture.catalog.serviceWindowInfo(windowID: 712))
        #expect(geometry.isMainWindow)
        #expect(geometry.isKeyWindow == nil)
        #expect(geometry.isFrontmost == nil)

        let result = try await fixture.focus()
        #expect(result.payload.isKeyWindow == true)
        #expect(result.payload.isFrontmost == true)
        #expect(result.payload.mutationIdentity?.hasSameStableReceipt(as: fixture.expected) == true)
        #expect(result.targetIdentity?.exactWindow?.identity == fixture.expected)
        #expect(result.outcome?.isConfirmed == true)
        #expect(result.outcome?.projection.retrySafe == false)
        #expect(result.outcome?.dispatchState.mutationDispatched == true)
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(fixture.dispatchCount == 1)
        #expect(fixture.focusReadCount == 1)
    }

    @Test(arguments: [
        "missing",
        "other-window",
        "foreground",
        "owner",
        "generation",
        "bounds",
        "catalog",
        "native-window",
        "cancel",
        "timeout",
        "ax-timeout",
    ])
    func `failed proof never retries an accepted mutation`(fault: String) async throws {
        let fixture = FocusReadbackFixture()
        fixture.afterDispatch = {
            if fault == "catalog" {
                fixture.catalogWindowID = 713
            }
        }
        fixture.onFocusRead = {
            switch fault {
            case "missing": fixture.focusedID = nil
            case "other-window": fixture.focusedID = 713
            case "foreground": fixture.foregroundPID = 52
            case "owner": fixture.ownerPID = 52
            case "native-window": fixture.nativeWindowID = 713
            case "generation": fixture.generation = 9002
            case "bounds": fixture.currentBounds.origin.x += 1
            case "cancel": throw CancellationError()
            case "timeout": fixture.clock = fixture.clock.advanced(by: .seconds(2))
            case "ax-timeout": throw FocusError.focusVerificationTimeout(712)
            default: break
            }
        }
        do {
            _ = try await fixture.focus()
            Issue.record("Expected exact focus proof to fail: \(fault)")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.projection.retrySafe == false)
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.targetReceipt == fixture.expected.actionTargetReceipt)
        }
        #expect(fixture.dispatchCount == 1)
        #expect(fixture.focusReadCount <= 1)
    }

    @Test(arguments: ["owner", "generation", "bounds", "missing-bounds", "selector"])
    func `invalid original receipt refuses before dispatch`(fault: String) async throws {
        let fixture = FocusReadbackFixture()
        switch fault {
        case "owner": fixture.ownerPID = 52
        case "generation": fixture.generation = 9002
        case "bounds": fixture.currentBounds.origin.x += 1
        case "missing-bounds":
            fixture.expected = WindowMutationIdentity(
                windowID: 712, ownerProcessIdentifier: 41, ownerProcessStartIdentity: 9001)
        default: break
        }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.focus(target: fault == "selector" ? .windowId(713) : .windowId(712))
        }
        #expect(fixture.dispatchCount == 0)
        #expect(fixture.focusReadCount == 0)
    }

    @Test
    func `native settlement failure stops after the first accepted raise`() async throws {
        let fixture = FocusReadbackFixture()
        fixture.settlementFails = true
        do {
            _ = try await fixture.focus()
            Issue.record("Expected settlement failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.projection.retrySafe == false)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(fixture.dispatchCount == 1)
        #expect(fixture.focusReadCount == 0)
    }

    @Test
    func `pre-cancelled native focus does not dispatch`() async throws {
        let fixture = FocusReadbackFixture()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.focus()
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fixture.dispatchCount == 0)
    }

    @Test
    func `focus readback completes before the existing global lane is released`() async throws {
        let fixture = FocusReadbackFixture()
        let entered = FocusReadbackGate()
        let release = FocusReadbackGate()
        fixture.onFocusRead = {
            await entered.open()
            await release.wait()
        }
        let task = Task { try await fixture.focus() }
        await entered.wait()
        let descriptor = open(fixture.root.appendingPathComponent("global.lock").path, O_RDWR | O_CLOEXEC)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
        await release.open()
        _ = try await task.value
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        _ = flock(descriptor, LOCK_UN)
        #expect(fixture.focusReadCount == 1)
    }
}

@MainActor
private final class FocusReadbackFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("focus-proof-\(UUID())")
    var expected = WindowMutationIdentity(
        windowID: 712,
        ownerProcessIdentifier: 41,
        ownerProcessStartIdentity: 9001,
        capturedBounds: CGRect(x: 10, y: 20, width: 800, height: 600))
    var ownerPID: pid_t = 41
    var generation: UInt64 = 9001
    var currentBounds = CGRect(x: 10, y: 20, width: 800, height: 600)
    var catalogWindowID = 712
    var nativeWindowID: CGWindowID?
    var focusedID: CGWindowID? = 712
    var foregroundPID: pid_t? = 41
    var clock = ContinuousClock.now
    var dispatchCount = 0
    var settlementFails = false
    var focusReadCount = 0
    var onFocusRead: () async throws -> Void = {}
    var afterDispatch: () -> Void = {}

    deinit { try? FileManager.default.removeItem(at: self.root) }

    var catalog: WindowCGInfoLookup {
        WindowCGInfoLookup(
            windowListProvider: { _, _ in
                [[
                    kCGWindowNumber as String: self.catalogWindowID,
                    kCGWindowOwnerPID as String: self.ownerPID,
                    kCGWindowBounds as String: [
                        "X": self.currentBounds.minX,
                        "Y": self.currentBounds.minY,
                        "Width": self.currentBounds.width,
                        "Height": self.currentBounds.height,
                    ],
                    kCGWindowIsOnscreen as String: true,
                ]]
            },
            processStartIdentityProvider: { _ in self.generation },
            currentWindowIdentityProvider: { self.systemWindow($0) },
            isMainWindowProvider: { _ in true })
    }

    func systemWindow(_ id: CGWindowID) -> SystemWindowIdentity {
        SystemWindowIdentity(
            windowID: self.nativeWindowID ?? id,
            ownerProcessIdentifier: self.ownerPID,
            title: "Fixture",
            bounds: self.currentBounds,
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: .readOnly)
    }

    func focus(target: WindowTarget = .windowId(712)) async throws -> UIAutomationActionResult<ServiceWindowInfo> {
        let readback = WindowFocusReadback(
            catalog: self.catalog,
            processStartIdentity: { _ in self.generation },
            windowIdentity: { self.systemWindow($0) },
            focusedWindowID: { pid, timeout in
                #expect(pid == 41)
                #expect(timeout > 0 && timeout <= 0.1)
                self.focusReadCount += 1
                try await self.onFocusRead()
                return self.focusedID
            },
            frontmostPID: { self.foregroundPID },
            now: { self.clock })
        let service = WindowManagementService(
            operationLaneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: self.root))
        return try await service.focusWindowProofActionResult(
            target: target,
            expectedIdentity: self.expected,
            validateBeforeDispatch: { try readback.validateIdentity(self.expected) },
            dispatch: { options, record in
                try await FocusRaiseSettlement.run(
                    attemptCount: options.retryCount,
                    requiresStrictDispatchOwnership: false,
                    prepareAttempt: {},
                    dispatchRaise: {
                        self.dispatchCount += 1
                        _ = try FocusDispatchAccounting.acceptingBool(
                            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                            onDispatch: record,
                            operation: { true })
                        self.afterDispatch()
                    },
                    verifyFocus: {
                        if self.settlementFails {
                            throw FocusError.focusVerificationTimeout(712)
                        }
                    },
                    completeRaise: {},
                    sleepBeforeRetry: { Issue.record("Unexpected mutation retry") },
                    fallbackError: FocusError.focusVerificationFailed(712))
            },
            readback: readback)
    }
}

private actor FocusReadbackGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if self.opened {
            return
        }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.opened = true
        self.waiters.forEach { $0.resume() }
        self.waiters.removeAll()
    }
}
