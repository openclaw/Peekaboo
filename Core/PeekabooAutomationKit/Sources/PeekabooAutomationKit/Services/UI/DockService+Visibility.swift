import Foundation
import PeekabooFoundation

struct DockVisibilityCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let captureOutput: Bool

    static let readAutohide = DockVisibilityCommand(
        executable: "/usr/bin/defaults",
        arguments: ["read", "com.apple.dock", "autohide"],
        captureOutput: true)

    static func writeAutohide(_ enabled: Bool) -> DockVisibilityCommand {
        DockVisibilityCommand(
            executable: "/usr/bin/defaults",
            arguments: ["write", "com.apple.dock", "autohide", "-bool", enabled ? "true" : "false"],
            captureOutput: false)
    }

    static let restartDock = DockVisibilityCommand(
        executable: "/usr/bin/killall",
        arguments: ["Dock"],
        captureOutput: false)
}

struct DockVisibilityCommandFailure: Error, Equatable, Sendable {
    let command: DockVisibilityCommand
    let terminationStatus: Int32
    let standardError: String

    var isMissingAutohidePreference: Bool {
        guard self.command == .readAutohide, self.terminationStatus == 1 else { return false }
        return self.standardError
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("The domain/default pair of (com.apple.dock, autohide) does not exist")
    }

    var peekabooError: PeekabooError {
        let detail = self.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty ? "exit status \(self.terminationStatus)" : detail
        return .operationError(message: "Command execution failed: \(message)")
    }
}

typealias DockVisibilityCommandRunner = @MainActor @Sendable (DockVisibilityCommand) async throws -> String

@MainActor
extension DockService {
    public func hideDockActionResult() async throws -> DesktopActionResult<Void> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.setDockVisibilityActionResult(hidden: true)
        }
    }

    public func showDockActionResult() async throws -> DesktopActionResult<Void> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.setDockVisibilityActionResult(hidden: false)
        }
    }

    func hideDockImpl() async throws {
        _ = try await self.setDockVisibilityActionResult(hidden: true)
    }

    func showDockImpl() async throws {
        _ = try await self.setDockVisibilityActionResult(hidden: false)
    }

    func isDockAutoHiddenImpl() async -> Bool {
        do {
            return try await self.readDockAutoHidden()
        } catch {
            return false
        }
    }

    private func setDockVisibilityActionResult(hidden: Bool) async throws -> DesktopActionResult<Void> {
        if try await self.readDockAutoHidden() == hidden {
            return DesktopActionResult(outcome: .confirmedNoChange())
        }
        try Self.checkDockDispatchCancellation()

        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        let unitCount = DesktopActionOutcome.DispatchUnitCount(2)
        try await self.setDockAutohide(hidden)
        do {
            let confirmed = try await self.readDockAutoHidden() == hidden
            return DesktopActionResult(outcome: confirmed
                ? .confirmedChange(delivery: delivery, unitCount: unitCount)
                : .suspectedNoop(delivery: delivery, unitCount: unitCount))
        } catch {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: unitCount,
                message: "Dock visibility was updated, but the resulting preference could not be verified.",
                hint: "Observe Dock visibility before retrying.",
                causeDescription: String(describing: error))
        }
    }

    private func readDockAutoHidden() async throws -> Bool {
        let output: String
        do {
            output = try await self.dockVisibilityCommandRunner(.readAutohide)
        } catch let failure as DockVisibilityCommandFailure {
            guard failure.isMissingAutohidePreference else {
                throw failure.peekabooError
            }
            return false
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "0", "false":
            return false
        case "1", "true":
            return true
        default:
            throw PeekabooError.operationError(
                message: "Could not parse Dock autohide preference value '\(trimmed)'; expected 0, 1, false, or true.")
        }
    }

    private func setDockAutohide(_ enabled: Bool) async throws {
        try Self.checkDockDispatchCancellation()
        _ = try await self.runCommand(.writeAutohide(enabled))
        do {
            try Task.checkCancellation()
            _ = try await self.runCommand(.restartDock)
        } catch {
            throw DesktopActionFailure.partial(
                delivery: .init(mechanism: .nativeFramework, mode: .background),
                unitCount: .one,
                message: "The Dock autohide preference was written, but Dock could not be restarted.",
                hint: "Observe Dock visibility and restart Dock before retrying.",
                causeDescription: String(describing: error))
        }
    }

    private func runCommand(_ command: DockVisibilityCommand) async throws -> String {
        do {
            return try await self.dockVisibilityCommandRunner(command)
        } catch let failure as DockVisibilityCommandFailure {
            throw failure.peekabooError
        }
    }

    nonisolated static func executeDockVisibilityCommand(_ command: DockVisibilityCommand) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: command.executable)
                process.arguments = command.arguments

                let pipe = Pipe()
                if command.captureOutput {
                    process.standardOutput = pipe
                }
                process.standardError = pipe

                try process.run()
                try DockService.waitForProcessExit(process, timeoutSeconds: 15)

                if process.terminationStatus != 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let error = String(data: data, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: DockVisibilityCommandFailure(
                        command: command,
                        terminationStatus: process.terminationStatus,
                        standardError: error))
                } else if command.captureOutput {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(returning: "")
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
