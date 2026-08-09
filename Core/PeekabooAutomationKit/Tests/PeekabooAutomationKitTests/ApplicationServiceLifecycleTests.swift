import AppKit
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceLifecycleTests {
    @Test
    @MainActor
    func `background quit suppresses global visualizer feedback`() {
        #expect(!ApplicationService.shouldShowQuitFeedback(hasForegroundConsent: false))
        #expect(ApplicationService.shouldShowQuitFeedback(hasForegroundConsent: true))
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
            backgroundLaunchActivationGraceDuration: .zero)

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
            backgroundLaunchActivationGraceDuration: .zero)

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

    @Test
    @MainActor
    func `background activation lease restores only when the launched PID activates`() throws {
        let previousApplication = try #require(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.isFinishedLaunching
        })
        var restoredPIDs: [pid_t] = []
        let targetPID = getpid() + 10000
        let frontmostPID = FrontmostPIDBox(previousApplication.processIdentifier)
        let lease = BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: {
                restoredPIDs.append($0.processIdentifier)
                frontmostPID.value = $0.processIdentifier
            })

        lease.handleActivatedProcessIdentifier(targetPID + 1)
        lease.setTargetProcessIdentifier(targetPID)
        #expect(restoredPIDs.isEmpty)

        frontmostPID.value = targetPID
        lease.handleActivatedProcessIdentifier(targetPID)
        #expect(restoredPIDs == [previousApplication.processIdentifier])
    }

    @Test
    @MainActor
    func `background activation lease handles activation before launch returns its PID`() throws {
        let previousApplication = try #require(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.isFinishedLaunching
        })
        var restoreCount = 0
        let targetPID = getpid() + 10000
        let frontmostPID = FrontmostPIDBox(targetPID)
        let lease = BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: { _ in
                restoreCount += 1
                frontmostPID.value = previousApplication.processIdentifier
            })

        lease.handleActivatedProcessIdentifier(targetPID)
        lease.setTargetProcessIdentifier(targetPID)

        #expect(restoreCount == 1)
    }

    @Test
    @MainActor
    func `background activation lease catches delayed self-activation within grace period`() async throws {
        let previousApplication = try #require(NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.isFinishedLaunching
        })
        var restoreCount = 0
        let targetPID = getpid() + 10000
        let frontmostPID = FrontmostPIDBox(targetPID)
        let now = ActivationInstantBox(ContinuousClock.now)
        let lease = BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            activationGraceDuration: .milliseconds(30),
            nowProvider: { now.value },
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: { _ in
                restoreCount += 1
                frontmostPID.value = previousApplication.processIdentifier
            })
        lease.setTargetProcessIdentifier(targetPID)
        now.value = now.value.advanced(by: .milliseconds(10))

        lease.handleActivatedProcessIdentifier(targetPID)
        now.value = now.value.advanced(by: .milliseconds(30))
        try await lease.holdThroughInitialActivationWindow()

        #expect(restoreCount == 1)
    }

    @Test
    @MainActor
    func `background activation callbacks ignore target after protection deadline`() throws {
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.isFinishedLaunching
        }
        let previousApplication = try #require(runningApplications.first)
        let targetApplication = try #require(runningApplications.first {
            $0.processIdentifier != previousApplication.processIdentifier
        })
        let now = ActivationInstantBox(ContinuousClock.now)
        let frontmostPID = FrontmostPIDBox(targetApplication.processIdentifier)
        var restoreCount = 0
        let lease = BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            activationGraceDuration: .milliseconds(500),
            nowProvider: { now.value },
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: { _ in restoreCount += 1 })
        lease.setTargetProcessIdentifier(targetApplication.processIdentifier)
        now.value = now.value.advanced(by: .milliseconds(501))

        lease.handleActivatedProcessIdentifier(targetApplication.processIdentifier)
        lease.handleActivatedApplication(targetApplication)

        #expect(restoreCount == 0)
        #expect(frontmostPID.value == targetApplication.processIdentifier)
    }

    @Test
    @MainActor
    func `background activation final check does not restore after slow readiness wait`() async throws {
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.isFinishedLaunching
        }
        let previousApplication = try #require(runningApplications.first)
        let targetApplication = try #require(runningApplications.first {
            $0.processIdentifier != previousApplication.processIdentifier
        })
        let now = ActivationInstantBox(ContinuousClock.now)
        let frontmostPID = FrontmostPIDBox(targetApplication.processIdentifier)
        var restoreCount = 0
        let lease = BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            activationGraceDuration: .seconds(2),
            nowProvider: { now.value },
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: { _ in restoreCount += 1 })
        lease.setTargetProcessIdentifier(targetApplication.processIdentifier)
        now.value = now.value.advanced(by: .seconds(10))

        try await lease.holdThroughInitialActivationWindow()

        #expect(restoreCount == 0)
        #expect(frontmostPID.value == targetApplication.processIdentifier)
    }

    @Test
    @MainActor
    func `background activation boundary restores target when callback was missed`() async throws {
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.isFinishedLaunching
        }
        let previousApplication = try #require(runningApplications.first)
        let targetApplication = try #require(runningApplications.first {
            $0.processIdentifier != previousApplication.processIdentifier
        })
        let now = ActivationInstantBox(ContinuousClock.now)
        let frontmostPID = FrontmostPIDBox(targetApplication.processIdentifier)
        var sleptDurations: [Duration] = []
        var restoreCount = 0
        let lease = BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            activationGraceDuration: .seconds(2),
            nowProvider: { now.value },
            sleepHandler: { duration in
                sleptDurations.append(duration)
                now.value = now.value.advanced(by: duration)
            },
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: { _ in
                restoreCount += 1
                frontmostPID.value = previousApplication.processIdentifier
            })
        lease.setTargetProcessIdentifier(targetApplication.processIdentifier)

        try await lease.holdThroughInitialActivationWindow()

        #expect(sleptDurations == [.seconds(2)])
        #expect(restoreCount == 1)
        frontmostPID.value = targetApplication.processIdentifier
        lease.handleActivatedProcessIdentifier(targetApplication.processIdentifier)
        #expect(restoreCount == 1)
    }

    @Test
    @MainActor
    func `cancelled launch wait keeps activation heartbeat through delayed target activation`() async throws {
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.isFinishedLaunching
        }
        let previousApplication = try #require(runningApplications.first)
        let targetApplication = try #require(runningApplications.first {
            $0.processIdentifier != previousApplication.processIdentifier
        })
        let now = ActivationInstantBox(ContinuousClock.now)
        let sleepGate = ActivationSleepGate()
        let frontmostPID = FrontmostPIDBox(previousApplication.processIdentifier)
        var restoreCount = 0
        let lease = BackgroundLaunchActivationLease(
            previousApplication: previousApplication,
            observeActivations: false,
            activationGraceDuration: .seconds(2),
            nowProvider: { now.value },
            sleepHandler: sleepGate.sleep,
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: { _ in
                restoreCount += 1
                frontmostPID.value = previousApplication.processIdentifier
            })
        lease.setTargetProcessIdentifier(targetApplication.processIdentifier)

        var callerStarted = false
        let caller = Task { @MainActor in
            defer { lease.finish(protectionCompleted: false) }
            callerStarted = true
            try await Task.sleep(for: .seconds(30))
        }
        while !callerStarted {
            await Task.yield()
        }
        caller.cancel()
        await #expect(throws: CancellationError.self) {
            try await caller.value
        }
        await sleepGate.waitUntilStarted()
        #expect(lease.hasProtectionHeartbeat)
        #expect(sleepGate.requestedDurations == [.seconds(2)])

        now.value = now.value.advanced(by: .seconds(1))
        frontmostPID.value = targetApplication.processIdentifier
        lease.handleActivatedProcessIdentifier(targetApplication.processIdentifier)
        #expect(restoreCount == 1)

        now.value = now.value.advanced(by: .seconds(1))
        sleepGate.release()
        await lease.waitForProtectionHeartbeat()
        #expect(!lease.hasProtectionHeartbeat)
        frontmostPID.value = targetApplication.processIdentifier
        lease.handleActivatedProcessIdentifier(targetApplication.processIdentifier)
        #expect(restoreCount == 1)
    }

    @Test
    @MainActor
    func `background activation lease restores latest user app after A to B to target`() throws {
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.isFinishedLaunching
        }
        let appA = try #require(runningApplications.first)
        let appB = try #require(runningApplications.first { $0.processIdentifier != appA.processIdentifier })
        let target = try #require(runningApplications.first {
            $0.processIdentifier != appA.processIdentifier && $0.processIdentifier != appB.processIdentifier
        })
        let frontmostPID = FrontmostPIDBox(appA.processIdentifier)
        var restoredPIDs: [pid_t] = []
        let lease = BackgroundLaunchActivationLease(
            previousApplication: appA,
            observeActivations: false,
            frontmostProcessIdentifierProvider: { frontmostPID.value },
            restorationHandler: {
                restoredPIDs.append($0.processIdentifier)
                frontmostPID.value = $0.processIdentifier
            })
        lease.setTargetProcessIdentifier(target.processIdentifier)

        frontmostPID.value = appB.processIdentifier
        lease.handleActivatedApplication(appB)
        frontmostPID.value = target.processIdentifier
        lease.handleActivatedApplication(target)

        #expect(restoredPIDs == [appB.processIdentifier])
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
            relaunchRunningHandler: lifecycle.isRunning)

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
private final class FrontmostPIDBox {
    var value: pid_t

    init(_ value: pid_t) {
        self.value = value
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
private final class ActivationSleepGate {
    private var sleepContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestedDurations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        self.requestedDurations.append(duration)
        self.startWaiters.forEach { $0.resume() }
        self.startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            self.sleepContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard self.requestedDurations.isEmpty else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release() {
        self.sleepContinuation?.resume()
        self.sleepContinuation = nil
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
