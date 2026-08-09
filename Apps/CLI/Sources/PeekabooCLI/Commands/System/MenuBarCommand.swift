import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Command for interacting with macOS menu bar items (status items).
@MainActor
struct MenuBarActionCommand: ErrorHandlingCommand, OutputFormattable, InjectedRuntimeBackedCommand {
    var action: String

    @Argument(help: "Name of the menu bar item to click (for click action)")
    var itemName: String?

    @Option(help: "0-based index shown by 'peekaboo menubar list' or 'peekaboo list menubar'")
    var index: Int?

    @Flag(help: "Include raw debug fields (window owner/layer) in JSON output")
    var includeRawDebug: Bool = false

    @Flag(help: "Verify the click by checking for a matching popover window")
    var verify: Bool = false
    @RuntimeStorage var runtime: CommandRuntime?

    private var configuration: CommandRuntime.Configuration {
        self.resolvedRuntime.configuration
    }

    private var isVerbose: Bool {
        self.configuration.verbose
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
            let verifyTarget = try await self.resolveVerificationTargetIfNeeded()
            let verifier = MenuBarClickVerifier(services: self.services)
            let focusSnapshot = self.verify ? try await verifier.captureFocusSnapshot() : nil
            let result: PeekabooCore.ClickResult
            if let idx = self.index {
                self.resolvedRuntime.beginInteractionMutation()
                result = try await MenuServiceBridge.clickMenuBarItem(at: idx, menu: self.services.menu)
            } else if let name = self.itemName {
                self.resolvedRuntime.beginInteractionMutation()
                result = try await MenuServiceBridge.clickMenuBarItem(named: name, menu: self.services.menu)
            } else {
                throw PeekabooError.invalidInput("Please provide either a menu bar item name or use --index")
            }

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

            if self.jsonOutput {
                let output = ClickJSONOutput(
                    success: true,
                    clicked: result.elementDescription,
                    executionTime: Date().timeIntervalSince(startTime),
                    verified: verification?.verified
                )
                outputSuccessCodable(data: output, logger: self.outputLogger)
            } else {
                print("✅ Clicked menu bar item: \(result.elementDescription)")
                if let verification {
                    print("🔎 Verified menu bar click (\(verification.method))")
                }
                if self.isVerbose {
                    print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
                }
            }
        } catch {
            if self.jsonOutput {
                self.handleError(error)
                throw ExitCode(1)
            } else {
                // Provide helpful hints for common errors
                if error.localizedDescription.contains("not found") {
                    print("❌ Error: \(error.localizedDescription)")
                    print("\n💡 Hints:")
                    print("  • Menu bar items often require clicking on their icon coordinates")
                    print("  • Try 'peekaboo see' first to get element IDs")
                    print("  • Use 'peekaboo menubar list' to see available items")
                    throw ExitCode(1)
                } else {
                    throw error
                }
            }
        }
    }

    private func resolveVerificationTargetIfNeeded() async throws -> MenuBarVerifyTarget? {
        guard self.verify else { return nil }

        let items = try await MenuServiceBridge.listMenuBarItems(
            menu: self.services.menu,
            includeRaw: true
        )

        if let idx = self.index {
            guard let item = items.first(where: { $0.index == idx }) else {
                throw PeekabooError.invalidInput("Menu bar item index \(idx) is out of range")
            }
            return MenuBarVerifyTarget(
                title: item.title ?? item.rawTitle,
                ownerPID: item.rawOwnerPID,
                ownerName: item.ownerName,
                bundleIdentifier: item.bundleIdentifier,
                preferredX: item.frame?.midX
            )
        }

        guard let name = self.itemName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw PeekabooError.invalidInput("Please provide a menu bar item name or use --index")
        }

        guard let item = matchMenuBarItem(named: name, items: items) else {
            throw PeekabooError.operationError(message: "Unable to resolve '\(name)' for verification")
        }

        return MenuBarVerifyTarget(
            title: item.title ?? item.rawTitle ?? name,
            ownerPID: item.rawOwnerPID,
            ownerName: item.ownerName,
            bundleIdentifier: item.bundleIdentifier,
            preferredX: item.frame?.midX
        )
    }
}

// MARK: - JSON Output Types

private struct ClickJSONOutput: Codable {
    let success: Bool
    let clicked: String
    let executionTime: TimeInterval
    let verified: Bool?
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

    struct ClickSubcommand: RuntimeBackedCommand {
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

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = MenuBarActionCommand(action: "click")
            command.itemName = self.itemName
            command.index = self.index
            command.verify = self.verify
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
    }
}
