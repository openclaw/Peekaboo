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
