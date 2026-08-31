import AppKit
import AXorcist
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceVisibilityLifecycleTests {
    @Test
    @MainActor
    func `AX hide preflight refuses unsupported action before submission`() {
        var submissionCount = 0

        do {
            try ApplicationService.dispatchApplicationAccessibilityHide(
                isSupported: { false },
                submit: { submissionCount += 1 })
            Issue.record("Expected unsupported AXHide refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(submissionCount == 0)
    }

    @Test
    @MainActor
    func `AX hide cancellation after support preflight refuses before submission`() {
        var events: [String] = []

        do {
            try ApplicationService.dispatchApplicationAccessibilityHide(
                isSupported: {
                    events.append("support")
                    return true
                },
                checkCancellation: {
                    events.append("cancellation")
                    throw CancellationError()
                },
                submit: { events.append("submission") })
            Issue.record("Expected typed AXHide cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(events == ["support", "cancellation"])
    }

    @Test
    @MainActor
    func `native visibility invocation is dispatched when AppKit returns false`() {
        var submissionCount = 0

        let dispatched = ApplicationService.submitNativeApplicationVisibility {
            submissionCount += 1
            return false
        }

        #expect(dispatched)
        #expect(submissionCount == 1)
    }

    @Test
    @MainActor
    func `show all cancellation immediately before AX submission is typed and dispatches nothing`() {
        var submissionCount = 0

        do {
            try ApplicationService.dispatchShowAllApplicationsAXAction(
                checkCancellation: { throw CancellationError() },
                submit: { submissionCount += 1 })
            Issue.record("Expected typed show-all cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submissionCount == 0)
    }

    @Test
    @MainActor
    func `application cancellation before native submission is typed and retry safe`() {
        do {
            try ApplicationService.checkApplicationDispatchCancellation(operation: "Hide others") {
                throw CancellationError()
            }
            Issue.record("Expected typed application cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try ApplicationService.checkApplicationFallbackCancellation(operation: "Hide others") {
                throw CancellationError()
            }
            Issue.record("Expected post-AX cancellation uncertainty")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try ApplicationService.checkApplicationFallbackCancellation(
                operation: "Hide others",
                acceptedFallbackCount: 2)
            {
                throw CancellationError()
            }
            Issue.record("Expected cancellation after accepted fallback requests")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == nil)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .init(3)))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `visibility cancellation at the native submission boundary emits nothing`() async throws {
        let runningApplication = try self.runningApplication()
        var nativeSubmissionCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationNativeVisibilityHandler: { _, _ in
                nativeSubmissionCount += 1
                return true
            })
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try service.requestApplicationVisibility(runningApplication, hidden: false)
        }

        do {
            _ = try await task.value
            Issue.record("Expected typed visibility cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(nativeSubmissionCount == 0)
    }

    @Test
    @MainActor
    func `cancellation after proven AX refusal remains pre-dispatch before native fallback`() async throws {
        let runningApplication = try self.runningApplication()
        var nativeSubmissionCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationAccessibilityHideHandler: { _ in
                withUnsafeCurrentTask { task in task?.cancel() }
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: "Fixture AX hide is unsupported")
            },
            applicationNativeVisibilityHandler: { _, _ in
                nativeSubmissionCount += 1
                return true
            })
        let task = Task { @MainActor in
            try service.requestApplicationVisibility(runningApplication, hidden: true)
        }

        do {
            _ = try await task.value
            Issue.record("Expected pre-fallback cancellation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(nativeSubmissionCount == 0)
    }

    @Test
    @MainActor
    func `pinned hide revalidates caller process generation immediately before dispatch`() async throws {
        let runningApplication = try self.runningApplication()
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: 80)
        let identityReadCount = AutomationTestLockedValue(0)
        var visibilityReadCount = 0
        let visibilityWasRead = AutomationTestLockedValue(false)
        let postVisibilityIdentityReadCount = AutomationTestLockedValue(0)
        var dispatchCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in
                identityReadCount.withValue { $0 += 1 }
                if visibilityWasRead.value {
                    return postVisibilityIdentityReadCount.withValue {
                        $0 += 1
                        return $0 == 1 ? expectedIdentity.processStartIdentity : 81
                    }
                }
                return expectedIdentity.processStartIdentity
            },
            applicationHiddenProvider: { _ in
                visibilityReadCount += 1
                visibilityWasRead.value = true
                return false
            },
            applicationVisibilityHandler: { _, _ in
                dispatchCount += 1
                return true
            })

        do {
            _ = try await service.hideApplicationTargetedResult(request: .init(
                identifier: "PID:\(expectedIdentity.processIdentifier)",
                expectedIdentity: expectedIdentity))
            Issue.record("Expected pre-dispatch generation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == .init(
                processIdentifier: expectedIdentity.processIdentifier,
                processStartIdentity: expectedIdentity.processStartIdentity))
        }

        #expect(identityReadCount.value >= 6)
        #expect(postVisibilityIdentityReadCount.value == 2)
        #expect(visibilityReadCount == 1)
        #expect(dispatchCount == 0)
    }

    @Test
    @MainActor
    func `pinned hide attributes ambiguous dispatch failure to selected process generation`() async throws {
        let runningApplication = try self.runningApplication()
        let identity = ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: 9_007_199_254_740_993)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in identity.processStartIdentity },
            applicationHiddenProvider: { _ in false },
            applicationAccessibilityHideHandler: { _ in
                throw VisibilityFixtureError.dispatchFailed
            },
            applicationNativeVisibilityHandler: { _, _ in false },
            applicationVisibilityTimeout: 0)

        do {
            _ = try await service.hideApplicationTargetedResult(request: .init(
                identifier: "PID:\(identity.processIdentifier)",
                expectedIdentity: identity))
            Issue.record("Expected ambiguous hide failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
            #expect(failure.targetReceipt?.windowID == nil)
        }
    }

    @Test
    @MainActor
    func `accepted hide never confirms visibility from a replacement process generation`() async throws {
        let runningApplication = try self.runningApplication()
        let identity = ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: 80)
        let generation = AutomationTestLockedValue(identity.processStartIdentity)
        var isHidden = false
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in generation.value },
            applicationHiddenProvider: { _ in isHidden },
            applicationVisibilityHandler: { _, hidden in
                isHidden = hidden
                generation.withValue { $0 += 1 }
                return true
            })

        do {
            _ = try await service.hideApplicationTargetedResult(request: .init(
                identifier: "PID:\(identity.processIdentifier)",
                expectedIdentity: identity))
            Issue.record("Expected post-dispatch process-generation drift")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .background))
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
        }
    }

    @Test
    @MainActor
    func `rejected unhide never reports no-change from a replacement process generation`() async throws {
        let runningApplication = try self.runningApplication()
        let identity = ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: 80)
        let generation = AutomationTestLockedValue(identity.processStartIdentity)
        var isHidden = true
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in generation.value },
            applicationHiddenProvider: { _ in isHidden },
            applicationNativeVisibilityHandler: { _, _ in
                isHidden = false
                generation.withValue { $0 += 1 }
                return false
            })

        do {
            _ = try await service.unhideApplicationActionResult(
                identifier: "PID:\(identity.processIdentifier)")
            Issue.record("Expected rejected visibility generation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    @Test
    @MainActor
    func `bulk visibility fallback keeps possible AX plus full native acceptance indeterminate`() throws {
        do {
            _ = try ApplicationService.applicationVisibilityFallbackResult(
                operation: "Show-all-applications",
                acceptedCount: 3,
                snapshotCount: 3,
                primaryError: VisibilityFixtureError.dispatchFailed)
            Issue.record("Expected mixed AX and native uncertainty")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == nil)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .init(4)))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    @MainActor
    func `bulk visibility fallback reports mixed accepted subset as delivery agnostic indeterminate failure`() throws {
        do {
            _ = try ApplicationService.applicationVisibilityFallbackResult(
                operation: "Hide-other-applications",
                acceptedCount: 2,
                snapshotCount: 3,
                primaryError: VisibilityFixtureError.dispatchFailed)
            Issue.record("Expected an indeterminate visibility failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.evidence != .primaryChangeVerifiedCleanupFailed)
            #expect(failure.outcome.delivery == nil)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .init(3)))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.escalation == .observeBeforeRetry)
            #expect(failure.message.contains("2 of 3"))
            #expect(failure.causeDescription?.contains("2 of 3") == true)
        }
    }

    @Test
    @MainActor
    func `bulk visibility fallback with no accepted request retains indeterminate primary dispatch`() throws {
        do {
            _ = try ApplicationService.applicationVisibilityFallbackResult(
                operation: "Show-all-applications",
                acceptedCount: 0,
                snapshotCount: 3,
                primaryError: VisibilityFixtureError.dispatchFailed)
            Issue.record("Expected an indeterminate visibility failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.escalation == .observeBeforeRetry)
            #expect(failure.message.contains("0 of 3"))
            #expect(failure.causeDescription?.contains("0 of 3") == true)
        }
    }

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
    func `AX hide ambiguity remains indeterminate when the requested state is observed`() async throws {
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

        do {
            _ = try await service.hideApplicationResult(
                identifier: "PID:\(runningApplication.processIdentifier)")
            Issue.record("Expected ambiguous AX delivery")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        }
        #expect(nativeFallbackCount == 0)
    }

    @Test
    @MainActor
    func `generic AX hide error never replays through native fallback`() async throws {
        let runningApplication = try self.runningApplication()
        let isHidden = false
        var nativeFallbackCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in isHidden },
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
            Issue.record("Expected ambiguous AX delivery")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        }
        #expect(nativeFallbackCount == 0)
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
            #expect(nativeFallbackCount == 0)
        }
    }

    @Test
    @MainActor
    func `proven pre-dispatch AX hide refusal may use native fallback`() async throws {
        let runningApplication = try self.runningApplication()
        var isHidden = false
        var nativeFallbackCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in isHidden },
            applicationAccessibilityHideHandler: { _ in
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: "AXHide is unavailable")
            },
            applicationNativeVisibilityHandler: { _, hidden in
                nativeFallbackCount += 1
                isHidden = hidden
                return true
            },
            applicationVisibilityTimeout: 0)

        let result = try await service.hideApplicationResult(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .background))
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(nativeFallbackCount == 1)
    }

    @Test
    @MainActor
    func `proven AX system hide refusals may use native fallback`() async throws {
        for axError in [AXError.actionUnsupported, .apiDisabled] {
            let runningApplication = try self.runningApplication()
            var isHidden = false
            var nativeFallbackCount = 0
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in runningApplication },
                applicationHiddenProvider: { _ in isHidden },
                applicationAccessibilityHideHandler: { _ in
                    throw AccessibilitySystemError(axError)
                },
                applicationNativeVisibilityHandler: { _, hidden in
                    nativeFallbackCount += 1
                    isHidden = hidden
                    return true
                },
                applicationVisibilityTimeout: 0)

            let result = try await service.hideApplicationResult(
                identifier: "PID:\(runningApplication.processIdentifier)")

            #expect(result.outcome?.state == .confirmedChange)
            #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .background))
            #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
            #expect(nativeFallbackCount == 1)
        }
    }

    @Test
    @MainActor
    func `ambiguous AX system hide error never replays through native fallback`() async throws {
        let runningApplication = try self.runningApplication()
        var nativeFallbackCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in false },
            applicationAccessibilityHideHandler: { _ in
                throw AccessibilitySystemError(.cannotComplete)
            },
            applicationNativeVisibilityHandler: { _, _ in
                nativeFallbackCount += 1
                return true
            },
            applicationVisibilityTimeout: 0)

        do {
            _ = try await service.hideApplicationResult(
                identifier: "PID:\(runningApplication.processIdentifier)")
            Issue.record("Expected ambiguous AX delivery")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        }
        #expect(nativeFallbackCount == 0)
    }

    @Test
    @MainActor
    func `cancelled AX hide refusal never uses native fallback`() async throws {
        let runningApplication = try self.runningApplication()
        var nativeFallbackCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in false },
            applicationAccessibilityHideHandler: { _ in
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .requestCancelled,
                    message: "AXHide was cancelled")
            },
            applicationNativeVisibilityHandler: { _, _ in
                nativeFallbackCount += 1
                return true
            },
            applicationVisibilityTimeout: 0)

        do {
            _ = try await service.hideApplicationResult(
                identifier: "PID:\(runningApplication.processIdentifier)")
            Issue.record("Expected cancellation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(nativeFallbackCount == 0)
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
