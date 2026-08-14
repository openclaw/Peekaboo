import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

private struct DialogTextFieldPayload: Codable {
    let title: String?
    let value: String?
    let placeholder: String?
}

private struct DialogListPayload: Codable {
    let title: String
    let role: String
    let buttons: [String]
    let textFields: [DialogTextFieldPayload]
    let textElements: [String]
}

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct DialogCommandTests {
    @Test
    func `Dialog  command exists`() {
        let config = DialogCommand.commandDescription
        #expect(config.commandName == "dialog")
        #expect(config.abstract.contains("Interact with system dialogs and alerts"))
    }

    @Test
    func `Dialog  command has expected subcommands`() {
        let subcommands = DialogCommand.commandDescription.subcommands
        #expect(subcommands.count == 5)

        var subcommandNames: [String] = []
        subcommandNames.reserveCapacity(subcommands.count)
        for descriptor in subcommands {
            guard let name = descriptor.commandDescription.commandName else { continue }
            subcommandNames.append(name)
        }
        #expect(subcommandNames.contains("click"))
        #expect(subcommandNames.contains("input"))
        #expect(subcommandNames.contains("file"))
        #expect(subcommandNames.contains("dismiss"))
        #expect(subcommandNames.contains("list"))
    }

    @Test
    func `Dialog  click command help`() async throws {
        let result = try await runCommand(["dialog", "click", "--help"])
        #expect(result.status == 0)
        let output = result.output

        #expect(output.contains("Click a button in a dialog using DialogService"))
        #expect(output.contains("--button"))
        #expect(output.contains("--window-title"))
        #expect(output.contains("--json"))
    }

    @Test
    func `Dialog  input command help`() async throws {
        let result = try await runCommand(["dialog", "input", "--help"])
        #expect(result.status == 0)
        let output = result.output

        #expect(output.contains("Enter text in a dialog field using DialogService"))
        #expect(output.contains("--text"))
        #expect(output.contains("--field"))
        #expect(output.contains("--index"))
        #expect(output.contains("--clear"))
    }

    @Test
    func `Dialog  file command help`() async throws {
        let result = try await runCommand(["dialog", "file", "--help"])
        #expect(result.status == 0)
        let output = result.output

        #expect(output.contains("Handle file save/open dialogs using DialogService"))
        #expect(output.contains("--path"))
        #expect(output.contains("--name"))
        #expect(output.contains("--select"))
    }

    @Test
    func `Dialog  dismiss command help`() async throws {
        let result = try await runCommand(["dialog", "dismiss", "--help"])
        #expect(result.status == 0)
        let output = result.output

        #expect(output.contains("Dismiss a dialog using DialogService"))
        #expect(output.contains("--force"))
        #expect(output.contains("--window-title"))
    }

    @Test
    func `dialog dismiss uses force flag`() async throws {
        let dialogService = StubDialogService()
        dialogService.dialogElements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Open",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: false,
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            buttons: [],
            textFields: [],
            staticTexts: []
        )
        dialogService.dismissResult = DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"]
        )

        let services = self.makeTestServices(dialogs: dialogService)
        let (output, status) = try await runCommand(
            ["dialog", "dismiss", "--force", "--foreground", "--json"],
            services: services
        )

        #expect(status == 0)
        struct Payload: Codable {
            let success: Bool
            let data: DialogDismissResult
        }
        struct DialogDismissResult: Codable {
            let method: String
        }

        let response = try JSONDecoder().decode(Payload.self, from: Data(output.utf8))
        #expect(response.success == true)
        #expect(response.data.method == "escape")
    }

    @Test
    func `Dialog  list command help`() async throws {
        let result = try await runCommand(["dialog", "list", "--help"])
        #expect(result.status == 0)
        let output = result.output

        #expect(output.contains("List elements in current dialog using DialogService"))
        #expect(output.contains("--json"))
    }

    @Test
    func `Dialog  error handling`() {
        // Test that DialogError enum values are properly mapped
        let errorCases: [(PeekabooError, StandardErrorCode, String)] = [
            (.elementNotFound("OK"), .elementNotFound, "Element not found: OK"),
            (.invalidInput("Field index 5 out of range"), .invalidInput, "Invalid input: Field index 5 out of range"),
            (
                .operationError(message: "No text fields found in dialog."),
                .unknownError,
                "No text fields found in dialog."
            ),
        ]

        for (error, code, message) in errorCases {
            #expect(error.code == code)
            #expect(error.errorDescription == message)
        }
    }

    @Test
    @MainActor
    func `Dialog  service integration`() {
        // Verify that PeekabooServices includes the dialog service
        let services = self.makeTestServices()
        _ = services.dialogs // This should compile without errors
    }

    @Test
    func `dialog list surfaces stubbed elements in JSON`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Open",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: true,
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            buttons: [
                DialogButton(title: "New Document"),
                DialogButton(title: "Open"),
            ],
            textFields: [
                DialogTextField(title: "Name", value: "", placeholder: "File name", index: 0, isEnabled: true),
            ],
            staticTexts: ["Choose a document to open"]
        )
        let dialogService = StubDialogService(elements: elements)
        let services = self.makeTestServices(dialogs: dialogService)

        let (output, status) = try await runCommand(
            ["dialog", "list", "--json"],
            services: services
        )
        #expect(status == 0)

        let data = try #require(output.data(using: .utf8))
        let response = try JSONDecoder().decode(CodableJSONResponse<DialogListPayload>.self, from: data)
        #expect(response.data.title == "Open")
        #expect(response.data.buttons.contains("New Document"))
        #expect(response.data.textFields.first?.placeholder == "File name")
    }

    @Test
    func `untargeted dialog list leaves latest snapshot eligible`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Open",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: true,
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            buttons: [],
            textFields: [],
            staticTexts: []
        )
        let snapshots = StubSnapshotManager()
        let latestSnapshotID = try await snapshots.createSnapshot()
        let services = TestServicesFactory.makePeekabooServices(
            dialogs: StubDialogService(elements: elements),
            snapshots: snapshots
        )

        let (_, status) = try await runCommand(
            ["dialog", "list", "--json"],
            services: services
        )

        #expect(status == 0)
        #expect(snapshots.invalidationCutoffs.isEmpty)
        #expect(await snapshots.getMostRecentSnapshot() == latestSnapshotID)
    }

    @Test
    func `dialog click emits JSON success when stub succeeds`() async throws {
        let dialogService = await MainActor.run { StubDialogService() }
        dialogService.dialogElements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Open",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: true,
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            buttons: [
                DialogButton(title: "New Document"),
            ],
            textFields: [],
            staticTexts: []
        )
        dialogService.clickButtonResult = DialogActionResult(
            success: true,
            action: .clickButton,
            details: ["button": "New Document", "window": "Open"]
        )
        let services = self.makeTestServices(dialogs: dialogService)

        let (output, status) = try await runCommand(
            ["dialog", "click", "--button", "New Document", "--json"],
            services: services
        )
        #expect(status == 0)

        let data = try #require(output.data(using: .utf8))
        struct DialogClickPayload: Codable {
            let action: String
            let button: String
            let window: String
        }

        let response = try JSONDecoder().decode(CodableJSONResponse<DialogClickPayload>.self, from: data)
        #expect(response.success == true)
        #expect(response.data.button == "New Document")
        #expect(dialogService.recordedButtonClicks.count == 1)
        #expect(dialogService.recordedButtonClicks.first?.button == "New Document")
        #expect(dialogService.clickFallbackRequests == [false])
    }

    @Test
    func `dialog click only permits global fallback in foreground mode`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            buttons: [DialogButton(title: "OK")]
        )
        let dialogService = StubDialogService(elements: elements)
        dialogService.clickButtonResult = DialogActionResult(
            success: true,
            action: .clickButton,
            details: ["button": "OK", "window": "Alert"]
        )
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            ["dialog", "click", "--button", "OK", "--foreground", "--json"],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(dialogService.clickFallbackRequests == [true])
    }

    @Test
    func `dialog input rejects background mode before calling service`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXWindow",
                subrole: "AXDialog",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            textFields: [DialogTextField(index: 0)]
        )
        let dialogService = StubDialogService(elements: elements)
        dialogService.enterTextResult = DialogActionResult(success: true, action: .enterText)
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            ["dialog", "input", "--text", "Hello", "--json"],
            services: services
        )
        let output = result.stdout.isEmpty ? result.stderr : result.stdout

        #expect(result.exitStatus != 0)
        #expect(output.contains("requires --foreground"))
        #expect(dialogService.enterTextCallCount == 0)
    }

    @Test
    func `dialog input preserves exact selector and focus policy for host execution`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXSheet",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            textFields: [DialogTextField(index: 0)]
        )
        let dialogService = StubDialogService(elements: elements)
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        dialogService.enterTextResult = DialogActionResult(
            success: true,
            action: .enterText,
            details: ["field": "Name", "text_length": "5"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetReceipt: DesktopActionTargetReceipt(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                windowID: identity.windowID
            )
        )
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            [
                "dialog", "input", "--text", "hello", "--field", "Name", "--foreground",
                "--pid", "42", "--window-id", "73", "--focus-timeout", "2s",
                "--focus-retry-count", "4", "--space-switch", "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(dialogService.exactInputRequests.count == 1)
        let request = try #require(dialogService.exactInputRequests.first)
        #expect(request.target.processIdentifier == 42)
        #expect(request.target.windowID == 73)
        #expect(request.target.windowTitle == nil)
        #expect(request.text == "hello")
        #expect(request.fieldIdentifier == "Name")
        #expect(request.focus.autoFocus)
        #expect(request.focus.timeout == 2)
        #expect(request.focus.retryCount == 4)
        #expect(request.focus.switchSpace)
        #expect(!request.focus.bringToCurrentSpace)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["pid"] as? Int == 42)
        #expect(data["window_id"] as? Int == 73)
        #expect(data["process_start_identity_decimal"] as? String == "9001")
    }

    @Test
    func `targetless dialog input preserves no auto focus inside the execution service`() async throws {
        let dialogService = StubDialogService(elements: DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXSheet",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            )
        ))
        dialogService.enterTextResult = DialogActionResult(success: true, action: .enterText)
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            [
                "dialog", "input", "--text", "hello", "--foreground", "--no-auto-focus",
                "--focus-timeout", "1750ms", "--focus-retry-count", "7", "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        let focus = try #require(dialogService.legacyInputFocusPolicies.first)
        #expect(!focus.autoFocus)
        #expect(focus.timeout == 1.75)
        #expect(focus.retryCount == 7)
    }

    @Test
    func `forced dialog dismiss preserves exact selector and host owned focus policy`() async throws {
        let dialogService = StubDialogService(elements: DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXSheet",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            )
        ))
        dialogService.dismissResult = DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
        )
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            [
                "dialog", "dismiss", "--force", "--foreground", "--no-auto-focus",
                "--pid", "42", "--window-id", "73", "--focus-timeout", "2s",
                "--focus-retry-count", "4", "--bring-to-current-space", "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 0)
        let request = try #require(dialogService.exactForcedDismissRequests.first)
        #expect(request.target.processIdentifier == 42)
        #expect(request.target.windowID == 73)
        #expect(!request.focus.autoFocus)
        #expect(request.focus.timeout == 2)
        #expect(request.focus.retryCount == 4)
        #expect(request.focus.bringToCurrentSpace)
    }

    @Test
    func `dialog PID app hint uses exact local capability and preserves legacy provider names`() async throws {
        var target = InteractionTargetOptions()
        target.pid = 42
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 9001,
            bundleIdentifier: "com.example.LegacyDialogApp",
            name: "Legacy Dialog App"
        )
        let applications = StubApplicationService(applications: [application])

        let exactServices = TestServicesFactory.makePeekabooServices(
            applications: applications,
            dialogs: DialogService(applicationService: applications)
        )
        let exactHint = try await DialogCommand.resolveDialogAppHint(target: target, services: exactServices)
        #expect(exactHint == "PID:42")

        let legacyServices = TestServicesFactory.makePeekabooServices(
            applications: applications,
            dialogs: StubDialogService()
        )
        let legacyHint = try await DialogCommand.resolveDialogAppHint(target: target, services: legacyServices)
        #expect(legacyHint == "com.example.LegacyDialogApp")

        var appPIDTarget = InteractionTargetOptions()
        appPIDTarget.app = "PID:42"
        let exactAppPIDHint = try await DialogCommand.resolveDialogAppHint(
            target: appPIDTarget,
            services: exactServices
        )
        #expect(exactAppPIDHint == "PID:42")
        let legacyAppPIDHint = try await DialogCommand.resolveDialogAppHint(
            target: appPIDTarget,
            services: legacyServices
        )
        #expect(legacyAppPIDHint == "com.example.LegacyDialogApp")

        let staleLegacyServices = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: []),
            dialogs: StubDialogService()
        )
        for staleTarget in [target, appPIDTarget] {
            do {
                _ = try await DialogCommand.resolveDialogAppHint(
                    target: staleTarget,
                    services: staleLegacyServices,
                    refusalRoute: .bridge
                )
                Issue.record("Expected stale explicit PID to refuse before dialog dispatch")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.route == .bridge)
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .targetUnavailable)
                #expect(failure.outcome.dispatchState == .none)
            }
        }

        let nameFallbackServices = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: 42,
                bundleIdentifier: "  ",
                name: "Fallback Name"
            )]),
            dialogs: StubDialogService()
        )
        let nameFallback = try await DialogCommand.resolveDialogAppHint(
            target: target,
            services: nameFallbackServices
        )
        #expect(nameFallback == "Fallback Name")

        let emptyIdentityServices = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [ServiceApplicationInfo(
                processIdentifier: 42,
                bundleIdentifier: "",
                name: " "
            )]),
            dialogs: StubDialogService()
        )
        do {
            _ = try await DialogCommand.resolveDialogAppHint(
                target: target,
                services: emptyIdentityServices
            )
            Issue.record("Expected empty legacy application identity to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    func `legacy foreground dialog successes remain unverified`() async throws {
        let dialogService = StubDialogService(elements: DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXSheet",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            )
        ))
        dialogService.enterTextResult = DialogActionResult(success: true, action: .enterText)
        dialogService.dismissResult = DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"]
        )
        let services = self.makeTestServices(dialogs: dialogService)

        for arguments in [
            ["dialog", "input", "--text", "hello", "--foreground", "--no-auto-focus", "--json"],
            ["dialog", "dismiss", "--force", "--foreground", "--no-auto-focus", "--json"],
        ] {
            let result = try await InProcessCommandRunner.run(arguments, services: services)
            #expect(result.exitStatus == 0)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            )
            #expect(object["effect"] as? String == "unverifiable")
            let outcome = try #require(object["outcome"] as? [String: Any])
            #expect(outcome["state"] as? String == "dispatched_unverified")
            #expect(outcome["retry_safe"] as? Bool == false)
        }
    }

    @Test
    func `dialog input projects canonical unverified outcome instead of confirmed`() async throws {
        let dialogService = StubDialogService(elements: DialogElements(
            dialogInfo: DialogInfo(
                title: "Alert",
                role: "AXSheet",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            textFields: [DialogTextField(title: "Name", value: "", index: 0)]
        ))
        dialogService.enterTextResult = DialogActionResult(
            success: true,
            action: .enterText,
            details: ["field": "Name", "text_length": "5"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
        )
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            ["dialog", "input", "--text", "hello", "--foreground", "--no-auto-focus", "--json"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["effect"] as? String == "unverifiable")
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(outcome["retry_safe"] as? Bool == false)
    }

    @Test
    func `forced dialog dismiss projects canonical unverified Escape outcome`() async throws {
        let dialogService = StubDialogService(elements: DialogElements(
            dialogInfo: DialogInfo(
                title: "Save",
                role: "AXSheet",
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            )
        ))
        dialogService.dismissResult = DialogActionResult(
            success: true,
            action: .dismiss,
            details: [
                "method": "escape",
                "pid": "42",
                "process_start_identity": "9007199254740993",
                "process_start_identity_decimal": "9007199254740993",
                "window_id": "73",
            ],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
        )
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            ["dialog", "dismiss", "--force", "--foreground", "--no-auto-focus", "--json"],
            services: services
        )

        #expect(result.exitStatus == 0)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        #expect(object["effect"] as? String == "unverifiable")
        let data = try #require(object["data"] as? [String: Any])
        #expect(data["pid"] as? Int == 42)
        #expect(data["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(data["window_id"] as? Int == 73)
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
    }

    @Test
    func `dialog input maps noActiveDialog to NO_ACTIVE_DIALOG`() async throws {
        let services = self.makeTestServices(dialogs: StubDialogService(elements: nil))
        let result = try await InProcessCommandRunner.run(
            ["dialog", "input", "--text", "Hello", "--foreground", "--json"],
            services: services
        )
        let output = result.stdout.isEmpty ? result.stderr : result.stdout

        let data = try #require(output.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(response.success == false)
        #expect(response.error?.code == "NO_ACTIVE_DIALOG")
    }

    @Test
    func `dialog input maps fieldNotFound to ELEMENT_NOT_FOUND`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Save",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: true,
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            buttons: [],
            textFields: [],
            staticTexts: []
        )
        let dialogService = StubDialogService(elements: elements)
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            ["dialog", "input", "--text", "Hello", "--field", "Filename", "--foreground", "--json"],
            services: services
        )
        let output = result.stdout.isEmpty ? result.stderr : result.stdout

        let data = try #require(output.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(response.success == false)
        #expect(response.error?.code == "ELEMENT_NOT_FOUND")
    }

    @Test
    func `dialog file maps noFileDialog to ELEMENT_NOT_FOUND`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Preferences",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: false,
                bounds: .init(x: 0, y: 0, width: 400, height: 300)
            ),
            buttons: [],
            textFields: [],
            staticTexts: []
        )
        let dialogService = StubDialogService(elements: elements)
        let services = self.makeTestServices(dialogs: dialogService)

        let result = try await InProcessCommandRunner.run(
            [
                "dialog", "file", "--path", "/tmp", "--name", "test.txt", "--select", "Save",
                "--foreground", "--json",
            ],
            services: services
        )
        let output = result.stdout.isEmpty ? result.stderr : result.stdout

        let data = try #require(output.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(response.success == false)
        #expect(response.error?.code == "ELEMENT_NOT_FOUND")
    }

    @Test
    func `dialog maps invalidFieldIndex to INVALID_INPUT`() async throws {
        @MainActor
        struct InvalidIndexDialogService: DialogServiceProtocol {
            func findActiveDialog(
                windowTitle: String?,
                appName: String?
            ) async throws -> DialogInfo {
                throw DialogError.noActiveDialog
            }

            func clickButton(
                buttonText: String,
                windowTitle: String?,
                appName: String?
            ) async throws -> DialogActionResult {
                throw DialogError.noActiveDialog
            }

            func enterText(
                text: String,
                fieldIdentifier: String?,
                clearExisting: Bool,
                windowTitle: String?,
                appName: String?
            ) async throws -> DialogActionResult {
                throw DialogError.invalidFieldIndex
            }

            func handleFileDialog(
                path: String?,
                filename: String?,
                actionButton: String?,
                ensureExpanded: Bool,
                appName: String?
            ) async throws -> DialogActionResult {
                throw DialogError.noActiveDialog
            }

            func dismissDialog(
                force: Bool,
                windowTitle: String?,
                appName: String?
            ) async throws -> DialogActionResult {
                throw DialogError.noActiveDialog
            }

            func listDialogElements(
                windowTitle: String?,
                appName: String?
            ) async throws -> DialogElements {
                throw DialogError.noActiveDialog
            }
        }

        let services = self.makeTestServices(dialogs: InvalidIndexDialogService())
        let result = try await InProcessCommandRunner.run(
            ["dialog", "input", "--text", "Hello", "--index", "5", "--foreground", "--json"],
            services: services
        )
        let output = result.stdout.isEmpty ? result.stderr : result.stdout

        let data = try #require(output.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(response.success == false)
        #expect(response.error?.code == "INVALID_INPUT")
    }

    private struct CommandFailure: Error {
        let status: Int32
        let stderr: String
    }

    private func runCommand(_ args: [String]) async throws -> (output: String, status: Int32) {
        let services = self.makeTestServices()
        return try await self.runCommand(args, services: services)
    }

    private func runCommand(
        _ args: [String],
        services: PeekabooServices
    ) async throws -> (output: String, status: Int32) {
        let result = try await InProcessCommandRunner.run(args, services: services)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        if result.exitStatus != 0 {
            throw CommandFailure(status: result.exitStatus, stderr: output)
        }
        return (output, result.exitStatus)
    }

    @MainActor
    private func makeTestServices(
        dialogs: any DialogServiceProtocol = StubDialogService()
    ) -> PeekabooServices {
        TestServicesFactory.makePeekabooServices(dialogs: dialogs)
    }
}

// MARK: - Dialog Command  Integration Tests

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationActions)
)
struct DialogCommandIntegrationTests {
    @Test
    func `List active dialogs with `() async throws {
        let output = try await runAutomationCommand([
            "dialog", "list",
            "--json",
        ])

        struct TextField: Codable {
            let title: String
            let value: String
            let placeholder: String
        }

        struct DialogListResult: Codable {
            let title: String
            let role: String
            let buttons: [String]
            let textFields: [TextField]
            let textElements: [String]
        }

        // Try to decode as success response first
        if let response = try? JSONDecoder().decode(
            CodableJSONResponse<DialogListResult>.self,
            from: Data(output.utf8)
        ) {
            if response.success {
                #expect(!response.data.title.isEmpty)
                #expect(!response.data.buttons.isEmpty)
            }
        } else {
            // Otherwise it's an error response
            let errorResponse = try JSONDecoder().decode(JSONResponse.self, from: Data(output.utf8))
            #expect(errorResponse.error?.code == "NO_ACTIVE_DIALOG")
        }
    }

    @Test
    func `Dialog  click workflow`() async throws {
        // This would click a button if a dialog is present
        let output = try await runAutomationCommand([
            "dialog", "click",
            "--button", "OK",
            "--json",
        ])

        let data = try JSONDecoder().decode(JSONResponse.self, from: Data(output.utf8))
        if !data.success {
            // Expected if no dialog is open
            #expect(data.error?.code == "NO_ACTIVE_DIALOG")
        }
    }

    @Test
    func `Dialog  input workflow`() async throws {
        let output = try await runAutomationCommand([
            "dialog", "input",
            "--text", "Test input",
            "--field", "Name",
            "--foreground",
            "--json",
        ])

        let data = try JSONDecoder().decode(JSONResponse.self, from: Data(output.utf8))
        if !data.success {
            // Expected if no dialog is open
            #expect(data.error?.code == "NO_ACTIVE_DIALOG")
        }
    }

    @Test
    func `Dialog  dismiss with escape`() async throws {
        let output = try await runAutomationCommand([
            "dialog", "dismiss",
            "--force",
            "--foreground",
            "--json",
        ])

        struct DialogDismissResult: Codable {
            let action: String
            let method: String
            let button: String?
        }

        if let response = try? JSONDecoder().decode(
            CodableJSONResponse<DialogDismissResult>.self,
            from: Data(output.utf8)
        ) {
            if response.success {
                #expect(response.data.method == "escape")
            }
        }
    }

    @Test
    func `File dialog  handling`() async throws {
        let output = try await runAutomationCommand([
            "dialog", "file",
            "--path", "/tmp",
            "--name", "test.txt",
            "--select", "Save",
            "--foreground",
            "--json",
        ])

        struct FileDialogResult: Codable {
            let action: String
            let path: String?
            let name: String?
            let buttonClicked: String
        }

        // Try to decode as success response first
        if let response = try? JSONDecoder().decode(
            CodableJSONResponse<FileDialogResult>.self,
            from: Data(output.utf8)
        ) {
            if response.success {
                #expect(response.data.action == "file_dialog")
                #expect(response.data.path == "/tmp")
                #expect(response.data.name == "test.txt")
            }
        } else {
            // Otherwise it's an error response
            let errorResponse = try JSONDecoder().decode(JSONResponse.self, from: Data(output.utf8))
            #expect(
                errorResponse.error?.code == "NO_ACTIVE_DIALOG" ||
                    errorResponse.error?.code == "ELEMENT_NOT_FOUND"
            )
        }
    }
}

// MARK: - Test Helpers

private func runAutomationCommand(
    _ args: [String],
    allowedExitStatuses: Set<Int32> = [0, 1, 64]
) async throws -> String {
    let result = try await InProcessCommandRunner.runShared(
        args,
        allowedExitCodes: allowedExitStatuses
    )
    return result.combinedOutput
}
#endif
