import CoreGraphics
import Foundation
import MCP
import PeekabooAgentRuntimeTestSupport
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct PasteToolExactWindowTests {
    init() throws {
        try AuthorityTestSupport.prepare()
    }

    private let firstWindow = ServiceWindowInfo(
        windowID: 41,
        title: "First Document",
        bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
        index: 0,
        mutationIdentity: AutomationTestFixtures.windowIdentity(
            windowID: 41,
            processIdentity: AutomationTestFixtures.processIdentity(
                processIdentifier: 333,
                processStartIdentity: 33),
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400)))
    private let secondWindow = ServiceWindowInfo(
        windowID: 42,
        title: "Second Document",
        bounds: CGRect(x: 600, y: 20, width: 500, height: 400),
        index: 1,
        mutationIdentity: AutomationTestFixtures.windowIdentity(
            windowID: 42,
            processIdentity: AutomationTestFixtures.processIdentity(
                processIdentifier: 333,
                processStartIdentity: 33),
            bounds: CGRect(x: 600, y: 20, width: 500, height: 400)))

    @Test
    @MainActor
    func `temporary clipboard grant reaches only the authorized exact snapshot receiver`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: true, temporaryClipboardPasteGranted: true)
        let snapshotID = try await self.publishPasteSnapshot(fixture: fixture)
        let response = try await fixture.context.execute(
            tool: fixture.tool,
            arguments: self.richSnapshotArguments(snapshotID))

        #expect(response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["delivery_mode"] == .string("background"))
        #expect(metadata["delivery_mechanism"] == .string("composite"))
        #expect(metadata["dispatched_unit_count"] == .int(8))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["clipboard_cleanup_status"] == .string("restored"))
        let receipt = try #require(metadata["target_receipt"]?.objectValue)
        #expect(receipt["pid"] == .int(333))
        #expect(receipt["process_start_identity_decimal"] == .string("33"))
        #expect(receipt["window_id"] == .int(42))
        let call = try #require(fixture.exactAutomation?.exactHotkeyCalls.first)
        #expect(call.targetProcessIdentifier == 333)
        #expect(call.targetWindowID == 42)
        #expect(call.expectedWindowBounds == self.secondWindow.bounds)
        #expect(fixture.exactAutomation?.backgroundPreparations == [.blankWindowChrome])
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
        #expect(fixture.automation.lastHotkeyKeys == nil)
        #expect(fixture.clipboard.setCallCount == 1)
        #expect(fixture.clipboard.restoreCallCount == 1)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `granted paste preserves truthful clipboard only failure through context`(newerCopy: Bool) async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: true, temporaryClipboardPasteGranted: true)
        let snapshotID = try await self.publishPasteSnapshot(fixture: fixture)
        let automation = try #require(fixture.exactAutomation)
        automation.beforeGuardedHotkey = {
            if newerCopy {
                fixture.clipboard.current = ClipboardReadResult(
                    utiIdentifier: UTType.plainText.identifier,
                    data: Data("newer".utf8),
                    textPreview: "newer")
            }
            throw DesktopActionFailure.preDispatchRefusal(reason: .targetUnavailable, message: "synthetic focus drift")
        }

        let response = try await fixture.context.execute(
            tool: fixture.tool,
            arguments: self.richSnapshotArguments(snapshotID))

        let metadata = try #require(response.meta?.objectValue)
        #expect(response.isError)
        #expect(metadata["state"] == .string("indeterminate"))
        #expect(metadata["delivery_mechanism"] == .string("clipboard_transaction"))
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["dispatched_unit_count"] == nil || metadata["dispatched_unit_count"] == .null)
        #expect(metadata["target_receipt"] == nil || metadata["target_receipt"] == .null)
        #expect(metadata["clipboard_cleanup_status"] == .string(newerCopy ? "preserved_newer_contents" : "restored"))
        #expect(fixture.clipboard.current?.data == Data((newerCopy ? "newer" : "before").utf8))
        #expect(automation.exactHotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(fixture.clipboard.restoreCallCount == (newerCopy ? 0 : 1))
    }

    @Test(arguments: ["no-grant", "missing", "dialog", "system-ui", "generation", "bounds", "competing"])
    @MainActor
    func `temporary grant refuses unproven targets before any clipboard access`(variant: String) async throws {
        let fixture = await self.makeFixture(
            exactKeyboardSupported: true,
            temporaryClipboardPasteGranted: variant != "no-grant")
        let snapshotID = try await self.publishPasteSnapshot(fixture: fixture, variant: variant)
        var arguments = self.richSnapshotArguments(variant == "missing" ? "missing-receipt" : snapshotID).rawDictionary
        if variant == "competing" {
            arguments["app"] = "Editor"
        }

        let response = try await fixture.context.execute(tool: fixture.tool, arguments: ToolArguments(raw: arguments))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(true))
        #expect(fixture.clipboard.getCallCount == 0)
        #expect(fixture.clipboard.setCallCount == 0)
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.exactAutomation?.guardedHotkeyClaims.isEmpty == true)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
        #expect(fixture.automation.lastHotkeyKeys == nil)
    }

    @Test(arguments: ["current", "file", "image", "large", "foreground", "bad-base64", "oversized", "delay"])
    @MainActor
    func `temporary grant schema and leaf reject broad or oversized payloads before clipboard reads`(
        variant: String) async throws
    {
        let fixture = await self.makeFixture(exactKeyboardSupported: true, temporaryClipboardPasteGranted: true)
        let snapshotID = try await self.publishPasteSnapshot(fixture: fixture)
        var arguments = self.richSnapshotArguments(snapshotID).rawDictionary
        switch variant {
        case "current":
            arguments.removeValue(forKey: "dataBase64")
            arguments.removeValue(forKey: "uti")
        case "file": arguments["filePath"] = "/not-read"
        case "image": arguments["imagePath"] = "/not-read"
        case "large": arguments["allowLarge"] = false
        case "foreground": arguments["foreground"] = true
        case "bad-base64": arguments["dataBase64"] = "not base64"
        case "oversized": arguments["alsoText"] = String(
                repeating: "x",
                count: ClipboardPayloadBuilder.defaultSizeLimit + 1)
        case "delay": arguments["restore_delay_ms"] = 10001
        default: Issue.record("Unknown variant")
        }

        let response = try await fixture.context.execute(tool: fixture.tool, arguments: ToolArguments(raw: arguments))

        #expect(response.isError)
        #expect(fixture.clipboard.getCallCount == 0)
        #expect(fixture.clipboard.setCallCount == 0)
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.exactAutomation?.guardedHotkeyClaims.isEmpty == true)
    }

    private func richSnapshotArguments(_ snapshotID: String) -> ToolArguments {
        ToolArguments(raw: [
            "snapshot": snapshotID,
            "dataBase64": Data("{\\rtf1 exact}".utf8).base64EncodedString(),
            "uti": UTType.rtf.identifier,
            "restore_delay_ms": 0,
        ])
    }

    @MainActor
    private func publishPasteSnapshot(
        fixture: PasteExactWindowFixture,
        variant: String = "valid") async throws -> String
    {
        let snapshot = try await MCPToolTestHelpers.createSnapshot(in: fixture.context)
        let bounds = variant == "bounds" ? self.firstWindow.bounds : self.secondWindow.bounds
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 333,
            ownerProcessStartIdentity: variant == "generation" ? 99 : 33,
            capturedBounds: bounds)
        let windowContext = WindowContext(
            applicationName: variant == "system-ui" ? "Dock" : "Editor",
            applicationBundleId: variant == "system-ui" ? "com.apple.dock" : "com.example.editor",
            applicationProcessId: 333,
            windowTitle: "Second Document",
            windowID: 42,
            windowBounds: bounds,
            windowMutationIdentity: identity)
        await snapshot.setTargetMetadata(from: windowContext)
        try await fixture.context.snapshots.storeDetectionResult(
            snapshotId: snapshot.id,
            result: ElementDetectionResult(
                snapshotId: snapshot.id,
                screenshotPath: "/tmp/synthetic-paste.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "synthetic",
                    windowContext: windowContext,
                    isDialog: variant == "dialog")))
        return await snapshot.id
    }

    @Test
    func `Exact title text paste keeps same-process sibling window identity`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: true)

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "window_title": "Second",
            "text": "only the second document",
        ]))

        #expect(!response.isError)
        let call = try #require(await MainActor.run { fixture.exactAutomation?.exactTypeCalls.first })
        #expect(call.targetProcessIdentifier == 333)
        #expect(call.targetWindowID == self.secondWindow.windowID)
        #expect(call.expectedWindowBounds == self.secondWindow.bounds)
        #expect(await MainActor.run { fixture.automation.targetedTypeActionsCalls.isEmpty })
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected exact-window paste metadata")
            return
        }
        #expect(meta["target_pid"] == .int(333))
        #expect(meta["target_window_id"] == .int(self.secondWindow.windowID))
    }

    @Test
    func `Exact window ID rich paste dispatches Cmd V only to selected sibling and stays retry unsafe`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: true)

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "window_id": self.secondWindow.windowID,
            "dataBase64": Data("{\\rtf1 exact}".utf8).base64EncodedString(),
            "uti": UTType.rtf.identifier,
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError)
        let call = try #require(await MainActor.run { fixture.exactAutomation?.exactHotkeyCalls.first })
        #expect(call.keys == "cmd,v")
        #expect(call.targetProcessIdentifier == 333)
        #expect(call.targetWindowID == self.secondWindow.windowID)
        #expect(call.expectedWindowBounds == self.secondWindow.bounds)
        #expect(await MainActor.run { fixture.automation.targetedHotkeyCalls.isEmpty })
        #expect(await MainActor.run { fixture.clipboard.setCallCount } == 1)
        #expect(await MainActor.run { fixture.clipboard.restoreCallCount } == 1)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected retry-safety metadata")
            return
        }
        let preparedOutcome = try #require(await MainActor.run { fixture.exactAutomation?.preparedOutcome })
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(preparedOutcome, in: response)
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor
    func `Exact clipboard paste retains rejected hotkey receipt without replay`(
        explicitPayload: Bool,
        indeterminate: Bool) async throws
    {
        let fixture = await self.makeFixture(exactKeyboardSupported: true)
        let automation = try #require(fixture.exactAutomation)
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: explicitPayload ? .composite : .windowTargetedEvents, mode: .background)
        let outcome: DesktopActionOutcome = indeterminate
            ? .indeterminate(
                route: .bridge,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: .init(explicitPayload ? 7 : 3))
            : .dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .init(explicitPayload ? 8 : 4))
        automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)
        automation.preparedOutcome = outcome
        var arguments: [String: Any] = [
            "window_id": self.secondWindow.windowID,
            "restore_delay_ms": 0,
        ]
        if explicitPayload {
            arguments["dataBase64"] = Data("{\\rtf1 exact}".utf8).base64EncodedString()
            arguments["uti"] = UTType.rtf.identifier
        }

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: arguments))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        let metadata = try #require(response.meta?.objectValue)
        let receipt = try #require(metadata["target_receipt"]?.objectValue)
        #expect(receipt["pid"] == .int(333))
        #expect(receipt["process_start_identity_decimal"] == .string("33"))
        #expect(receipt["window_id"] == .int(self.secondWindow.windowID))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["clipboard_cleanup_status"] == (explicitPayload ? .string("restored") : nil))
        #expect(automation.exactHotkeyCalls.count == 1)
        #expect(automation.guardedHotkeyClaims.map(\.changeCount) == (explicitPayload ? [1] : []))
        #expect(automation.exactHotkeyCalls.first?.targetWindowID == self.secondWindow.windowID)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.lastHotkeyKeys == nil)
        #expect(fixture.clipboard.setCallCount == (explicitPayload ? 1 : 0))
        #expect(fixture.clipboard.restoreCallCount == (explicitPayload ? 1 : 0))
        #expect(try fixture.clipboard.get(prefer: nil)?.data == Data("before".utf8))
    }

    @Test
    func `Exact rich paste fails before clipboard mutation when atomic delivery is unavailable`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: false)

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "window_title": "Second",
            "dataBase64": Data("{\\rtf1 exact}".utf8).base64EncodedString(),
            "uti": UTType.rtf.identifier,
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("requires clipboard-guarded exact-window hotkey delivery"))
        #expect(await MainActor.run { fixture.clipboard.saveCallCount } == 0)
        #expect(await MainActor.run { fixture.clipboard.setCallCount } == 0)
        #expect(await MainActor.run { fixture.automation.targetedHotkeyCalls.isEmpty })
        #expect(await MainActor.run { fixture.automation.lastHotkeyKeys } == nil)
    }

    @Test(arguments: 0..<8)
    @MainActor
    func `temporary exact paste preflights prepared guard and claim support before write`(flags: Int) async throws {
        let hostSupportsGuard = flags & 1 != 0
        let hostSupportsPreparation = flags & 2 != 0
        let transactionRetainsClaim = flags & 4 != 0
        let fixture = await self.makeFixture(exactKeyboardSupported: true)
        let automation = try #require(fixture.exactAutomation)
        automation.supportsClipboardGuardedExactWindowHotkeys = hostSupportsGuard
        automation.supportsPreparedClipboardGuardedExactWindowHotkeys = hostSupportsPreparation
        automation.supportsExactWindowTargetedKeyboard = !hostSupportsGuard
        fixture.clipboard.retainsTemporaryWriteClaims = transactionRetainsClaim
        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "window_id": self.secondWindow.windowID,
            "dataBase64": Data("{\\rtf1 exact}".utf8).base64EncodedString(),
            "uti": UTType.rtf.identifier,
            "restore_delay_ms": 0,
        ]))
        let hostSupportsPaste = hostSupportsGuard && hostSupportsPreparation
        let dispatched = hostSupportsPaste && transactionRetainsClaim
        #expect(response.isError)
        #expect(fixture.clipboard.getCallCount == (hostSupportsPaste ? 1 : 0))
        #expect(fixture.clipboard.setCallCount == (dispatched ? 1 : 0))
        #expect(fixture.clipboard.restoreCallCount == (dispatched ? 1 : 0))
        #expect(fixture.clipboard.current?.data == Data("before".utf8))
        #expect(automation.guardedHotkeyClaims.map(\.changeCount) == (dispatched ? [1] : []))
        #expect(automation.backgroundPreparations == (dispatched ? [.blankWindowChrome] : []))
        #expect(automation.exactHotkeyCalls.count == (dispatched ? 1 : 0))
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(automation.lastHotkeyKeys == nil)
    }

    @Test
    @MainActor
    func `guarded paste retains its declaration claim and preserves a newer copy after refusal`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: true)
        let automation = try #require(fixture.exactAutomation)
        let newer = ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data("newer".utf8),
            textPreview: "newer")
        automation.beforeGuardedHotkey = {
            fixture.clipboard.current = newer
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Synthetic clipboard claim was superseded")
        }
        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "window_id": self.secondWindow.windowID,
            "dataBase64": Data("{\\rtf1 exact}".utf8).base64EncodedString(),
            "uti": UTType.rtf.identifier,
            "restore_delay_ms": 0,
        ]))
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["clipboard_cleanup_status"] == .string("preserved_newer_contents"))
        #expect(automation.guardedHotkeyClaims.map(\.changeCount) == [1])
        #expect(automation.exactHotkeyCalls.isEmpty)
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(fixture.clipboard.current?.data == newer.data)
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.clipboard.clearCallCount == 0)
    }

    @Test
    @MainActor
    func `cancellation after a claimed temporary write restores once without hotkey delivery`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: true)
        let automation = try #require(fixture.exactAutomation)
        fixture.clipboard.afterSet = { withUnsafeCurrentTask { $0?.cancel() } }
        let command = Task { @MainActor in
            try await fixture.tool.execute(arguments: ToolArguments(raw: [
                "window_id": self.secondWindow.windowID,
                "dataBase64": Data("{\\rtf1 exact}".utf8).base64EncodedString(),
                "uti": UTType.rtf.identifier,
                "restore_delay_ms": 0,
            ]))
        }
        let response = try await command.value
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["clipboard_cleanup_status"] == .string("restored"))
        #expect(automation.guardedHotkeyClaims.isEmpty)
        #expect(automation.exactHotkeyCalls.isEmpty)
        #expect(fixture.clipboard.setCallCount == 1)
        #expect(fixture.clipboard.restoreCallCount == 1)
        #expect(fixture.clipboard.clearCallCount == 0)
        #expect(fixture.clipboard.current?.data == Data("before".utf8))
    }

    @Test(arguments: [false, true])
    @MainActor
    func `foreground temporary and current clipboard paths remain claimless`(foreground: Bool) async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: true)
        let automation = try #require(fixture.exactAutomation)
        automation.supportsClipboardGuardedExactWindowHotkeys = false
        fixture.clipboard.retainsTemporaryWriteClaims = false
        var arguments: [String: Any] = ["restore_delay_ms": 0]
        if foreground {
            arguments["foreground"] = true
            arguments["dataBase64"] = Data("{\\rtf1 exact}".utf8).base64EncodedString()
            arguments["uti"] = UTType.rtf.identifier
        } else {
            arguments["window_id"] = self.secondWindow.windowID
        }
        _ = try await fixture.tool.execute(arguments: ToolArguments(raw: arguments))
        #expect(automation.guardedHotkeyClaims.isEmpty)
        #expect(automation.uiAutomationOutcomeScript.callCount(for: .hotkey) == 1)
        #expect(fixture.clipboard.setCallCount == (foreground ? 1 : 0))
        #expect(fixture.clipboard.restoreCallCount == (foreground ? 1 : 0))
        #expect(fixture.clipboard.current?.data == Data("before".utf8))
    }

    @Test
    func `Exact current clipboard paste fails closed instead of collapsing to process delivery`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: false)

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "window_title": "Second",
            "restore_delay_ms": 0,
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("requires atomic exact-window keyboard delivery"))
        #expect(await MainActor.run { fixture.clipboard.setCallCount } == 0)
        #expect(await MainActor.run { fixture.automation.targetedHotkeyCalls.isEmpty })
        #expect(await MainActor.run { fixture.automation.lastHotkeyKeys } == nil)
    }

    @Test
    @MainActor
    func `Exact window paste refuses an incomplete owner before dispatch`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: nil,
            name: "Incomplete Editor",
            isHiddenKnown: false,
            activationPolicy: nil,
            metadataWarnings: ["metadata timed out"])
        let fixture = await self.makeFixture(
            exactKeyboardSupported: true,
            application: application)

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "window_id": self.secondWindow.windowID,
            "text": "must not dispatch",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("cannot receive background input"))
        #expect(await MainActor.run { fixture.exactAutomation?.exactTypeCalls.isEmpty } == true)
        #expect(await MainActor.run { fixture.automation.targetedTypeActionsCalls.isEmpty })
        self.expectClipboardUntouched(fixture.clipboard)
    }

    @Test
    @MainActor
    func `Process text prefix failure is indeterminate retry unsafe and leaves clipboard untouched`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = PartialProcessPasteAutomationService(
            accessibilityGranted: true,
            deliveredPrefix: "partial")
        let applications = MockApplicationService(applications: [application])
        let clipboard = ExactPasteClipboardService(current: ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data("before".utf8),
            textPreview: "before"))
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "partial delivery",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("Paste outcome is indeterminate"))
        #expect(self.responseText(response).contains("do not retry"))
        #expect(await MainActor.run { automation.deliveredText } == "partial")
        #expect(automation.targetedTypeActionsCalls.count == 1)
        #expect(automation.targetedTypeActionsCalls.first?.expectedProcessIdentity ==
            AutomationTestFixtures.processIdentity(processIdentifier: 333, processStartIdentity: 33))
        #expect(automation.lastTypeActions == nil)
        self.expectIndeterminateTextMetadata(
            response,
            requestedCharacters: "partial delivery".count,
            emittedCharacters: "partial".count,
            targetWindowID: nil)
        self.expectClipboardUntouched(clipboard)
    }

    @Test
    @MainActor
    func `Known pre-dispatch text failure remains an ordinary retryable failure`() async throws {
        let application = AutomationTestFixtures.application(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let automation = PredispatchProcessPasteAutomationService(accessibilityGranted: true)
        let applications = MockApplicationService(applications: [application])
        let clipboard = ExactPasteClipboardService(current: ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data("before".utf8),
            textPreview: "before"))
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            clipboard: clipboard)

        let response = try await PasteTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "not dispatched",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("Paste failed"))
        #expect(!self.responseText(response).contains("indeterminate"))
        #expect(response.meta == nil)
        #expect(automation.targetedTypeActionsCalls.count == 1)
        #expect(automation.targetedTypeActionsCalls.first?.expectedProcessIdentity ==
            AutomationTestFixtures.processIdentity(processIdentifier: 333, processStartIdentity: 33))
        #expect(automation.lastTypeActions == nil)
        self.expectClipboardUntouched(clipboard)
    }

    @Test
    func `PID conversion rejects oversized values without truncation and accepts the exact boundary`() throws {
        #expect(try PasteTool.checkedProcessIdentifier(Int(pid_t.max)) == pid_t.max)
        #expect(throws: MCPInteractionTargetError.self) {
            try PasteTool.checkedProcessIdentifier(Int.max)
        }
        #expect(throws: MCPInteractionTargetError.self) {
            try PasteTool.checkedProcessIdentifier(Int(pid_t.max) + 1)
        }
        #expect(throws: MCPInteractionTargetError.self) {
            try PasteTool.checkedProcessIdentifier(-1)
        }
    }

    @Test
    @MainActor
    func `Oversized PID fails before any background text dispatch`() async throws {
        let fixture = await self.makeFixture(exactKeyboardSupported: false)

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "pid": Int.max,
            "text": "must not dispatch",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("pid must be a positive 32-bit integer"))
        #expect(fixture.automation.targetedTypeActionsCalls.isEmpty)
        #expect(fixture.automation.lastTypeActions == nil)
        self.expectClipboardUntouched(fixture.clipboard)
    }

    @Test
    @MainActor
    func `Exact text cancellation after a prefix is indeterminate retry unsafe and keeps sibling receipt`() async
        throws
    {
        let fixture = await self.makeFixture(
            exactKeyboardSupported: true,
            exactTypeErrorAfterPrefix: "only the")

        let response = try await fixture.tool.execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "window_title": "Second",
            "text": "only the second document",
        ]))

        #expect(response.isError)
        #expect(self.responseText(response).contains("Paste outcome is indeterminate"))
        #expect(await MainActor.run { fixture.exactAutomation?.deliveredText } == "only the")
        self.expectIndeterminateTextMetadata(
            response,
            requestedCharacters: "only the second document".count,
            emittedCharacters: "only the".count,
            targetWindowID: self.secondWindow.windowID)
        self.expectClipboardUntouched(fixture.clipboard)
    }

    @Test
    func `Paste schema advertises atomic background window selectors`() async {
        let fixture = await self.makeFixture(exactKeyboardSupported: false)
        let schema = fixture.tool.inputSchema
        guard case let .object(root) = schema,
              case let .object(properties)? = root["properties"],
              case let .object(windowID)? = properties["window_id"],
              case let .string(windowIDDescription)? = windowID["description"],
              case let .object(windowTitle)? = properties["window_title"],
              case let .string(windowTitleDescription)? = windowTitle["description"],
              case let .object(text)? = properties["text"],
              case let .string(textDescription)? = text["description"]
        else {
            Issue.record("Expected paste window schemas")
            return
        }

        #expect(windowIDDescription.contains("atomic background"))
        #expect(windowTitleDescription.contains("exact-window background"))
        #expect(!windowIDDescription.contains("requires foreground"))
        #expect(!windowTitleDescription.contains("requires foreground"))
        #expect(textDescription.contains("clipboard untouched"))
        #expect(textDescription.contains("retry-unsafe"))
    }

    @MainActor
    private func makeFixture(
        exactKeyboardSupported: Bool,
        exactTypeErrorAfterPrefix: String? = nil,
        application: ServiceApplicationInfo? = nil,
        temporaryClipboardPasteGranted: Bool = false) async -> PasteExactWindowFixture
    {
        let application = application ?? ServiceApplicationInfo(
            processIdentifier: 333,
            processStartIdentity: 33,
            bundleIdentifier: "com.example.editor",
            name: "Editor")
        let applications = MockApplicationService(applications: [application])
        let windows = PasteSiblingWindowService(windows: [self.firstWindow, self.secondWindow])
        let clipboard = ExactPasteClipboardService(current: ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data("before".utf8),
            textPreview: "before"))
        let automation: MockAutomationService
        let exactAutomation: ExactPasteAutomationService?
        if exactKeyboardSupported {
            let exact = ExactPasteAutomationService(accessibilityGranted: true)
            exact.typeErrorAfterPrefix = exactTypeErrorAfterPrefix
            automation = exact
            exactAutomation = exact
        } else {
            automation = MockAutomationService(accessibilityGranted: true)
            exactAutomation = nil
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            windows: windows,
            clipboard: clipboard,
            snapshots: InMemorySnapshotManager(),
            temporaryClipboardPasteGranted: temporaryClipboardPasteGranted)
        let tool = PasteTool(context: context)
        return PasteExactWindowFixture(
            context: context,
            tool: tool,
            automation: automation,
            exactAutomation: exactAutomation,
            clipboard: clipboard)
    }

    private func responseText(_ response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else { return "" }
        return text
    }

    private func expectIndeterminateTextMetadata(
        _ response: ToolResponse,
        requestedCharacters: Int,
        emittedCharacters: Int?,
        targetWindowID: Int?)
    {
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected direct text outcome metadata")
            return
        }
        #expect(meta["paste_outcome"] == .string("indeterminate"))
        #expect(meta["paste_method"] == .string("background_text"))
        #expect(meta["delivery_mode"] == .string("background"))
        #expect(meta["may_have_pasted"] == .bool(true))
        #expect(meta["partial_text_possible"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["clipboard_mutated"] == .bool(false))
        #expect(meta["clipboard_restore_attempted"] == .bool(false))
        #expect(meta["requested_characters"] == .int(requestedCharacters))
        #expect(meta["characters_typed"] == emittedCharacters.map(Value.int) ?? .null)
        #expect(meta["target_pid"] == .int(333))
        #expect(meta["target_window_id"] == targetWindowID.map(Value.int) ?? .null)
        #expect(meta["requires_fresh_observation"] == .bool(true))
    }

    @MainActor
    private func expectClipboardUntouched(_ clipboard: ExactPasteClipboardService) {
        #expect(clipboard.saveCallCount == 0)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        let clipboardData = try? clipboard.get(prefer: nil)?.data
        #expect(clipboardData == Data("before".utf8))
    }
}

private struct PasteExactWindowFixture {
    let context: MCPToolContext
    let tool: PasteTool
    let automation: MockAutomationService
    let exactAutomation: ExactPasteAutomationService?
    let clipboard: ExactPasteClipboardService
}

@MainActor
private final class ExactPasteAutomationService: MockAutomationService,
    ExactWindowTargetedKeyboardServiceProtocol,
    PreparedClipboardGuardedExactWindowHotkeyServiceProtocol,
    ScriptedUIAutomationActionOutcomeProviding,
    TargetedFocusedElementServiceProtocol
{
    struct TypeCall {
        let targetProcessIdentifier: pid_t
        let targetWindowID: Int
        let expectedWindowBounds: CGRect
    }

    struct HotkeyCall {
        let keys: String
        let targetProcessIdentifier: pid_t
        let targetWindowID: Int
        let expectedWindowBounds: CGRect
    }

    var supportsExactWindowTargetedKeyboard = true
    var supportsClipboardGuardedExactWindowHotkeys = true
    var supportsPreparedClipboardGuardedExactWindowHotkeys = true
    var backgroundPreparations: [BackgroundWindowKeyboardPreparationMode] = []
    var preparedOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .composite, mode: .background), evidence: .deliveryAccepted, unitCount: .init(8))
    let exactWindowTargetedKeyboardUnavailableReason: String? = nil
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(defaultResponse: .outcome(
        .confirmedChange(delivery: .init(
            mechanism: .windowTargetedEvents,
            mode: .background))))
    private(set) var exactTypeCalls: [TypeCall] = []
    private(set) var exactHotkeyCalls: [HotkeyCall] = []
    private(set) var guardedHotkeyClaims: [GeneralPasteboardWriteClaim] = []
    var beforeGuardedHotkey: (() throws -> Void)?
    var typeErrorAfterPrefix: String?
    private(set) var deliveredText: String?

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> TypeResult
    {
        self.exactTypeCalls.append(TypeCall(
            targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
            targetWindowID: expectedWindowIdentity.windowID,
            expectedWindowBounds: expectedWindowBounds))
        if let typeErrorAfterPrefix {
            self.deliveredText = typeErrorAfterPrefix
            throw InputDeliveryIndeterminateError(
                operation: .type,
                emittedUnitCount: typeErrorAfterPrefix.count,
                causeDescription: "caller cancelled after prefix delivery")
        }
        let characterCount = actions.reduce(into: 0) { count, action in
            if case let .text(text) = action {
                count += text.count
            }
        }
        return TypeResult(totalCharacters: characterCount, keyPresses: 0)
    }

    func hotkey(
        keys: String,
        holdDuration _: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        self.exactHotkeyCalls.append(HotkeyCall(
            keys: keys,
            targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
            targetWindowID: expectedWindowIdentity.windowID,
            expectedWindowBounds: expectedWindowBounds))
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        try await self.typeActions(
            actions,
            cadence: cadence,
            snapshotId: snapshotId,
            expectedWindowIdentity: target.windowIdentity,
            expectedWindowBounds: target.windowBounds)
    }

    func hotkey(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws
    {
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: target.windowIdentity,
            expectedWindowBounds: target.windowBounds)
    }

    func getFocusedElement(targetProcessIdentifier: pid_t) async -> UIFocusInfo? {
        UIFocusInfo(
            role: "AXTextArea",
            title: nil,
            value: nil,
            frame: CGRect(x: 620, y: 50, width: 200, height: 100),
            applicationName: "Editor",
            bundleIdentifier: "com.example.editor",
            processId: Int(targetProcessIdentifier),
            windowID: 42,
            identifier: "editor")
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: UIAutomationTarget.ExactWindow,
        clipboardClaim: GeneralPasteboardWriteClaim) async throws -> UIAutomationActionResult<Void>
    {
        self.guardedHotkeyClaims.append(clipboardClaim)
        try self.beforeGuardedHotkey?()
        guard let focused = target.focusedElement else {
            throw PeekabooError.invalidInput("Missing retained focus")
        }
        let keyboardTarget = ExactWindowKeyboardTarget(
            windowIdentity: target.identity,
            windowBounds: target.bounds,
            focusedElement: focused)
        let result = try self.scriptedExactHotkeyResult(target: keyboardTarget)
        try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            target: keyboardTarget)
        return result
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: UIAutomationTarget.ExactWindow,
        clipboardClaim: GeneralPasteboardWriteClaim,
        preparation: BackgroundWindowKeyboardPreparationMode) async throws -> UIAutomationActionResult<Void>
    {
        self.backgroundPreparations.append(preparation)
        let result = try await self.hotkeyWithOutcome(
            keys: keys, holdDuration: holdDuration, target: target, clipboardClaim: clipboardClaim)
        return UIAutomationActionResult(
            payload: (),
            outcome: self.preparedOutcome,
            targetIdentity: result.targetIdentity)
    }
}

@MainActor
private final class PartialProcessPasteAutomationService: MockAutomationService {
    private let deliveredPrefix: String
    private(set) var deliveredText: String?

    init(accessibilityGranted: Bool, deliveredPrefix: String) {
        self.deliveredPrefix = deliveredPrefix
        super.init(accessibilityGranted: accessibilityGranted)
        self.pinnedTypeError = { [weak self] _ in
            guard let self else {
                return PeekabooError.invalidInput("partial paste fixture was released")
            }
            self.deliveredText = self.deliveredPrefix
            return InputDeliveryIndeterminateError(
                operation: .type,
                emittedUnitCount: self.deliveredPrefix.count,
                causeDescription: "simulated failure after a text prefix was delivered")
        }
    }
}

@MainActor
private final class PredispatchProcessPasteAutomationService: MockAutomationService {
    init(accessibilityGranted: Bool) {
        super.init(accessibilityGranted: accessibilityGranted)
        self.pinnedTypeError = { _ in
            PeekabooError.invalidInput("simulated pre-dispatch validation failure")
        }
    }
}

private actor PasteSiblingWindowService: WindowManagementServiceProtocol, WindowMutationInventoryProviding {
    private let windows: [ServiceWindowInfo]

    init(windows: [ServiceWindowInfo]) {
        self.windows = windows
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        switch target {
        case let .windowId(windowID):
            self.windows.filter { $0.windowID == windowID }
        case let .title(title), let .applicationAndTitle(_, title):
            self.windows.filter { $0.title.localizedCaseInsensitiveContains(title) }
        case let .index(_, index):
            self.windows.filter { $0.index == index }
        case .application, .frontmost:
            self.windows
        }
    }

    func windowMutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        try await .complete(self.listWindows(target: target))
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.windows.first
    }
}

@MainActor
private final class ExactPasteClipboardService: ScriptedClipboardService {}
