import Commander
import PeekabooCore

extension DockCommand {
    // MARK: - Right-Click Dock Item

    @MainActor
    struct RightClickSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @Option(help: "Application name in the Dock")
        var app: String

        @Option(help: "Menu item to select after right-clicking")
        var select: String?

        @Flag(help: "Confirm opening the global Dock context menu")
        var foreground = false
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                guard self.foreground else {
                    throw ActionRefusalError(
                        message: "dock right-click opens global Dock UI and requires explicit foreground consent.",
                        hint: "Use --foreground to allow the Dock context menu to open."
                    )
                }
                let dockItem = try await DockServiceBridge.findDockItem(dock: self.services.dock, name: self.app)
                self.resolvedRuntime.beginInteractionMutation()
                try await DockServiceBridge.rightClickDockItem(
                    dock: self.services.dock,
                    appName: self.app,
                    menuItem: self.select
                )
                let selectionDescription = self.select ?? "context-only"
                AutomationEventLogger.log(.dock, "right_click app=\(dockItem.title) selection=\(selectionDescription)")

                if self.jsonOutput {
                    struct DockRightClickResult: Codable {
                        let action: String
                        let app: String
                        let selectedItem: String
                    }

                    let outputData = DockRightClickResult(
                        action: "dock_right_click",
                        app: dockItem.title,
                        selectedItem: self.select ?? ""
                    )
                    outputSuccessCodable(data: outputData, effect: .confirmed, logger: self.outputLogger)
                } else if let selected = self.select {
                    print("✓ Right-clicked \(dockItem.title) and selected '\(selected)'")
                } else {
                    print("✓ Right-clicked \(dockItem.title) in Dock")
                }
            } catch let error as DockError {
                handleDockServiceError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            } catch {
                self.handleError(error)
                throw ExitCode(1)
            }
        }
    }
}
