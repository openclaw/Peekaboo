import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension DialogCommand {
    // MARK: - Handle File Dialog

    @MainActor
    struct FileSubcommand: ConfirmedActionOutputFormattable, InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "file",
            abstract: "Handle file save/open dialogs using DialogService"
        )

        @Option(help: "Full file path to navigate to")
        var path: String?

        @Option(help: "File name to enter (for save dialogs)")
        var name: String?

        @Option(help: "Button to click after entering path/name. Omit (or pass 'default') to click the OKButton.")
        var select: String?

        @Flag(name: .long, help: "Ensure file dialogs are expanded (Show Details) before setting --path")
        var ensureExpanded = false

        @Flag(help: "Focus the file dialog before keyboard or coordinate interaction")
        var foreground = false

        @Option(name: .customLong("timeout"), help: "File-dialog timeout (bare values are milliseconds; default 20s)")
        var timeout: CLIDuration = .seconds(20)

        @OptionGroup var target: InteractionTargetOptions
        @OptionGroup var focusOptions: FocusCommandOptions
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let path = self.path
            let name = self.name
            let select = self.select
            let ensureExpanded = self.ensureExpanded
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .required(self.focusOptions),
                resolveWindowTitle: false,
                handlesPeekabooError: true,
                validate: {
                    guard self.foreground else {
                        throw ValidationError(
                            "dialog file uses keyboard/coordinate interaction and requires --foreground"
                        )
                    }
                },
                operation: { context in
                    let result = try await withMainActorCommandTimeout(
                        seconds: self.timeout.seconds,
                        operationName: "dialog file",
                        desktopMutationWatermarkStore: DesktopMutationWatermarkStore()
                    ) {
                        try await context.services.dialogs.handleFileDialog(
                            path: path,
                            filename: name,
                            actionButton: select,
                            ensureExpanded: ensureExpanded,
                            appName: context.appHint
                        )
                    }
                    let outcome = result.foregroundOutcomeOrUnverified(
                        route: context.services.dialogs.foregroundOutcomeRoute
                    )
                    let targetIdentity: DesktopTargetIdentity?
                    do {
                        targetIdentity = try DialogCommand.exactResultTargetIdentity(
                            from: result,
                            matching: context.target
                        )
                    } catch {
                        // The service already returned from the foreground leaf. Preserve that
                        // dispatch while refusing to project setup focus as the file-panel target.
                        try context.actionSequence.recordExactTargetLeaf(
                            outcome: outcome,
                            targetIdentity: nil,
                            operation: "File dialog"
                        )
                        throw error
                    }
                    try context.actionSequence.recordExactTargetLeaf(
                        outcome: outcome,
                        targetIdentity: targetIdentity,
                        operation: "File dialog"
                    )
                    let compositeResult = context.actionSequence.result(payload: ())

                    if self.jsonOutput {
                        outputSuccessCodable(
                            data: self.makeOutput(from: result),
                            outcome: compositeResult.outcome,
                            targetIdentity: compositeResult.targetIdentity,
                            logger: self.outputLogger
                        )
                    } else {
                        print(ActionOutcomeHumanRenderer.statusLine(
                            for: compositeResult.outcome ?? outcome,
                            operation: "File dialog"
                        ))
                        if let path = result.details["path"] {
                            print("  Path: \(path)")
                        }
                        if let name = result.details["filename"] {
                            print("  Name: \(name)")
                        }
                        print("  Action: \(result.details["button_clicked"] ?? self.select ?? "default")")
                        if let savedPath = result.details["saved_path"], result.details["saved_path_exists"] == "true" {
                            print("  Saved: \(savedPath)")
                        }
                    }
                    let resolvedPath = result.details["path"] ?? self.path ?? "unknown"
                    let resolvedName = result.details["filename"] ?? self.name ?? "unknown"
                    let buttonClicked = result.details["button_clicked"] ?? self.select ?? "default"
                    let savedPath = result.details["saved_path"] ?? "unknown"
                    let savedPathVerified = result.details["saved_path_exists"] ?? "unknown"
                    AutomationEventLogger.log(
                        .dialog,
                        "action=file path='\(resolvedPath)' name='\(resolvedName)' "
                            + "button='\(buttonClicked)' saved_path='\(savedPath)' "
                            + "saved_path_verified=\(savedPathVerified) app='\(context.appHint ?? "unknown")'"
                    )
                }
            )
        }

        private func makeOutput(from result: DialogActionResult) -> FileDialogResult {
            let savedPathVerified =
                result.details["saved_path_verified"] == "true" || result.details["saved_path_exists"] == "true"

            return FileDialogResult(
                action: "file_dialog",
                dialogIdentifier: result.details["dialog_identifier"],
                foundVia: result.details["found_via"],
                path: result.details["path"],
                pathNavigationMethod: result.details["path_navigation_method"],
                name: result.details["filename"],
                buttonClicked: result.details["button_clicked"] ?? self.select ?? "default",
                buttonIdentifier: result.details["button_identifier"],
                savedPath: result.details["saved_path"],
                savedPathVerified: savedPathVerified,
                savedPathFoundVia: result.details["saved_path_found_via"],
                savedPathMatchesExpected: result.details["saved_path_matches_expected"].map { $0 == "true" },
                savedPathExpected: result.details["saved_path_expected"],
                savedPathMatchesExpectedDirectory: result.details["saved_path_matches_expected_directory"]
                    .map { $0 == "true" },
                savedPathExpectedDirectory: result.details["saved_path_expected_directory"],
                savedPathDirectory: result.details["saved_path_directory"],
                overwriteConfirmed: result.details["overwrite_confirmed"].map { $0 == "true" },
                ensureExpanded: result.details["ensure_expanded"].map { $0 == "true" }
            )
        }
    }
}

private struct FileDialogResult: Codable {
    let action: String
    let dialogIdentifier: String?
    let foundVia: String?
    let path: String?
    let pathNavigationMethod: String?
    let name: String?
    let buttonClicked: String
    let buttonIdentifier: String?
    let savedPath: String?
    let savedPathVerified: Bool
    let savedPathFoundVia: String?
    let savedPathMatchesExpected: Bool?
    let savedPathExpected: String?
    let savedPathMatchesExpectedDirectory: Bool?
    let savedPathExpectedDirectory: String?
    let savedPathDirectory: String?
    let overwriteConfirmed: Bool?
    let ensureExpanded: Bool?

    enum CodingKeys: String, CodingKey {
        case action
        case dialogIdentifier = "dialog_identifier"
        case foundVia = "found_via"
        case path
        case pathNavigationMethod = "path_navigation_method"
        case name
        case buttonClicked
        case buttonIdentifier = "button_identifier"
        case savedPath
        case savedPathVerified
        case savedPathFoundVia = "saved_path_found_via"
        case savedPathMatchesExpected = "saved_path_matches_expected"
        case savedPathExpected = "saved_path_expected"
        case savedPathMatchesExpectedDirectory = "saved_path_matches_expected_directory"
        case savedPathExpectedDirectory = "saved_path_expected_directory"
        case savedPathDirectory = "saved_path_directory"
        case overwriteConfirmed = "overwrite_confirmed"
        case ensureExpanded = "ensure_expanded"
    }
}
