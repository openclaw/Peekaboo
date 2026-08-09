import Commander
import Foundation

@available(macOS 14.0, *)
@MainActor
struct SleepCommand: OutputFormattable, RuntimeBackedCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "sleep",
                abstract: "Pause execution for a specified duration",
                showHelpOnEmptyInvocation: true
            )
        }
    }

    @Argument(help: "Duration to sleep in milliseconds")
    var duration: Int
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()
        self.logger.setJsonOutputMode(self.jsonOutput)

        guard self.duration > 0 else {
            let error = ValidationError("Duration must be positive")
            if self.jsonOutput {
                outputError(message: error.localizedDescription, code: .INVALID_ARGUMENT, logger: self.outputLogger)
            } else {
                var stderrStream = FileHandleTextOutputStream(FileHandle.standardError)
                print("Error: \(error.localizedDescription)", to: &stderrStream)
            }
            throw ExitCode.failure
        }

        try await Task.sleep(nanoseconds: UInt64(self.duration) * 1_000_000)

        let actualDuration = Date().timeIntervalSince(startTime) * 1000
        let result = SleepResult(success: true, requested_duration: duration, actual_duration: Int(actualDuration))
        output(result) {
            let seconds = Double(duration) / 1000.0
            print("✅ Paused for \(seconds)s")
        }
    }
}

struct SleepResult: Codable {
    let success: Bool
    let requested_duration: Int
    let actual_duration: Int
}

@MainActor
extension SleepCommand: ParsableCommand {}
extension SleepCommand: AsyncRuntimeCommand {}

@MainActor
extension SleepCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.duration = try values.decodePositional(0, label: "duration", as: Int.self)
    }
}
