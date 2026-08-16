import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

private enum MenuBarClickPreflight {
    static let foregroundConsentRequired = PreDispatchActionError(
        message: "Menu bar clicks require --foreground because status items open global UI.",
        code: .VALIDATION_ERROR,
        hint: "Re-run with --foreground only when interrupting the user's menu bar is acceptable. " +
            "Use 'peekaboo menubar list' for read-only discovery.",
        reason: .foregroundConsentRequired
    )

    static func itemNotFound(_ item: String, hint: String) -> PreDispatchActionError {
        PreDispatchActionError(
            message: "Menu bar item not found: \(item)",
            code: .MENU_ITEM_NOT_FOUND,
            hint: hint,
            reason: .targetUnavailable
        )
    }
}

private struct ResolvedMenuBarClickTarget {
    let item: MenuBarItemInfo
    let normalizedSelector: String
    let matchKind: DesktopSelectedLeafEvidence.MatchKind
}

/// Command for interacting with macOS menu bar items (status items).
@MainActor
struct MenuBarActionCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
InjectedRuntimeBackedCommand {
    var action: String

    @Argument(help: "Name of the menu bar item to click (for click action)")
    var itemName: String?

    @Option(help: "0-based index shown by 'peekaboo menubar list'")
    var index: Int?

    @Flag(help: "Include raw debug fields (window owner/layer) in JSON output")
    var includeRawDebug: Bool = false

    @Flag(help: "Verify the click by checking for a matching popover window")
    var verify: Bool = false

    @Flag(help: "Allow opening global menu bar UI (required for click)")
    var foreground: Bool = false
    @RuntimeStorage var runtime: CommandRuntime?

    private var configuration: CommandRuntime.Configuration {
        self.resolvedRuntime.configuration
    }

    private var isVerbose: Bool {
        self.configuration.verbose
    }

    var defaultEffect: ActionEffect? {
        self.action.lowercased() == "click" ? .unverifiable : nil
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        switch self.action.lowercased() {
        case "list":
            try await self.listMenuBarItems()
        case "click":
            try await self.clickMenuBarItem()
        default:
            throw PeekabooError.invalidInput("Unknown action '\(self.action)'. Use 'list' or 'click'.")
        }
    }

    @MainActor
    private func listMenuBarItems() async throws {
        do {
            self.logger.debug("Listing menu bar items includeRawDebug=\(self.includeRawDebug)")
            let menuBarItems = try await MenuServiceBridge.listMenuBarItems(
                menu: self.services.menu,
                includeRaw: self.includeRawDebug
            )

            if self.jsonOutput {
                MenuBarItemListOutput.outputJSON(items: menuBarItems, logger: self.outputLogger)
            } else {
                MenuBarItemListOutput.display(menuBarItems)
                if !menuBarItems.isEmpty {
                    print("\n💡 Tip: Use 'peekaboo menubar click --index <index>' or click by name")
                }
            }
        } catch {
            self.handleError(error)
            throw ExitCode(1)
        }
    }

    @MainActor
    private func clickMenuBarItem() async throws {
        let startTime = Date()

        do {
            guard self.foreground else {
                throw MenuBarClickPreflight.foregroundConsentRequired
            }

            let resolvedTarget = try await self.resolveClickTarget()
            let resolvedItem = resolvedTarget.item
            let verifyTarget = self.verify ? Self.makeVerificationTarget(from: resolvedItem) : nil
            let verifier = MenuBarClickVerifier(services: self.services)
            let focusSnapshot = self.verify ? try await verifier.captureFocusSnapshot() : nil
            self.resolvedRuntime.beginInteractionMutation()
            let actionResult: UIAutomationActionResult<PeekabooCore.ClickResult>
            if let baseEvidence = resolvedItem.selectionEvidence {
                let evidence = try baseEvidence.selecting(
                    normalizedSelector: resolvedTarget.normalizedSelector,
                    matchKind: resolvedTarget.matchKind
                )
                let request: MenuBarItemActionRequest
                if let idx = self.index {
                    request = try MenuBarItemActionRequest(index: idx, expectedLeafEvidence: evidence)
                } else if let name = self.itemName {
                    request = try MenuBarItemActionRequest(named: name, expectedLeafEvidence: evidence)
                } else {
                    throw PreDispatchActionError(
                        message: "Provide a menu bar item name or use --index.",
                        code: .VALIDATION_ERROR,
                        hint: "Run 'peekaboo menubar list' to discover available status items.",
                        reason: .invalidRequest
                    )
                }
                actionResult = try await MenuServiceBridge.clickMenuBarItem(
                    request: request,
                    menu: self.services.menu
                )
            } else if let idx = self.index {
                // Receiptless providers retain legacy compatibility, but current concrete services
                // always publish selected-leaf evidence and take the exact request path above.
                actionResult = try await MenuServiceBridge.clickMenuBarItem(at: idx, menu: self.services.menu)
            } else if let name = self.itemName {
                // Keep name-based dispatch bound to the name. Reusing the preflight index
                // could click a different global item if status items reorder between calls.
                actionResult = try await MenuServiceBridge.clickMenuBarItem(named: name, menu: self.services.menu)
            } else {
                throw PreDispatchActionError(
                    message: "Provide a menu bar item name or use --index.",
                    code: .VALIDATION_ERROR,
                    hint: "Run 'peekaboo menubar list' to discover available status items.",
                    reason: .invalidRequest
                )
            }
            let result = actionResult.payload
            let resultTargetIdentity = try validatedSuccessfulActionResult(
                actionResult,
                operation: "Menu bar click",
                requiresTarget: self.services.menu is any MenuServiceActionResultProviding
            )

            try await withPreservedActionResultOnFailure(
                actionResult,
                targetIdentity: resultTargetIdentity,
                operation: "Menu bar click"
            ) {
                let verification: MenuBarClickVerification?
                if self.verify {
                    guard let verifyTarget else {
                        throw PeekabooError
                            .operationError(message: "Menu bar verification requested but no target resolved")
                    }
                    verification = try await verifier.verifyClick(
                        target: verifyTarget,
                        preFocus: focusSnapshot,
                        clickLocation: result.location
                    )
                } else {
                    verification = nil
                }
                let outputOutcome = verification?.verified == true
                    ? canonicalActionOutcomeAfterSuccessfulVerification(actionResult.outcome)
                    : actionResult.outcome

                if self.jsonOutput {
                    let output = ClickJSONOutput(
                        success: true,
                        clicked: result.elementDescription,
                        executionTime: Date().timeIntervalSince(startTime),
                        verified: verification?.verified,
                        selectedLeafEvidence: actionResult.selectedLeafEvidence
                    )
                    outputSuccessCodable(
                        data: output,
                        effect: verification?.verified == true ? .confirmed : .unverifiable,
                        outcome: outputOutcome,
                        targetIdentity: resultTargetIdentity,
                        logger: self.outputLogger
                    )
                } else if let outputOutcome {
                    print(ActionOutcomeHumanRenderer.statusLine(for: outputOutcome, operation: "Menu bar click"))
                } else {
                    print("✅ Clicked menu bar item: \(result.elementDescription)")
                    if let verification {
                        print("🔎 Verified menu bar click (\(verification.method))")
                    }
                    if self.isVerbose {
                        print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
                    }
                }
            }
        } catch {
            self.handleError(error)
            throw ExitCode(1)
        }
    }

    private func resolveClickTarget() async throws -> ResolvedMenuBarClickTarget {
        let requestedName: String?
        if self.index == nil {
            guard let name = self.itemName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                throw PreDispatchActionError(
                    message: "Provide a menu bar item name or use --index.",
                    code: .VALIDATION_ERROR,
                    hint: "Run 'peekaboo menubar list' to discover available status items.",
                    reason: .invalidRequest
                )
            }
            requestedName = name
        } else {
            requestedName = nil
        }

        let items = try await MenuServiceBridge.listMenuBarItems(
            menu: self.services.menu,
            includeRaw: self.verify
        )

        if let idx = self.index {
            let selection: DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
            do {
                selection = try MenuBarItemSelector.select(index: idx, from: items)
            } catch {
                throw MenuBarClickPreflight.itemNotFound(
                    "index \(idx)",
                    hint: "Run 'peekaboo menubar list' and retry with a current index."
                )
            }
            return ResolvedMenuBarClickTarget(
                item: selection.candidate.value,
                normalizedSelector: selection.normalizedSelector,
                matchKind: selection.matchKind
            )
        }

        let name = requestedName ?? ""
        let selection: DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
        do {
            selection = try MenuBarItemSelector.select(named: name, from: items)
        } catch let error as DesktopLeafSelectionError {
            if case .notFound = error {
                throw MenuBarClickPreflight.itemNotFound(
                    name,
                    hint: "Run 'peekaboo menubar list' and retry with an exact current name or index."
                )
            }
            throw PreDispatchActionError(
                message: error.localizedDescription,
                code: .VALIDATION_ERROR,
                hint: "Use an exact current item name or --index.",
                reason: .invalidRequest
            )
        }
        return ResolvedMenuBarClickTarget(
            item: selection.candidate.value,
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind
        )
    }

    private static func makeVerificationTarget(from item: MenuBarItemInfo) -> MenuBarVerifyTarget {
        MenuBarVerifyTarget(
            title: item.title ?? item.rawTitle,
            ownerPID: item.rawOwnerPID,
            ownerName: item.ownerName,
            bundleIdentifier: item.bundleIdentifier,
            preferredX: item.frame?.midX
        )
    }
}

private struct ClickJSONOutput: Codable {
    let success: Bool
    let clicked: String
    let executionTime: TimeInterval
    let verified: Bool?
    let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?
}

@MainActor
struct MenuBarCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "menubar",
                abstract: "Interact with macOS menu bar status items",
                discussion: """
                List status items or click one by fuzzy title match or list index.
                Application menus such as File and Edit are handled by `peekaboo menu`.
                Clicking a status item requires explicit `--foreground` consent because it opens global UI.
                """,
                subcommands: [ListSubcommand.self, ClickSubcommand.self],
                showHelpOnEmptyInvocation: true
            )
        }
    }

    struct ListSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "list",
            abstract: "List menu bar status items"
        )

        @Flag(name: .long, help: "Include raw debug fields (window owner/layer) in JSON output")
        var includeRawDebug = false

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = MenuBarActionCommand(action: "list")
            command.includeRawDebug = self.includeRawDebug
            try await command.run(using: runtime)
        }
    }

    struct ClickSubcommand: ActionOutputFormattable, RuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "click",
            abstract: "Click a menu bar status item"
        )

        @Argument(help: "Menu bar item name (exact or fuzzy match)")
        var itemName: String?

        @Option(name: .long, help: "0-based index shown by `peekaboo menubar list`")
        var index: Int?

        @Flag(name: .long, help: "Verify the click by checking for a matching popover window")
        var verify = false

        @Flag(name: .long, help: "Allow opening global menu bar UI (required)")
        var foreground = false

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = MenuBarActionCommand(action: "click")
            command.itemName = self.itemName
            command.index = self.index
            command.verify = self.verify
            command.foreground = self.foreground
            try await command.run(using: runtime)
        }
    }
}

extension MenuBarCommand.ListSubcommand: AsyncRuntimeCommand {}
extension MenuBarCommand.ClickSubcommand: AsyncRuntimeCommand {}

@MainActor
extension MenuBarCommand.ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.includeRawDebug = values.flag("includeRawDebug")
    }
}

@MainActor
extension MenuBarCommand.ClickSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.itemName = try values.decodeOptionalPositional(0, label: "itemName")
        self.index = try values.decodeOption("index", as: Int.self)
        self.verify = values.flag("verify")
        self.foreground = values.flag("foreground")
        if self.itemName != nil, self.index != nil {
            throw CommanderBindingError.invalidArgument(
                label: "item-name or --index",
                value: "both",
                reason: "Provide a menu bar item either by name or by --index, not both"
            )
        }
        guard self.itemName != nil || self.index != nil else {
            throw CommanderBindingError.missingArgument(label: "item-name or --index")
        }
        guard self.foreground else {
            throw MenuBarClickPreflight.foregroundConsentRequired
        }
    }
}
