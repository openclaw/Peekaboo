import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.unit))
struct DialogFileJSONOutputTests {
    @Test
    func `dialog file forwards path_navigation_method in JSON`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Save",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: true,
                bounds: .init(x: 0, y: 0, width: 420, height: 320)
            ),
            buttons: [],
            textFields: [],
            staticTexts: []
        )

        let dialogService = StubDialogService(elements: elements)
        dialogService.handleFileDialogResult = DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: [
                "dialog_identifier": "sheet:Save:0",
                "found_via": "ax",
                "path": "/tmp",
                "path_navigation_method": "path_textfield_typed+fallback_go_to_folder",
                "filename": "out.txt",
                "button_clicked": "Save",
                "button_identifier": "OKButton",
                "saved_path": "/tmp/out.txt",
                "saved_path_verified": "true",
                "saved_path_found_via": "expected_path",
            ]
        )

        let services = TestServicesFactory.makePeekabooServices(dialogs: dialogService)
        let result = try await InProcessCommandRunner.run(
            [
                "dialog", "file", "--path", "/tmp", "--name", "out.txt", "--select", "Save",
                "--foreground", "--json",
            ],
            services: services
        )

        struct Payload: Codable {
            let action: String
            let dialogIdentifier: String?
            let foundVia: String?
            let path: String?
            let pathNavigationMethod: String?
            let name: String?
            let buttonClicked: String

            enum CodingKeys: String, CodingKey {
                case action
                case dialogIdentifier = "dialog_identifier"
                case foundVia = "found_via"
                case path
                case pathNavigationMethod = "path_navigation_method"
                case name
                case buttonClicked
            }
        }

        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(CodableJSONResponse<Payload>.self, from: Data(output.utf8))
        #expect(response.success == true)
        #expect(response.data.action == "file_dialog")
        #expect(response.data.dialogIdentifier == "sheet:Save:0")
        #expect(response.data.foundVia == "ax")
        #expect(response.data.path == "/tmp")
        #expect(response.data.name == "out.txt")
        #expect(response.data.buttonClicked == "Save")
        #expect(response.data.pathNavigationMethod == "path_textfield_typed+fallback_go_to_folder")
        #expect(response.effect == .unverifiable)
        #expect(response.outcome?.state == .dispatchedUnverified)
        #expect(response.outcome?.route == .local)
        #expect(response.outcome?.deliveryMechanism == .globalEvents)
        #expect(response.outcome?.deliveryMode == .foreground)
    }

    @Test
    func `dialog file returns timeout JSON when service hangs`() async throws {
        let elements = DialogElements(
            dialogInfo: DialogInfo(
                title: "Save",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: true,
                bounds: .init(x: 0, y: 0, width: 420, height: 320)
            ),
            buttons: [],
            textFields: [],
            staticTexts: []
        )

        let dialogService = StubDialogService(elements: elements)
        dialogService.handleFileDialogDelay = 2.0

        let services = TestServicesFactory.makePeekabooServices(dialogs: dialogService)
        let result = try await InProcessCommandRunner.run(
            [
                "dialog", "file",
                "--path", "/tmp",
                "--name", "out.txt",
                "--select", "Save",
                "--timeout", "1s",
                "--foreground",
                "--json",
            ],
            services: services
        )

        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        let response = try JSONDecoder().decode(JSONResponse.self, from: Data(output.utf8))
        #expect(result.exitStatus == 1)
        #expect(response.success == false)
        #expect(response.error?.code == "TIMEOUT")
    }

    @Test
    func `dialog file publishes exact retained leaf target`() async throws {
        let dialogService = Self.successfulDialogService()
        dialogService.handleFileDialogResult = Self.successResult(
            targetIdentity: DialogFileFocusWindowService.identity,
            targetBounds: DialogFileFocusWindowService.bounds
        )
        let windows = DialogFileFocusWindowService()
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            dialogs: dialogService
        )

        let result = try await InProcessCommandRunner.run(
            Self.targetedArguments,
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let target = try #require(object["target_identity"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 0)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(target["kind"] as? String == "window")
        #expect(target["pid"] as? Int == Int(DialogFileFocusWindowService.processIdentifier))
        #expect(target["process_start_identity_decimal"] as? String ==
            String(DialogFileFocusWindowService.processStartIdentity))
        #expect(target["window_id"] as? Int == DialogFileFocusWindowService.windowID)
        #expect(receipt["window_id"] as? Int == DialogFileFocusWindowService.windowID)
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(outcome["dispatched_unit_count"] as? Int == 2)
    }

    @Test
    func `dialog file does not inherit setup target when leaf omits target evidence`() async throws {
        let dialogService = Self.successfulDialogService()
        dialogService.handleFileDialogResult = Self.successResult()
        let windows = DialogFileFocusWindowService()
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            dialogs: dialogService
        )

        let result = try await InProcessCommandRunner.run(
            Self.targetedArguments,
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 0)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
        #expect(outcome["state"] as? String == "dispatched_unverified")
        #expect(outcome["dispatched_unit_count"] as? Int == 2)
    }

    @Test
    func `dialog file fails closed when leaf returns incomplete exact target evidence`() async throws {
        let dialogService = Self.successfulDialogService()
        dialogService.handleFileDialogResult = DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: ["button_clicked": "Save"],
            outcome: nil,
            targetReceipt: DesktopActionTargetReceipt(
                processIdentifier: DialogFileFocusWindowService.processIdentifier,
                processStartIdentity: DialogFileFocusWindowService.processStartIdentity,
                windowID: DialogFileFocusWindowService.windowID
            )
        )
        let windows = DialogFileFocusWindowService()
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            dialogs: dialogService
        )

        let result = try await InProcessCommandRunner.run(
            Self.targetedArguments,
            services: services
        )
        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["dispatched_unit_count"] as? Int == 2)
        #expect(outcome["retry_safe"] as? Bool == false)
    }

    private static var targetedArguments: [String] {
        [
            "dialog", "file",
            "--window-id", String(DialogFileFocusWindowService.windowID),
            "--path", "/tmp",
            "--name", "out.txt",
            "--select", "Save",
            "--foreground",
            "--focus-timeout", "1ms",
            "--focus-retry-count", "0",
            "--json",
            "--no-remote",
        ]
    }

    private static func successfulDialogService() -> StubDialogService {
        StubDialogService(elements: DialogElements(
            dialogInfo: DialogInfo(
                title: "Save",
                role: "AXWindow",
                subrole: "AXDialog",
                isFileDialog: true,
                bounds: .init(x: 0, y: 0, width: 420, height: 320)
            )
        ))
    }

    private static func successResult(
        targetIdentity: WindowMutationIdentity? = nil,
        targetBounds: CGRect? = nil
    ) -> DialogActionResult {
        DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: ["button_clicked": "Save"],
            outcome: nil,
            targetReceipt: targetIdentity.map {
                DesktopActionTargetReceipt(
                    processIdentifier: $0.ownerProcessIdentifier,
                    processStartIdentity: $0.ownerProcessStartIdentity,
                    windowID: $0.windowID
                )
            },
            targetWindowIdentity: targetIdentity,
            targetWindowBounds: targetBounds,
            focusedElement: nil
        )
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        let data = try #require(output.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class DialogFileFocusWindowService: StubWindowService,
WindowManagementPinnedFocusActionResultProviding {
    static let windowID = 2_100_000_001
    static let processIdentifier: pid_t = 42
    static let processStartIdentity: UInt64 = 9_007_199_254_740_993
    static let bounds = CGRect(x: 40, y: 50, width: 640, height: 480)
    static let identity = WindowMutationIdentity(
        windowID: windowID,
        ownerProcessIdentifier: processIdentifier,
        ownerProcessStartIdentity: processStartIdentity,
        capturedBounds: bounds
    )

    private(set) var pinnedFocusCalls: [(target: WindowTarget, identity: WindowMutationIdentity)] = []

    init() {
        super.init(windowsByApp: [
            "Fixture": [
                ServiceWindowInfo(
                    windowID: Self.windowID,
                    title: "Save",
                    bounds: Self.bounds,
                    mutationIdentity: Self.identity
                ),
            ],
        ])
    }

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindowActionResult(target: target, expectedIdentity: Self.identity)
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.pinnedFocusCalls.append((target, expectedIdentity))
        try await self.focusWindow(target: target)
        return try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            ),
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: expectedIdentity,
                bounds: Self.bounds
            ))
        )
    }
}
