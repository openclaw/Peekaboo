import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PasteToolTransactionGateTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `MCP paste re-resolves its process after shared-lock contention`() async throws {
        let heldFD = try self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner,
            executionPolicy: .unrestricted)

        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "app": "Editor",
                "dataBase64": "cGF5bG9hZA==",
                "uti": "public.data",
                "restore_delay_ms": 0,
            ]))
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        await MainActor.run {
            applications.replaceApplicationsForTesting([
                Self.editorApplication(processIdentifier: 444, processStartIdentity: 44),
            ])
        }

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        let response = try await command.value
        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.map(\.keys) } == ["cmd,v"])
        #expect(await MainActor.run { automation.targetedHotkeyCalls.first?.targetProcessIdentifier } == 444)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.first?.expectedProcessIdentity } ==
            AutomationTestFixtures.processIdentity(processIdentifier: 444, processStartIdentity: 44))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected paste metadata")
            return
        }
        #expect(meta["target_pid"] == .int(444))
        #expect(meta["paste_outcome"] == .string("unverified"))
        #expect(meta["may_have_pasted"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
    }

    @Test
    func `MCP capability refusal never reads or mutates the clipboard`() async throws {
        let app = Self.editorApplication()
        let automation = await MainActor.run {
            let service = MockAutomationService(accessibilityGranted: true)
            service.supportsTargetedHotkeys = false
            return service
        }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { clipboard.getCallCount } == 0)
        #expect(await MainActor.run { clipboard.saveCallCount } == 0)
        #expect(await MainActor.run { clipboard.setCallCount } == 0)
        #expect(await MainActor.run { clipboard.clearCallCount } == 0)
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `MCP background paste refuses prohibited and incomplete inventory rows before dispatch`() async throws {
        let ineligibleApplications = [
            AutomationTestFixtures.application(
                processIdentifier: 333,
                processStartIdentity: 33,
                bundleIdentifier: "com.example.helper",
                name: "Prohibited Helper",
                isHiddenKnown: true,
                activationPolicy: .prohibited),
            ServiceApplicationInfo(
                processIdentifier: 444,
                processStartIdentity: 44,
                bundleIdentifier: nil,
                name: "Incomplete Helper",
                isHiddenKnown: false,
                activationPolicy: nil,
                metadataWarnings: ["metadata timed out"]),
        ]

        for application in ineligibleApplications {
            let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
            let applications = await MainActor.run { MockApplicationService(applications: [application]) }
            let clipboard = await MainActor.run { TransactionGateClipboardService() }
            let context = await MCPToolTestHelpers.makeContext(
                automation: automation,
                applications: applications,
                clipboard: clipboard,
                snapshotOwner: Self.uiSnapshots.owner)

            let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "app": application.name,
                "text": "must not dispatch",
            ]))

            #expect(response.isError)
            #expect(self.responseText(response).contains("cannot receive background input"))
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
                .refused(reason: .targetUnavailable),
                in: response)
            #expect(await MainActor.run { automation.targetedTypeActionsCalls.isEmpty })
            #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
            #expect(await MainActor.run { clipboard.getCallCount } == 0)
            #expect(await MainActor.run { clipboard.setCallCount } == 0)
            #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
        }
    }

    @Test
    func `MCP clipboard read failure is not treated as empty`() async throws {
        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run {
            let service = TransactionGateClipboardService()
            service.getError = ClipboardServiceError.writeFailed("simulated read failure")
            return service
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("simulated read failure"))
        #expect(await MainActor.run { clipboard.getCallCount } == 1)
        #expect(await MainActor.run { clipboard.saveCallCount } == 0)
        #expect(await MainActor.run { clipboard.setCallCount } == 0)
        #expect(await MainActor.run { clipboard.clearCallCount } == 0)
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `MCP current clipboard read failure aborts before Cmd V`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let clipboard = await MainActor.run {
            let service = TransactionGateClipboardService()
            service.getError = ClipboardServiceError.writeFailed("simulated current read failure")
            return service
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("simulated current read failure"))
        #expect(await MainActor.run { clipboard.getCallCount } == 1)
        #expect(await MainActor.run { clipboard.setCallCount } == 0)
        #expect(await MainActor.run { clipboard.clearCallCount } == 0)
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `MCP cancellation after snapshot but before write never restores or clears`() async throws {
        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run {
            let service = TransactionGateClipboardService()
            service.afterSave = {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
            return service
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "app": "Editor",
                "dataBase64": "cGF5bG9hZA==",
                "uti": "public.data",
            ]))
        }

        let response = try await command.value

        #expect(response.isError)
        #expect(await MainActor.run { clipboard.saveCallCount } == 1)
        #expect(await MainActor.run { clipboard.setCallCount } == 0)
        #expect(await MainActor.run { clipboard.clearCallCount } == 0)
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `MCP cancellation during clipboard write restores before dispatch`() async throws {
        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run {
            let service = TransactionGateClipboardService()
            service.afterSet = {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            }
            return service
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "app": "Editor",
                "dataBase64": "cGF5bG9hZA==",
                "uti": "public.data",
            ]))
        }

        let response = try await command.value

        #expect(response.isError)
        #expect(await MainActor.run { clipboard.setCallCount } == 1)
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test(arguments: [false, true])
    func `MCP set failure restores prior clipboard before dispatch`(mutatesBeforeThrow: Bool) async throws {
        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run {
            let service = TransactionGateClipboardService()
            service.setError = ClipboardServiceError.writeFailed("simulated set failure")
            service.setMutatesBeforeThrow = mutatesBeforeThrow
            return service
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("simulated set failure"))
        #expect(await MainActor.run { clipboard.saveCallCount } == 1)
        #expect(await MainActor.run { clipboard.setCallCount } == 1)
        #expect(await MainActor.run { clipboard.clearCallCount } == 0)
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `MCP set and restoration failure reports integrity risk without dispatch`() async throws {
        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run {
            let service = TransactionGateClipboardService()
            service.setError = ClipboardServiceError.writeFailed("simulated partial set failure")
            service.setMutatesBeforeThrow = true
            service.restoreError = ClipboardServiceError.writeFailed("simulated restore failure")
            return service
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("Paste payload setup failed"))
        #expect(self.responseText(response).contains("restoring the prior clipboard also failed"))
        #expect(await MainActor.run { clipboard.setCallCount } == 1)
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
        #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Cancellation during restore delay waits for consumption before restoring`() async throws {
        let app = Self.editorApplication()
        let delivered = PasteDeliveryLatch()
        let automation = await MainActor.run {
            SignalingAutomationService(accessibilityGranted: true, delivered: delivered)
        }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "app": "Editor",
                "dataBase64": "cGF5bG9hZA==",
                "uti": "public.data",
                "restore_delay_ms": 250,
            ]))
        }

        await delivered.wait()
        let clock = ContinuousClock()
        let canceledAt = clock.now
        command.cancel()

        try await Task.sleep(for: .milliseconds(75))
        #expect(await MainActor.run { clipboard.current.utiIdentifier } == "public.data")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)

        let response = try await command.value
        #expect(response.isError)
        #expect(self.responseText(response).contains("may have pasted; do not retry"))
        #expect(self.responseText(response).contains("indeterminate"))
        #expect(await MainActor.run { automation.targetedHotkeyCalls.first?.expectedProcessIdentity } ==
            AutomationTestFixtures.processIdentity(processIdentifier: 333, processStartIdentity: 33))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(clock.now - canceledAt >= .milliseconds(150))
        #expect(clock.now - canceledAt < .seconds(1))
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
    }

    @Test
    func `Foreground focus occurs after the transaction lock and is revalidated`() async throws {
        let heldFD = try self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let windows = RecordingWindowService()
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "app": "Editor",
                "foreground": true,
                "dataBase64": "cGF5bG9hZA==",
                "uti": "public.data",
                "restore_delay_ms": 0,
            ]))
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(windows.focusCalls.isEmpty)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        windows.focusError = ExpectedFocusError.targetDisappeared

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        let response = try await command.value
        #expect(response.isError)
        let focusCalls = windows.focusCalls
        #expect(focusCalls.count == 1)
        if case .windowId(700)? = focusCalls.first {} else {
            Issue.record("Expected the queued foreground target to be resolved and revalidated exactly")
        }
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
    }

    @Test
    func `Foreground PID paste fails closed when process identity changes while queued`() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let heldFD = try self.holdPasteTransactionLock()
        var lockHeld = true
        defer {
            if lockHeld {
                flock(heldFD, LOCK_UN)
            }
            close(heldFD)
        }

        let processIdentifier = process.processIdentifier
        let app = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.pid-target",
            name: "PID Target")
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let windows = RecordingWindowService()
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            windows: windows,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "pid": Int(processIdentifier),
                "foreground": true,
                "dataBase64": "cGF5bG9hZA==",
                "uti": "public.data",
                "restore_delay_ms": 0,
            ]))
        }

        try await Task.sleep(for: .milliseconds(75))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        process.terminate()
        process.waitUntilExit()

        #expect(flock(heldFD, LOCK_UN) == 0)
        lockHeld = false

        let response = try await command.value
        #expect(response.isError)
        #expect(windows.focusCalls.isEmpty)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
    }

    @Test
    func `Throwing dispatch settles before MCP restore and unlock`() async throws {
        let app = Self.editorApplication()
        let delivered = PasteDeliveryLatch()
        let automation = await MainActor.run {
            SignalingAutomationService(
                accessibilityGranted: true,
                delivered: delivered,
                errorAfterDelivery: ExpectedPasteToolDispatchError.afterPosting)
        }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "app": "Editor",
                "dataBase64": "cGF5bG9hZA==",
                "uti": "public.data",
                "restore_delay_ms": 250,
            ]))
        }

        await delivered.wait()
        let clock = ContinuousClock()
        let dispatchedAt = clock.now
        try await Task.sleep(for: .milliseconds(75))
        #expect(await MainActor.run { clipboard.current.utiIdentifier } == "public.data")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)

        let contenderFD = try self.openPasteTransactionLock()
        defer { close(contenderFD) }
        #expect(flock(contenderFD, LOCK_EX | LOCK_NB) != 0)

        let response = try await command.value
        #expect(response.isError)
        #expect(self.responseText(response).contains("may have pasted; do not retry"))
        #expect(self.responseText(response).contains("indeterminate"))
        #expect(await MainActor.run { automation.targetedHotkeyCalls.first?.expectedProcessIdentity } ==
            AutomationTestFixtures.processIdentity(processIdentifier: 333, processStartIdentity: 33))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(clock.now - dispatchedAt >= .milliseconds(150))
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
        #expect(flock(contenderFD, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(contenderFD, LOCK_UN) == 0)
    }

    @Test
    func `Current clipboard background paste is explicitly unverified`() async throws {
        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("Background paste delivery could not be verified"))
        #expect(self.responseText(response).contains("may have pasted; do not retry"))
        #expect(await MainActor.run { automation.targetedHotkeyCalls.map(\.keys) } == ["cmd,v"])
        #expect(await MainActor.run { automation.targetedHotkeyCalls.first?.expectedProcessIdentity } ==
            AutomationTestFixtures.processIdentity(processIdentifier: 333, processStartIdentity: 33))
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected paste metadata")
            return
        }
        #expect(meta["paste_outcome"] == .string("unverified"))
        #expect(meta["retry_safe"] == .bool(false))
    }

    @Test
    func `Current clipboard foreground paste can report successful dispatch`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "foreground": true,
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == "cmd,v")
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected paste metadata")
            return
        }
        #expect(meta["paste_method"] == .string("current_clipboard"))
        #expect(meta["clipboard_mutated"] == .bool(false))
    }
}

extension PasteToolTransactionGateTests {
    @Test
    func `Foreground paste composes focus with a compatible legacy hotkey result`() async throws {
        let leafTargetIdentity = try RecordingWindowService.targetIdentity()
        let automation = await MainActor.run {
            OutcomePasteAutomationService(
                hotkeyResponse: .outcome(nil),
                targetIdentity: leafTargetIdentity)
        }
        let windows = RecordingWindowService()
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "foreground": true,
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
            "restore_delay_ms": 0,
        ]))

        #expect(!response.isError)
        let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
            .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: twoUnits),
            in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["target_receipt"]?.objectValue?["pid"] == .int(89))
        #expect(meta["target_receipt"]?.objectValue?["window_id"] == .int(700))
        #expect(windows.focusCalls.count == 1)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == "cmd,v")
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
    }

    @Test
    func `Foreground paste rejects a contradictory legacy hotkey target after focus`() async throws {
        let leafTargetIdentity = try DesktopTargetIdentity(processIdentity: AutomationTestFixtures.processIdentity(
            processIdentifier: 987,
            processStartIdentity: 9870))
        let automation = await MainActor.run {
            OutcomePasteAutomationService(
                hotkeyResponse: .outcome(nil),
                targetIdentity: leafTargetIdentity)
        }
        let windows = RecordingWindowService()
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "foreground": true,
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["target_receipt"] == nil)
        #expect(windows.focusCalls.count == 1)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == "cmd,v")
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
    }
}

extension PasteToolTransactionGateTests {
    @Test
    func `Foreground paste composes exact setup focus with result-aware hotkey`() async throws {
        let automation = await MainActor.run {
            OutcomePasteAutomationService(hotkeyResponse: .outcome(.confirmedChange(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                unitCount: .one)))
        }
        let windows = RecordingWindowService()
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "foreground": true,
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
            "restore_delay_ms": 0,
        ]))

        #expect(!response.isError)
        let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
            .confirmedChange(
                delivery: .init(mechanism: .composite, mode: .foreground),
                unitCount: twoUnits),
            in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["target_receipt"]?.objectValue?["pid"] == .int(89))
        #expect(meta["target_receipt"]?.objectValue?["window_id"] == .int(700))
        #expect(windows.focusCalls.count == 1)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == "cmd,v")
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
    }

    @Test
    func `Foreground paste preserves completed focus when result-aware hotkey refuses`() async throws {
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied,
            message: "Hotkey refused")
        let automation = await MainActor.run {
            OutcomePasteAutomationService(hotkeyResponse: .failure(refusal))
        }
        let windows = RecordingWindowService()
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "foreground": true,
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["target_receipt"]?.objectValue?["window_id"] == .int(700))
        #expect(windows.focusCalls.count == 1)
        #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
    }

    @Test
    func `Cancelled foreground current clipboard paste settles then reports indeterminate`() async throws {
        let delivered = PasteDeliveryLatch()
        let automation = await MainActor.run {
            SignalingAutomationService(accessibilityGranted: true, delivered: delivered)
        }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)
        let command = Task { @MainActor in
            try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
                "foreground": true,
                "restore_delay_ms": 250,
            ]))
        }

        await delivered.wait()
        command.cancel()
        let response = try await command.value

        #expect(response.isError)
        #expect(self.responseText(response).contains("indeterminate"))
        #expect(self.responseText(response).contains("may have pasted; do not retry"))
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 0)
    }

    @Test
    func `MCP mutation wrapper invalidates snapshots for unverified paste outcomes`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        _ = await Self.uiSnapshots.createSnapshot()
        let app = Self.editorApplication()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let applications = await MainActor.run { MockApplicationService(applications: [app]) }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        let arguments = ToolArguments(raw: [
            "app": "Editor",
            "restore_delay_ms": 0,
        ])

        let response = try await context.execute(
            tool: PasteTool(context: context),
            arguments: arguments)

        #expect(response.isError)
        #expect(await Self.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    func `Throwing foreground payload dispatch restores then reports indeterminate`() async throws {
        let delivered = PasteDeliveryLatch()
        let automation = await MainActor.run {
            SignalingAutomationService(
                accessibilityGranted: true,
                delivered: delivered,
                errorAfterDelivery: ExpectedPasteToolDispatchError.afterPosting)
        }
        let clipboard = await MainActor.run { TransactionGateClipboardService() }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            clipboard: clipboard,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "foreground": true,
            "dataBase64": "cGF5bG9hZA==",
            "uti": "public.data",
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("indeterminate"))
        #expect(self.responseText(response).contains("may have pasted; do not retry"))
        #expect(await MainActor.run { clipboard.current.textPreview } == "prior")
        #expect(await MainActor.run { clipboard.restoreCallCount } == 1)
    }

    private func responseText(_ response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else { return "" }
        return text
    }

    private static func editorApplication(
        processIdentifier: Int32 = 333,
        processStartIdentity: UInt64 = 33) -> ServiceApplicationInfo
    {
        AutomationTestFixtures.application(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
    }

    private func holdPasteTransactionLock() throws -> Int32 {
        let fd = try self.openPasteTransactionLock()
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else {
                let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                close(fd)
                throw error
            }
        }
        return fd
    }

    private func openPasteTransactionLock() throws -> Int32 {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = applicationSupport.appendingPathComponent("Peekaboo", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("clipboard-paste-transaction.lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }
}

private enum ExpectedFocusError: Error {
    case targetDisappeared
}

private enum ExpectedPasteToolDispatchError: Error {
    case afterPosting
}

@MainActor
private final class OutcomePasteAutomationService: MockAutomationService,
    ScriptedUIAutomationActionOutcomeProviding
{
    let uiAutomationOutcomeScript: UIAutomationOutcomeScript
    let uiAutomationOutcomeTargetIdentity: DesktopTargetIdentity?

    init(
        hotkeyResponse: UIAutomationOutcomeScript.Response,
        targetIdentity: DesktopTargetIdentity? = nil)
    {
        self.uiAutomationOutcomeScript = UIAutomationOutcomeScript(responses: [
            .hotkey: [hotkeyResponse],
        ])
        self.uiAutomationOutcomeTargetIdentity = targetIdentity
        super.init(accessibilityGranted: true)
    }
}

private final class RecordingWindowService: WindowManagementPinnedFocusActionResultProviding, @unchecked Sendable {
    private let lock = NSLock()
    private static let identity = WindowMutationIdentity(
        windowID: 700,
        ownerProcessIdentifier: 89,
        ownerProcessStartIdentity: 890,
        capturedBounds: CGRect(x: 20, y: 30, width: 640, height: 480))
    private var storedFocusCalls: [WindowTarget] = []
    private var storedFocusError: (any Error)?

    var focusCalls: [WindowTarget] {
        self.lock.withLock { self.storedFocusCalls }
    }

    var focusError: (any Error)? {
        get { self.lock.withLock { self.storedFocusError } }
        set { self.lock.withLock { self.storedFocusError = newValue } }
    }

    static func targetIdentity() throws -> DesktopTargetIdentity {
        try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: self.identity,
            bounds: self.identity.capturedBounds ?? .zero))
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}

    func focusWindow(target: WindowTarget) async throws {
        let focusError = self.lock.withLock {
            self.storedFocusCalls.append(target)
            return self.storedFocusError
        }
        if let focusError {
            throw focusError
        }
    }

    func focusWindowActionResult(target _: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.commandFailed("Unpinned focus must not be used")
    }

    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        try await self.focusWindow(target: target)
        guard expectedIdentity.hasSameStableReceipt(as: Self.identity),
              let bounds = Self.identity.capturedBounds
        else {
            throw PeekabooError.commandFailed("Unexpected exact focus target")
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: Self.identity,
                bounds: bounds)))
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        [ServiceWindowInfo(
            windowID: Self.identity.windowID,
            title: "Editor",
            bounds: Self.identity.capturedBounds ?? .zero,
            mutationIdentity: Self.identity)]
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private actor PasteDeliveryLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }
}

@MainActor
private final class SignalingAutomationService: MockAutomationService {
    private let delivered: PasteDeliveryLatch
    private let errorAfterDelivery: (any Error)?

    init(
        accessibilityGranted: Bool,
        delivered: PasteDeliveryLatch,
        errorAfterDelivery: (any Error)? = nil)
    {
        self.delivered = delivered
        self.errorAfterDelivery = errorAfterDelivery
        super.init(accessibilityGranted: accessibilityGranted)
        self.afterPinnedHotkey = {
            Task { await delivered.open() }
        }
        self.pinnedHotkeyError = { _ in errorAfterDelivery }
    }

    override func hotkey(keys: String, holdDuration: Int) async throws {
        try await super.hotkey(keys: keys, holdDuration: holdDuration)
        await self.delivered.open()
        if let errorAfterDelivery {
            throw errorAfterDelivery
        }
    }
}

@MainActor
private final class TransactionGateClipboardService: ClipboardServiceProtocol {
    private(set) var current = ClipboardReadResult(
        utiIdentifier: UTType.plainText.identifier,
        data: Data("prior".utf8),
        textPreview: "prior")
    private var slots: [String: ClipboardReadResult] = [:]
    var afterSave: (() -> Void)?
    var afterSet: (() -> Void)?
    var getError: (any Error)?
    var setError: (any Error)?
    var setMutatesBeforeThrow = false
    var restoreError: (any Error)?
    private(set) var getCallCount = 0
    private(set) var setCallCount = 0
    private(set) var clearCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var restoreCallCount = 0

    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        self.getCallCount += 1
        if let getError {
            throw getError
        }
        return self.current
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        self.setCallCount += 1
        guard let representation = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided")
        }
        let result = ClipboardReadResult(
            utiIdentifier: representation.utiIdentifier,
            data: representation.data,
            textPreview: request.alsoText)
        if let setError {
            if self.setMutatesBeforeThrow {
                self.current = result
            }
            throw setError
        }
        self.current = result
        self.afterSet?()
        return result
    }

    func clear() {
        self.clearCallCount += 1
        self.current = ClipboardReadResult(
            utiIdentifier: UTType.data.identifier,
            data: Data(),
            textPreview: nil)
    }

    func save(slot: String) {
        self.saveCallCount += 1
        self.slots[slot] = self.current
        self.afterSave?()
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        self.restoreCallCount += 1
        if let restoreError {
            throw restoreError
        }
        guard let saved = slots[slot] else {
            throw ClipboardServiceError.slotNotFound(slot)
        }
        self.current = saved
        return saved
    }
}
