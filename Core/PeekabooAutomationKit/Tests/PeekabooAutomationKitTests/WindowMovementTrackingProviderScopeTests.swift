import CoreGraphics
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooAutomationKitTestSupport

struct WindowMovementTrackingProviderScopeTests {
    @Test
    @MainActor
    func `Provider scopes exclude concurrent overrides until restoration`() async {
        let firstProvider = ProviderScopeWindowTracker(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let secondProvider = ProviderScopeWindowTracker(bounds: .zero)
        let firstInstalled = AsyncTestLatch()
        let releaseFirst = AsyncTestLatch()
        let secondInstalled = AsyncTestLatch()

        let firstTask = Task { @MainActor in
            await WindowMovementTrackingProviderScope.withProvider(firstProvider) {
                #expect(WindowMovementTracking.provider === firstProvider)
                await firstInstalled.open()
                await releaseFirst.wait()
                #expect(WindowMovementTracking.provider === firstProvider)
            }
        }
        let secondTask = Task { @MainActor in
            await firstInstalled.wait()
            await WindowMovementTrackingProviderScope.withProvider(secondProvider) {
                #expect(WindowMovementTracking.provider === secondProvider)
                await secondInstalled.open()
            }
        }

        await firstInstalled.wait()
        let installedBeforeRelease = await secondInstalled.opensWithin(.milliseconds(50))
        #expect(!installedBeforeRelease)
        #expect(WindowMovementTracking.provider === firstProvider)
        await releaseFirst.open()
        await firstTask.value
        await secondTask.value
        #expect(await secondInstalled.isOpen)
    }

    @Test
    @MainActor
    func `Throwing provider scope restores provider and releases next waiter`() async {
        let initialProvider = await WindowMovementTrackingProviderScope.withExclusiveAccess {
            WindowMovementTracking.provider
        }
        let throwingProvider = ProviderScopeWindowTracker(bounds: .zero)

        do {
            try await WindowMovementTrackingProviderScope.withProvider(throwingProvider) {
                #expect(WindowMovementTracking.provider === throwingProvider)
                throw ProviderScopeTestError.expected
            }
            Issue.record("Expected provider operation to throw")
        } catch ProviderScopeTestError.expected {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let restoredProvider = await WindowMovementTrackingProviderScope.withExclusiveAccess {
            WindowMovementTracking.provider
        }
        #expect(restoredProvider === initialProvider)

        let nextProvider = ProviderScopeWindowTracker(bounds: CGRect(x: 0, y: 0, width: 50, height: 50))
        await WindowMovementTrackingProviderScope.withProvider(nextProvider) {
            #expect(WindowMovementTracking.provider === nextProvider)
        }
    }

    @Test
    @MainActor
    func `Cancelled queued scope still acquires restores and releases in FIFO order`() async {
        let initialProvider = await WindowMovementTrackingProviderScope.withExclusiveAccess {
            WindowMovementTracking.provider
        }
        let holdingProvider = ProviderScopeWindowTracker(bounds: .zero)
        let cancelledProvider = ProviderScopeWindowTracker(bounds: CGRect(x: 10, y: 10, width: 10, height: 10))
        let finalProvider = ProviderScopeWindowTracker(bounds: CGRect(x: 20, y: 20, width: 20, height: 20))
        let holderInstalled = AsyncTestLatch()
        let releaseHolder = AsyncTestLatch()
        let cancelledQueued = AsyncTestLatch()
        let finalQueued = AsyncTestLatch()
        var entryOrder: [String] = []

        let holderTask = Task { @MainActor in
            await WindowMovementTrackingProviderScope.withProvider(holdingProvider) {
                await holderInstalled.open()
                await releaseHolder.wait()
            }
        }
        await holderInstalled.wait()

        var cancelledTaskReachedScope = false
        let cancelledTask = Task { @MainActor in
            cancelledTaskReachedScope = true
            await WindowMovementTrackingProviderScope.withProvider(
                cancelledProvider,
                queuedSignal: cancelledQueued)
            {
                #expect(Task.isCancelled)
                #expect(WindowMovementTracking.provider === cancelledProvider)
                entryOrder.append("cancelled")
            }
        }
        #expect(await cancelledQueued.opensWithin(.seconds(1)))
        #expect(cancelledTaskReachedScope)
        cancelledTask.cancel()

        var finalTaskReachedScope = false
        let finalTask = Task { @MainActor in
            finalTaskReachedScope = true
            await WindowMovementTrackingProviderScope.withProvider(
                finalProvider,
                queuedSignal: finalQueued)
            {
                #expect(!Task.isCancelled)
                #expect(WindowMovementTracking.provider === finalProvider)
                entryOrder.append("final")
            }
        }
        #expect(await finalQueued.opensWithin(.seconds(1)))
        #expect(finalTaskReachedScope)

        await releaseHolder.open()
        await holderTask.value
        await cancelledTask.value
        await finalTask.value

        #expect(entryOrder == ["cancelled", "final"])
        let restoredProvider = await WindowMovementTrackingProviderScope.withExclusiveAccess {
            WindowMovementTracking.provider
        }
        #expect(restoredProvider === initialProvider)
    }

    @Test
    @MainActor
    func `Provider scope diagnoses inherited reentrancy without leaking to detached tasks`() async {
        let releaseDelayedChild = AsyncTestLatch()
        let result = await WindowMovementTrackingProviderScope.withExclusiveAccess {
            let sameTaskMessage = WindowMovementTrackingProviderScope.reentrancyViolationMessage()
            let childTaskMessage = await Task {
                WindowMovementTrackingProviderScope.reentrancyViolationMessage()
            }.value
            let delayedChildTask = Task {
                await releaseDelayedChild.wait()
                return WindowMovementTrackingProviderScope.reentrancyViolationMessage()
            }
            let detachedTaskMessage = await Task.detached {
                WindowMovementTrackingProviderScope.reentrancyViolationMessage()
            }.value
            return (sameTaskMessage, childTaskMessage, delayedChildTask, detachedTaskMessage)
        }
        await releaseDelayedChild.open()
        let delayedChildMessage = await result.2.value

        #expect(result.0?.contains("cannot be nested") == true)
        #expect(result.1 == result.0)
        #expect(delayedChildMessage == result.0)
        #expect(result.3 == nil)
        #expect(WindowMovementTrackingProviderScope.reentrancyViolationMessage() == nil)
    }
}

private enum ProviderScopeTestError: Error {
    case expected
}

@MainActor
private final class ProviderScopeWindowTracker: WindowTrackingProviding {
    let bounds: CGRect

    init(bounds: CGRect) {
        self.bounds = bounds
    }

    func windowBounds(for _: CGWindowID) -> CGRect? {
        self.bounds
    }

    func windowOwnerProcessIdentifier(for _: CGWindowID) -> pid_t? {
        nil
    }
}
