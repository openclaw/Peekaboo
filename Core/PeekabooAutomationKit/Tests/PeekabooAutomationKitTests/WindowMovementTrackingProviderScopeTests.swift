import CoreGraphics
import PeekabooAutomationKitTestSupport
import Testing
@testable import PeekabooAutomationKit

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
