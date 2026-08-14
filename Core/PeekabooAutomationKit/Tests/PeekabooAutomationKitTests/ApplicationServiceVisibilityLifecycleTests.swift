import AppKit
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceVisibilityLifecycleTests {
    @Test
    @MainActor
    func `rejected native visibility request rechecks state before returning no change`() async throws {
        let runningApplication = try self.runningApplication()
        var visibilityReadCount = 0
        var sleepCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in
                visibilityReadCount += 1
                return visibilityReadCount == 1
            },
            applicationNativeVisibilityHandler: { _, _ in false },
            applicationVisibilitySleepHandler: { _ in sleepCount += 1 },
            applicationVisibilityTimeout: 1)

        let result = try await service.unhideApplicationResult(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(result.outcome?.state == .confirmedNoChange)
        #expect(result.outcome?.delivery == nil)
        #expect(result.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(visibilityReadCount == 2)
        #expect(sleepCount == 0)
    }

    @Test
    @MainActor
    func `AX hide ambiguity is confirmed when the requested state is observed`() async throws {
        let runningApplication = try self.runningApplication()
        var isHidden = false
        var nativeFallbackCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in isHidden },
            applicationAccessibilityHideHandler: { _ in
                isHidden = true
                throw VisibilityFixtureError.dispatchFailed
            },
            applicationNativeVisibilityHandler: { _, _ in
                nativeFallbackCount += 1
                return false
            },
            applicationVisibilityTimeout: 0)

        let result = try await service.hideApplicationResult(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(nativeFallbackCount == 1)
    }

    @Test
    @MainActor
    func `AX hide ambiguity remains retry unsafe when requested state is not proven`() async throws {
        let runningApplication = try self.runningApplication()
        var visibilityReadCount = 0
        var nativeFallbackCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in
                visibilityReadCount += 1
                return false
            },
            applicationAccessibilityHideHandler: { _ in
                throw VisibilityFixtureError.dispatchFailed
            },
            applicationNativeVisibilityHandler: { _, _ in
                nativeFallbackCount += 1
                return false
            },
            applicationVisibilityTimeout: 0)

        do {
            _ = try await service.hideApplicationResult(
                identifier: "PID:\(runningApplication.processIdentifier)")
            Issue.record("Expected an indeterminate visibility failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(visibilityReadCount == 2)
            #expect(nativeFallbackCount == 1)
        }
    }

    @MainActor
    private func runningApplication() throws -> NSRunningApplication {
        try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated && $0.isFinishedLaunching
        })
    }
}

private enum VisibilityFixtureError: Error {
    case dispatchFailed
}
