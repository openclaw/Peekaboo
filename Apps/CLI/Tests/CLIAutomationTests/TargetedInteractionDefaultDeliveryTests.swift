import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
@MainActor
struct TargetedInteractionDefaultDeliveryTests {
    @Test
    func `keyboard commands reject targetless delivery unless foreground is explicit`() async throws {
        let automation = StubAutomationService()
        let services = TestServicesFactory.makePeekabooServices(
            clipboard: StubClipboardService(),
            automation: automation
        )

        for arguments in [
            ["type", "hello"],
            ["press", "return"],
            ["paste", "--text", "hello"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus != 0, "Expected targetless input to fail: \(arguments)")
            #expect(result.combinedOutput.contains("--foreground"))
        }

        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `no auto focus preserves typed delivery while raw press still refuses`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            unitCount: .one
        )
        automation.actionOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: #require(app.processIdentity)
        )
        let applications = StubApplicationService(applications: [app])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: StubClipboardService(),
            automation: automation
        )

        for arguments in [
            ["type", "hello", "--app", "TextEdit", "--no-auto-focus"],
            ["paste", "--text", "hello", "--app", "TextEdit", "--no-auto-focus"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus == 0, "Expected targeted input to succeed: \(arguments)")
        }
        let press = try await InProcessCommandRunner.run(
            ["press", "return", "--app", "TextEdit", "--no-auto-focus", "--no-remote"],
            services: services
        )
        #expect(press.exitStatus != 0)
        #expect(press.combinedOutput.contains("require explicit foreground consent"))

        #expect(automation.targetedTypeActionsCalls.count == 2)
        #expect(automation.targetedTypeActionsCalls.allSatisfy { $0.targetProcessIdentifier == 2468 })
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(applications.activateCalls.isEmpty)
    }

    @Test
    func `keyboard target resolution failure never falls back to global input`() async throws {
        let automation = StubAutomationService()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: []),
            clipboard: StubClipboardService(),
            automation: automation
        )

        for arguments in [
            ["type", "hello", "--app", "Missing"],
            ["press", "return", "--app", "Missing"],
            ["paste", "--text", "hello", "--app", "Missing"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus != 0, "Expected unresolved target to fail: \(arguments)")
        }

        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `CLI background keyboard refuses fuzzy application selectors before dispatch`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 2468,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit",
            isHiddenKnown: true,
            activationPolicy: .regular
        )
        let automation = StubAutomationService()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [application]),
            windows: StubWindowService(windowsByApp: [:]),
            clipboard: StubClipboardService(),
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            ["type", "must not dispatch", "--app", "Text", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("not allowed for mutation"))
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
    }

    @Test
    func `CLI background keyboard refuses one title match from a partial catalog`() async throws {
        let processIdentity = AutomationTestFixtures.processIdentity(
            processIdentifier: 2468,
            processStartIdentity: 7
        )
        let application = AutomationTestFixtures.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit",
            isHiddenKnown: true,
            activationPolicy: .regular
        )
        let window = AutomationTestFixtures.window(
            windowID: 42,
            title: "Document",
            processIdentity: processIdentity
        )
        let automation = StubAutomationService()
        let windows = PartialKeyboardWindowInventoryService(windowsByApp: ["TextEdit": [window]])
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [application]),
            windows: windows,
            clipboard: StubClipboardService(),
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "must not dispatch", "--app", "TextEdit", "--window-title", "Document",
                "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("incomplete"))
        #expect(result.combinedOutput.contains("AX enumeration timed out"))
        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
    }

    @Test
    func `exact Calculator window ignores unrelated unpinnable system application row`() async throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 2468, processStartIdentity: 7),
            applicationName: "Calculator",
            windowID: 42
        )
        let unpinnableSystemRow = AutomationTestFixtures.application(
            processIdentifier: 1,
            processStartIdentity: nil,
            bundleIdentifier: nil,
            name: "WindowServer",
            isHiddenKnown: false,
            activationPolicy: .prohibited
        )
        let candidates = [fixture.application, unpinnableSystemRow]
            .map(ApplicationIdentifierMatcher.Candidate.init)
        let resolution = try #require(try ApplicationIdentifierMatcher.resolution(
            for: "Calculator",
            in: candidates
        ))
        let calculator = fixture.application.withSelectorResolutionProofs([
            resolution.proof(selectedProcessIdentity: fixture.processIdentity),
        ])
        let applications = StubApplicationService(applications: [calculator, unpinnableSystemRow])
        applications.inventoryCompleteness = .partial
        applications.inventoryWarnings = [
            "Application PID 1 lacked process-generation identity and was omitted.",
        ]
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            unitCount: .one
        )
        automation.actionOutcomeTargetIdentity = fixture.windowTargetIdentity
        automation.targetedFocusedElement = UIFocusInfo(
            role: "AXTextField",
            title: nil,
            value: nil,
            frame: fixture.window.bounds.insetBy(dx: 40, dy: 40),
            applicationName: fixture.application.name,
            bundleIdentifier: fixture.application.bundleIdentifier ?? "com.apple.calculator",
            processId: Int(fixture.processIdentity.processIdentifier),
            windowID: fixture.window.windowID,
            identifier: "calculator-display"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: StubWindowService(windowsByApp: [fixture.application.name: [fixture.window]]),
            clipboard: StubClipboardService(),
            automation: automation
        )

        for arguments in [
            ["type", "12345"],
            ["press", "return"],
        ] {
            let result = try await InProcessCommandRunner.run(
                arguments + [
                    "--app", "Calculator",
                    "--window-id", String(fixture.window.windowID),
                    "--json", "--no-remote",
                ],
                services: services
            )
            #expect(result.exitStatus == 0, "Unexpected exact-window refusal: \(result.combinedOutput)")
        }

        #expect(automation.exactTypeActionsCalls.count == 1)
        #expect(automation.exactTypeActionsCalls.first?.target.windowIdentity == fixture.windowIdentity)
        #expect(automation.exactHotkeyCalls.count == 1)
        #expect(automation.exactHotkeyCalls.first?.target.windowIdentity == fixture.windowIdentity)
        #expect(automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `foreground explicitly preserves intentional global keyboard delivery`() async throws {
        let automation = StubAutomationService()
        let services = TestServicesFactory.makePeekabooServices(
            clipboard: StubClipboardService(),
            automation: automation
        )

        let typeResult = try await InProcessCommandRunner.run(
            ["type", "hello", "--foreground", "--no-remote"],
            services: services
        )
        #expect(typeResult.exitStatus == 1)
        #expect(typeResult.combinedOutput.contains("outcome is indeterminate"))

        for arguments in [
            ["press", "return", "--foreground"],
            ["paste", "--text", "hello", "--foreground", "--restore-delay", "0"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus == 0, "Expected explicit foreground input to succeed: \(arguments)")
        }

        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.typeActionsCalls.count == 1)
        #expect(automation.hotkeyCalls.map(\.keys) == ["return", "cmd,v"])
    }

    @Test
    func `unresolved background window selectors refuse instead of collapsing to pid`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = StubAutomationService()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            clipboard: StubClipboardService(),
            automation: automation
        )

        for arguments in [
            ["type", "hello", "--app", "TextEdit", "--window-title", "Document"],
            ["paste", "--text", "hello", "--app", "TextEdit", "--window-title", "Document"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus != 0, "Expected unsafe window targeting to fail: \(arguments)")
            #expect(result.combinedOutput.contains("no matching window"))
        }
        let press = try await InProcessCommandRunner.run(
            [
                "press", "return", "--app", "TextEdit", "--window-title", "Document", "--no-remote",
            ],
            services: services
        )
        #expect(press.exitStatus != 0)
        #expect(press.combinedOutput.contains("no matching window"))

        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `snapshot exact-window evidence without captured bounds refuses keyboard delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let context = TestServicesFactory.makeAutomationTestContext(
            applications: StubApplicationService(applications: [app])
        )
        let snapshotId = try await context.snapshots.createSnapshot()
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 2468,
            ownerProcessStartIdentity: 7
        )
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: ElementDetectionResult(
                snapshotId: snapshotId,
                screenshotPath: "/tmp/screenshot.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: "TextEdit",
                        applicationBundleId: "com.apple.TextEdit",
                        applicationProcessId: 2468,
                        windowID: identity.windowID,
                        windowMutationIdentity: identity
                    )
                )
            )
        )

        let type = try await InProcessCommandRunner.run(
            ["type", "hello", "--snapshot", snapshotId, "--no-auto-focus", "--no-remote"],
            services: context.services
        )
        #expect(type.exitStatus != 0)
        let press = try await InProcessCommandRunner.run(
            ["press", "return", "--snapshot", snapshotId, "--no-auto-focus", "--no-remote"],
            services: context.services
        )
        #expect(press.exitStatus != 0)
        #expect(press.combinedOutput.contains("no exact process-generation, window, and bounds receipt"))

        #expect(context.automation.targetedTypeActionsCalls.isEmpty)
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
        #expect(context.automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `CLI keyboard receipt adapter accepts only complete immutable exact-window evidence`() async throws {
        let processIdentifier: pid_t = 2468
        let processStartIdentity: UInt64 = 7
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let application = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let window = AutomationTestFixtures.window(
            windowID: 42,
            bounds: bounds,
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity
            )
        )
        let context = TestServicesFactory.makeAutomationTestContext(
            applications: StubApplicationService(applications: [application]),
            windows: StubWindowService(windowsByApp: ["TextEdit": [window]])
        )
        let malformedReceipts: [(windowID: Int, capturedBounds: CGRect?)] = [
            (42, nil),
            (42, bounds.offsetBy(dx: 1, dy: 0)),
            (0, bounds),
            (Int(UInt32.max) + 1, bounds),
        ]

        for malformed in malformedReceipts {
            let snapshotID = try await self.storeKeyboardSnapshot(
                in: context.services,
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                windowID: malformed.windowID,
                windowBounds: bounds,
                capturedBounds: malformed.capturedBounds
            )

            await #expect(throws: ValidationError.self) {
                _ = try await KeyboardDeliverySupport.requireBackgroundKeyboardTarget(
                    target: InteractionTargetOptions(),
                    snapshotId: snapshotID,
                    services: context.services
                )
            }
        }

        let validSnapshotID = try await self.storeKeyboardSnapshot(
            in: context.services,
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            windowID: 42,
            windowBounds: bounds,
            capturedBounds: bounds
        )
        let target = try await KeyboardDeliverySupport.requireBackgroundKeyboardTarget(
            target: InteractionTargetOptions(),
            snapshotId: validSnapshotID,
            services: context.services
        )
        #expect(target.exactWindow?.identity.windowID == 42)
        #expect(target.exactWindow?.identity.capturedBounds == bounds)
        #expect(target.exactWindow?.bounds == bounds)
    }

    @Test
    func `explicit app cannot override stale snapshot generation`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 8,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let context = TestServicesFactory.makeAutomationTestContext(
            applications: StubApplicationService(applications: [app])
        )
        let snapshotId = try await context.snapshots.createSnapshot()
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: ElementDetectionResult(
                snapshotId: snapshotId,
                screenshotPath: "/tmp/screenshot.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: "TextEdit",
                        applicationBundleId: "com.apple.TextEdit",
                        applicationProcessId: 2468,
                        windowID: 42,
                        windowBounds: bounds,
                        windowMutationIdentity: WindowMutationIdentity(
                            windowID: 42,
                            ownerProcessIdentifier: 2468,
                            ownerProcessStartIdentity: 7,
                            capturedBounds: bounds
                        )
                    )
                )
            )
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "hello", "--app", "TextEdit", "--snapshot", snapshotId,
                "--no-auto-focus", "--no-remote",
            ],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("do not identify the same process generation"))
        #expect(context.automation.targetedTypeActionsCalls.isEmpty)
    }

    @Test
    func `snapshot PID without generation receipt never reaches keyboard delivery`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        let snapshotId = try await context.snapshots.createSnapshot()
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: ElementDetectionResult(
                snapshotId: snapshotId,
                screenshotPath: "/tmp/screenshot.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: "TextEdit",
                        applicationBundleId: "com.apple.TextEdit",
                        applicationProcessId: 2468
                    )
                )
            )
        )

        let type = try await InProcessCommandRunner.run(
            ["type", "hello", "--snapshot", snapshotId, "--no-auto-focus", "--no-remote"],
            services: context.services
        )
        #expect(type.exitStatus != 0)
        #expect(type.combinedOutput.contains("no exact process-generation, window, and bounds receipt"))
        let press = try await InProcessCommandRunner.run(
            ["press", "return", "--snapshot", snapshotId, "--no-auto-focus", "--no-remote"],
            services: context.services
        )
        #expect(press.exitStatus != 0)
        #expect(press.combinedOutput.contains("no exact process-generation, window, and bounds receipt"))

        #expect(context.automation.targetedTypeActionsCalls.isEmpty)
        #expect(context.automation.targetedHotkeyCalls.isEmpty)
        #expect(context.automation.typeActionsCalls.isEmpty)
        #expect(context.automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `snapshot without process metadata never falls back to global keyboard input`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        let snapshotId = try await context.snapshots.createSnapshot()
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: ElementDetectionResult(
                snapshotId: snapshotId,
                screenshotPath: "/tmp/screenshot.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "stub")
            )
        )

        let result = try await InProcessCommandRunner.run(
            ["type", "hello", "--snapshot", snapshotId, "--no-auto-focus", "--no-remote"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("no exact process-generation, window, and bounds receipt"))
        #expect(context.automation.typeActionsCalls.isEmpty)
        #expect(context.automation.targetedTypeActionsCalls.isEmpty)
    }

    @Test
    func `targeted semantic commands default to background while raw press refuses`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 7,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            unitCount: .one
        )
        automation.actionOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: #require(app.processIdentity)
        )
        let applications = StubApplicationService(applications: [app])
        let clipboard = StubClipboardService()
        let windowBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let windowIdentity = WindowMutationIdentity(
            windowID: 314,
            ownerProcessIdentifier: app.processIdentifier,
            ownerProcessStartIdentity: 7,
            capturedBounds: windowBounds
        )
        let window = ServiceWindowInfo(
            windowID: windowIdentity.windowID,
            title: "Document",
            bounds: windowBounds,
            mutationIdentity: windowIdentity
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )
        let clickServices = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: StubWindowService(windowsByApp: [app.name: [window]]),
            clipboard: clipboard,
            automation: automation
        )

        try await self.assertTypeDefaultsToBackground(services: services, automation: automation)
        try await self.assertPressDefaultsToRefusal(services: services, automation: automation)
        try await self.assertPasteDefaultsToBackground(services: services, automation: automation)
        try await self.assertClickDefaultsToBackground(
            services: clickServices,
            automation: automation,
            targetWindow: window
        )
        #expect(applications.activateCalls.isEmpty)
    }

    private func assertTypeDefaultsToBackground(
        services: PeekabooServices,
        automation: StubAutomationService
    ) async throws {
        let result = try await InProcessCommandRunner.run(
            ["type", "hello", "--app", "TextEdit", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let call = try #require(automation.targetedTypeActionsCalls.last)
        #expect(call.targetProcessIdentifier == 2468)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<TypeCommandResult>.self
        )
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == 2468)
    }

    private func assertPressDefaultsToRefusal(
        services: PeekabooServices,
        automation: StubAutomationService
    ) async throws {
        let result = try await InProcessCommandRunner.run(
            ["press", "return", "--app", "TextEdit", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus != 0)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: JSONResponse.self
        )
        #expect(payload.success == false)
        #expect(payload.effect == .refused)
        #expect(payload.error?.code == "INTERACTION_FAILED")
        #expect(payload.error?.retry_safe == true)
        #expect(payload.error?.mutation_dispatched == false)
    }

    private func assertPasteDefaultsToBackground(
        services: PeekabooServices,
        automation: StubAutomationService
    ) async throws {
        let result = try await InProcessCommandRunner.run(
            ["paste", "--text", "hello", "--app", "TextEdit", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let call = try #require(automation.targetedTypeActionsCalls.last)
        #expect(call.targetProcessIdentifier == 2468)
        if case .text("hello") = call.actions.first {} else {
            Issue.record("Expected paste text to use targeted text delivery")
        }
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == 2468)
    }

    private func assertClickDefaultsToBackground(
        services: PeekabooServices,
        automation: StubAutomationService,
        targetWindow: ServiceWindowInfo
    ) async throws {
        let snapshotId = try await services.snapshots.createSnapshot()
        try await services.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: ElementDetectionResult(
                snapshotId: snapshotId,
                screenshotPath: "/tmp/screenshot.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: "TextEdit",
                        applicationBundleId: "com.apple.TextEdit",
                        applicationProcessId: 2468,
                        windowTitle: targetWindow.title,
                        windowID: targetWindow.windowID,
                        windowBounds: targetWindow.bounds,
                        windowMutationIdentity: targetWindow.mutationIdentity
                    ),
                    truncationInfo: nil,
                    captureCoordinateContext: CaptureCoordinateContext(
                        metadata: CaptureMetadata(
                            size: targetWindow.bounds.size,
                            mode: .window,
                            windowInfo: targetWindow
                        ),
                        referenceID: snapshotId
                    )
                )
            )
        )
        let result = try await InProcessCommandRunner.run(
            [
                "click", "--at", "10,20", "--snapshot", snapshotId,
                "--app", "TextEdit", "--global", "--json", "--no-remote",
            ],
            services: services
        )

        #expect(result.exitStatus == 0, "Unexpected click refusal: \(result.combinedOutput)")
        let call = try #require(automation.targetedClickCalls.last)
        #expect(call.targetProcessIdentifier == 2468)
        #expect(call.targetWindowID == targetWindow.windowID)
        #expect(call.snapshotId == snapshotId)
        #expect(call.allowsAccessibilityValueDelivery == true)
        if case let .coordinates(point) = call.target {
            #expect(point == CGPoint(x: 10, y: 20))
        } else {
            Issue.record("Expected click to use targeted coordinate delivery")
        }
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<ClickDeliveryPayload>.self
        )
        #expect(payload.data.deliveryMode == "background")
    }

    private func storeKeyboardSnapshot(
        in services: PeekabooServices,
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        windowID: Int,
        windowBounds: CGRect,
        capturedBounds: CGRect?
    ) async throws -> String {
        let snapshotID = try await services.snapshots.createSnapshot()
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: capturedBounds
        )
        try await services.snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/keyboard-receipt.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: "TextEdit",
                        applicationBundleId: "com.apple.TextEdit",
                        applicationProcessId: processIdentifier,
                        windowTitle: "Document",
                        windowID: windowID,
                        windowBounds: windowBounds,
                        windowMutationIdentity: identity
                    )
                )
            )
        )
        return snapshotID
    }
}

@MainActor
private final class PartialKeyboardWindowInventoryService: StubWindowService {
    override func windowMutationInventory(
        target: WindowTarget
    ) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo> {
        try await .partial(
            self.listWindows(target: target),
            warnings: ["AX enumeration timed out"]
        )
    }
}

private struct ClickDeliveryPayload: Codable {
    let deliveryMode: String?
}
