import Algorithms
import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

private typealias ScreenOutput = UnifiedToolOutput<ScreenListData>

/// Display inventory shortcuts.
@MainActor
struct ScreenCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "screen",
        abstract: "Inspect connected displays",
        discussion: """
        Examples:
          peekaboo screen list
          peekaboo screen list --json
        """,
        subcommands: [ListSubcommand.self],
        defaultSubcommand: ListSubcommand.self
    )

    func run() async throws {}

    @MainActor
    struct ListSubcommand: ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            let screens = self.services.screens.listScreens()
            let screenListData = self.buildScreenListData(from: screens)
            let output = UnifiedToolOutput(
                data: screenListData,
                summary: self.buildScreenSummary(for: screens),
                metadata: self.buildScreenMetadata()
            )

            if self.jsonOutput {
                outputSuccessCodable(data: output.data, logger: self.outputLogger)
            } else {
                self.displayScreenDetails(screenListData)
            }
        }

        private func displayScreenDetails(_ data: ScreenListData) {
            Swift.print("Screens (\(data.screens.count) total):")
            for screen in data.screens {
                let primaryBadge = screen.isPrimary ? " (Primary)" : ""
                Swift.print("\n\(screen.index). \(screen.name)\(primaryBadge)")
                Swift.print("   Resolution: \(screen.bounds.width)×\(screen.bounds.height)")
                Swift.print("   Position: \(screen.position.x),\(screen.position.y)")
                let retinaBadge = screen.scaleFactor > 1 ? " (Retina)" : ""
                Swift.print("   Scale: \(screen.scaleFactor)x\(retinaBadge)")
                if screen.visibleBounds != screen.bounds {
                    Swift.print("   Visible Area: \(screen.visibleArea.width)×\(screen.visibleArea.height)")
                    Swift.print("   Visible Position: \(screen.visibleBounds.x),\(screen.visibleBounds.y)")
                }
            }
            Swift.print("\n💡 Use 'peekaboo see --screen-index N' to capture a specific screen")
        }

        func buildScreenListData(from screens: [PeekabooCore.ScreenInfo]) -> ScreenListData {
            let primaryFrame = screens.first(where: \.isPrimary)?.frame
            let details = screens.map { screen in
                let globalBounds = Self.globalBounds(
                    fromAppKit: screen.frame,
                    primaryScreenFrame: primaryFrame
                )
                let visibleBounds = Self.globalBounds(
                    fromAppKit: screen.visibleFrame,
                    primaryScreenFrame: primaryFrame
                )
                return ScreenListData.ScreenDetails(
                    index: screen.index,
                    name: screen.name,
                    resolution: ScreenListData.Resolution(
                        width: Int(screen.frame.width),
                        height: Int(screen.frame.height)
                    ),
                    position: ScreenListData.Position(
                        x: Int(globalBounds.origin.x),
                        y: Int(globalBounds.origin.y)
                    ),
                    bounds: ScreenListData.Bounds(
                        x: Int(globalBounds.origin.x),
                        y: Int(globalBounds.origin.y),
                        width: Int(globalBounds.width),
                        height: Int(globalBounds.height)
                    ),
                    visibleBounds: ScreenListData.Bounds(
                        x: Int(visibleBounds.origin.x),
                        y: Int(visibleBounds.origin.y),
                        width: Int(visibleBounds.width),
                        height: Int(visibleBounds.height)
                    ),
                    visibleArea: ScreenListData.Resolution(
                        width: Int(screen.visibleFrame.width),
                        height: Int(screen.visibleFrame.height)
                    ),
                    isPrimary: screen.isPrimary,
                    scaleFactor: screen.scaleFactor,
                    displayID: Int(screen.displayID)
                )
            }

            return ScreenListData(
                screens: details,
                primaryIndex: screens.firstIndex { $0.isPrimary }
            )
        }

        nonisolated static func globalBounds(
            fromAppKit frame: CGRect,
            primaryScreenFrame: CGRect?
        ) -> CGRect {
            GlobalScreenCoordinateGeometry.globalDisplayRect(
                fromAppKit: frame,
                primaryScreenFrame: primaryScreenFrame
            )
        }

        private func buildScreenSummary(for screens: [PeekabooCore.ScreenInfo]) -> ScreenOutput.Summary {
            let count = screens.count
            let highlights = screens.indexed().compactMap { index, screen in
                screen.isPrimary ? ScreenOutput.Summary.Highlight(
                    label: "Primary",
                    value: "\(screen.name) (Index \(index))",
                    kind: .primary
                ) : nil
            }
            return ScreenOutput.Summary(
                brief: "Found \(count) screen\(count == 1 ? "" : "s")",
                detail: nil,
                status: ScreenOutput.Summary.Status.success,
                counts: ["screens": count],
                highlights: highlights
            )
        }

        private func buildScreenMetadata() -> ScreenOutput.Metadata {
            ScreenOutput.Metadata(
                duration: 0.0,
                warnings: [],
                hints: ["Use 'peekaboo see --screen-index N' to capture a specific screen"]
            )
        }
    }
}

@MainActor
extension ScreenCommand.ListSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "list",
                abstract: "List displays with IDs, bounds, scale, and primary status"
            )
        }
    }
}

extension ScreenCommand.ListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ScreenCommand.ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

struct ScreenListData {
    let screens: [ScreenDetails]
    let primaryIndex: Int?

    struct ScreenDetails {
        let index: Int
        let name: String
        let resolution: Resolution
        let position: Position
        let bounds: Bounds
        let visibleBounds: Bounds
        let visibleArea: Resolution
        let isPrimary: Bool
        let scaleFactor: CGFloat
        let displayID: Int
    }

    struct Resolution {
        let width: Int
        let height: Int
    }

    struct Position {
        let x: Int
        let y: Int
    }

    struct Bounds {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
}

nonisolated extension ScreenListData: Sendable, Codable {}
nonisolated extension ScreenListData.ScreenDetails: Sendable, Codable {}
nonisolated extension ScreenListData.Resolution: Sendable, Codable {}
nonisolated extension ScreenListData.Position: Sendable, Codable {}
nonisolated extension ScreenListData.Bounds: Sendable, Codable, Equatable {}
