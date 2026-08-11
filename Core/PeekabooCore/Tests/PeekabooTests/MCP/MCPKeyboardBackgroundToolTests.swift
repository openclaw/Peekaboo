import CoreGraphics
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct MCPKeyboardBackgroundToolTests {
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
    }

    @Test
    func `Press tool rejects mixed schema shapes`() {
        #expect(throws: KeyboardChordError.self) {
            _ = try PressTool.parseChords(arguments: ToolArguments(raw: [
                "keys": ["cmd+c"],
                "key": "v",
                "modifiers": ["cmd"],
            ]))
        }
    }

    @Test
    func `Keyboard tools reject targetless input instead of injecting globally`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: MockClipboardService())

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
            clipboard: MockClipboardService())

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
    func `Foreground explicitly preserves intentional global keyboard delivery`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: MockClipboardService())

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

        #expect(typeResponse.isError == false)
        #expect(hotkeyResponse.isError == false)
        #expect(pasteResponse.isError == false)
        #expect(await MainActor.run { automation.lastTypeActions } != nil)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == "cmd,v")
        #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Type tool uses snapshot process without requiring an element`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: 444,
                processStartIdentity: 44,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 444,
                    processStartIdentity: 44,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
            "text": "hello",
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.snapshotId == snapshotId)
        #expect(calls.first?.targetProcessIdentifier == 444)
        #expect(calls.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 444,
            processStartIdentity: 44))
        #expect(await MainActor.run { automation.clickCalls.isEmpty })
    }

    @Test
    func `Snapshot without process metadata fails instead of typing globally`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
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
    func `Background keyboard tools reject window selectors instead of collapsing to pid`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: MockClipboardService())

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
    func `Type tool uses background click and typing when snapshot process is known`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: 111,
                processStartIdentity: 11,
                bundleIdentifier: "com.example.snapshot",
                name: "SnapshotApp")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications)
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

        #expect(response.isError == false)
        let targetedClicks = await MainActor.run { automation.targetedClickCalls }
        #expect(targetedClicks.count == 1)
        #expect(targetedClicks.first?.targetProcessIdentifier == 111)
        #expect(targetedClicks.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 111,
            processStartIdentity: 11))
        let targetedTypes = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(targetedTypes.count == 1)
        #expect(targetedTypes.first?.snapshotId == snapshotId)
        #expect(targetedTypes.first?.targetProcessIdentifier == 111)
        #expect(targetedTypes.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 111,
            processStartIdentity: 11))
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected metadata")
            return
        }
        #expect(meta["delivery_mode"] == .string("background"))
        #expect(meta["target_pid"] == .int(111))
    }

    @Test
    func `Type tool reports failure after background focus click as retry unsafe`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedTypeError = { _ in
                PeekabooError.invalidInput("target process changed generation")
            }
            return automation
        }
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
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
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
        #expect(await UISnapshotManager.shared.getSnapshot(id: snapshotId) != nil)
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
    }

    @Test
    func `Type tool does not count an indeterminate focus click as typed characters`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
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
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
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
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
    }

    @Test
    func `Press tool uses targeted delivery when pid is supplied`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run {
            MockApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: 222,
                processStartIdentity: 22,
                bundleIdentifier: "com.example.target",
                name: "Target")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications)
        let tool = PressTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+l"],
            "pid": 222,
        ]))

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedHotkeyCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.keys == "cmd,l")
        #expect(calls.first?.targetProcessIdentifier == 222)
        #expect(calls.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 222,
            processStartIdentity: 22))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected metadata")
            return
        }
        #expect(meta["delivery_mode"] == .string("background"))
        #expect(meta["target_pid"] == .int(222))
    }

    @Test
    func `Press sequence reports process reuse after partial delivery as retry unsafe`() async throws {
        let original = ApplicationProcessIdentity(processIdentifier: 223, processStartIdentity: 22)
        let replacement = ApplicationProcessIdentity(processIdentifier: 223, processStartIdentity: 23)
        var current = original
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.currentProcessIdentity = { _ in current }
            automation.afterPinnedHotkey = { current = replacement }
            return automation
        }
        let applications = await MainActor.run {
            MockApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: original.processIdentifier,
                processStartIdentity: original.processStartIdentity,
                bundleIdentifier: "com.example.target",
                name: "Target")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+l", "cmd+k"],
            "pid": 223,
            "delay": 0,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.count } == 1)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected indeterminate metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["emitted_units"] == .int(1))
    }

    @Test
    func `Press sequence includes prior chords in indeterminate emitted count`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 224, processStartIdentity: 24)
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedHotkeyError = { keys in
                guard keys == "cmd,k" else { return nil }
                return InputDeliveryIndeterminateError(
                    operation: .hotkey,
                    emittedUnitCount: 1,
                    causeDescription: "completion identity drift")
            }
            return automation
        }
        let applications = await MainActor.run {
            MockApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity,
                bundleIdentifier: "com.example.target",
                name: "Target")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+l", "cmd+k"],
            "pid": Int(identity.processIdentifier),
            "delay": 0,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.count } == 2)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected indeterminate press metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["emitted_units"] == .int(2))
    }

    @Test
    func `Press sequence preserves unknown count for indeterminate current chord`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 225, processStartIdentity: 25)
        let automation = await MainActor.run {
            let automation = MockAutomationService(accessibilityGranted: true)
            automation.pinnedHotkeyError = { keys in
                guard keys == "cmd,k" else { return nil }
                return InputDeliveryIndeterminateError(
                    operation: .hotkey,
                    causeDescription: "unknown current chord completion")
            }
            return automation
        }
        let applications = await MainActor.run {
            MockApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: identity.processIdentifier,
                processStartIdentity: identity.processStartIdentity,
                bundleIdentifier: "com.example.target",
                name: "Target")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+l", "cmd+k"],
            "pid": Int(identity.processIdentifier),
            "delay": 0,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.count } == 2)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected indeterminate press metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["emitted_units"] == .null)
    }

    @Test
    func `Type and press tools use targeted delivery when app process is known`() async throws {
        let app = ServiceApplicationInfo(
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
            applications: applications)

        let typeResponse = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "hello",
        ]))
        let hotkeyResponse = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "keys": ["cmd+l"],
        ]))

        #expect(typeResponse.isError == false)
        #expect(hotkeyResponse.isError == false)
        let typeCalls = await MainActor.run { automation.targetedTypeActionsCalls }
        #expect(typeCalls.count == 1)
        #expect(typeCalls.first?.targetProcessIdentifier == 333)
        #expect(typeCalls.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 333,
            processStartIdentity: 33))
        let hotkeyCalls = await MainActor.run { automation.targetedHotkeyCalls }
        #expect(hotkeyCalls.count == 1)
        #expect(hotkeyCalls.first?.targetProcessIdentifier == 333)
        #expect(hotkeyCalls.first?.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 333,
            processStartIdentity: 33))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
    }

    @Test
    func `Paste tool uses targeted delivery when app process is known`() async throws {
        let app = ServiceApplicationInfo(
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
            clipboard: clipboard)
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
        #expect(calls.first?.expectedProcessIdentity == ApplicationProcessIdentity(
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
        let app = ServiceApplicationInfo(
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
            clipboard: clipboard)

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
        let app = ServiceApplicationInfo(
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
            clipboard: clipboard)
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
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
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
