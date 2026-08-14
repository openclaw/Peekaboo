import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@MainActor
@Suite(.serialized)
struct MCPDialogPreparedActionTests {
    @Test
    func `background-only dialog click prepares and executes one exact action with canonical outcome`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 89,
            processStartIdentity: 890,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit")
        let applications = MockApplicationService(applications: [application])
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            dialogs: dialogs,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "button": "OK",
                "app": "TextEdit",
            ]))

        #expect(!response.isError)
        #expect(dialogs.prepareCount == 1)
        #expect(dialogs.executeCount == 1)
        #expect(dialogs.lastPreparation?.target.processIdentifier == 89)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(dialogs.outcome, in: response)
    }

    @Test
    func `background-only targetless dialog click refuses before service planning`() async throws {
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "button": "OK",
            ]))

        #expect(response.isError)
        #expect(dialogs.prepareCount == 0)
        #expect(dialogs.executeCount == 0)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["refusal_reason"] == .string("invalid_request"))
    }

    @Test
    func `unrestricted foreground dialog mutation still requires a target`() async throws {
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(dialogs: dialogs)

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "button": "OK",
                "foreground": true,
            ]))

        #expect(response.isError)
        #expect(dialogs.prepareCount == 0)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("invalid_request"))
    }

    @Test
    func `foreground dialog prepares after focus so the receipt is fresh`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 89,
            processStartIdentity: 890,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit")
        let applications = MockApplicationService(applications: [application])
        let windows = EmptyRecordingWindowService()
        let dialogs = PreparedDialogService()
        dialogs.preparationFailure = .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Dialog is ambiguous")
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            windows: windows,
            dialogs: dialogs)

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "button": "OK",
                "app": "TextEdit",
                "foreground": true,
            ]))

        #expect(response.isError)
        #expect(dialogs.prepareCount == 1)
        #expect(dialogs.executeCount == 0)
        #expect(await windows.focusRequests.count == 1)
    }

    @Test
    func `targetless foreground input and file preserve legacy current-dialog behavior`() async throws {
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(dialogs: dialogs)

        let input = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "input",
                "text": "value",
                "foreground": true,
            ]))
        let file = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "file",
                "path": "/tmp",
                "foreground": true,
            ]))

        #expect(!input.isError)
        #expect(!file.isError)
        #expect(dialogs.prepareCount == 0)
        #expect(dialogs.inputCount == 1)
        #expect(dialogs.fileCount == 1)
    }

    @Test
    func `exact-window input leaves sheet focus to dialog service without selector downgrade`() async throws {
        let windows = EmptyRecordingWindowService()
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(
            windows: windows,
            dialogs: dialogs)

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "input",
                "text": "value",
                "pid": 89,
                "window_id": 700,
                "foreground": true,
            ]))

        #expect(!response.isError)
        #expect(dialogs.inputCount == 1)
        let request = try #require(dialogs.lastExactInputRequest)
        #expect(request.target.applicationIdentifier == nil)
        #expect(request.target.processIdentifier == 89)
        #expect(request.target.windowID == 700)
        #expect(request.text == "value")
        #expect(request.focus == DialogForegroundFocusPolicy())
        #expect(await windows.focusRequests.isEmpty)
    }

    @Test
    func `exact forced dismiss leaves focus and selector ownership to dialog service`() async throws {
        let windows = EmptyRecordingWindowService()
        let dialogs = PreparedDialogService()
        dialogs.foregroundOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let context = await MCPToolTestHelpers.makeContext(
            windows: windows,
            dialogs: dialogs)

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "dismiss",
                "force": true,
                "pid": 89,
                "window_id": 700,
                "foreground": true,
            ]))

        #expect(!response.isError)
        let request = try #require(dialogs.lastExactForcedDismissRequest)
        #expect(request.target.processIdentifier == 89)
        #expect(request.target.windowID == 700)
        #expect(request.focus == DialogForegroundFocusPolicy())
        #expect(await windows.focusRequests.isEmpty)
    }

    @Test
    func `foreground input and forced dismiss expose unverified outcome warnings`() async throws {
        let dialogs = PreparedDialogService()
        dialogs.foregroundOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let context = await MCPToolTestHelpers.makeContext(dialogs: dialogs)

        let input = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "input",
                "text": "value",
                "foreground": true,
            ]))
        let dismiss = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "dismiss",
                "force": true,
                "foreground": true,
            ]))

        for response in [input, dismiss] {
            #expect(!response.isError)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("dispatched_unverified"))
            #expect(meta["retry_safe"] == .bool(false))
            guard case let .text(text, _, _)? = response.content.first else {
                Issue.record("Expected dialog response text")
                continue
            }
            #expect(text.contains(AgentDisplayTokens.Status.warning))
            #expect(text.contains("effect is unverifiable"))
        }

        dialogs.omitForegroundOutcome = true
        let legacyInput = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "input",
                "text": "legacy",
                "foreground": true,
            ]))
        let legacyDismiss = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "dismiss",
                "force": true,
                "foreground": true,
            ]))
        for response in [legacyInput, legacyDismiss] {
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("dispatched_unverified"))
            guard case let .text(text, _, _)? = response.content.first else {
                Issue.record("Expected legacy dialog response text")
                continue
            }
            #expect(text.contains(AgentDisplayTokens.Status.warning))
        }
    }
}

@MainActor
private final class PreparedDialogService: DialogServiceProtocol {
    let outcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .accessibilityAction, mode: .background),
        unitCount: .one)
    var prepareCount = 0
    var executeCount = 0
    var inputCount = 0
    var fileCount = 0
    var lastPreparation: DialogActionPreparationRequest?
    var preparationFailure: DesktopActionFailure?
    var foregroundOutcome: DesktopActionOutcome?
    var omitForegroundOutcome = false
    var lastInputAppHint: String?
    var lastExactInputRequest: DialogInputExecutionRequest?
    var lastExactForcedDismissRequest: DialogForcedDismissExecutionRequest?

    func prepareDialogAction(_ request: DialogActionPreparationRequest) throws -> PreparedDialogActionReceipt {
        self.prepareCount += 1
        self.lastPreparation = request
        if let preparationFailure {
            throw preparationFailure
        }
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: request.target.processIdentifier ?? 89,
            ownerProcessStartIdentity: 890,
            capturedBounds: bounds)
        return try PreparedDialogActionReceipt(
            token: UUID(),
            kind: request.kind,
            target: UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds))
    }

    func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) -> DialogActionResult {
        self.executeCount += 1
        return DialogActionResult(
            success: true,
            action: receipt.kind == .clickButton ? .clickButton : .dismiss,
            details: ["button": "OK"],
            outcome: self.outcome)
    }

    func findActiveDialog(windowTitle _: String?, appName _: String?) async throws -> DialogInfo {
        throw DialogError.noActiveDialog
    }

    func clickButton(buttonText _: String, windowTitle _: String?, appName _: String?) async throws
        -> DialogActionResult
    {
        throw DialogError.noActiveDialog
    }

    func enterText(
        text _: String,
        fieldIdentifier _: String?,
        clearExisting _: Bool,
        windowTitle _: String?,
        appName: String?) async throws -> DialogActionResult
    {
        self.inputCount += 1
        self.lastInputAppHint = appName
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: ["field": "Text Field", "text_length": "5"],
            outcome: self.omitForegroundOutcome ? nil : (self.foregroundOutcome ?? self.outcome))
    }

    func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        self.inputCount += 1
        self.lastExactInputRequest = request
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: ["field": "Text Field", "text_length": "5"],
            outcome: self.omitForegroundOutcome ? nil : (self.foregroundOutcome ?? self.outcome))
    }

    func handleFileDialog(
        path _: String?,
        filename _: String?,
        actionButton _: String?,
        ensureExpanded _: Bool,
        appName _: String?) async throws -> DialogActionResult
    {
        self.fileCount += 1
        return DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: ["button_clicked": "Open"],
            outcome: self.outcome)
    }

    func dismissDialog(force: Bool, windowTitle _: String?, appName _: String?) async throws -> DialogActionResult {
        guard force else { throw DialogError.noActiveDialog }
        return DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"],
            outcome: self.omitForegroundOutcome ? nil : (self.foregroundOutcome ?? self.outcome))
    }

    func forceDismissDialog(_ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult {
        self.lastExactForcedDismissRequest = request
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: request.target.processIdentifier ?? 89,
            processStartIdentity: 890,
            windowID: request.target.windowID ?? 700)
        return DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"],
            outcome: self.omitForegroundOutcome ? nil : (self.foregroundOutcome ?? self.outcome),
            targetReceipt: targetReceipt)
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw DialogError.noActiveDialog
    }
}
