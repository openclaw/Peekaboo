import Commander
import Foundation
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
struct RunCommand: OutputFormattable {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "run",
                abstract: "Execute a Peekaboo automation script",
                showHelpOnEmptyInvocation: true
            )
        }
    }

    @Argument(help: "Path to the script file (.peekaboo.json)")
    var scriptPath: String

    @Option(help: "Save results to file (JSON mode also emits stdout)")
    var output: String?

    @Flag(help: "Continue execution even if a step fails")
    var noFailFast = false
    @RuntimeStorage private var runtime: CommandRuntime?

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    var outputLogger: Logger {
        self.logger
    }

    private var configuration: CommandRuntime.Configuration {
        self.resolvedRuntime.configuration
    }

    var jsonOutput: Bool {
        self.configuration.jsonOutput
    }

    private var isVerbose: Bool {
        self.configuration.verbose
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()
        var didEmitJSONResponse = false

        do {
            let resolvedScriptPath = resolvedScriptPath()
            let script = try await ProcessServiceBridge.loadScript(services: self.services, path: resolvedScriptPath)
            switch Self.finalSnapshotEffect(in: script) {
            case .none:
                break
            case .mutation, .freshObservation:
                self.resolvedRuntime.beginInteractionMutation()
            }
            let results = try await ProcessServiceBridge.executeScript(
                services: self.services,
                script,
                failFast: !self.noFailFast,
                verbose: self.isVerbose
            )
            if let freshObservation = Self.terminalFreshObservation(in: script, results: results) {
                self.resolvedRuntime.preserveFreshObservation(
                    snapshotId: freshObservation.snapshotId,
                    startedAt: freshObservation.confirmedMutationCompletedAt ?? freshObservation.startedAt,
                    preservedAt: freshObservation.completedAt,
                    preservationAllowed: freshObservation.preservationAllowed
                )
            }

            let output = ScriptExecutionResult(
                success: results.allSatisfy(\.success),
                scriptPath: resolvedScriptPath,
                description: script.description,
                totalSteps: script.steps.count,
                completedSteps: results.count { $0.success },
                failedSteps: results.count { !$0.success },
                executionTime: Date().timeIntervalSince(startTime),
                steps: results
            )

            if let outputPath = self.output {
                let resolvedOutputPath = resolvedOutputPath(from: outputPath)
                let data = try JSONEncoder().encode(output)
                try data.write(to: URL(fileURLWithPath: resolvedOutputPath), options: .atomic)
                if !self.jsonOutput {
                    print("✅ Script completed. Results saved to: \(resolvedOutputPath)")
                }
            }

            if self.jsonOutput {
                let response = CodableJSONResponse(
                    success: output.success,
                    data: output,
                    messages: nil,
                    debug_logs: self.outputLogger.getDebugLogs()
                )
                outputJSONCodable(response, logger: self.outputLogger)
                didEmitJSONResponse = true
            } else if self.output == nil {
                self.printSummary(output)
            }

            if !output.success {
                throw ExitCode.failure
            }
        } catch let error as ExitCode {
            // RunCommand intentionally exits non-zero when a step fails. In JSON mode we already emitted
            // a structured payload, so don't print a second JSON error wrapper.
            if didEmitJSONResponse {
                throw error
            }
            throw ExitCode.failure
        } catch {
            if self.jsonOutput {
                outputError(message: error.localizedDescription, code: .INVALID_ARGUMENT, logger: self.outputLogger)
            } else {
                print("❌ Error: \(error.localizedDescription)")
            }
            throw ExitCode.failure
        }
    }

    func resolvedScriptPath() -> String {
        PathResolver.expandPath(self.scriptPath)
    }

    func resolvedOutputPath(from outputPath: String) -> String {
        PathResolver.expandPath(outputPath)
    }

    enum ScriptFinalSnapshotEffect: Equatable {
        case none
        case mutation
        case freshObservation
    }

    static func finalSnapshotEffect(in script: PeekabooScript) -> ScriptFinalSnapshotEffect {
        var effect = ScriptFinalSnapshotEffect.none
        for step in script.steps {
            switch step.command.lowercased() {
            case "sleep":
                continue
            case "see":
                effect = self.isFreshObservationStep(step) ? .freshObservation : .mutation
            case "dock":
                if self.isReadOnlyDockStep(step) {
                    continue
                }
                effect = .mutation
            case "clipboard":
                if self.isReadOnlyClipboardStep(step) {
                    continue
                }
                effect = .mutation
            default:
                effect = .mutation
            }
        }
        return effect
    }

    private static func isFreshObservationStep(_ step: ScriptStep) -> Bool {
        guard step.command.lowercased() == "see" else { return false }
        let annotate: Bool? = switch step.params {
        case let .screenshot(parameters):
            parameters.annotate
        case let .generic(parameters):
            parameters["annotate"].flatMap { Bool($0) }
        default:
            nil
        }
        return annotate ?? true
    }

    private static func isReadOnlyClipboardStep(_ step: ScriptStep) -> Bool {
        let action: String? = switch step.params {
        case let .clipboard(parameters):
            parameters.action
        case let .generic(parameters):
            parameters["action"]
        default:
            nil
        }
        guard let action else { return false }
        return ["get", "save"].contains(action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func isReadOnlyDockStep(_ step: ScriptStep) -> Bool {
        let action: String? = switch step.params {
        case let .dock(parameters):
            parameters.action
        case let .generic(parameters):
            parameters["action"]
        default:
            nil
        }
        return action?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "list"
    }

    struct TerminalFreshObservation {
        let snapshotId: String
        let startedAt: Date
        let completedAt: Date
        let confirmedMutationCompletedAt: Date?
        let preservationAllowed: Bool
    }

    static func terminalFreshObservation(
        in script: PeekabooScript,
        results: [StepResult]
    ) -> TerminalFreshObservation? {
        guard self.finalSnapshotEffect(in: script) == .freshObservation,
              results.count == script.steps.count,
              results.allSatisfy(\.success),
              let observationIndex = script.steps.lastIndex(where: { self.isFreshObservationStep($0) })
        else { return nil }
        let result = results[observationIndex]
        guard result.command.lowercased() == "see",
              let snapshotId = result.snapshotId,
              let startedAt = result.startedAt
        else { return nil }
        return TerminalFreshObservation(
            snapshotId: snapshotId,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(result.executionTime),
            confirmedMutationCompletedAt: result.desktopMutationCompletedAt,
            preservationAllowed: result.desktopMutationPreservationAllowed ?? true
        )
    }

    @MainActor
    private func printSummary(_ result: ScriptExecutionResult) {
        if result.success {
            print("✅ Script completed successfully")
        } else {
            print("❌ Script failed")
        }
        print("   Total steps: \(result.totalSteps)")
        print("   Completed: \(result.completedSteps)")
        print("   Failed: \(result.failedSteps)")
        print("   Execution time: \(String(format: "%.2f", result.executionTime))s")

        if !result.success {
            let failedSteps = result.steps.filter { !$0.success }
            if !failedSteps.isEmpty {
                print("\nFailed steps:")
                for step in failedSteps {
                    print("   - Step \(step.stepNumber) (\(step.command)): \(step.error ?? "Unknown error")")
                }
            }
        }
    }
}

struct ScriptExecutionResult: Codable {
    let success: Bool
    let scriptPath: String
    let description: String?
    let totalSteps: Int
    let completedSteps: Int
    let failedSteps: Int
    let executionTime: TimeInterval
    let steps: [PeekabooCore.StepResult]
}

private enum ProcessServiceBridge {
    static func loadScript(services: any PeekabooServiceProviding, path: String) async throws -> PeekabooScript {
        try await Task { @MainActor in
            try await services.process.loadScript(from: path)
        }.value
    }

    static func executeScript(
        services: any PeekabooServiceProviding,
        _ script: PeekabooScript,
        failFast: Bool,
        verbose: Bool
    ) async throws -> [StepResult] {
        try await Task { @MainActor in
            try await services.process.executeScript(script, failFast: failFast, verbose: verbose)
        }.value
    }
}

@MainActor
extension RunCommand: ParsableCommand {}
extension RunCommand: AsyncRuntimeCommand {}

@MainActor
extension RunCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.scriptPath = try values.decodePositional(0, label: "scriptPath")
        self.output = try values.decodeOption("output", as: String.self)
        self.noFailFast = values.flag("noFailFast")
    }
}
