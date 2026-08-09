import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
struct OpenCommand: ParsableCommand, OutputFormattable, ErrorHandlingCommand, RuntimeBackedCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "open",
                abstract: "Open a URL or file with its default (or specified) application",
                discussion: """
                Mirrors macOS `open` but adds Peekaboo’s quality-of-life features:

                - `--app` / `--bundle-id` to force a handler
                - `--wait-until-ready` to block until the app reports it has finished launching
                - background delivery by default; `--foreground` activates the handler
                - `--json` for structured scripting (alias: `--json-output`)

                EXAMPLES:
                  peekaboo open https://example.com --json
                  peekaboo open ~/Documents/report.pdf --app "Preview"
                  peekaboo open myfile.txt --bundle-id com.apple.TextEdit --wait-until-ready
                  peekaboo open ~/Desktop --app Finder
                  peekaboo open https://example.com --foreground
                """,
                showHelpOnEmptyInvocation: true
            )
        }
    }

    @Argument(help: "URL or file path to open")
    var target: String

    @Option(help: "Explicit application (name or path) to handle the target")
    var app: String?

    @Option(help: "Bundle identifier of the application to handle the target")
    var bundleId: String?

    @Flag(help: "Wait until the handling application finishes launching")
    var waitUntilReady = false

    @Flag(help: "Bring the handling application to the foreground")
    var foreground = false

    @Flag(name: .customLong("no-focus"), help: "Deprecated compatibility flag; background open is now the default")
    var noFocus = false

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var shouldFocus: Bool {
        self.foreground
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.prepare(using: runtime)

        do {
            guard !(self.foreground && self.noFocus) else {
                throw ValidationError("--foreground cannot be combined with deprecated --no-focus")
            }
            if self.noFocus {
                self.logger.warn("--no-focus is deprecated because open is background by default")
            }
            let targetURL = try Self.resolveTarget(self.target)
            let handlerIdentifier = self.bundleId == nil
                ? app.map { ApplicationIdentifierResolver.resolve($0) }
                : nil
            self.resolvedRuntime.beginInteractionMutation()
            let app = try await services.applications.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: handlerIdentifier,
                applicationBundleIdentifier: self.bundleId,
                openURLs: [targetURL],
                activates: self.shouldFocus,
                waitUntilReady: self.waitUntilReady
            ))
            await self.invalidateSnapshotsAfterOpen()
            self.renderSuccess(app: app, targetURL: targetURL)
        } catch {
            handleError(error, customCode: applicationLaunchErrorCode(for: error))
            throw ExitCode.failure
        }
    }

    private mutating func prepare(using runtime: CommandRuntime) {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
    }

    private func invalidateSnapshotsAfterOpen() async {
        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: self.resolvedRuntime.interactionMutationTargets,
            logger: self.logger,
            reason: "open"
        )
    }

    static func resolveTarget(_ target: String, cwd: String = FileManager.default.currentDirectoryPath) throws -> URL {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError("Target must not be empty")
        }

        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let absolutePath: String = if expanded.hasPrefix("/") {
            expanded
        } else {
            NSString(string: cwd).appendingPathComponent(expanded)
        }

        return URL(fileURLWithPath: absolutePath)
    }

    private func renderSuccess(app: ServiceApplicationInfo, targetURL: URL) {
        let result = OpenResult(
            success: true,
            action: "open",
            target: target,
            resolved_target: normalizedTargetString(for: targetURL),
            handler_app: app.name,
            bundle_id: app.bundleIdentifier,
            pid: app.processIdentifier,
            is_ready: app.isFinishedLaunching ?? !self.waitUntilReady,
            focused: self.shouldFocus && app.isActive
        )
        AutomationEventLogger.log(
            .open,
            "target=\(result.resolved_target) handler=\(result.handler_app) "
                + "bundle=\(result.bundle_id ?? "unknown") focused=\(result.focused)"
        )

        output(result) {
            print("✅ Opened \(result.resolved_target) with \(app.name)")
        }
    }

    private func normalizedTargetString(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }
}

struct OpenResult: Codable {
    let success: Bool
    let action: String
    let target: String
    let resolved_target: String
    let handler_app: String
    let bundle_id: String?
    let pid: Int32
    let is_ready: Bool
    let focused: Bool
}

@MainActor
extension OpenCommand: AsyncRuntimeCommand {}

@MainActor
extension OpenCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.target = try values.decodePositional(0, label: "target", as: String.self)
        self.app = values.singleOption("app")
        self.bundleId = values.singleOption("bundleId")
        self.waitUntilReady = values.flag("waitUntilReady")
        self.foreground = values.flag("foreground")
        self.noFocus = values.flag("noFocus")
    }
}
