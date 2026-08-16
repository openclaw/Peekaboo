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
    @Test(arguments: ["click", "dismiss"])
    func `background prepared dialog action rejects generation flip before dispatch`(
        action: String) async throws
    {
        let application = ServiceApplicationInfo(
            processIdentifier: 89,
            processStartIdentity: 890,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit")
        let applications = MockApplicationService(applications: [application])
        let dialogs = PreparedDialogService()
        dialogs.preparedProcessGeneration = 891
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            dialogs: dialogs,
            executionPolicy: .backgroundOnly)
        var raw: [String: Any] = [
            "action": action,
            "app": "TextEdit",
        ]
        if action == "click" {
            raw["button"] = "OK"
        }

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: raw))

        #expect(response.isError)
        #expect(dialogs.prepareCount == 1)
        #expect(dialogs.executeCount == 0)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

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
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)

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
        let windows = MCPFocusResultWindowService()
        let dialogs = PreparedDialogService()
        dialogs.preparationFailure = .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Dialog is ambiguous")
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            windows: windows,
            dialogs: dialogs,
            executionPolicy: .unrestricted)

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
        #expect(windows.focusCalls == 1)
    }

    @Test
    func `foreground dialog rejects malformed and contradictory leaf targets after focus`() async throws {
        for mismatch in DialogLeafTargetMismatch.allCases {
            let windows = MCPFocusResultWindowService()
            let dialogs = PreparedDialogService()
            switch mismatch {
            case .incompleteWindow:
                dialogs.preparedTargetWindowIdentity = windows.identity
            case .contradictoryReceipt:
                dialogs.preparedTargetReceipt = .init(
                    processIdentifier: 999,
                    processStartIdentity: 1,
                    windowID: windows.identity.windowID)
            }
            let context = await MCPToolTestHelpers.makeContext(
                windows: windows,
                dialogs: dialogs,
                executionPolicy: .unrestricted)

            let response = try await context.execute(
                tool: DialogTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": "click",
                    "button": "OK",
                    "app": "TextEdit",
                    "foreground": true,
                ]))

            #expect(response.isError)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("indeterminate"))
            #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
            #expect(meta["dispatched_unit_count"] == .int(2))
            if mismatch == .contradictoryReceipt {
                #expect(meta["target_receipt"] == nil)
            }
        }
    }

    @Test
    func `targetless foreground input and file preserve legacy current-dialog behavior`() async throws {
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)

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
    func `exact dialog input defaults to background AXValue and emits its target receipt`() async throws {
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)

        let response = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "input",
                "text": "value",
                "pid": 89,
                "window_id": 700,
            ]))

        #expect(!response.isError)
        #expect(dialogs.inputCount == 1)
        #expect(dialogs.foregroundExactInputCount == 0)
        #expect(dialogs.lastExactInputRequest?.focus.autoFocus == false)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["delivery_mechanism"] == .string("accessibility_value"))
        #expect(meta["delivery_mode"] == .string("background"))
        guard case let .object(target)? = meta["target_identity"],
              case let .object(receipt)? = meta["target_receipt"]
        else {
            Issue.record("Expected exact dialog target metadata")
            return
        }
        #expect(target["window_id"] == .int(700))
        #expect(receipt["window_id"] == .int(700))
    }

    @Test
    func `targeted dialog list preserves exact target and rejects substitution`() async throws {
        let dialogs = PreparedDialogService()
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        func elements(windowID: Int) throws -> DialogElements {
            let identity = WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: 89,
                ownerProcessStartIdentity: 890,
                capturedBounds: bounds)
            let exact = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
            return try DialogElements(
                dialogInfo: .init(title: "Alert", role: "AXSheet", bounds: bounds),
                resolvedTarget: ResolvedDialogTargetEvidence(
                    target: exact,
                    application: .init(
                        processIdentifier: 89,
                        processStartIdentity: 890,
                        bundleIdentifier: "com.apple.TextEdit",
                        name: "TextEdit"),
                    window: .init(
                        windowID: windowID,
                        title: "Alert",
                        bounds: bounds,
                        mutationIdentity: identity)))
        }
        dialogs.targetedListElements = try elements(windowID: 700)
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)
        let arguments = ToolArguments(raw: [
            "action": "list",
            "pid": 89,
            "window_id": 700,
        ])

        let valid = try await context.execute(tool: DialogTool(context: context), arguments: arguments)
        #expect(!valid.isError)
        let meta = try #require(valid.meta?.objectValue)
        guard case let .object(receipt)? = meta["target_receipt"] else {
            Issue.record("Expected targeted dialog-list receipt")
            return
        }
        #expect(receipt["window_id"] == .int(700))

        dialogs.targetedListElements = try elements(windowID: 701)
        let forged = try await context.execute(tool: DialogTool(context: context), arguments: arguments)
        #expect(forged.isError)
    }

    @Test
    func `exact-window input leaves sheet focus to dialog service without selector downgrade`() async throws {
        let windows = EmptyRecordingWindowService()
        let dialogs = PreparedDialogService()
        let context = await MCPToolTestHelpers.makeContext(
            windows: windows,
            dialogs: dialogs,
            executionPolicy: .unrestricted)

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
        #expect(dialogs.foregroundExactInputCount == 1)
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
            dialogs: dialogs,
            executionPolicy: .unrestricted)

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
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)

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

    @Test
    func `foreground input and forced dismiss reject nonthrowing provider refusals`() async throws {
        let dialogs = PreparedDialogService()
        dialogs.foregroundOutcome = .refused(reason: .permissionDenied)
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)

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
            #expect(response.isError)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("refused"))
            #expect(meta["refusal_reason"] == .string("permission_denied"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }
    }

    @Test
    func `file dialog exposes canonical and legacy conservative outcomes`() async throws {
        let dialogs = PreparedDialogService()
        dialogs.fileOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one)
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)

        let canonical = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "file",
                "path": "/tmp",
                "foreground": true,
            ]))

        #expect(!canonical.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
            #require(dialogs.fileOutcome),
            in: canonical)

        dialogs.omitFileOutcome = true
        let legacy = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "file",
                "path": "/tmp",
                "foreground": true,
            ]))

        #expect(!legacy.isError)
        let expected = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: legacy)
        guard case let .text(text, _, _)? = legacy.content.first else {
            Issue.record("Expected legacy file dialog warning")
            return
        }
        #expect(text.contains(AgentDisplayTokens.Status.warning))
        #expect(text.contains("effect is unverifiable"))
    }

    @Test
    func `file dialog converts nonthrowing provider failures before success formatting`() async throws {
        let dialogs = PreparedDialogService()
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 89,
            processStartIdentity: 890,
            windowID: 700)
        dialogs.fileTargetReceipt = receipt
        let context = await MCPToolTestHelpers.makeContext(
            dialogs: dialogs,
            executionPolicy: .unrestricted)
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .clipboardTransaction,
            mode: .foreground)
        let failures: [DesktopActionOutcome] = [
            .refused(reason: .permissionDenied),
            .partial(delivery: delivery, unitCount: .one),
            .indeterminate(
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: .one),
        ]

        for outcome in failures {
            dialogs.fileSuccess = true
            dialogs.fileOutcome = outcome
            let response = try await context.execute(
                tool: DialogTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": "file",
                    "path": "/tmp",
                    "foreground": true,
                ]))

            #expect(response.isError, "Expected \(outcome.state.rawValue) to be a failure response")
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string(outcome.state.rawValue))
            #expect(meta["dispatched_unit_count"] == outcome.dispatchState.unitCount.map {
                .int($0.rawValue)
            })
            let target = try #require(meta["target_receipt"]?.objectValue)
            #expect(target["pid"] == .int(Int(receipt.processIdentifier)))
            #expect(target["process_start_identity_decimal"] == .string("890"))
            #expect(target["window_id"] == .int(700))
            guard case let .text(text, _, _)? = response.content.first else {
                Issue.record("Expected canonical file failure text")
                continue
            }
            #expect(!text.contains("Handled file dialog"))
            #expect(!text.contains(AgentDisplayTokens.Status.success))
        }

        let confirmed = DesktopActionOutcome.confirmedChange(
            delivery: delivery,
            unitCount: .one)
        dialogs.fileSuccess = false
        dialogs.fileOutcome = confirmed
        let unsuccessful = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "file",
                "path": "/tmp",
                "foreground": true,
            ]))
        #expect(unsuccessful.isError)
        let unsuccessfulMeta = try #require(unsuccessful.meta?.objectValue)
        #expect(unsuccessfulMeta["state"] == .string("indeterminate"))
        #expect(unsuccessfulMeta["dispatched_unit_count"] == .int(1))
        #expect(unsuccessfulMeta["target_receipt"] != nil)

        dialogs.fileSuccess = true
        let successful = try await context.execute(
            tool: DialogTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "file",
                "path": "/tmp",
                "foreground": true,
            ]))
        #expect(!successful.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(confirmed, in: successful)
        guard case let .text(successText, _, _)? = successful.content.first else {
            Issue.record("Expected confirmed file success text")
            return
        }
        #expect(successText.contains(AgentDisplayTokens.Status.success))
        #expect(successText.contains("Handled file dialog"))
    }
}

private enum DialogLeafTargetMismatch: CaseIterable {
    case incompleteWindow
    case contradictoryReceipt
}

@MainActor
private final class PreparedDialogService: DialogServiceProtocol {
    let supportsBackgroundExactDialogInput = true
    let outcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .accessibilityAction, mode: .background),
        unitCount: .one)
    var prepareCount = 0
    var executeCount = 0
    var inputCount = 0
    var foregroundExactInputCount = 0
    var fileCount = 0
    var lastPreparation: DialogActionPreparationRequest?
    var preparationFailure: DesktopActionFailure?
    var foregroundOutcome: DesktopActionOutcome?
    var fileOutcome: DesktopActionOutcome?
    var fileSuccess = true
    var fileTargetReceipt: DesktopActionTargetReceipt?
    var preparedTargetReceipt: DesktopActionTargetReceipt?
    var preparedTargetWindowIdentity: WindowMutationIdentity?
    var preparedTargetWindowBounds: CGRect?
    var omitForegroundOutcome = false
    var omitFileOutcome = false
    var lastInputAppHint: String?
    var lastExactInputRequest: DialogInputExecutionRequest?
    var lastExactForcedDismissRequest: DialogForcedDismissExecutionRequest?
    var targetedListElements: DialogElements?
    var preparedProcessGeneration: UInt64 = 890

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
            ownerProcessStartIdentity: self.preparedProcessGeneration,
            capturedBounds: bounds)
        return try PreparedDialogActionReceipt(
            token: UUID(),
            kind: request.kind,
            target: UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds))
    }

    func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) -> DialogActionResult {
        self.executeCount += 1
        let targetReceipt = self.preparedTargetReceipt ?? DesktopActionTargetReceipt(
            processIdentifier: receipt.target.identity.ownerProcessIdentifier,
            processStartIdentity: receipt.target.identity.ownerProcessStartIdentity,
            windowID: receipt.target.identity.windowID)
        let targetWindowIdentity = self.preparedTargetWindowIdentity ?? receipt.target.identity
        let targetWindowBounds = if self.preparedTargetWindowIdentity != nil {
            self.preparedTargetWindowBounds
        } else {
            receipt.target.bounds
        }
        return DialogActionResult(
            success: true,
            action: receipt.kind == .clickButton ? .clickButton : .dismiss,
            details: ["button": "OK"],
            outcome: self.outcome,
            targetReceipt: targetReceipt,
            targetWindowIdentity: targetWindowIdentity,
            targetWindowBounds: targetWindowBounds,
            focusedElement: nil)
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
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: request.target.windowID ?? 700,
            ownerProcessIdentifier: request.target.processIdentifier ?? 89,
            ownerProcessStartIdentity: 890,
            capturedBounds: bounds)
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: ["field": "Text Field", "text_length": "5"],
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .one),
            targetReceipt: DesktopActionTargetReceipt(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID),
            targetWindowIdentity: identity,
            targetWindowBounds: bounds,
            focusedElement: nil)
    }

    func enterTextForegroundCompatible(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        self.foregroundExactInputCount += 1
        self.inputCount += 1
        self.lastExactInputRequest = request
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: request.target.windowID ?? 700,
            ownerProcessIdentifier: request.target.processIdentifier ?? 89,
            ownerProcessStartIdentity: 890,
            capturedBounds: bounds)
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: ["field": "Text Field", "text_length": "5"],
            outcome: self.omitForegroundOutcome ? nil : (self.foregroundOutcome ?? .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one)),
            targetReceipt: DesktopActionTargetReceipt(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID),
            targetWindowIdentity: identity,
            targetWindowBounds: bounds,
            focusedElement: nil)
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
            success: self.fileSuccess,
            action: .handleFileDialog,
            details: ["button_clicked": "Open"],
            outcome: self.omitFileOutcome ? nil : (self.fileOutcome ?? self.outcome),
            targetReceipt: self.fileTargetReceipt)
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
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: request.target.windowID ?? 700,
            ownerProcessIdentifier: request.target.processIdentifier ?? 89,
            ownerProcessStartIdentity: 890,
            capturedBounds: bounds)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity,
            windowID: identity.windowID)
        return DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"],
            outcome: self.omitForegroundOutcome ? nil : (self.foregroundOutcome ?? self.outcome),
            targetReceipt: targetReceipt,
            targetWindowIdentity: identity,
            targetWindowBounds: bounds,
            focusedElement: nil)
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw DialogError.noActiveDialog
    }

    func listDialogElements(target _: DialogTargetSelector) async throws -> DialogElements {
        guard let targetedListElements else { throw DialogError.noActiveDialog }
        return targetedListElements
    }
}
