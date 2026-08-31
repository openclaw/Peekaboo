import AppKit
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceLifecycleTests {
    @Test
    @MainActor
    func `application activation retries until exact PID owns Workspace and frontmost window`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && !$0.isTerminated
        })
        let targetProcessIdentifier = runningApplication.processIdentifier
        var nativeActivationCount = 0
        var accessibilityActivationCount = 0
        var sleepCount = 0
        var isActive = false
        let frontmostProcessIdentifier = AutomationTestLockedValue<pid_t?>(nil)
        var windowServerState = ApplicationService.WindowServerActivationState(
            targetHasVisibleWindow: true,
            frontmostWindowProcessIdentifier: nil)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in
                nativeActivationCount += 1
                return true
            },
            applicationAccessibilityActivationHandler: { processIdentifier in
                accessibilityActivationCount += 1
                #expect(processIdentifier == targetProcessIdentifier)
                isActive = true
                frontmostProcessIdentifier.value = processIdentifier
                windowServerState = ApplicationService.WindowServerActivationState(
                    targetHasVisibleWindow: true,
                    frontmostWindowProcessIdentifier: processIdentifier)
                return true
            },
            applicationActiveProvider: { _ in isActive },
            frontmostProcessIdentifierProvider: { frontmostProcessIdentifier.value },
            windowServerActivationStateProvider: { _ in windowServerState },
            applicationActivationSleepHandler: { _ in sleepCount += 1 },
            applicationActivationTimeout: .seconds(1))

        let result = try await service.activateApplicationResult(request: ApplicationActivationRequest(
            identifier: "PID:\(targetProcessIdentifier)"))

        #expect(nativeActivationCount == 2)
        #expect(accessibilityActivationCount == 1)
        #expect(sleepCount == 1)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .foreground))
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: nil))
    }

    @Test
    @MainActor
    func `application activation reports native delivery when native request verifies immediately`() async throws {
        let runningApplication = try self.runningApplication()
        let processIdentifier = runningApplication.processIdentifier
        var nativeActivationCount = 0
        var accessibilityActivationCount = 0
        var isActive = false
        let frontmostProcessIdentifier = AutomationTestLockedValue<pid_t?>(nil)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in
                nativeActivationCount += 1
                isActive = true
                frontmostProcessIdentifier.value = processIdentifier
                return true
            },
            applicationAccessibilityActivationHandler: { _ in
                accessibilityActivationCount += 1
                return true
            },
            applicationActiveProvider: { _ in isActive },
            frontmostProcessIdentifierProvider: { frontmostProcessIdentifier.value },
            windowServerActivationStateProvider: { _ in
                ApplicationService.WindowServerActivationState(
                    targetHasVisibleWindow: false,
                    frontmostWindowProcessIdentifier: nil)
            })

        let result = try await service.activateApplicationResult(request: ApplicationActivationRequest(
            identifier: "PID:\(processIdentifier)"))

        #expect(result.outcome?.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(nativeActivationCount == 1)
        #expect(accessibilityActivationCount == 0)
    }

    @Test
    @MainActor
    func `pinned activation rejects process generation drift before dispatch`() async throws {
        let runningApplication = try self.runningApplication()
        let processIdentifier = runningApplication.processIdentifier
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(processIdentifier))
        var dispatchCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in
                dispatchCount += 1
                return true
            },
            processStartIdentityProvider: { _ in processStartIdentity })

        await #expect(throws: PeekabooError.self) {
            try await service.activateApplication(request: ApplicationActivationRequest(
                identifier: "PID:\(processIdentifier)",
                expectedIdentity: ApplicationProcessIdentity(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity + 1)))
        }

        #expect(dispatchCount == 0)
    }

    @Test
    @MainActor
    func `application activation verification requires exact Workspace and visible window owners`() {
        #expect(ApplicationService.isVerifiedApplicationActivation(
            processIdentifier: 42,
            isActive: true,
            frontmostProcessIdentifier: 42,
            targetHasVisibleWindow: true,
            frontmostWindowProcessIdentifier: 42))
        #expect(!ApplicationService.isVerifiedApplicationActivation(
            processIdentifier: 42,
            isActive: false,
            frontmostProcessIdentifier: 42,
            targetHasVisibleWindow: true,
            frontmostWindowProcessIdentifier: 42))
        #expect(!ApplicationService.isVerifiedApplicationActivation(
            processIdentifier: 42,
            isActive: true,
            frontmostProcessIdentifier: 43,
            targetHasVisibleWindow: true,
            frontmostWindowProcessIdentifier: 42))
        #expect(!ApplicationService.isVerifiedApplicationActivation(
            processIdentifier: 42,
            isActive: true,
            frontmostProcessIdentifier: 42,
            targetHasVisibleWindow: true,
            frontmostWindowProcessIdentifier: 43))
        #expect(ApplicationService.isVerifiedApplicationActivation(
            processIdentifier: 42,
            isActive: true,
            frontmostProcessIdentifier: 42,
            targetHasVisibleWindow: false,
            frontmostWindowProcessIdentifier: 43))
    }

    @Test
    @MainActor
    func `application activation rejects an accepted request that never becomes frontmost`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && !$0.isTerminated
        })
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in true },
            applicationAccessibilityActivationHandler: { _ in true },
            applicationActiveProvider: { _ in true },
            frontmostProcessIdentifierProvider: { runningApplication.processIdentifier + 1 },
            windowServerActivationStateProvider: { _ in
                ApplicationService.WindowServerActivationState(
                    targetHasVisibleWindow: true,
                    frontmostWindowProcessIdentifier: runningApplication.processIdentifier + 1)
            },
            applicationActivationTimeout: .zero)

        do {
            try await service.activateApplication(identifier: "PID:\(runningApplication.processIdentifier)")
            Issue.record("Expected canonical activation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .suspectedNoop)
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
        }
    }

    @Test
    @MainActor
    func `application activation refuses when native and accessibility requests are rejected`() async throws {
        let runningApplication = try self.runningApplication()
        let processIdentifier = runningApplication.processIdentifier
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(processIdentifier))
        var nativeRequestCount = 0
        var accessibilityRequestCount = 0
        var sleepCount = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in
                nativeRequestCount += 1
                return false
            },
            applicationAccessibilityActivationHandler: { _ in
                accessibilityRequestCount += 1
                return false
            },
            applicationActiveProvider: { _ in false },
            frontmostProcessIdentifierProvider: { nil },
            windowServerActivationStateProvider: { _ in
                ApplicationService.WindowServerActivationState(
                    targetHasVisibleWindow: false,
                    frontmostWindowProcessIdentifier: nil)
            },
            applicationActivationSleepHandler: { _ in sleepCount += 1 },
            processStartIdentityProvider: { _ in processStartIdentity },
            applicationActivationTimeout: .zero)

        do {
            _ = try await service.activateApplicationResult(request: ApplicationActivationRequest(
                identifier: "PID:\(processIdentifier)"))
            Issue.record("Expected pre-dispatch activation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(nativeRequestCount == 1)
            #expect(accessibilityRequestCount == 1)
            #expect(sleepCount == 0)
        }
    }

    @Test
    @MainActor
    func `quit verification waits until the process is actually terminated`() async throws {
        var checks = 0
        let terminated = try await waitForApplicationTermination(
            timeoutSeconds: 1,
            pollInterval: .zero)
        {
            checks += 1
            return checks >= 3
        }

        #expect(terminated)
        #expect(checks == 3)
    }

    @Test
    @MainActor
    func `quit verification returns false when the process outlives its deadline`() async throws {
        var checks = 0
        let terminated = try await waitForApplicationTermination(
            timeoutSeconds: 0,
            pollInterval: .zero)
        {
            checks += 1
            return false
        }

        #expect(!terminated)
        #expect(checks == 2)
    }

    @Test
    @MainActor
    func `cancelled quit verification stops before another process check`() async throws {
        var checks = 0
        let task = Task { @MainActor in
            try await waitForApplicationTermination(
                timeoutSeconds: 30,
                pollInterval: .seconds(30))
            {
                checks += 1
                return false
            }
        }
        while checks == 0 {
            await Task.yield()
        }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(checks == 1)
    }

    @Test
    @MainActor
    func `pre-cancelled quit verification performs no process check`() async {
        var checks = 0
        await #expect(throws: CancellationError.self) {
            try await Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await waitForApplicationTermination(timeoutSeconds: 30) {
                    checks += 1
                    return false
                }
            }.value
        }
        #expect(checks == 0)
    }

    @Test
    func `application info decodes older bridge payload without window identities`() throws {
        let data = Data(
            """
            {
              "processIdentifier": 42,
              "bundleIdentifier": "com.example.App",
              "name": "App",
              "bundlePath": null,
              "isActive": false,
              "isHidden": false,
              "windowCount": 1,
              "activationPolicy": "regular",
              "isFinishedLaunching": true
            }
            """.utf8)

        let info = try JSONDecoder().decode(ServiceApplicationInfo.self, from: data)

        #expect(info.windowCount == 1)
        #expect(info.windowIDs == nil)
        #expect(info.processStartIdentity == nil)
        #expect(info.executablePath == nil)
    }

    @Test
    @MainActor
    func `normal and forced quit reject PID reuse immediately before termination`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })

        for force in [false, true] {
            let identities = AutomationTestLockedValue<[UInt64]>([70, 70, 70, 71])
            var terminationCalls = 0
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in runningApplication },
                processStartIdentityProvider: { _ in
                    identities.withValue { $0.isEmpty ? 71 : $0.removeFirst() }
                },
                applicationQuitHandler: { _, _ in
                    terminationCalls += 1
                    return true
                })
            let expectedIdentity = ApplicationProcessIdentity(
                processIdentifier: runningApplication.processIdentifier,
                processStartIdentity: 70)

            await #expect(throws: PeekabooError.self) {
                try await service.quitApplication(request: ApplicationQuitRequest(
                    identifier: "PID:\(runningApplication.processIdentifier)",
                    force: force,
                    expectedIdentity: expectedIdentity))
            }

            #expect(terminationCalls == 0)
            #expect(identities.value.isEmpty)
        }
    }

    @Test
    @MainActor
    func `nil identity quit derives stable receipt and rejects PID reuse`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })

        for force in [false, true] {
            let identities = AutomationTestLockedValue<[UInt64]>([70, 70, 70, 71])
            var terminationCalls = 0
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in runningApplication },
                processStartIdentityProvider: { _ in identities.withValue { $0.removeFirst() } },
                applicationQuitHandler: { _, _ in
                    terminationCalls += 1
                    return true
                })

            await #expect(throws: PeekabooError.self) {
                try await service.quitApplication(request: ApplicationQuitRequest(
                    identifier: "PID:\(runningApplication.processIdentifier)",
                    force: force))
            }

            #expect(terminationCalls == 0)
            #expect(identities.value.isEmpty)
        }
    }

    @Test
    @MainActor
    func `legacy quit overload unwraps the lane-owned result and rejects PID reuse`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })

        for force in [false, true] {
            let identities = AutomationTestLockedValue<[UInt64]>([70, 70, 70, 71])
            var terminationCalls = 0
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in runningApplication },
                processStartIdentityProvider: { _ in
                    identities.withValue { $0.isEmpty ? 71 : $0.removeFirst() }
                },
                applicationQuitHandler: { _, _ in
                    terminationCalls += 1
                    return true
                })

            await #expect(throws: PeekabooError.self) {
                try await service.quitApplication(
                    identifier: "PID:\(runningApplication.processIdentifier)",
                    force: force)
            }

            #expect(terminationCalls == 0)
            #expect(identities.value.isEmpty)
        }
    }

    @Test
    @MainActor
    func `application discovery omits an unstable process generation`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })
        let identities = AutomationTestLockedValue<[UInt64]>([70, 71])
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in identities.withValue { $0.removeFirst() } })

        let application = try await service.findApplication(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(application.processStartIdentity == nil)
        #expect(identities.value.isEmpty)
    }

    @Test
    func `Launch request defaults to background`() {
        let request = ApplicationLaunchRequest(applicationIdentifier: "Finder")
        #expect(request.activates == false)
        #expect(request.createsNewInstance == false)
    }

    @Test
    func `Launch request decodes pre-1_13 bridge payloads`() throws {
        let data = Data(
            """
            {
              "applicationIdentifier": "Finder",
              "openURLs": [],
              "activates": false,
              "waitUntilReady": true
            }
            """.utf8)

        let request = try JSONDecoder().decode(ApplicationLaunchRequest.self, from: data)

        #expect(request.applicationIdentifier == "Finder")
        #expect(request.waitUntilReady)
        #expect(!request.waitForWindow)
        #expect(!request.createsNewInstance)
    }

    @Test
    @MainActor
    func `background no-op returns the selected process generation`() async throws {
        let recorder = ApplicationOpenRecorder()
        let identities = AutomationTestLockedValue<[UInt64]>([70, 70, 70, 70])
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            processStartIdentityProvider: { _ in identities.withValue { $0.removeFirst() } })

        let application = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder"))

        #expect(application.processIdentity == ApplicationProcessIdentity(
            processIdentifier: recorder.runningApplication.processIdentifier,
            processStartIdentity: 70))
        #expect(identities.value.isEmpty)
    }

    @Test
    @MainActor
    func `background no-op rejects PID reuse before returning its receipt`() async throws {
        let recorder = ApplicationOpenRecorder()
        let identities = AutomationTestLockedValue<[UInt64]>([70, 70, 71, 71])
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            processStartIdentityProvider: { _ in identities.withValue { $0.removeFirst() } })

        do {
            _ = try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder"))
            Issue.record("Expected launch receipt generation mismatch")
        } catch let error as ApplicationLifecycleRefusalError {
            #expect(error.userMessage.contains("process generation"))
        }
        #expect(identities.value.isEmpty)
    }

    @Test
    @MainActor
    func `PID candidate selection keeps the exact requested process generation`() throws {
        let applications = try self.runningApplications(count: 2)
        let target = applications[1]
        let targetIdentity = ApplicationProcessIdentity(
            processIdentifier: target.processIdentifier,
            processStartIdentity: 900)
        let service = ApplicationService(
            applicationOpenHandler: ApplicationOpenRecorder().open,
            processStartIdentityProvider: { processIdentifier in
                processIdentifier == target.processIdentifier ? 900 : 800
            })

        let selected = service.selectRunningApplication(
            applications,
            requestedIdentity: targetIdentity)

        #expect(selected?.processIdentifier == target.processIdentifier)
    }

    @Test
    @MainActor
    func `PID launch rejects open delivery before LaunchServices dispatch`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)
        let targetURL = try #require(URL(string: "https://example.com"))

        await #expect(throws: PeekabooError.self) {
            try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "PID:\(recorder.runningApplication.processIdentifier)",
                openURLs: [targetURL],
                activates: true))
        }

        #expect(recorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `Finder resolves from CoreServices without launching`() throws {
        let url = try ApplicationService().resolveApplicationURL("Finder")

        #expect(url.path == "/System/Library/CoreServices/Finder.app")
    }

    @Test
    @MainActor
    func `background launch returns an exact already-running no-op without dispatch`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] })

        let application = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: false))

        #expect(recorder.calls.isEmpty)
        #expect(application.processIdentifier == recorder.runningApplication.processIdentifier)
    }

    @Test
    @MainActor
    func `unsafe background launch shapes refuse before every dispatch surface`() async throws {
        let applicationRecorder = ApplicationOpenRecorder()
        let defaultRecorder = DefaultApplicationOpenRecorder()
        var runningInventoryReads = 0
        let service = ApplicationService(
            applicationOpenHandler: applicationRecorder.open,
            defaultApplicationOpenHandler: defaultRecorder.open,
            runningApplicationsForURLProvider: { _ in
                runningInventoryReads += 1
                return []
            })
        let target = try #require(URL(string: "https://example.com/background-refusal"))
        let requests = [
            ApplicationLaunchRequest(applicationIdentifier: "Finder"),
            ApplicationLaunchRequest(applicationIdentifier: "Finder", openURLs: [target]),
            ApplicationLaunchRequest(applicationIdentifier: "Finder", createsNewInstance: true),
            ApplicationLaunchRequest(openURLs: [target]),
        ]

        for request in requests {
            await #expect(throws: ApplicationLifecycleRefusalError.self) {
                _ = try await service.launchApplication(request: request)
            }
        }

        #expect(runningInventoryReads == 1)
        #expect(applicationRecorder.calls.isEmpty)
        #expect(defaultRecorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `foreground default-handler URL open preserves LaunchServices delivery`() async throws {
        let applicationRecorder = ApplicationOpenRecorder()
        let defaultRecorder = DefaultApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: applicationRecorder.open,
            defaultApplicationOpenHandler: defaultRecorder.open)
        let target = try #require(URL(string: "https://example.com/fixture"))

        let application = try await service.launchApplication(request: ApplicationLaunchRequest(
            openURLs: [target],
            activates: true))

        let call = try #require(defaultRecorder.calls.first)
        #expect(defaultRecorder.calls.count == 1)
        #expect(applicationRecorder.calls.isEmpty)
        #expect(call.targetURL == target)
        #expect(call.activates)
        #expect(application.processIdentifier == defaultRecorder.runningApplication.processIdentifier)
    }

    @Test
    @MainActor
    func `foreground new-instance launch configures LaunchServices`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: true,
            createsNewInstance: true))

        let call = try #require(recorder.calls.first)
        #expect(call.createsNewApplicationInstance)
        #expect(!call.allowsRunningApplicationSubstitution)
        #expect(call.activates)
    }

    @Test
    @MainActor
    func `new-instance launch binds the exact process returned by LaunchServices`() async throws {
        let recorder = ApplicationOpenRecorder()
        let runningApplication = recorder.runningApplication
        let processStartIdentity = try #require(
            SystemIdentityResolver.processStartIdentity(runningApplication.processIdentifier))
        var ambientCandidateReads = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            applicationSelectorCandidatesProvider: {
                ambientCandidateReads += 1
                return [ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: runningApplication.processIdentifier + 1,
                    bundleIdentifier: runningApplication.bundleIdentifier,
                    name: runningApplication.localizedName ?? "Finder",
                    bundlePath: runningApplication.bundleURL?.path,
                    executablePath: runningApplication.executableURL?.path,
                    isRegularApplication: true)]
            },
            applicationActiveProvider: { _ in true },
            processStartIdentityProvider: { _ in processStartIdentity })

        let result = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: true,
            waitUntilReady: false,
            createsNewInstance: true))

        let proof = try #require(result.payload.selectorResolutionProofs?.first)
        #expect(result.payload.processIdentity == ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: processStartIdentity))
        #expect(proof.selectedProcessIdentity == result.payload.processIdentity)
        #expect(proof.candidateCount == 1)
        #expect(ambientCandidateReads == 0)
    }

    @Test
    @MainActor
    func `new-instance selector mismatch remains an unsafe post-dispatch failure`() async throws {
        let recorder = ApplicationOpenRecorder()
        let processStartIdentity = try #require(
            SystemIdentityResolver.processStartIdentity(recorder.runningApplication.processIdentifier))
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            applicationActiveProvider: { _ in true },
            processStartIdentityProvider: { _ in processStartIdentity })

        do {
            _ = try await service.launchApplicationResult(request: ApplicationLaunchRequest(
                applicationIdentifier: "TextEdit",
                activates: true,
                waitUntilReady: false,
                createsNewInstance: true))
            Issue.record("Expected the returned application to fail its exact launch selector")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(recorder.calls.count == 1)
    }

    @Test
    @MainActor
    func `wait-for-window polls for automation readiness after process launch`() async throws {
        let recorder = ApplicationOpenRecorder()
        var readinessChecks = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            applicationReadinessHandler: { _ in
                readinessChecks += 1
                return readinessChecks >= 2
            })

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            waitForWindow: true))

        #expect(readinessChecks == 2)
        #expect(recorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `wait-until-ready preserves launch-completion semantics`() async throws {
        let recorder = ApplicationOpenRecorder()
        var windowReadinessChecks = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            applicationReadinessHandler: { _ in
                windowReadinessChecks += 1
                return false
            })

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            waitUntilReady: true))

        #expect(windowReadinessChecks == 0)
    }

    @Test
    @MainActor
    func `wait-for-window fails within its bounded timeout`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            applicationReadinessHandler: { _ in false },
            applicationReadinessTimeout: 0)

        do {
            _ = try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                waitForWindow: true))
            Issue.record("Expected window readiness timeout")
        } catch let failure as ApplicationLifecycleReadOnlyFailureError {
            guard case let .timeout(message) = failure.underlyingError else {
                Issue.record("Expected wrapped timeout, got \(failure.underlyingError)")
                return
            }
            #expect(message.contains("automatable window"))
            #expect(failure.applicationLifecycleFailureMetadata?.retrySafe == true)
            #expect(failure.applicationLifecycleFailureMetadata?.mutationDispatched == false)
        }
    }
}
