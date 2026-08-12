import Commander
import Dispatch
import Foundation

// MARK: - Runtime Command Protocol

/// A command whose request-only safety checks can run before runtime-host selection.
@MainActor
protocol PreRuntimeValidatingCommand: ParsableCommand {
    func validateBeforeRuntime() throws
}

/// Protocol for commands that accept runtime context injection.
/// Commands conforming to this protocol receive a `CommandRuntime` instance
/// containing logger, services, and configuration instead of accessing singletons.
protocol AsyncRuntimeCommand: ParsableCommand {
    /// Run the command with injected runtime context.
    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws
}

extension AsyncRuntimeCommand {
    /// Default synchronous run() implementation that builds the runtime context
    /// and executes the async implementation on the main actor.
    mutating func run() throws {
        var commandCopy = self
        let semaphore = DispatchSemaphore(value: 0)
        var thrownError: (any Error)?

        Task { @MainActor in
            do {
                let runtime = try await CommandRuntime.makeDefaultAsync()
                try await commandCopy.run(using: runtime)
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }

        semaphore.wait()
        self = commandCopy
        if let error = thrownError {
            throw error
        }
    }
}
