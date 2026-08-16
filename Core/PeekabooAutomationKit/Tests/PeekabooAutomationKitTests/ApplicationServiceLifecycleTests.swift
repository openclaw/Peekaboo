import AppKit
import Foundation
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
        var frontmostProcessIdentifier: pid_t?
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
                frontmostProcessIdentifier = processIdentifier
                windowServerState = ApplicationService.WindowServerActivationState(
                    targetHasVisibleWindow: true,
                    frontmostWindowProcessIdentifier: processIdentifier)
                return true
            },
            applicationActiveProvider: { _ in isActive },
            frontmostProcessIdentifierProvider: { frontmostProcessIdentifier },
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
        var frontmostProcessIdentifier: pid_t?
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationActivationHandler: { _ in
                nativeActivationCount += 1
                isActive = true
                frontmostProcessIdentifier = processIdentifier
                return true
            },
            applicationAccessibilityActivationHandler: { _ in
                accessibilityActivationCount += 1
                return true
            },
            applicationActiveProvider: { _ in isActive },
            frontmostProcessIdentifierProvider: { frontmostProcessIdentifier },
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
            var identities: [UInt64] = [70, 70, 70, 71]
            var terminationCalls = 0
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in runningApplication },
                processStartIdentityProvider: { _ in
                    identities.isEmpty ? 71 : identities.removeFirst()
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
            #expect(identities.isEmpty)
        }
    }

    @Test
    @MainActor
    func `nil identity quit derives stable receipt and rejects PID reuse`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })

        for force in [false, true] {
            var identities: [UInt64] = [70, 70, 70, 71]
            var terminationCalls = 0
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in runningApplication },
                processStartIdentityProvider: { _ in identities.removeFirst() },
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
            #expect(identities.isEmpty)
        }
    }

    @Test
    @MainActor
    func `legacy quit overload unwraps the lane-owned result and rejects PID reuse`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })

        for force in [false, true] {
            var identities: [UInt64] = [70, 70, 70, 71]
            var terminationCalls = 0
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in runningApplication },
                processStartIdentityProvider: { _ in
                    identities.isEmpty ? 71 : identities.removeFirst()
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
            #expect(identities.isEmpty)
        }
    }

    @Test
    @MainActor
    func `application discovery omits an unstable process generation`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })
        var identities: [UInt64] = [70, 71]
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in identities.removeFirst() })

        let application = try await service.findApplication(
            identifier: "PID:\(runningApplication.processIdentifier)")

        #expect(application.processStartIdentity == nil)
        #expect(identities.isEmpty)
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
        var identities: [UInt64] = [70, 70, 70, 70]
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            processStartIdentityProvider: { _ in identities.removeFirst() })

        let application = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder"))

        #expect(application.processIdentity == ApplicationProcessIdentity(
            processIdentifier: recorder.runningApplication.processIdentifier,
            processStartIdentity: 70))
        #expect(identities.isEmpty)
    }

    @Test
    @MainActor
    func `background no-op rejects PID reuse before returning its receipt`() async throws {
        let recorder = ApplicationOpenRecorder()
        var identities: [UInt64] = [70, 70, 71, 71]
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            runningApplicationsForURLProvider: { _ in [recorder.runningApplication] },
            processStartIdentityProvider: { _ in identities.removeFirst() })

        do {
            _ = try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder"))
            Issue.record("Expected launch receipt generation mismatch")
        } catch let error as ApplicationLifecycleRefusalError {
            #expect(error.userMessage.contains("process generation"))
        }
        #expect(identities.isEmpty)
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
        var generations: [UInt64] = [700, 701]
        var quitCalls = 0
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            processStartIdentityProvider: { _ in generations.removeFirst() },
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
        #expect(generations.isEmpty)
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

@MainActor
extension ApplicationServiceLifecycleTests {
    fileprivate func runningApplication() throws -> NSRunningApplication {
        try self.runningApplications(count: 1)[0]
    }

    fileprivate func runningApplications(count: Int) throws -> [NSRunningApplication] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier > 0 && !$0.isTerminated && $0.isFinishedLaunching
        }
        try #require(applications.count >= count)
        return Array(applications.prefix(count))
    }
}

@MainActor
private final class ApplicationOpenRecorder {
    struct Call {
        let applicationURL: URL
        let openURLs: [URL]
        let activates: Bool
        let allowsRunningApplicationSubstitution: Bool
        let createsNewApplicationInstance: Bool
    }

    private(set) var calls: [Call] = []
    let runningApplication: NSRunningApplication

    init() {
        self.runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
            .first ?? NSWorkspace.shared.frontmostApplication ?? NSRunningApplication.current
    }

    func open(
        applicationURL: URL,
        openURLs: [URL],
        configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    {
        self.calls.append(Call(
            applicationURL: applicationURL,
            openURLs: openURLs,
            activates: configuration.activates,
            allowsRunningApplicationSubstitution: configuration.allowsRunningApplicationSubstitution,
            createsNewApplicationInstance: configuration.createsNewApplicationInstance))
        return self.runningApplication
    }
}

@MainActor
private final class DefaultApplicationOpenRecorder {
    struct Call {
        let targetURL: URL
        let activates: Bool
    }

    private(set) var calls: [Call] = []
    let runningApplication = NSWorkspace.shared.runningApplications.first {
        !$0.isTerminated && $0.isFinishedLaunching
    } ?? NSRunningApplication.current

    func open(
        targetURL: URL,
        configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    {
        self.calls.append(.init(targetURL: targetURL, activates: configuration.activates))
        return self.runningApplication
    }
}

@MainActor
private final class RelaunchLifecycleRecorder {
    struct QuitCall: Equatable {
        let identifier: String
        let force: Bool
        let expectedIdentity: ApplicationProcessIdentity?
    }

    private let targetPID: Int32
    private let quitAttempt: ApplicationService.ApplicationQuitAttempt
    private(set) var resolvedIdentifiers: [String] = []
    private(set) var quitCalls: [QuitCall] = []
    private(set) var runningIdentifiers: [String] = []

    init(
        targetPID: Int32,
        quitAttempt: ApplicationService.ApplicationQuitAttempt = .init(
            requestAccepted: true,
            terminated: true))
    {
        self.targetPID = targetPID
        self.quitAttempt = quitAttempt
    }

    func resolve(identifier: String) async throws -> ServiceApplicationInfo {
        self.resolvedIdentifiers.append(identifier)
        return ServiceApplicationInfo(
            processIdentifier: self.targetPID,
            processStartIdentity: 700,
            bundleIdentifier: "com.apple.finder",
            name: "Finder",
            bundlePath: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder")?.path)
    }

    func quit(request: ApplicationQuitRequest) async throws -> ApplicationService.ApplicationQuitAttempt {
        self.quitCalls.append(.init(
            identifier: request.identifier,
            force: request.force,
            expectedIdentity: request.expectedIdentity))
        return self.quitAttempt
    }

    func isRunning(identifier: String) async -> Bool {
        self.runningIdentifiers.append(identifier)
        return false
    }
}

private enum ApplicationLifecycleFixtureError: Error {
    case dispatchFailed
}
