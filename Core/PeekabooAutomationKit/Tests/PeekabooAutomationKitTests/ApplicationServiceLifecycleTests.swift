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

        try await service.activateApplication(identifier: "PID:\(targetProcessIdentifier)")

        #expect(nativeActivationCount == 2)
        #expect(accessibilityActivationCount == 1)
        #expect(sleepCount == 1)
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

        await #expect(throws: PeekabooError.self) {
            try await service.activateApplication(identifier: "PID:\(runningApplication.processIdentifier)")
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
    func `legacy quit overload pins generation and rejects PID reuse`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })

        for force in [false, true] {
            var identities: [UInt64] = [70, 70, 70, 70, 70, 71]
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
    func `launch result retains the process generation selected by LaunchServices`() async throws {
        let recorder = ApplicationOpenRecorder()
        var identities: [UInt64] = [70, 70, 70, 70]
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            processStartIdentityProvider: { _ in identities.removeFirst() },
            backgroundLaunchActivationGraceDuration: .zero,
            backgroundActivationLeaseFactory: self.isolatedBackgroundActivationLeaseFactory())

        let application = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder"))

        #expect(application.processIdentity == ApplicationProcessIdentity(
            processIdentifier: recorder.runningApplication.processIdentifier,
            processStartIdentity: 70))
        #expect(identities.isEmpty)
    }

    @Test
    @MainActor
    func `launch result rejects PID reuse after LaunchServices selects the process`() async throws {
        let recorder = ApplicationOpenRecorder()
        var identities: [UInt64] = [70, 70, 71, 71]
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            processStartIdentityProvider: { _ in identities.removeFirst() },
            backgroundLaunchActivationGraceDuration: .zero,
            backgroundActivationLeaseFactory: self.isolatedBackgroundActivationLeaseFactory())

        do {
            _ = try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder"))
            Issue.record("Expected launch receipt generation mismatch")
        } catch let PeekabooError.commandFailed(message) {
            #expect(message.contains("process generation changed"))
        }
        #expect(identities.isEmpty)
    }

    @Test
    @MainActor
    func `Finder resolves from CoreServices without launching`() throws {
        let url = try ApplicationService().resolveApplicationURL("Finder")

        #expect(url.path == "/System/Library/CoreServices/Finder.app")
    }

    @Test
    @MainActor
    func `launch dispatches a no-focus reopen for an already running application`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)

        let application = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: false))

        let call = try #require(recorder.calls.first)
        #expect(recorder.calls.count == 1)
        #expect(call.applicationURL.path == "/System/Library/CoreServices/Finder.app")
        #expect(call.openURLs.isEmpty)
        #expect(!call.activates)
        #expect(!call.createsNewApplicationInstance)
        #expect(call.allowsRunningApplicationSubstitution)
        #expect(application.processIdentifier == recorder.runningApplication.processIdentifier)
    }

    @Test
    @MainActor
    func `default-handler URL open uses the same background configuration`() async throws {
        let applicationRecorder = ApplicationOpenRecorder()
        let defaultRecorder = DefaultApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: applicationRecorder.open,
            defaultApplicationOpenHandler: defaultRecorder.open,
            backgroundOpenActivationGraceDuration: .zero)
        let target = try #require(URL(string: "https://example.com/fixture"))

        let application = try await service.launchApplication(request: ApplicationLaunchRequest(
            openURLs: [target],
            activates: false))

        let call = try #require(defaultRecorder.calls.first)
        #expect(defaultRecorder.calls.count == 1)
        #expect(applicationRecorder.calls.isEmpty)
        #expect(call.targetURL == target)
        #expect(!call.activates)
        #expect(application.processIdentifier == defaultRecorder.runningApplication.processIdentifier)
    }

    @Test
    @MainActor
    func `new-instance launch remains background and configures LaunchServices`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            activates: false,
            createsNewInstance: true))

        let call = try #require(recorder.calls.first)
        #expect(call.createsNewApplicationInstance)
        #expect(!call.allowsRunningApplicationSubstitution)
        #expect(!call.activates)
    }

    @Test
    @MainActor
    func `wait-for-window polls for automation readiness after process launch`() async throws {
        let recorder = ApplicationOpenRecorder()
        var readinessChecks = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
            applicationReadinessHandler: { _ in
                readinessChecks += 1
                return readinessChecks >= 2
            })

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "Finder",
            waitForWindow: true))

        #expect(readinessChecks == 2)
        #expect(recorder.calls.count == 1)
    }

    @Test
    @MainActor
    func `wait-until-ready preserves launch-completion semantics`() async throws {
        let recorder = ApplicationOpenRecorder()
        var windowReadinessChecks = 0
        let service = ApplicationService(
            applicationOpenHandler: recorder.open,
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
            applicationReadinessHandler: { _ in false },
            applicationReadinessTimeout: 0)

        do {
            _ = try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                waitForWindow: true))
            Issue.record("Expected window readiness timeout")
        } catch let PeekabooError.timeout(message) {
            #expect(message.contains("automatable window"))
        }
    }
}

extension ApplicationServiceLifecycleTests {
    @Test
    @MainActor
    func `background restoration confirms only an active exact candidate`() async throws {
        let candidate = try self.runningApplication()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
        probe.activeProcessIdentifiers.insert(candidate.processIdentifier)
        let lease = probe.makeLease(previousApplication: candidate)

        #expect(lease.setTargetProcessIdentifier(self.syntheticTargetPID()))
        let outcome = await lease.waitForReconciliation()

        #expect(outcome == .candidateConfirmed(candidate.processIdentifier))
        #expect(probe.nativeActivationRequests.isEmpty)
        #expect(probe.accessibilityActivationRequests.isEmpty)
    }

    @Test
    @MainActor
    func `background restoration accepts user foreground without fighting it`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()
        let frontmostPIDs = [candidate.processIdentifier, targetPID + 1]

        for frontmostPID in frontmostPIDs {
            let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: frontmostPID)
            let lease = probe.makeLease(previousApplication: candidate)
            #expect(lease.setTargetProcessIdentifier(targetPID))

            #expect(await lease.waitForReconciliation() == .differentFrontmost(frontmostPID))
            #expect(probe.nativeActivationRequests.isEmpty)
            #expect(probe.accessibilityActivationRequests.isEmpty)
        }
    }

    @Test
    @MainActor
    func `background restoration waits through transient nil without activating`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: nil)
        probe.onConfirmationSleep = { callCount in
            #expect(probe.nativeActivationRequests.isEmpty)
            if callCount == 1 {
                probe.frontmostProcessIdentifier = targetPID
                probe.onNativeActivation = { application in
                    probe.activeProcessIdentifiers.insert(application.processIdentifier)
                    probe.frontmostProcessIdentifier = application.processIdentifier
                }
            }
        }
        let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(250))

        #expect(lease.setTargetProcessIdentifier(targetPID))

        #expect(await lease.waitForReconciliation() == .candidateConfirmed(candidate.processIdentifier))
        #expect(probe.nativeActivationRequests == [candidate.processIdentifier])
    }

    @Test
    @MainActor
    func `background restoration accepts a candidate selected during transient nil`() async throws {
        let candidate = try self.runningApplication()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: nil)
        probe.onConfirmationSleep = { callCount in
            if callCount == 1 {
                probe.frontmostProcessIdentifier = candidate.processIdentifier
                probe.activeProcessIdentifiers.insert(candidate.processIdentifier)
            }
        }
        let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(250))

        #expect(lease.setTargetProcessIdentifier(self.syntheticTargetPID()))

        #expect(await lease.waitForReconciliation() == .candidateConfirmed(candidate.processIdentifier))
        #expect(probe.nativeActivationRequests.isEmpty)
    }

    @Test
    @MainActor
    func `background restoration treats persistent nil as non-target only at deadline`() async throws {
        let candidate = try self.runningApplication()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: nil)
        let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(250))

        #expect(lease.setTargetProcessIdentifier(self.syntheticTargetPID()))

        #expect(await lease.waitForReconciliation() == .targetNotFrontmost)
        #expect(probe.confirmationSleepDurations == [.milliseconds(100), .milliseconds(100), .milliseconds(50)])
        #expect(probe.nativeActivationRequests.isEmpty)
        #expect(probe.accessibilityActivationRequests.isEmpty)
    }

    @Test
    @MainActor
    func `background restoration retries native then AX while target survives deadline`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
        let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(250))
        probe.frontmostProcessIdentifier = targetPID

        #expect(lease.setTargetProcessIdentifier(targetPID))
        await #expect(throws: PeekabooError.self) {
            try await lease.holdThroughInitialActivationWindow()
        }

        #expect(probe.nativeActivationRequests == Array(repeating: candidate.processIdentifier, count: 4))
        #expect(probe.accessibilityActivationRequests == Array(repeating: candidate.processIdentifier, count: 2))
        #expect(probe.confirmationSleepDurations == [.milliseconds(100), .milliseconds(100), .milliseconds(50)])
    }

    @Test
    @MainActor
    func `activation work reaching deadline does not add a stale confirmation sleep`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
        let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(100))
        probe.frontmostProcessIdentifier = targetPID
        probe.onNativeActivation = { _ in
            probe.now = probe.now.advanced(by: .milliseconds(100))
        }

        #expect(lease.setTargetProcessIdentifier(targetPID))

        #expect(await lease.waitForReconciliation() == .targetStillFrontmost)
        #expect(probe.nativeActivationRequests == [candidate.processIdentifier, candidate.processIdentifier])
        #expect(probe.accessibilityActivationRequests.isEmpty)
        #expect(probe.confirmationSleepDurations.isEmpty)
    }

    @Test
    @MainActor
    func `post-native user foreground stops before AX or another native request`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()

        for candidateBecomesFrontmost in [true, false] {
            let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
            let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(250))
            probe.frontmostProcessIdentifier = targetPID
            probe.onNativeActivation = { application in
                probe.frontmostProcessIdentifier = candidateBecomesFrontmost
                    ? application.processIdentifier
                    : targetPID + 1
            }

            #expect(lease.setTargetProcessIdentifier(targetPID))

            let expectedPID = candidateBecomesFrontmost ? candidate.processIdentifier : targetPID + 1
            #expect(await lease.waitForReconciliation() == .differentFrontmost(expectedPID))
            #expect(probe.nativeActivationRequests == [candidate.processIdentifier])
            #expect(probe.accessibilityActivationRequests.isEmpty)
            #expect(probe.confirmationSleepDurations.isEmpty)
        }
    }

    @Test
    @MainActor
    func `terminated restoration candidate fails boundedly without activation`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
        probe.terminatedProcessIdentifiers.insert(candidate.processIdentifier)
        let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(150))
        probe.frontmostProcessIdentifier = targetPID

        #expect(lease.setTargetProcessIdentifier(targetPID))

        #expect(await lease.waitForReconciliation() == .targetStillFrontmost)
        #expect(probe.nativeActivationRequests.isEmpty)
        #expect(probe.accessibilityActivationRequests.isEmpty)
        #expect(probe.confirmationSleepDurations == [.milliseconds(100), .milliseconds(50)])
    }

    @Test
    @MainActor
    func `new candidate supersedes pending native fallback during confirmation`() async throws {
        let applications = try self.runningApplications(count: 2)
        let candidateA = applications[0]
        let candidateB = applications[1]
        let targetPID = self.syntheticTargetPID()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidateA.processIdentifier)
        let lease = probe.makeLease(previousApplication: candidateA, confirmationTimeout: .milliseconds(250))
        probe.frontmostProcessIdentifier = targetPID
        probe.onNativeActivation = { application in
            guard application.processIdentifier == candidateA.processIdentifier else {
                probe.activeProcessIdentifiers.insert(candidateB.processIdentifier)
                probe.frontmostProcessIdentifier = candidateB.processIdentifier
                return
            }
            Task { @MainActor in
                lease.handleActivatedApplication(candidateB)
                probe.frontmostProcessIdentifier = targetPID
            }
        }

        #expect(lease.setTargetProcessIdentifier(targetPID))

        #expect(await lease.waitForReconciliation() == .candidateConfirmed(candidateB.processIdentifier))
        #expect(probe.nativeActivationRequests == [candidateA.processIdentifier, candidateB.processIdentifier])
        #expect(probe.accessibilityActivationRequests.isEmpty)
    }

    @Test
    @MainActor
    func `anonymous activation clears stale candidate before and during confirmation`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()

        for supersedeBeforeTargetResolution in [true, false] {
            let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
            let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(150))
            if supersedeBeforeTargetResolution {
                lease.handleActivatedProcessIdentifier(targetPID + 1)
            } else {
                probe.onNativeActivation = { _ in
                    Task { @MainActor in
                        lease.handleActivatedProcessIdentifier(targetPID + 1)
                    }
                }
            }
            probe.frontmostProcessIdentifier = targetPID
            #expect(lease.setTargetProcessIdentifier(targetPID))

            #expect(await lease.waitForReconciliation() == .targetStillFrontmost)
            let expectedNativeRequests = supersedeBeforeTargetResolution ? [] : [candidate.processIdentifier]
            #expect(probe.nativeActivationRequests == expectedNativeRequests)
            #expect(probe.accessibilityActivationRequests.isEmpty)
        }
    }

    @Test
    @MainActor
    func `already-frontmost target is not treated as its own restoration candidate`() async throws {
        let target = try self.runningApplication()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: target.processIdentifier)
        let lease = probe.makeLease(previousApplication: target, confirmationTimeout: .milliseconds(250))

        #expect(lease.setTargetProcessIdentifier(target.processIdentifier))

        #expect(await lease.waitForReconciliation() == .targetWasAlreadyFrontmost)
        #expect(probe.nativeActivationRequests.isEmpty)
        #expect(probe.accessibilityActivationRequests.isEmpty)
        #expect(probe.confirmationSleepDurations.isEmpty)
    }

    @Test
    @MainActor
    func `initial target restores only a later user candidate after target steals back`() async throws {
        let applications = try self.runningApplications(count: 2)
        let target = applications[0]
        let candidate = applications[1]
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: target.processIdentifier)
        probe.onNativeActivation = { application in
            probe.activeProcessIdentifiers.insert(application.processIdentifier)
            probe.frontmostProcessIdentifier = application.processIdentifier
        }
        let lease = probe.makeLease(previousApplication: target, confirmationTimeout: .milliseconds(250))
        lease.handleActivatedApplication(candidate)
        lease.handleActivatedProcessIdentifier(target.processIdentifier)
        probe.frontmostProcessIdentifier = target.processIdentifier

        #expect(lease.setTargetProcessIdentifier(target.processIdentifier))

        #expect(await lease.waitForReconciliation() == .candidateConfirmed(candidate.processIdentifier))
        #expect(probe.nativeActivationRequests == [candidate.processIdentifier])
        #expect(probe.accessibilityActivationRequests.isEmpty)
    }

    @Test
    @MainActor
    func `target receipt is one-shot and starts one reconciliation`() async throws {
        let candidate = try self.runningApplication()
        let firstTargetPID = self.syntheticTargetPID()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: firstTargetPID + 1)
        let lease = probe.makeLease(previousApplication: candidate, activationGraceDuration: .milliseconds(100))

        #expect(lease.setTargetProcessIdentifier(firstTargetPID))
        #expect(!lease.setTargetProcessIdentifier(firstTargetPID + 1))
        lease.handleActivatedProcessIdentifier(firstTargetPID)
        lease.handleActivatedProcessIdentifier(firstTargetPID)

        #expect(await lease.waitForReconciliation() == .differentFrontmost(firstTargetPID + 1))
        #expect(probe.graceSleepDurations == [.milliseconds(100)])
        #expect(!lease.hasActiveReconciliation)
    }

    @Test
    @MainActor
    func `reused target PID stops restoration against the replacement generation`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()
        let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
        let lease = probe.makeLease(previousApplication: candidate, confirmationTimeout: .milliseconds(250))
        probe.frontmostProcessIdentifier = targetPID

        #expect(lease.setTargetProcessIdentifier(targetPID))
        probe.processStartIdentity = 71

        #expect(await lease.waitForReconciliation() == .targetNotFrontmost)
        #expect(probe.nativeActivationRequests == [candidate.processIdentifier])
        #expect(probe.accessibilityActivationRequests.isEmpty)
        #expect(probe.confirmationSleepDurations.isEmpty)
    }

    @Test
    @MainActor
    func `background restoration clamps invalid protection durations`() async throws {
        let candidate = try self.runningApplication()
        let targetPID = self.syntheticTargetPID()

        let negativeProbe = BackgroundRestorationProbe(frontmostProcessIdentifier: candidate.processIdentifier)
        let negativeLease = negativeProbe.makeLease(
            previousApplication: candidate,
            activationGraceDuration: .seconds(-1),
            confirmationTimeout: .seconds(-1))
        negativeProbe.frontmostProcessIdentifier = targetPID
        #expect(negativeLease.setTargetProcessIdentifier(targetPID))
        #expect(await negativeLease.waitForReconciliation() == .targetStillFrontmost)
        #expect(negativeProbe.graceSleepDurations.isEmpty)
        #expect(negativeProbe.confirmationSleepDurations.isEmpty)

        let maximumProbe = BackgroundRestorationProbe(frontmostProcessIdentifier: targetPID + 1)
        let maximumLease = maximumProbe.makeLease(
            previousApplication: candidate,
            activationGraceDuration: .seconds(60))
        #expect(maximumLease.setTargetProcessIdentifier(targetPID))
        #expect(await maximumLease.waitForReconciliation() == .differentFrontmost(targetPID + 1))
        #expect(maximumProbe.graceSleepDurations == [.seconds(10)])
    }

    @Test
    @MainActor
    func `original readiness error wins over restoration failure`() async throws {
        let applications = try self.runningApplications(count: 2)
        let runningApplication = applications[0]
        let previousApplication = applications[1]
        let targetPID = runningApplication.processIdentifier
        let now = ActivationInstantBox(ContinuousClock.now)
        let frontmostPID = ActivationPIDBox(previousApplication.processIdentifier)
        let dependencies = BackgroundRestorationDependencies(
            applicationActivationHandler: { _ in true },
            accessibilityActivationHandler: { _ in true },
            applicationActiveProvider: { _ in false },
            applicationTerminatedProvider: { _ in false },
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            processStartIdentityProvider: { _ in 70 },
            confirmationSleepHandler: { duration in now.value = now.value.advanced(by: duration) },
            confirmationTimeout: .milliseconds(100))
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationReadinessHandler: { _ in false },
            processStartIdentityProvider: { _ in 70 },
            applicationReadinessTimeout: 0,
            backgroundLaunchActivationGraceDuration: .zero,
            backgroundActivationLeaseFactory: { duration, _ in
                let lease = BackgroundLaunchActivationLease(
                    previousApplication: previousApplication,
                    observeActivations: false,
                    activationGraceDuration: duration,
                    nowProvider: { now.value },
                    restorationDependencies: dependencies)
                frontmostPID.value = targetPID
                return lease
            })

        do {
            _ = try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: false,
                waitForWindow: true))
            Issue.record("Expected the original readiness timeout")
        } catch let PeekabooError.timeout(message) {
            #expect(message.contains("automatable window"))
        }
    }

    @Test
    @MainActor
    func `application launch maps every background restoration outcome`() async throws {
        enum Scenario: CaseIterable {
            case candidateConfirmed
            case differentFrontmost
            case targetWasAlreadyFrontmost
            case targetNotFrontmost
            case targetStillFrontmost
        }

        let applications = try self.runningApplications(count: 2)
        let target = applications[0]
        let candidate = applications[1]

        for scenario in Scenario.allCases {
            let initialFrontmostPID = scenario == .targetWasAlreadyFrontmost
                ? target.processIdentifier
                : candidate.processIdentifier
            let probe = BackgroundRestorationProbe(frontmostProcessIdentifier: initialFrontmostPID)
            if scenario == .candidateConfirmed {
                probe.onNativeActivation = { application in
                    probe.activeProcessIdentifiers.insert(application.processIdentifier)
                    probe.frontmostProcessIdentifier = application.processIdentifier
                }
            }
            let service = ApplicationService(
                applicationOpenHandler: { _, _, _ in target },
                processStartIdentityProvider: { _ in 70 },
                backgroundLaunchActivationGraceDuration: .zero,
                backgroundActivationLeaseFactory: { duration, _ in
                    let lease = probe.makeLease(
                        previousApplication: scenario == .targetWasAlreadyFrontmost ? target : candidate,
                        activationGraceDuration: duration,
                        confirmationTimeout: .milliseconds(100))
                    switch scenario {
                    case .candidateConfirmed, .targetStillFrontmost:
                        probe.frontmostProcessIdentifier = target.processIdentifier
                    case .differentFrontmost:
                        probe.frontmostProcessIdentifier = target.processIdentifier + 10000
                    case .targetNotFrontmost:
                        probe.frontmostProcessIdentifier = nil
                    case .targetWasAlreadyFrontmost:
                        break
                    }
                    return lease
                })

            if scenario == .targetStillFrontmost {
                await #expect(throws: PeekabooError.self) {
                    _ = try await service.launchApplication(request: ApplicationLaunchRequest(
                        applicationIdentifier: "Finder",
                        activates: false))
                }
            } else {
                let result = try await service.launchApplication(request: ApplicationLaunchRequest(
                    applicationIdentifier: "Finder",
                    activates: false))
                #expect(result.processIdentifier == target.processIdentifier)
            }

            if scenario == .targetWasAlreadyFrontmost || scenario == .differentFrontmost ||
                scenario == .targetNotFrontmost
            {
                #expect(probe.nativeActivationRequests.isEmpty)
                #expect(probe.accessibilityActivationRequests.isEmpty)
            }
        }
    }

    @Test
    @MainActor
    func `explicit application path disables running application substitution`() async throws {
        let recorder = ApplicationOpenRecorder()
        let service = ApplicationService(applicationOpenHandler: recorder.open)

        _ = try await service.launchApplication(request: ApplicationLaunchRequest(
            applicationIdentifier: "/System/Library/CoreServices/Finder.app",
            activates: false))

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
            activates: false))

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

        await #expect(throws: PeekabooError.self) {
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
                    activates: false),
                waitSeconds: 0))
        }

        #expect(lifecycle.resolvedIdentifiers == ["  host.bundle.identifier  "])
        #expect(lifecycle.quitCalls.isEmpty)
        #expect(openRecorder.calls.isEmpty)
    }

    @Test
    @MainActor
    func `relaunch quits and polls only the canonical target PID`() async throws {
        let lifecycle = RelaunchLifecycleRecorder(targetPID: 4242)
        let openRecorder = ApplicationOpenRecorder()
        let service = ApplicationService(
            applicationOpenHandler: openRecorder.open,
            relaunchTargetResolver: lifecycle.resolve,
            relaunchQuitHandler: lifecycle.quit,
            relaunchRunningHandler: lifecycle.isRunning,
            processStartIdentityProvider: { _ in 700 })

        _ = try await service.relaunchApplication(request: ApplicationRelaunchRequest(
            targetIdentifier: "  Example  ",
            expectedTargetIdentity: ApplicationProcessIdentity(
                processIdentifier: 4242,
                processStartIdentity: 700),
            launchRequest: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: false),
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
                    activates: false),
                waitSeconds: 0))
        }

        #expect(lifecycle.quitCalls.isEmpty)
        #expect(openRecorder.calls.isEmpty)
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

    private func syntheticTargetPID() -> pid_t {
        getpid() + 10000
    }

    private func isolatedBackgroundActivationLeaseFactory() -> ApplicationService.BackgroundActivationLeaseFactory {
        { duration, _ in
            BackgroundLaunchActivationLease(
                observeActivations: false,
                activationGraceDuration: duration,
                restorationDependencies: BackgroundRestorationDependencies(
                    applicationActivationHandler: { _ in true },
                    accessibilityActivationHandler: { _ in true },
                    applicationActiveProvider: { _ in false },
                    applicationTerminatedProvider: { _ in false },
                    frontmostProcessIdentifierProvider: { nil },
                    processStartIdentityProvider: { _ in 70 },
                    confirmationSleepHandler: { _ in },
                    confirmationTimeout: .zero))
        }
    }
}

@MainActor
private final class ActivationInstantBox {
    var value: ContinuousClock.Instant

    init(_ value: ContinuousClock.Instant) {
        self.value = value
    }
}

@MainActor
private final class ActivationPIDBox {
    var value: pid_t?

    init(_ value: pid_t?) {
        self.value = value
    }
}

@MainActor
private final class BackgroundRestorationProbe {
    var now = ContinuousClock.now
    var frontmostProcessIdentifier: pid_t?
    var activeProcessIdentifiers: Set<pid_t> = []
    var terminatedProcessIdentifiers: Set<pid_t> = []
    var processStartIdentity: UInt64? = 70
    var nativeRequestAccepted = true
    var onNativeActivation: ((NSRunningApplication) -> Void)?
    var onAccessibilityActivation: ((pid_t) -> Void)?
    var onConfirmationSleep: ((Int) -> Void)?
    private(set) var nativeActivationRequests: [pid_t] = []
    private(set) var accessibilityActivationRequests: [pid_t] = []
    private(set) var graceSleepDurations: [Duration] = []
    private(set) var confirmationSleepDurations: [Duration] = []

    init(frontmostProcessIdentifier: pid_t?) {
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
    }

    func makeLease(
        previousApplication: NSRunningApplication,
        activationGraceDuration: Duration = .zero,
        confirmationTimeout: Duration = .zero) -> BackgroundLaunchActivationLease
    {
        BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            activationGraceDuration: activationGraceDuration,
            nowProvider: { self.now },
            sleepHandler: { duration in
                self.graceSleepDurations.append(duration)
                self.now = self.now.advanced(by: duration)
            },
            restorationDependencies: BackgroundRestorationDependencies(
                applicationActivationHandler: { application in
                    self.nativeActivationRequests.append(application.processIdentifier)
                    self.onNativeActivation?(application)
                    return self.nativeRequestAccepted
                },
                accessibilityActivationHandler: { processIdentifier in
                    self.accessibilityActivationRequests.append(processIdentifier)
                    self.onAccessibilityActivation?(processIdentifier)
                    return true
                },
                applicationActiveProvider: { application in
                    self.activeProcessIdentifiers.contains(application.processIdentifier)
                },
                applicationTerminatedProvider: { application in
                    self.terminatedProcessIdentifiers.contains(application.processIdentifier)
                },
                frontmostProcessIdentifierProvider: { self.frontmostProcessIdentifier },
                processStartIdentityProvider: { _ in self.processStartIdentity },
                confirmationSleepHandler: { duration in
                    self.confirmationSleepDurations.append(duration)
                    self.now = self.now.advanced(by: duration)
                    self.onConfirmationSleep?(self.confirmationSleepDurations.count)
                    await Task.yield()
                },
                confirmationTimeout: confirmationTimeout))
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
    let runningApplication = NSWorkspace.shared.runningApplications.first {
        !$0.isTerminated && $0.isFinishedLaunching
    } ?? NSRunningApplication.current

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
    private(set) var resolvedIdentifiers: [String] = []
    private(set) var quitCalls: [QuitCall] = []
    private(set) var runningIdentifiers: [String] = []

    init(targetPID: Int32) {
        self.targetPID = targetPID
    }

    func resolve(identifier: String) async throws -> ServiceApplicationInfo {
        self.resolvedIdentifiers.append(identifier)
        return ServiceApplicationInfo(
            processIdentifier: self.targetPID,
            processStartIdentity: 700,
            bundleIdentifier: "com.example.target",
            name: "Target")
    }

    func quit(request: ApplicationQuitRequest) async throws -> Bool {
        self.quitCalls.append(.init(
            identifier: request.identifier,
            force: request.force,
            expectedIdentity: request.expectedIdentity))
        return true
    }

    func isRunning(identifier: String) async -> Bool {
        self.runningIdentifiers.append(identifier)
        return false
    }
}
