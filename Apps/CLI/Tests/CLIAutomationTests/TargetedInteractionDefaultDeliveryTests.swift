import CoreGraphics
import Foundation
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
            ["hotkey", "cmd,l"],
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
    func `no auto focus does not downgrade targeted keyboard delivery to global input`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = StubAutomationService()
        let applications = StubApplicationService(applications: [app])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: StubClipboardService(),
            automation: automation
        )

        for arguments in [
            ["type", "hello", "--app", "TextEdit", "--no-auto-focus"],
            ["press", "return", "--app", "TextEdit", "--no-auto-focus"],
            ["hotkey", "cmd,l", "--app", "TextEdit", "--no-auto-focus"],
            ["paste", "--text", "hello", "--app", "TextEdit", "--no-auto-focus"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus == 0, "Expected targeted input to succeed: \(arguments)")
        }

        #expect(automation.targetedTypeActionsCalls.count == 3)
        #expect(automation.targetedTypeActionsCalls.allSatisfy { $0.targetProcessIdentifier == 2468 })
        #expect(automation.targetedHotkeyCalls.count == 1)
        #expect(automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 2468)
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
            ["hotkey", "cmd,l", "--app", "Missing"],
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
    func `foreground explicitly preserves intentional global keyboard delivery`() async throws {
        let automation = StubAutomationService()
        let services = TestServicesFactory.makePeekabooServices(
            clipboard: StubClipboardService(),
            automation: automation
        )

        for arguments in [
            ["type", "hello", "--foreground"],
            ["press", "return", "--foreground"],
            ["hotkey", "cmd,space", "--foreground"],
            ["paste", "--text", "hello", "--foreground", "--restore-delay-ms", "0"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus == 0, "Expected explicit foreground input to succeed: \(arguments)")
        }

        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.hotkeyCalls.map(\.keys) == ["return", "cmd,space", "cmd,v"])
    }

    @Test
    func `background keyboard delivery rejects window selectors instead of collapsing to pid`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
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
            ["press", "return", "--app", "TextEdit", "--window-title", "Document"],
            ["hotkey", "cmd,l", "--app", "TextEdit", "--window-title", "Document"],
            ["paste", "--text", "hello", "--app", "TextEdit", "--window-title", "Document"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments + ["--no-remote"], services: services)
            #expect(result.exitStatus != 0, "Expected unsafe window targeting to fail: \(arguments)")
            #expect(result.combinedOutput.contains("cannot safely target a specific window"))
        }

        #expect(automation.targetedTypeActionsCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `snapshot process metadata keeps keyboard delivery pid routed without an element`() async throws {
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

        for arguments in [
            ["type", "hello", "--snapshot", snapshotId, "--no-auto-focus"],
            ["press", "return", "--snapshot", snapshotId, "--no-auto-focus"],
            ["hotkey", "cmd,l", "--snapshot", snapshotId, "--no-auto-focus"],
        ] {
            let result = try await InProcessCommandRunner.run(
                arguments + ["--no-remote"],
                services: context.services
            )
            #expect(result.exitStatus == 0, "Expected snapshot-targeted input to succeed: \(arguments)")
        }

        #expect(context.automation.targetedTypeActionsCalls.count == 2)
        #expect(context.automation.targetedTypeActionsCalls.allSatisfy { $0.targetProcessIdentifier == 2468 })
        #expect(context.automation.targetedHotkeyCalls.count == 1)
        #expect(context.automation.targetedHotkeyCalls.first?.targetProcessIdentifier == 2468)
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
        #expect(result.combinedOutput.contains("does not identify a target process"))
        #expect(context.automation.typeActionsCalls.isEmpty)
        #expect(context.automation.targetedTypeActionsCalls.isEmpty)
    }

    @Test
    func `targeted interaction commands default to background delivery`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let automation = StubAutomationService()
        let applications = StubApplicationService(applications: [app])
        let clipboard = StubClipboardService()
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )

        try await self.assertTypeDefaultsToBackground(services: services, automation: automation)
        try await self.assertPressDefaultsToBackground(services: services, automation: automation)
        try await self.assertHotkeyDefaultsToBackground(services: services, automation: automation)
        try await self.assertPasteDefaultsToBackground(services: services, automation: automation)
        try await self.assertClickDefaultsToBackground(services: services, automation: automation)
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

    private func assertPressDefaultsToBackground(
        services: PeekabooServices,
        automation: StubAutomationService
    ) async throws {
        let result = try await InProcessCommandRunner.run(
            ["press", "return", "--app", "TextEdit", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let call = try #require(automation.targetedTypeActionsCalls.last)
        #expect(call.targetProcessIdentifier == 2468)
        if case .key(.return) = call.actions.first {} else {
            Issue.record("Expected press to use a targeted return key action")
        }
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PressResult>.self
        )
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == 2468)
    }

    private func assertHotkeyDefaultsToBackground(
        services: PeekabooServices,
        automation: StubAutomationService
    ) async throws {
        let result = try await InProcessCommandRunner.run(
            ["hotkey", "cmd,l", "--app", "TextEdit", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let call = try #require(automation.targetedHotkeyCalls.last)
        #expect(call.keys == "cmd,l")
        #expect(call.targetProcessIdentifier == 2468)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<HotkeyResult>.self
        )
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == 2468)
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
        automation: StubAutomationService
    ) async throws {
        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "10,20", "--app", "TextEdit", "--global-coords", "--json", "--no-remote"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let call = try #require(automation.targetedClickCalls.last)
        #expect(call.targetProcessIdentifier == 2468)
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
}

private struct ClickDeliveryPayload: Codable {
    let deliveryMode: String?
}
