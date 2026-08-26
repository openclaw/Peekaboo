import CoreGraphics
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct MCPKeyboardBackgroundToolTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `Press tool accepts both deliberate schema shapes`() throws {
        let sequence = try PressTool.parseChords(arguments: ToolArguments(raw: [
            "keys": ["cmd+shift+t", "Return"],
        ]))
        #expect(sequence.map(\.serviceKeys) == ["cmd,shift,t", "return"])

        let single = try PressTool.parseChords(arguments: ToolArguments(raw: [
            "key": "c",
            "modifiers": ["command", "shift"],
        ]))
        #expect(single.map(\.serviceKeys) == ["cmd,shift,c"])

        let keyOnly = try PressTool.parseChords(arguments: ToolArguments(raw: [
            "key": "Return",
        ]))
        #expect(keyOnly.map(\.serviceKeys) == ["return"])

        let emptyModifiers = try PressTool.parseChords(arguments: ToolArguments(raw: [
            "key": "Tab",
            "modifiers": [],
        ]))
        #expect(emptyModifiers.map(\.serviceKeys) == ["tab"])
    }

    @Test
    func `Press tool rejects mixed schema shapes`() {
        let error = #expect(throws: PressToolValidationError.self) {
            _ = try PressTool.parseChords(arguments: ToolArguments(raw: [
                "keys": ["cmd+c"],
                "key": "v",
                "modifiers": ["cmd"],
            ]))
        }
        #expect(error?.message == "Use either keys or key+modifiers, not both")
    }

    @Test
    func `Press tool reports malformed modifier shapes without dispatch`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: Self.uiSnapshots.owner)
        let cases: [([String: Any], String)] = [
            (["key": "c", "modifiers": "cmd"], "modifiers must be an array of modifier strings"),
            (["key": "c", "modifiers": ["cmd": true]], "modifiers must be an array of modifier strings"),
            (["key": "c", "modifiers": ["cmd", 7]], "modifiers[1] must be a non-empty modifier string"),
            (["key": "c", "modifiers": ["cmd", "  "]], "modifiers[1] must be a non-empty modifier string"),
            (
                ["keys": ["cmd+c"], "modifiers": ["unexpected": true]],
                "Use either keys or key+modifiers, not both"),
            (["keys": ["cmd+c"], "modifiers": []], "Use either keys or key+modifiers, not both"),
        ]

        for (arguments, expectedMessage) in cases {
            var foregroundArguments = arguments
            foregroundArguments["foreground"] = true
            let response = try await PressTool(context: context).execute(
                arguments: ToolArguments(raw: foregroundArguments))
            #expect(response.isError)
            guard case let .text(message, _, _)? = response.content.first else {
                Issue.record("Expected press validation text")
                continue
            }
            #expect(message.contains(expectedMessage))
            #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
            #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected press validation metadata")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["refusal_reason"] == .string("invalid_request"))
        }
    }

    @Test
    func `Press tool reports empty and malformed input shapes without dispatch`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: Self.uiSnapshots.owner)
        let cases: [([String: Any], String)] = [
            ([:], "Provide either a non-empty keys array or a non-empty key with optional modifiers"),
            (["keys": []], "keys must contain at least one chord"),
            (["key": ""], "Provide either a non-empty keys array or a non-empty key with optional modifiers"),
            (["keys": ""], "keys must be an array of chord strings"),
            (["keys": [""]], "keys[0] must be a non-empty chord string"),
        ]

        for (arguments, expectedMessage) in cases {
            let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: arguments))
            #expect(response.isError)
            guard case let .text(message, _, _)? = response.content.first else {
                Issue.record("Expected press validation text")
                continue
            }
            #expect(message.contains(expectedMessage))
            #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
            #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected press validation metadata")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["refusal_reason"] == .string("invalid_request"))
        }
    }

    @Test
    func `Keyboard tools reject targetless input instead of injecting globally`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: MockClipboardService(),
            snapshotOwner: Self.uiSnapshots.owner)

        let typeResponse = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
        ]))
        let hotkeyResponse = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+space"],
        ]))
        let pasteResponse = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "restore_delay_ms": 0,
        ]))

        #expect(typeResponse.isError)
        #expect(hotkeyResponse.isError)
        #expect(pasteResponse.isError)
        #expect(await MainActor.run { automation.lastTypeActions } == nil)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Keyboard target resolution failure never falls back to global input`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: []) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: MockClipboardService(),
            snapshotOwner: Self.uiSnapshots.owner)

        let typeResponse = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Missing",
            "text": "hello",
        ]))
        let hotkeyResponse = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Missing",
            "keys": ["cmd+l"],
        ]))
        let pasteResponse = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Missing",
            "text": "hello",
            "restore_delay_ms": 0,
        ]))

        #expect(typeResponse.isError)
        #expect(hotkeyResponse.isError)
        #expect(pasteResponse.isError)
        #expect(await MainActor.run { automation.lastTypeActions } == nil)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Foreground explicitly dispatches type without claiming unconfirmed receiver change`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: MockClipboardService(),
            snapshotOwner: Self.uiSnapshots.owner)

        let typeResponse = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "foreground": true,
        ]))
        let hotkeyResponse = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+space"],
            "foreground": true,
        ]))
        let pasteResponse = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "foreground": true,
            "restore_delay_ms": 0,
        ]))

        #expect(typeResponse.isError)
        #expect(hotkeyResponse.isError == false)
        #expect(pasteResponse.isError == false)
        #expect(await MainActor.run { automation.lastTypeActions } != nil)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == "cmd,v")
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
        #expect(typeResponse.meta?.objectValue?["characters_typed"] == .null)
        guard case let .object(hotkeyMeta) = hotkeyResponse.meta else {
            Issue.record("Expected foreground press metadata")
            return
        }
        #expect(hotkeyMeta["delivery_mode"] == .string("foreground"))
        #expect(hotkeyMeta["effect"] == .string("unverifiable"))
        #expect(hotkeyMeta["mutation_dispatched"] == .bool(true))
        #expect(hotkeyMeta["retry_safe"] == .bool(false))
        #expect(hotkeyMeta["requires_fresh_observation"] == .bool(true))
    }

    @Test
    func `Type tool dispatches to snapshot process without claiming unconfirmed characters`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 444,
                processStartIdentity: 44,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: AutomationTestFixtures.application(
                    processIdentifier: 444,
                    processStartIdentity: 44,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
            "text": "hello",
        ]))

        #expect(response.isError)
        let calls = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.snapshotId == snapshotId)
        #expect(calls.first?.targetProcessIdentifier == 444)
        #expect(calls.first?.expectedProcessIdentity == AutomationTestFixtures.processIdentity(
            processIdentifier: 444,
            processStartIdentity: 44))
        #expect(await MainActor.run { automation.clickCalls.isEmpty })
        #expect(response.meta?.objectValue?["characters_typed"] == .null)
    }

    @Test
    func `Snapshot without process metadata fails instead of typing globally`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
            "text": "hello",
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.lastTypeActions } == nil)
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
    }

    @Test
    func `Snapshot PID without capture generation fails instead of targeting reused process`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 445,
                processStartIdentity: 45,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "SnapshotApp",
            applicationProcessId: 445,
            windowTitle: "Document"))

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
            "text": "hello",
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.lastTypeActions } == nil)
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
    }

    @Test
    func `Explicit app cannot authorize receiptless element snapshot`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 446,
                processStartIdentity: 46,
                bundleIdentifier: "com.example.editor",
                name: "Editor")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setUIElements([
            AutomationTestFixtures.storedElement(
                id: "T1",
                role: "textField",
                title: nil,
                label: "Name",
                roleDescription: "text field",
                frame: CGRect(x: 10, y: 20, width: 160, height: 30),
                isActionable: true),
        ])

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "snapshot": snapshotId,
            "app": "Editor",
            "text": "hello",
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
    }

    @Test
    func `Background keyboard tools reject window selectors instead of collapsing to pid`() async throws {
        let app = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: MockClipboardService(),
            snapshotOwner: Self.uiSnapshots.owner)

        let typeResponse = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "window_title": "Document",
            "text": "hello",
        ]))
        let hotkeyResponse = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "window_title": "Document",
            "keys": ["cmd+l"],
        ]))
        let pasteResponse = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "window_title": "Document",
            "text": "hello",
            "restore_delay_ms": 0,
        ]))

        #expect(typeResponse.isError)
        #expect(hotkeyResponse.isError)
        #expect(pasteResponse.isError)
        #expect(await MainActor.run { automation.lastTypeActions } == nil)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Type tool preserves background focus and typing dispatch without false character claims`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 111,
                processStartIdentity: 11,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: AutomationTestFixtures.application(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
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
        ]))

        #expect(response.isError)
        let targetedClicks = await MainActor.run { automation.targetedClickCalls }
        #expect(targetedClicks.count == 1)
        #expect(targetedClicks.first?.targetProcessIdentifier == 111)
        #expect(targetedClicks.first?.expectedProcessIdentity == AutomationTestFixtures.processIdentity(
            processIdentifier: 111,
            processStartIdentity: 11))
        let targetedTypes = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(targetedTypes.count == 1)
        #expect(targetedTypes.first?.snapshotId == snapshotId)
        #expect(targetedTypes.first?.targetProcessIdentifier == 111)
        #expect(targetedTypes.first?.expectedProcessIdentity == AutomationTestFixtures.processIdentity(
            processIdentifier: 111,
            processStartIdentity: 11))
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected metadata")
            return
        }
        #expect(meta["delivery_mode"] == nil)
        #expect(meta["characters_typed"] == .null)
        #expect(meta["mutation_dispatched"] == .bool(true))
    }

    @Test
    func `Process clear refuses missing composite capability before element focus`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.supportsExactWindowCompositeTypeDelivery = false
            return automation
        }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 112,
                processStartIdentity: 12,
                bundleIdentifier: "com.example.legacy",
                name: "LegacyApp")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/legacy-type.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: AutomationTestFixtures.application(
                    processIdentifier: 112,
                    processStartIdentity: 12,
                    bundleIdentifier: "com.example.legacy",
                    name: "LegacyApp")))
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

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "clear": true,
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("runtime_incompatible"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
    }

    @Test
    func `Type tool reports failure after background focus click as retry unsafe`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedTypeError = { _ in
                PeekabooError.invalidInput("target process changed generation")
            }
            return automation
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 113,
                processStartIdentity: 13,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")]),
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: AutomationTestFixtures.application(
                    processIdentifier: 113,
                    processStartIdentity: 13,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
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

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.count } == 1)
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.count } == 1)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected indeterminate type metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["characters_typed"] == .null)
        #expect(meta["delivery_mechanism"] == nil)
        #expect(meta["delivery_mode"] == nil)
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
        #expect(await Self.uiSnapshots.getSnapshot(id: snapshotId) != nil)
        #expect(await Self.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    func `indeterminate typing after focus never reports emitted units as typed characters`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedTypeError = { _ in
                InputDeliveryIndeterminateError(
                    operation: .type,
                    emittedUnitCount: 2,
                    causeDescription: "typing completion drift")
            }
            return automation
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 115,
                processStartIdentity: 15,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")]),
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshotId = await self.makeTypingSnapshot(
            processIdentifier: 115,
            processStartIdentity: 15)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatched_unit_count"] == .int(3))
        #expect(meta["characters_typed"] == .null)
        #expect(meta["delivery_mechanism"] == nil)
        #expect(meta["delivery_mode"] == nil)
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
    }

    @Test
    func `Type tool does not count an indeterminate focus click as typed characters`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedClickError = { _ in
                InputDeliveryIndeterminateError(
                    operation: .click,
                    emittedUnitCount: 1,
                    causeDescription: "focus click completion drift")
            }
            return automation
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 114,
                processStartIdentity: 14,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")]),
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshotId = await self.makeTypingSnapshot(
            processIdentifier: 114,
            processStartIdentity: 14)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.count } == 1)
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected indeterminate type metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["characters_typed"] == .null)
        #expect(meta["delivery_mechanism"] == nil)
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
    }

    @Test
    func `Press tool refuses pid-targeted raw background delivery`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 222,
                processStartIdentity: 22,
                bundleIdentifier: "com.example.target",
                name: "Target")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = PressTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+l"],
            "pid": 222,
        ]))

        #expect(response.isError)
        let calls = await MainActor.run { automation.targetedHotkeyCalls }
        #expect(calls.isEmpty)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected metadata")
            return
        }
        #expect(meta["code"] == .string("INTERACTION_FAILED"))
        #expect(meta["effect"] == .string("refused"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["escalation"] == .string("correct_request"))
        #expect(meta["refusal_reason"] == .string("foreground_consent_required"))
        #expect(meta["hint"]?.description.contains("foreground=true") == true)
    }
}

extension MCPKeyboardBackgroundToolTests {
    @Test
    func `Type dispatches targeted delivery without claiming success while raw press refuses`() async throws {
        let app = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [app])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner)

        let typeResponse = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "hello",
        ]))
        let hotkeyResponse = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "keys": ["cmd+l"],
        ]))

        #expect(typeResponse.isError)
        #expect(hotkeyResponse.isError)
        let typeCalls = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(typeCalls.count == 1)
        #expect(typeCalls.first?.targetProcessIdentifier == 333)
        #expect(typeCalls.first?.expectedProcessIdentity == AutomationTestFixtures.processIdentity(
            processIdentifier: 333,
            processStartIdentity: 33))
        #expect(typeResponse.meta?.objectValue?["characters_typed"] == .null)
        let hotkeyCalls = await MainActor.run { automation.targetedHotkeyCalls }
        #expect(hotkeyCalls.isEmpty)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
    }

    @Test
    func `Paste tool uses targeted delivery when app process is known`() async throws {
        let app = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [app])
        }
        let priorClipboard = ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data("before".utf8),
            textPreview: "before")
        let clipboard = await MainActor.run {
            MockClipboardService(current: priorClipboard)
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = PasteTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "hello",
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.targetProcessIdentifier == 333)
        #expect(calls.first?.expectedProcessIdentity == AutomationTestFixtures.processIdentity(
            processIdentifier: 333,
            processStartIdentity: 33))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected metadata")
            return
        }
        #expect(meta["delivery_mode"] == .string("background"))
        #expect(meta["target_pid"] == .int(333))
        #expect(meta["paste_method"] == .string("background_text"))
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
    }

    @Test
    func `Paste tool routes UTF8 data through targeted text delivery`() async throws {
        let app = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run { MockClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "dataBase64": Data("decoded text".utf8).base64EncodedString(),
            "uti": UTType.utf8PlainText.identifier,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(calls.count == 1)
        if case .text("decoded text")? = calls.first?.actions.first {} else {
            Issue.record("Expected UTF-8 data to use targeted text delivery")
        }
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
    }

    @Test
    func `Paste tool warns without inviting retry when clipboard restoration fails`() async throws {
        let app = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [app])
        }
        let priorClipboard = ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data("before".utf8),
            textPreview: "before")
        let restoreError = ClipboardServiceError.writeFailed("simulated restore failure")
        let clipboard = await MainActor.run {
            MockClipboardService(current: priorClipboard, restoreError: restoreError)
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = PasteTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "foreground": true,
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError == false)
        guard case let .text(text: message, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response")
            return
        }
        #expect(message.contains(AgentDisplayTokens.Status.warning))
        #expect(message.contains("clipboard restoration failed"))
        #expect(message.contains("Do not retry the paste"))
        #expect(!message.contains(AgentDisplayTokens.Status.success))

        guard case let .object(meta) = response.meta else {
            Issue.record("Expected metadata")
            return
        }
        #expect(meta["restore_succeeded"] == .bool(false))
        #expect(meta["restore_error"] == .string("Failed to write to clipboard: simulated restore failure"))
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
    }

    private func makeTypingSnapshot(
        processIdentifier: pid_t,
        processStartIdentity: UInt64) async -> String
    {
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: AutomationTestFixtures.application(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
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
        return snapshotId
    }
}

struct PressToolParsingValidationTests {
    @Test
    func `Press tool rejects malformed modifier shapes while parsing`() {
        let cases: [([String: Any], String)] = [
            (["key": "c", "modifiers": "cmd"], "modifiers must be an array of modifier strings"),
            (["key": "c", "modifiers": ["cmd": true]], "modifiers must be an array of modifier strings"),
            (["key": "c", "modifiers": ["cmd", 7]], "modifiers[1] must be a non-empty modifier string"),
            (["key": "c", "modifiers": ["cmd", "  "]], "modifiers[1] must be a non-empty modifier string"),
            (
                ["keys": ["cmd+c"], "modifiers": ["unexpected": true]],
                "Use either keys or key+modifiers, not both"),
            (["keys": ["cmd+c"], "modifiers": []], "Use either keys or key+modifiers, not both"),
        ]

        for (arguments, expectedMessage) in cases {
            let error = #expect(throws: PressToolValidationError.self) {
                _ = try PressTool.parseChords(arguments: ToolArguments(raw: arguments))
            }
            #expect(error?.message == expectedMessage)
        }
    }
}

private final class MockClipboardService: ClipboardServiceProtocol, @unchecked Sendable {
    private var current: ClipboardReadResult?
    private var slots: [String: ClipboardReadResult] = [:]
    private let restoreError: ClipboardServiceError?
    private(set) var restoreCallCount = 0

    init(current: ClipboardReadResult? = nil, restoreError: ClipboardServiceError? = nil) {
        self.current = current
        self.restoreError = restoreError
    }

    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        self.current
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        guard let representation = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided")
        }
        let result = ClipboardReadResult(
            utiIdentifier: representation.utiIdentifier,
            data: representation.data,
            textPreview: request.alsoText)
        self.current = result
        return result
    }

    func clear() {
        self.current = nil
    }

    func save(slot: String) throws {
        guard let current else {
            throw ClipboardServiceError.empty
        }
        self.slots[slot] = current
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        self.restoreCallCount += 1
        if let restoreError {
            throw restoreError
        }
        guard let saved = self.slots[slot] else {
            throw ClipboardServiceError.slotNotFound(slot)
        }
        self.current = saved
        return saved
    }
}
