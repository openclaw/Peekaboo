import Commander
import Foundation
import PeekabooCore

typealias LiveCaptureMode = PeekabooCore.CaptureMode
typealias LiveCaptureFocus = PeekabooCore.CaptureFocus
typealias LiveCaptureSessionResult = PeekabooCore.CaptureSessionResult

enum CaptureCommandOptionParser {
    static func diffStrategy(_ value: String?) throws -> CaptureOptions.DiffStrategy {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "fast"
        guard let strategy = CaptureOptions.DiffStrategy(rawValue: normalized) else {
            throw ValidationError("Unsupported diff strategy '\(value ?? "")'. Use fast or quality.")
        }
        return strategy
    }
}

@MainActor
struct CaptureCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "capture",
                abstract: "Capture live screens/windows or ingest a video and extract frames",
                subcommands: [
                    CaptureLiveCommand.self,
                    CaptureActionCommand.self,
                    CaptureVideoCommand.self,
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}
