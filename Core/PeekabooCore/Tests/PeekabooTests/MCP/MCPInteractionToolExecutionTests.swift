import AppKit
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

extension MCPToolExecutionTests {
    // MARK: - App Tool Tests

    @Test
    func `App tool missing action`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeLegacyContext(applications: mockApps)
        let tool = AppTool(context: context)
        let args = ToolArguments(raw: ["target": "Finder"])

        let response = try await tool.execute(arguments: args)
        #expect(response.isError == true)
    }

    @Test
    func `App tool switch cycle uses automation service`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "switch",
            "cycle": true,
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == "cmd,tab")
        #expect(await MainActor.run { automation.lastHotkeyHoldDuration } == 50)
    }

    @Test
    func `Click tool preserves element target for automation service`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let tool = ClickTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedClickCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.snapshotId == snapshotId)
        #expect(calls.first?.targetProcessIdentifier == 111)
        #expect(calls.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 111,
            processStartIdentity: 11))
        if case let .elementId(id) = calls.first?.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected ClickTool to forward .elementId, not coordinates")
        }
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(preserved != nil)
        #expect(implicitLatest == nil)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `Click tool forwards latest snapshot id when snapshot argument is omitted`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let tool = ClickTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: ["on": "B1"]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedClickCalls }
        #expect(calls.first?.snapshotId == snapshotId)
        #expect(calls.first?.targetProcessIdentifier == 111)
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(preserved != nil)
        #expect(implicitLatest == nil)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `Click tool invalidates snapshot after indeterminate delivery`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedClickError = { _ in
                InputDeliveryIndeterminateError(
                    operation: .click,
                    causeDescription: "post-dispatch identity drift")
            }
            return automation
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 112,
                    processStartIdentity: 12,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.count } == 1)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected indeterminate click metadata")
            return
        }
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["delivery_mechanism"] == nil)
        #expect(meta["delivery_mode"] == nil)
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
        #expect(await UISnapshotManager.shared.getSnapshot(id: snapshotId) != nil)
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
    }

    @Test
    func `Click tool projects canonical post-dispatch failure without replay`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let failure = DesktopActionFailure.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            message: "Click was dispatched, but post-click validation failed",
            hint: "Observe the target before retrying this click.",
            causeDescription: "post-dispatch identity drift")
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedClickError = { _ in failure }
            return automation
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 113,
                    processStartIdentity: 13,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.count } == 1)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected canonical click failure metadata")
            return
        }
        #expect(meta["effect"] == .string("unverifiable"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
        let wireResult = PeekabooMCPServer.callToolResult(from: response, toolName: "click")
        let wireData = try JSONEncoder().encode(wireResult)
        let wireJSON = try #require(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
        let wireMeta = try #require(wireJSON["_meta"] as? [String: Any])
        #expect(wireMeta["effect"] as? String == "unverifiable")
        #expect(wireMeta["mutation_dispatched"] as? Bool == true)
        #expect(wireMeta["retry_safe"] as? Bool == false)
        #expect(wireMeta["requires_fresh_observation"] as? Bool == true)
        guard case let .text(message, _, _)? = response.content.first else {
            Issue.record("Expected canonical click failure guidance")
            return
        }
        #expect(message.contains("Observe the target before retrying this click."))
        #expect(await UISnapshotManager.shared.getSnapshot(id: snapshotId) != nil)
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
    }

    @Test
    func `Click tool refuses empty or conflicting target shapes before dispatch or invalidation`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        let invalidArguments: [[String: Any]] = [
            ["on": "B1", "query": "OK"],
            ["on": "B1", "coords": "10,20", "foreground": true],
            ["query": "OK", "coords": "10,20", "foreground": true],
            ["on": "B1", "query": "OK", "coords": "10,20", "foreground": true],
            ["on": " ", "query": " "],
        ]

        for arguments in invalidArguments {
            let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: arguments))

            #expect(response.isError == true)
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected typed pre-dispatch click metadata")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }

        #expect(await MainActor.run { automation.clickCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil)?.id == snapshotId)
    }

    @Test
    func `Click tool preserves resolved query element target for automation service`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: false),
            UIElement(
                id: "B2",
                elementId: "B2",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 110, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let tool = ClickTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "query": "OK",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedClickCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.snapshotId == snapshotId)
        #expect(calls.first?.targetProcessIdentifier == 111)
        if case let .elementId(id) = calls.first?.target {
            #expect(id == "B2")
        } else {
            Issue.record("Expected ClickTool query click to forward resolved .elementId")
        }
    }

    @Test
    func `Click tool reports explicit background pid for element target`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 222,
                    processStartIdentity: 22,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let tool = ClickTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
            "background": true,
            "pid": 222,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedClickCalls }
        let call = try #require(calls.first)
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 222)
        #expect(Self.targetPID(from: response) == 222)
    }

    @Test
    func `Click tool rejects an explicit PID that contradicts the snapshot receipt`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([UIElement(
            id: "B1",
            elementId: "B1",
            role: "button",
            title: "OK",
            label: "OK",
            value: nil,
            description: nil,
            help: nil,
            roleDescription: "button",
            identifier: nil,
            frame: CGRect(x: 10, y: 20, width: 80, height: 30),
            isActionable: true)])

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
            "pid": 222,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected pre-dispatch metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    func `Click tool rejects snapshot PID without capture generation`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: 223,
                processStartIdentity: 23,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")])
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            applications: applications)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "SnapshotApp",
            applicationProcessId: 223,
            windowTitle: "Document"))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "OK",
                label: "OK",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `Click tool does not invent a routed double click outcome for a legacy service`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/routed-double-click.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "Open",
                label: "Open",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 80, height: 30),
                isActionable: true),
        ])

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
            "double": true,
        ]))

        #expect(!response.isError)
        let call = try #require(await MainActor.run { automation.targetedClickCalls.first })
        #expect(call.clickType == .double)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected routed click metadata")
            return
        }
        #expect(meta["verified"] == nil)
        #expect(meta["effect"] == nil)
        guard case let .text(text, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected routed click text response")
            return
        }
        #expect(!text.contains("effect is unverifiable"))
    }

    @Test
    func `snapshot independent coordinate click invalidates implicit latest`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id

        let tool = ClickTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "coords": "40,50",
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.clickCalls }
        #expect(calls.first?.snapshotId == nil)
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(preserved != nil)
        #expect(implicitLatest == nil)
    }

    @Test
    func `Click tool invalidates implicit latest while preserving explicit snapshot history`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let explicitSnapshot = await Self.makeCoordinateSnapshot()
        let explicitSnapshotId = await explicitSnapshot.id
        let latestSnapshot = await UISnapshotManager.shared.createSnapshot()
        let latestSnapshotId = await latestSnapshot.id

        let tool = ClickTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "coords": "40,50",
            "snapshot": explicitSnapshotId,
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.clickCalls }
        #expect(calls.first?.snapshotId == explicitSnapshotId)
        let explicitHistory = await UISnapshotManager.shared.getSnapshot(id: explicitSnapshotId)
        let latestHistory = await UISnapshotManager.shared.getSnapshot(id: latestSnapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(explicitHistory != nil)
        #expect(latestHistory != nil)
        #expect(implicitLatest == nil)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `foreground global coordinates remain snapshot-free`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "40,50",
            "foreground": true,
        ]))

        #expect(response.isError == false)
        guard case let .coordinates(point) = try #require(await MainActor.run { automation.clickCalls.first }).target
        else {
            Issue.record("Expected a global coordinate click")
            return
        }
        #expect(point == CGPoint(x: 40, y: 50))
    }

    @Test
    func `referenced foreground global coordinates validate context before using raw points`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await Self.makeCoordinateSnapshot()
        let snapshotID = await snapshot.id

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "140,150",
            "coordinate_reference": snapshotID,
            "foreground": true,
        ]))

        #expect(response.isError == false)
        guard case let .coordinates(point) = try #require(await MainActor.run { automation.clickCalls.first }).target
        else {
            Issue.record("Expected a referenced global coordinate click")
            return
        }
        #expect(point == CGPoint(x: 140, y: 150))
    }

    @Test
    func `referenced foreground globals reject stale moved and reused windows`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let (movedSnapshot, capturedWindow) = await Self.makeExactCoordinateSnapshot()
        let movedSnapshotID = await movedSnapshot.id
        let movedWindow = ServiceWindowInfo(
            windowID: capturedWindow.windowID,
            title: capturedWindow.title,
            bounds: capturedWindow.bounds.offsetBy(dx: 10, dy: 0),
            mutationIdentity: capturedWindow.mutationIdentity)
        let movedContext = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: movedWindow))
        let moved = try await ClickTool(context: movedContext).execute(arguments: ToolArguments(raw: [
            "coords": "200,200",
            "snapshot": movedSnapshotID,
            "foreground": true,
        ]))

        let (reusedSnapshot, reusedCapturedWindow) = await Self.makeExactCoordinateSnapshot()
        let reusedSnapshotID = await reusedSnapshot.id
        let reusedWindow = ServiceWindowInfo(
            windowID: reusedCapturedWindow.windowID,
            title: reusedCapturedWindow.title,
            bounds: reusedCapturedWindow.bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: reusedCapturedWindow.windowID,
                ownerProcessIdentifier: 111,
                ownerProcessStartIdentity: 8,
                capturedBounds: reusedCapturedWindow.bounds))
        let reusedContext = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: reusedWindow))
        let reused = try await ClickTool(context: reusedContext).execute(arguments: ToolArguments(raw: [
            "coords": "200,200",
            "coordinate_reference": reusedSnapshotID,
            "foreground": true,
        ]))

        let stale = try await ClickTool(context: movedContext).execute(arguments: ToolArguments(raw: [
            "coords": "200,200",
            "snapshot": "missing-snapshot",
            "foreground": true,
        ]))

        #expect(moved.isError)
        #expect(reused.isError)
        #expect(stale.isError)
        #expect(await MainActor.run { automation.clickCalls.isEmpty })
    }

    @Test
    func `Click tool maps referenced image pixels to global logical points`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let (snapshot, window) = await Self.makeExactCoordinateSnapshot()
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: window))
        let snapshotId = await snapshot.id

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "1000,500",
            "coordinate_space": "image_pixels",
            "coordinate_reference": snapshotId,
        ]))

        #expect(response.isError == false)
        let call = try #require(await MainActor.run { automation.targetedClickCalls.first })
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 111)
        guard case let .coordinates(point) = call.target else {
            Issue.record("Expected mapped coordinate target")
            return
        }
        #expect(point == CGPoint(x: 600, y: 300))
    }

    @Test
    func `Click tool rejects every conflicting variant before snapshot lookup or dispatch`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let variants = ["double", "right", "middle", "triple"]
        for first in variants.indices {
            for second in variants.indices where first < second {
                let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
                let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
                let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
                    "coords": "40,50",
                    "foreground": true,
                    variants[first]: true,
                    variants[second]: true,
                ]))

                #expect(response.isError)
                #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
                #expect(response.meta?.objectValue?["retry_safe"] == .bool(true))
                #expect(await MainActor.run { automation.clickCalls.isEmpty })
                #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
            }
        }

        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let accepted = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "40,50",
            "foreground": true,
            "middle": true,
            "triple": false,
            "double": false,
            "right": false,
        ]))
        #expect(!accepted.isError)
        #expect(await MainActor.run { automation.clickCalls.first?.clickType } == .middle)
    }

    @Test
    func `Click tool forwards middle and triple and projects exact target receipts`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        for (variant, clickType, units) in [
            ("middle", ClickType.middle, 3),
            ("triple", ClickType.triple, 7),
        ] {
            let outcome = DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units))
            let automation = await MainActor.run {
                OutcomeMockAutomationService(
                    accessibilityGranted: true,
                    outcome: outcome)
            }
            let (snapshot, window) = await Self.makeExactCoordinateSnapshot()
            let snapshotID = await snapshot.id
            let context = await MCPToolTestHelpers.makeLegacyContext(
                automation: automation,
                windows: PointerPolicyWindowService(window: window))
            let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
                "coords": "200,200",
                "snapshot": snapshotID,
                variant: true,
            ]))

            #expect(response.isError)
            let call = try #require(await MainActor.run { automation.targetedClickCalls.first })
            #expect(call.clickType == clickType)
            #expect(call.targetWindowID == window.windowID)
            let metadata = try #require(response.meta?.objectValue)
            #expect(metadata["click_type"] == .string(clickType.rawValue))
            #expect(metadata["dispatched_unit_count"] == .int(units))
            #expect(metadata["target_identity"]?.objectValue?["window_id"] == .int(window.windowID))
            #expect(metadata["target_receipt"]?.objectValue?["window_id"] == .int(window.windowID))
        }
    }

    @Test
    func `Click tool allows explicit foreground middle click without background capability`() async throws {
        let automation = await MainActor.run {
            let service = MockAutomationService(accessibilityGranted: true)
            service.supportsStatelessClickVariants = false
            return service
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "40,50",
            "foreground": true,
            "middle": true,
        ]))

        #expect(response.isError == false)
        let call = try #require(await MainActor.run { automation.clickCalls.first })
        #expect(call.clickType == .middle)
    }

    @Test
    func `Click tool maps ROI pixels while validating the full exact window receipt`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let (snapshot, window) = await Self.makeROICoordinateSnapshot()
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: window))
        let snapshotID = await snapshot.id

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "200,100",
            "coordinate_space": "image_pixels",
            "coordinate_reference": snapshotID,
        ]))

        #expect(response.isError == false)
        let call = try #require(await MainActor.run { automation.targetedClickCalls.first })
        #expect(call.targetWindowID == window.windowID)
        guard case let .coordinates(point) = call.target else {
            Issue.record("Expected ROI-mapped coordinate target")
            return
        }
        #expect(point == CGPoint(x: 400, y: 200))
    }

    @Test
    func `ROI pixel clicks refuse moved resized and reused exact windows`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }

        let (movedSnapshot, movedCapture) = await Self.makeROICoordinateSnapshot()
        let movedWindow = ServiceWindowInfo(
            windowID: movedCapture.windowID,
            title: movedCapture.title,
            bounds: movedCapture.bounds.offsetBy(dx: 10, dy: 0),
            mutationIdentity: movedCapture.mutationIdentity)
        let movedContext = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: movedWindow))
        let moved = try await ClickTool(context: movedContext).execute(arguments: ToolArguments(raw: [
            "coords": "200,100",
            "coordinate_space": "image_pixels",
            "coordinate_reference": movedSnapshot.id,
        ]))

        let (resizedSnapshot, resizedCapture) = await Self.makeROICoordinateSnapshot()
        let resizedWindow = ServiceWindowInfo(
            windowID: resizedCapture.windowID,
            title: resizedCapture.title,
            bounds: CGRect(
                origin: resizedCapture.bounds.origin,
                size: CGSize(width: resizedCapture.bounds.width - 1, height: resizedCapture.bounds.height)),
            mutationIdentity: resizedCapture.mutationIdentity)
        let resizedContext = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: resizedWindow))
        let resized = try await ClickTool(context: resizedContext).execute(arguments: ToolArguments(raw: [
            "coords": "200,100",
            "coordinate_space": "image_pixels",
            "coordinate_reference": resizedSnapshot.id,
        ]))

        let (reusedSnapshot, reusedCapture) = await Self.makeROICoordinateSnapshot()
        let reusedIdentity = try #require(reusedCapture.mutationIdentity)
        let reusedWindow = ServiceWindowInfo(
            windowID: reusedCapture.windowID,
            title: reusedCapture.title,
            bounds: reusedCapture.bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: reusedIdentity.windowID,
                ownerProcessIdentifier: reusedIdentity.ownerProcessIdentifier,
                ownerProcessStartIdentity: reusedIdentity.ownerProcessStartIdentity + 1,
                capturedBounds: reusedIdentity.capturedBounds))
        let reusedContext = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: reusedWindow))
        let reused = try await ClickTool(context: reusedContext).execute(arguments: ToolArguments(raw: [
            "coords": "200,100",
            "coordinate_space": "image_pixels",
            "coordinate_reference": reusedSnapshot.id,
        ]))

        #expect(moved.isError)
        #expect(resized.isError)
        #expect(reused.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `Click tool maps referenced normalized coordinates`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await Self.makeCoordinateSnapshot()
        let snapshotId = await snapshot.id

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "0.25,0.75",
            "coordinate_space": "normalized",
            "coordinate_reference": snapshotId,
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let call = try #require(await MainActor.run { automation.clickCalls.first })
        #expect(call.snapshotId == snapshotId)
        guard case let .coordinates(point) = call.target else {
            Issue.record("Expected mapped coordinate target")
            return
        }
        #expect(point == CGPoint(x: 350, y: 425))
    }

    @Test
    func `Click tool rejects missing stale and out-of-bounds coordinate references`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService() }
        let windows = EmptyRecordingWindowService()
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            applications: applications,
            windows: windows)
        let snapshot = await Self.makeCoordinateSnapshot()
        let snapshotId = await snapshot.id
        let tool = ClickTool(context: context)

        let missing = try await tool.execute(arguments: ToolArguments(raw: [
            "coords": "100,100",
            "coordinate_space": "image_pixels",
        ]))
        let stale = try await tool.execute(arguments: ToolArguments(raw: [
            "coords": "100,100",
            "coordinate_space": "image_pixels",
            "coordinate_reference": "missing-snapshot",
        ]))
        let outOfBounds = try await tool.execute(arguments: ToolArguments(raw: [
            "coords": "2000,500",
            "coordinate_space": "image_pixels",
            "coordinate_reference": snapshotId,
        ]))
        let windowSnapshot = await UISnapshotManager.shared.createSnapshot()
        let windowSnapshotId = await windowSnapshot.id
        await windowSnapshot.setScreenshot(
            path: "/tmp/stale-window-snapshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 1000, height: 500),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: ServiceWindowInfo(
                    windowID: 2_147_483_647,
                    title: "Missing Window",
                    bounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
                    index: 0)))
        let staleWindow = try await tool.execute(arguments: ToolArguments(raw: [
            "coords": "500,250",
            "coordinate_space": "image_pixels",
            "coordinate_reference": windowSnapshotId,
            "foreground": true,
        ]))

        #expect(missing.isError)
        #expect(stale.isError)
        #expect(outOfBounds.isError)
        #expect(staleWindow.isError)
        #expect(await MainActor.run { automation.clickCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await windows.requestedWindowIDs == [2_147_483_647])
    }

    @Test
    func `Type tool preserves element target when focusing before typing`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setUIElements([
            UIElement(
                id: "T1",
                elementId: "T1",
                role: "textField",
                title: nil,
                label: "Name",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "text field",
                identifier: nil,
                frame: CGRect(x: 10, y: 20, width: 160, height: 30),
                isActionable: true),
        ])

        let tool = TypeTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotId,
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.clickCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.snapshotId == snapshotId)
        if case let .elementId(id) = calls.first?.target {
            #expect(id == "T1")
        } else {
            Issue.record("Expected TypeTool focus click to forward .elementId, not coordinates")
        }
    }

    @Test
    func `snapshot independent foreground type invalidates implicit latest`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id

        let tool = TypeTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let typeSnapshotId = await MainActor.run { automation.lastTypeSnapshotId }
        #expect(typeSnapshotId == nil)
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(preserved != nil)
        #expect(implicitLatest == nil)
        #expect(MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `Type tool invalidates implicit latest while preserving explicit snapshot history`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let explicitSnapshot = await UISnapshotManager.shared.createSnapshot()
        let explicitSnapshotId = await explicitSnapshot.id
        let latestSnapshot = await UISnapshotManager.shared.createSnapshot()
        let latestSnapshotId = await latestSnapshot.id

        let tool = TypeTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "snapshot": explicitSnapshotId,
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let typeSnapshotId = await MainActor.run { automation.lastTypeSnapshotId }
        #expect(typeSnapshotId == explicitSnapshotId)
        let explicitHistory = await UISnapshotManager.shared.getSnapshot(id: explicitSnapshotId)
        let latestHistory = await UISnapshotManager.shared.getSnapshot(id: latestSnapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(explicitHistory != nil)
        #expect(latestHistory != nil)
        #expect(implicitLatest == nil)
        #expect(MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `snapshot independent pointer scroll invalidates implicit latest`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id

        let tool = ScrollTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let requests = await MainActor.run { automation.scrollRequests }
        #expect(requests.first?.snapshotId == nil)
        let preserved = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(preserved != nil)
        #expect(implicitLatest == nil)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `background scroll forwards the snapshot exact window receipt`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotID = await snapshot.id
        let bounds = CGRect(x: 100, y: 50, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 11,
            capturedBounds: bounds)
        await snapshot.setScreenshot(
            path: "/tmp/background-scroll.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.scroll",
                    name: "ScrollApp"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Scroll",
                    bounds: bounds,
                    mutationIdentity: identity)))
        await snapshot.setUIElements([
            UIElement(
                id: "S1",
                elementId: "S1",
                role: "scrollArea",
                title: nil,
                label: "Items",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "scroll area",
                identifier: "scroll-fixture",
                frame: CGRect(x: 120, y: 80, width: 300, height: 250),
                isActionable: true),
        ])

        let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "on": "S1",
            "snapshot": snapshotID,
        ]))

        #expect(!response.isError)
        let request = try #require(await MainActor.run { automation.scrollRequests.first })
        #expect(request.snapshotId == snapshotID)
        #expect(request.expectedWindow?.identity == identity)
        #expect(request.expectedWindow?.bounds == bounds)
    }

    @Test
    func `Scroll tool invalidates implicit latest while preserving explicit snapshot history`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let explicitSnapshot = await UISnapshotManager.shared.createSnapshot()
        let explicitSnapshotId = await explicitSnapshot.id
        let latestSnapshot = await UISnapshotManager.shared.createSnapshot()
        let latestSnapshotId = await latestSnapshot.id

        let tool = ScrollTool(context: context)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "snapshot": explicitSnapshotId,
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let requests = await MainActor.run { automation.scrollRequests }
        #expect(requests.first?.snapshotId == explicitSnapshotId)
        let explicitHistory = await UISnapshotManager.shared.getSnapshot(id: explicitSnapshotId)
        let latestHistory = await UISnapshotManager.shared.getSnapshot(id: latestSnapshotId)
        let implicitLatest = await UISnapshotManager.shared.getSnapshot(id: nil)
        #expect(explicitHistory != nil)
        #expect(latestHistory != nil)
        #expect(implicitLatest == nil)
        #expect(!MCPResponseMeta.requiresFreshObservation(response))
        #expect(!MCPResponseMeta.hasRequiresFreshSee(response))
    }

    @Test
    func `Move tool center uses screen and cursor services`() async throws {
        let automation = await MainActor.run {
            MockAutomationService(accessibilityGranted: true, currentMouseLocation: CGPoint(x: 10, y: 20))
        }
        let screens = await MainActor.run {
            MockScreenService(screens: [
                ScreenInfo(
                    index: 0,
                    name: "Mock Display",
                    frame: CGRect(x: 100, y: 200, width: 800, height: 600),
                    visibleFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
                    isPrimary: true,
                    scaleFactor: 1,
                    displayID: 1),
            ])
        }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation, screens: screens)
        let tool = MoveTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "center": true,
            "foreground": true,
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { automation.lastMoveTarget } == CGPoint(x: 500, y: 500))
        #expect(await MainActor.run { automation.lastMoveDuration } == 0)
    }

    private static func makeCoordinateSnapshot() async -> UISnapshot {
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/coordinate-snapshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 2000, height: 1000),
                mode: .screen,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                displayInfo: DisplayInfo(
                    index: 0,
                    name: "Display",
                    bounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
                    scaleFactor: 2)))
        return snapshot
    }

    private static func makeExactCoordinateSnapshot() async -> (UISnapshot, ServiceWindowInfo) {
        let bounds = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds)
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Coordinate Window",
            bounds: bounds,
            index: 0,
            mutationIdentity: identity)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/exact-coordinate-snapshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 2000, height: 1000),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 7,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: window))
        return (snapshot, window)
    }

    private static func makeROICoordinateSnapshot() async -> (UISnapshot, ServiceWindowInfo) {
        let sourceBounds = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 7,
            capturedBounds: sourceBounds)
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "ROI Coordinate Window",
            bounds: sourceBounds,
            mutationIdentity: identity)
        let viewport = CaptureViewport(
            sourceLogicalBounds: sourceBounds,
            requestedWindowRelativeBounds: CGRect(x: 200, y: 100, width: 200, height: 100),
            deliveredWindowRelativeBounds: CGRect(x: 200, y: 100, width: 200, height: 100),
            logicalBounds: CGRect(x: 300, y: 150, width: 200, height: 100),
            sourceImageSize: CGSize(width: 2000, height: 1000))
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        await snapshot.setScreenshot(
            path: "/tmp/roi-coordinate-snapshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 400, height: 200),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 7,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: window,
                viewport: viewport))
        return (snapshot, window)
    }

    private static func targetPID(from response: ToolResponse) -> Int32? {
        guard case let .object(meta) = response.meta,
              case let .double(pid)? = meta["target_pid"]
        else {
            return nil
        }
        return Int32(pid)
    }
}

@MainActor
private final class OutcomeMockAutomationService: MockAutomationService,
ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript: UIAutomationOutcomeScript

    init(accessibilityGranted: Bool, outcome: DesktopActionOutcome) {
        self.uiAutomationOutcomeScript = UIAutomationOutcomeScript(defaultResponse: .outcome(outcome))
        super.init(accessibilityGranted: accessibilityGranted)
    }
}
