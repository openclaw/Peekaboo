import AppKit
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

extension ApplicationServiceLifecycleTests {
    @Test
    @MainActor
    func `explicit application path disables running application substitution`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "/System/Library/CoreServices/Finder.app",
            activates: true))

        let call = try #require(recorder.calls.first)
        #expect(!call.allowsRunningApplicationSubstitution)
    }

    @Test
    @MainActor
    func `bundle identifier launch allows running application substitution`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "com.apple.finder",
            activates: true))

        let call = try #require(recorder.calls.first)
        #expect(call.allowsRunningApplicationSubstitution)
    }

    @Test
    @MainActor
    func `strict bundle identifier does not fall back to application name`() {
        #expect(throws: PeekabooError.self) {
            _ = try ApplicationService().prepareApplicationLaunch(ApplicationLaunchRequest(
                applicationBundleIdentifier: "Finder",
                activates: false))
        }
    }

    @Test
    @MainActor
    func `blank explicit launch selectors never fall through to the default URL handler`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)
        let target = try #require(URL(string: "https://example.com"))
        let requests = [
            ApplicationLaunchRequest(
                applicationIdentifier: "   ",
                openURLs: [target],
                activates: false),
            ApplicationLaunchRequest(
                applicationBundleIdentifier: "\t\n",
                openURLs: [target],
                activates: false),
        ]

        for request in requests {
            await #expect(throws: PeekabooError.self) {
                try await service.launchApplication(request: request)
            }
        }
        #expect(recorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `legacy launch accepts an exact running PID without launching`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first { !$0.isTerminated })
        let recorder = ApplicationOpenRecorder()

        let application = try await ApplicationService(applicationOpenHandler: recorder.open).launchApplication(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(application.processIdentifier == runningApplication.processIdentifier)
        #expect(recorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `legacy launch returns a running bundle match without reopening it`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleIdentifier != nil
        })
        let bundleIdentifier = try #require(runningApplication.bundleIdentifier)
        let recorder = ApplicationOpenRecorder()

        let application = try await ApplicationService(applicationOpenHandler: recorder.open).launchApplication(
            identifier: bundleIdentifier)

        #expect(application.bundleIdentifier == bundleIdentifier)
        #expect(recorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `relaunch rejects an invalid launch before resolving or quitting the target`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning)

        await #expect(throws: ApplicationLifecycleRefusalError.self) {
            try await service.relaunchApplication(request: ApplicationRelaunchRequest(
                targetIdentifier: "Example",
                launchRequest: ApplicationLaunchRequest(),
                waitSeconds: 0))
        }

        #expect(lifecycle.resolvedIdentifiers.isEmpty)
        #expect(lifecycle.quitCalls.isEmpty)
        #expect(openRecorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `relaunch rejects a canonically resolved self target before quitting`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: getpid())
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning)

        await #expect(throws: PeekabooError.self) {
            try await service.relaunchApplication(request: ApplicationRelaunchRequest(
                targetIdentifier: "  host.bundle.identifier  ",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: getpid(),
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 0))
        }

        #expect(lifecycle.resolvedIdentifiers == ["  host.bundle.identifier  "])
        #expect(lifecycle.quitCalls.isEmpty)
        #expect(openRecorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `normal local relaunch composes background quit and foreground launch`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning,
            applicationActiveProvider: { _ in true },
            processStartIdentityProvider: { _ in 700 })

        let result = try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
            targetIdentifier: "  Example  ",
            expectedTargetIdentity: ApplicationProcessIdentity(
                processIdentifier: 4242,
                processStartIdentity: 700),
            launchRequest: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: true),
            waitSeconds: 0))

        #expect(lifecycle.resolvedIdentifiers == ["  Example  "])
        #expect(lifecycle.quitCalls == [.init(
            identifier: "PID:4242",
            force: false,
            expectedIdentity: ApplicationProcessIdentity(
                processIdentifier: 4242,
                processStartIdentity: 700))])
        #expect(lifecycle.runningIdentifiers == ["PID:4242"])
        #expect(openRecorder.calls.count == 1)
        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
        #expect(result.outcome?.dispatchState == .dispatched(
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
    }

    @Test
    @MainActor
    func `relaunch refuses a different launch bundle before quitting its pinned target`() async throws {
        let openRecorder = ApplicationOpenRecorder()
        var resolvedIdentifiers: [String] = []
        var quitCalls = 0
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: { identifier in
                resolvedIdentifiers.append(identifier)
                return ServiceApplicationInfo(
                    processIdentifier: 4242,
                    processStartIdentity: 700,
                    bundleIdentifier: "com.example.Unrelated",
                    name: "Unrelated",
                    bundlePath: "/Applications/Unrelated.app")
            },
            relaunchQuitHandler: { _ in
                quitCalls += 1
                return .init(requestAccepted: true, terminated: true)
            })

        do {
            _ = try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "PID:4242",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 0))
            Issue.record("Expected a mismatched relaunch target refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == .init(
                processIdentifier: 4242,
                processStartIdentity: 700))
        }

        #expect(resolvedIdentifiers == ["PID:4242"])
        #expect(quitCalls == 0)
        #expect(openRecorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `relaunch rejects changed process generation before quit`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning)

        await #expect(throws: PeekabooError.self) {
            try await service.relaunchApplication(request: ApplicationRelaunchRequest(
                targetIdentifier: "PID:4242",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 701),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 0))
        }

        #expect(lifecycle.quitCalls.isEmpty)
        #expect(openRecorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `relaunch classifies in-lane generation drift as a pre-dispatch refusal`() async throws {
        let runningApplication = try self.runningApplication()
        let lifecycle = RelaunchLifecycleRecorder(targetPID: runningApplication.processIdentifier)
        let openRecorder = ApplicationOpenRecorder()
        let generations = AutomationTestLockedValue<[UInt64]>([700, 701])
        var quitCalls = 0
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            processStartIdentityProvider: { _ in generations.withValue { $0.removeFirst() } },
            applicationQuitHandler: { _, _ in
                quitCalls += 1
                return true
            })

        do {
            _ = try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "PID:\(runningApplication.processIdentifier)",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: runningApplication.processIdentifier,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationBundleIdentifier: "com.apple.finder",
                    activates: true),
                waitSeconds: 0))
            Issue.record("Expected a pre-dispatch relaunch refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }

        #expect(quitCalls == 0)
        #expect(openRecorder.calls.isEmpty)
        #expect(generations.value.isEmpty)
    }

    @Test
    @MainActor
    func `relaunch refuses when its quit request is rejected before dispatch`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(
            targetPID: 4242,
            quitAttempt: .init(requestAccepted: false, terminated: false))
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning,
            processStartIdentityProvider: { _ in 700 })

        do {
            _ = try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "Example",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 0))
            Issue.record("Expected pre-dispatch relaunch refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(lifecycle.quitCalls.count == 1)
            #expect(lifecycle.runningIdentifiers.isEmpty)
            #expect(openRecorder.calls.isEmpty)
        }
    }

    @Test
    @MainActor
    func `background launch result is a confirmed no-op with no dispatch`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] })

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: false))

        #expect(result.outcome?.state == .confirmedNoChange)
        #expect(result.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(recorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `foreground launch counts only its accepted open when activation is already complete`() async throws {
        let recorder = ApplicationOpenRecorder()
        var activationRequestCount = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            applicationActivationHandler: { _ in
                activationRequestCount += 1
                return true
            },
            applicationActiveProvider: { _ in true })

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: true))

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(recorder.calls.count == 1)
        #expect(activationRequestCount == 0)
    }

    @Test
    @MainActor
    func `foreground launch counts every accepted native activation retry after open`() async throws {
        let recorder = ApplicationOpenRecorder()
        var acceptedActivationCount = 0
        var isActive = false
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            applicationActivationHandler: { _ in
                acceptedActivationCount += 1
                isActive = acceptedActivationCount == 2
                return true
            },
            applicationActiveProvider: { _ in isActive },
            applicationActivationSleepHandler: { _ in })

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: true))

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
        #expect(result.outcome?.dispatchState == .dispatched(
            unitCount: DesktopActionOutcome.DispatchUnitCount(3)))
        #expect(recorder.calls.count == 1)
        #expect(acceptedActivationCount == 2)
    }

    @Test
    @MainActor
    func `foreground launch failure retains open and accepted activation counts`() async throws {
        let recorder = ApplicationOpenRecorder()
        var acceptedActivationCount = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            applicationActivationHandler: { _ in
                acceptedActivationCount += 1
                return true
            },
            applicationActiveProvider: { _ in false },
            applicationActivationSleepHandler: { _ in
                throw ApplicationLifecycleFixtureError.dispatchFailed
            })

        do {
            _ = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: true))
            Issue.record("Expected canonical post-dispatch launch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
            #expect(failure.outcome.dispatchState == .dispatched(
                unitCount: DesktopActionOutcome.DispatchUnitCount(3)))
            #expect(recorder.calls.count == 1)
            #expect(acceptedActivationCount == 2)
        }
    }

    @Test
    @MainActor
    func `relaunch rejects a PID-selected launch before resolving or quitting the target`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        let launchApplication = openRecorder.runningApplication
        let launchProcessIdentifier = launchApplication.processIdentifier
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning)

        await #expect(throws: PeekabooError.self) {
            try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "Example",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "PID:\(launchProcessIdentifier)",
                    activates: true),
                waitSeconds: 0))
        }

        #expect(lifecycle.resolvedIdentifiers.isEmpty)
        #expect(lifecycle.quitCalls.isEmpty)
        #expect(lifecycle.runningIdentifiers.isEmpty)
        #expect(openRecorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `launch handler failure is canonical and retry unsafe`() async throws {
        let service = ApplicationService(applicationOpenHandler: { _, _, _ in
            throw ApplicationLifecycleFixtureError.dispatchFailed
        })

        do {
            _ = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: true))
            Issue.record("Expected canonical launch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        }
    }

    @Test
    @MainActor
    func `relaunch uncertain launch failure composes with confirmed quit`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in
                throw ApplicationLifecycleFixtureError.dispatchFailed
            },
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning,
            processStartIdentityProvider: { _ in 700 })

        do {
            _ = try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "Example",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 0))
            Issue.record("Expected indeterminate relaunch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
            #expect(failure.targetReceipt == .init(
                processIdentifier: 4242,
                processStartIdentity: 700))
            #expect(lifecycle.quitCalls.count == 1)
            #expect(lifecycle.runningIdentifiers == ["PID:4242"])
        }
    }

    @Test
    @MainActor
    func `relaunch preserves response loss across confirmed quit and uncertain foreground launch`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in
                throw DesktopActionFailure.indeterminate(
                    delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                    evidence: .responseLost,
                    unitCount: .one,
                    message: "The launch response was lost.")
            },
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning,
            processStartIdentityProvider: { _ in 700 })

        do {
            _ = try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "Example",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 0))
            Issue.record("Expected response-lost relaunch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .local)
            #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
            #expect(failure.outcome.evidence == .responseLost)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
            #expect(lifecycle.quitCalls.count == 1)
            #expect(lifecycle.runningIdentifiers == ["PID:4242"])
        }
    }

    @Test
    @MainActor
    func `relaunch cancellation during wait keeps confirmed quit background delivery`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning,
            processStartIdentityProvider: { _ in 700 })
        let task = Task { @MainActor in
            try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "Example",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 30))
        }
        while lifecycle.runningIdentifiers.isEmpty {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected partial relaunch cancellation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .background))
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(openRecorder.calls.isEmpty)
        }
    }

    @Test
    @MainActor
    func `relaunch cancellation while target remains alive is unverified rather than partial`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        var runningCheckCount = 0
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: { _ in
                runningCheckCount += 1
                return true
            },
            processStartIdentityProvider: { _ in 700 })
        let task = Task { @MainActor in
            try await service.relaunchApplicationResult(request: ApplicationRelaunchRequest(
                targetIdentifier: "Example",
                expectedTargetIdentity: ApplicationProcessIdentity(
                    processIdentifier: 4242,
                    processStartIdentity: 700),
                launchRequest: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: true),
                waitSeconds: 0))
        }
        while runningCheckCount == 0 {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected canonical relaunch cancellation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.evidence == .operationStillRunning)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
            #expect(openRecorder.calls.isEmpty)
        }
    }

    @Test
    @MainActor
    func `relaunch termination timeout is a suspected no-op instead of a partial quit`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: { _ in true },
            processStartIdentityProvider: { _ in 700 })

        do {
            _ = try await service.performApplicationRelaunchWithOutcomeOwnedLane(
                ApplicationRelaunchRequest(
                    targetIdentifier: "Example",
                    expectedTargetIdentity: ApplicationProcessIdentity(
                        processIdentifier: 4242,
                        processStartIdentity: 700),
                    launchRequest: ApplicationLaunchRequest(
                        applicationIdentifier: "Finder",
                        activates: true),
                    waitSeconds: 0),
                terminationTimeoutSeconds: 0)
            Issue.record("Expected canonical relaunch termination failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .suspectedNoop)
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .safe)
            #expect(lifecycle.quitCalls.count == 1)
            #expect(openRecorder.calls.isEmpty)
        }
    }

    @Test
    @MainActor
    func `already active activation result is confirmed no-change without dispatch`() async throws {
        let runningApplication = try self.runningApplication()
        var dispatchCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in
                dispatchCount += 1
                return true
            },
            applicationActiveProvider: { _ in true },
            frontmostProcessIdentifierProvider: { runningApplication.processIdentifier },
            windowServerActivationStateProvider: { _ in
                ApplicationService.WindowServerActivationState(
                    targetHasVisibleWindow: false,
                    frontmostWindowProcessIdentifier: nil)
            })

        let result = try await service.activateApplicationResult(request: ApplicationActivationRequest(
            identifier: "PID:\(runningApplication.processIdentifier)"))

        #expect(result.outcome?.state == .confirmedNoChange)
        #expect(result.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(dispatchCount == 0)
    }

    @Test
    @MainActor
    func `legacy quit overloads return false while result refuses a rejected request`() async throws {
        let runningApplication = try self.runningApplication()
        let processIdentifier = runningApplication.processIdentifier
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(processIdentifier))
        var quitRequestForces: [Bool] = []
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in processStartIdentity },
            applicationQuitHandler: { _, force in
                quitRequestForces.append(force)
                return false
            })
        let identifier = "PID:\(processIdentifier)"

        let identifierResult = try await service.quitApplication(identifier: identifier)
        let requestResult = try await service.quitApplication(request: ApplicationQuitRequest(
            identifier: identifier,
            force: true))

        #expect(!identifierResult)
        #expect(!requestResult)

        do {
            _ = try await service.quitApplicationResult(request: ApplicationQuitRequest(
                identifier: identifier))
            Issue.record("Expected pre-dispatch quit refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == .init(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity))
        }
        #expect(quitRequestForces == [false, true, false])
    }

    @Test
    @MainActor
    func `legacy quit propagates an unsafe failure after dispatch`() async throws {
        let runningApplication = try self.runningApplication()
        let processIdentifier = runningApplication.processIdentifier
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(processIdentifier))
        var requestAccepted = false
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in processStartIdentity },
            applicationQuitHandler: { _, _ in
                requestAccepted = true
                return true
            },
            applicationQuitTimeout: 30)
        let task = Task { @MainActor in
            try await service.quitApplication(identifier: "PID:\(processIdentifier)")
        }
        while !requestAccepted {
            await Task.yield()
        }

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected unsafe post-dispatch quit failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    @MainActor
    func `accepted quit with no observed effect preserves false payload and suspected no-op`() async throws {
        let runningApplication = try self.runningApplication()
        let processIdentifier = runningApplication.processIdentifier
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(processIdentifier))
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in processStartIdentity },
            applicationQuitHandler: { _, _ in true },
            applicationQuitTimeout: 0)

        let result = try await service.quitApplicationResult(request: ApplicationQuitRequest(
            identifier: "PID:\(processIdentifier)"))

        #expect(!result.payload)
        #expect(result.outcome?.state == .suspectedNoop)
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(result.outcome?.retrySafety == .safe)
    }

    @Test
    @MainActor
    func `activation cancellation after dispatch is a canonical unsafe failure`() async throws {
        let runningApplication = try self.runningApplication()
        let identity = try ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(
                runningApplication.processIdentifier)))
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in true },
            applicationActiveProvider: { _ in false },
            frontmostProcessIdentifierProvider: { nil },
            windowServerActivationStateProvider: { _ in
                ApplicationService.WindowServerActivationState(
                    targetHasVisibleWindow: false,
                    frontmostWindowProcessIdentifier: nil)
            },
            applicationActivationSleepHandler: { _ in throw CancellationError() },
            applicationActivationTimeout: .seconds(1))

        do {
            _ = try await service.activateApplicationResult(request: ApplicationActivationRequest(
                identifier: "PID:\(runningApplication.processIdentifier)",
                expectedIdentity: identity))
            Issue.record("Expected canonical post-dispatch cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.evidence == .operationStillRunning)
            #expect(failure.targetReceipt == .init(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    @MainActor
    func `visibility result never reports no-change after dispatch`() async throws {
        let runningApplication = try self.runningApplication()
        var isHidden = false
        var dispatchCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in isHidden },
            applicationVisibilityHandler: { _, hidden in
                dispatchCount += 1
                isHidden = hidden
                return true
            },
            applicationVisibilityTimeout: 0)

        let result = try await service.hideApplicationResult(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .background))
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(dispatchCount == 1)
    }

    @Test
    @MainActor
    func `AX hide result reports accessibility action delivery`() async throws {
        let runningApplication = try self.runningApplication()
        var isHidden = false
        var accessibilityHideCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in isHidden },
            applicationAccessibilityHideHandler: { _ in
                accessibilityHideCount += 1
                isHidden = true
            },
            applicationVisibilityTimeout: 0)

        let result = try await service.hideApplicationResult(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(result.outcome?.state == .confirmedChange)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(accessibilityHideCount == 1)
    }

    @Test
    @MainActor
    func `visibility request with observed no effect throws suspected no-op`() async throws {
        let runningApplication = try self.runningApplication()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in false },
            applicationVisibilityHandler: { _, _ in true },
            applicationVisibilityTimeout: 0)

        do {
            _ = try await service.hideApplicationResult(
                identifier: "PID:\(runningApplication.processIdentifier)")
            Issue.record("Expected suspected no-op visibility failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .suspectedNoop)
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
        }
    }

    @Test
    @MainActor
    func `rejected visibility request is refused without dispatch or polling`() async throws {
        let runningApplication = try self.runningApplication()
        var visibilityReadCount = 0
        var sleepCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationHiddenProvider: { _ in
                visibilityReadCount += 1
                return false
            },
            applicationVisibilityHandler: { _, _ in false },
            applicationVisibilitySleepHandler: { _ in sleepCount += 1 },
            applicationVisibilityTimeout: 1)

        do {
            _ = try await service.hideApplicationResult(
                identifier: "PID:\(runningApplication.processIdentifier)")
            Issue.record("Expected pre-dispatch visibility refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.message.contains("visibility request was not accepted"))
            #expect(visibilityReadCount == 2)
            #expect(sleepCount == 0)
        }
    }
}
