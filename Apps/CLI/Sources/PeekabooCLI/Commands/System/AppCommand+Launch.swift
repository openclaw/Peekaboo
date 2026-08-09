import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension AppCommand {
    // MARK: - Launch Application

    @MainActor
    struct LaunchSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "launch",
            abstract: "Launch an application",
            discussion: """
            Launches the target app, optionally waits for it to finish starting,
            and can hand one or more documents/URLs to the app immediately.

            KEY OPTIONS:
              --bundle-id <id>       Launch by bundle identifier instead of name/path
              --open <path-or-url>   Repeatable; pass documents/URLs to the app right after launch
              --wait-until-ready     Poll until the app reports it is fully launched
              --foreground           Bring the app to the foreground after launching

            EXAMPLES:
              peekaboo app launch "Safari"
              peekaboo app launch "Safari" --open https://example.com --open https://news.ycombinator.com
              peekaboo app launch "Preview" --open ~/Desktop/report.pdf
              peekaboo app launch "Safari" --foreground
              peekaboo app launch --bundle-id com.apple.Notes --wait-until-ready
            """
        )

        @Argument(help: "Application name or path")
        var app: String?

        @Option(help: "Launch by bundle identifier instead of name")
        var bundleId: String?

        @Flag(help: "Wait for the application to be ready")
        var waitUntilReady = false

        @Flag(help: "Bring the app to the foreground after launching")
        var foreground = false

        @Flag(help: "Deprecated compatibility flag; background launch is now the default")
        var noFocus = false

        @Option(
            name: .customLong("open"),
            help: "Document or URL to open immediately after launch",
            parsing: .upToNextOption
        )
        var openTargets: [String] = []
        @RuntimeStorage var runtime: CommandRuntime?

        var shouldFocusAfterLaunch: Bool {
            self.foreground
        }

        /// Resolve the requested app target, launch it, optionally wait until ready, and emit output.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            do {
                try self.validateInputs()
                if self.noFocus {
                    self.logger.warn("--no-focus is deprecated because app launch is background by default")
                }
                self.resolvedRuntime.beginInteractionMutation()
                let launchedApp = try await launchApplication()
                await invalidateSnapshotsAfterLaunch()
                self.renderLaunchSuccess(app: launchedApp)
            } catch {
                handleError(error, customCode: applicationLaunchErrorCode(for: error))
                throw ExitCode(1)
            }
        }

        private mutating func prepare(using runtime: CommandRuntime) {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)
            self.logger.verbose("Launching application: \(self.requestedAppIdentifier)")
        }

        private func validateInputs() throws {
            guard self.app?.isEmpty == false || self.bundleId?.isEmpty == false else {
                throw PeekabooError.invalidInput("Provide an application name/path or --bundle-id")
            }
            guard !(self.foreground && self.noFocus) else {
                throw PeekabooError.invalidInput("--foreground cannot be combined with deprecated --no-focus")
            }
        }

        private var requestedAppIdentifier: String {
            self.bundleId ?? self.app ?? "unknown"
        }

        private func invalidateSnapshotsAfterLaunch() async {
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "app launch"
            )
        }

        private func renderLaunchSuccess(app: ServiceApplicationInfo) {
            struct LaunchResult: Codable {
                let action: String
                let app_name: String
                let bundle_id: String
                let pid: Int32
                let is_ready: Bool
            }

            let data = LaunchResult(
                action: "launch",
                app_name: app.name,
                bundle_id: app.bundleIdentifier ?? "unknown",
                pid: app.processIdentifier,
                is_ready: app.isFinishedLaunching ?? !self.waitUntilReady
            )
            AutomationEventLogger.log(
                .app,
                "launch app=\(data.app_name) bundle=\(data.bundle_id) pid=\(data.pid) ready=\(data.is_ready)"
            )

            output(data) {
                print("✓ Launched \(app.name) (PID: \(app.processIdentifier))")
            }
        }

        private func launchApplication() async throws -> ServiceApplicationInfo {
            let urls = try openTargets.map { try Self.resolveOpenTarget($0) }
            let applicationIdentifier = self.bundleId == nil
                ? self.app.map { ApplicationIdentifierResolver.resolve($0) }
                : nil
            return try await self.services.applications.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: applicationIdentifier,
                applicationBundleIdentifier: self.bundleId,
                openURLs: urls,
                activates: self.shouldFocusAfterLaunch,
                waitUntilReady: self.waitUntilReady
            ))
        }

        static func resolveOpenTarget(
            _ value: String,
            cwd: String = FileManager.default.currentDirectoryPath
        ) throws -> URL {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ValidationError("Open target must not be empty")
            }

            if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
                return url
            }

            let expanded = NSString(string: trimmed).expandingTildeInPath
            let absolutePath: String = if expanded.hasPrefix("/") {
                expanded
            } else {
                NSString(string: cwd)
                    .appendingPathComponent(expanded)
            }

            return URL(fileURLWithPath: absolutePath)
        }
    }
}

extension AppCommand.LaunchSubcommand: AsyncRuntimeCommand, ErrorHandlingCommand, OutputFormattable {}

@MainActor
extension AppCommand.LaunchSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        app = try values.decodeOptionalPositional(0, label: "app")
        bundleId = values.singleOption("bundleId")
        waitUntilReady = values.flag("waitUntilReady")
        foreground = values.flag("foreground")
        noFocus = values.flag("noFocus")
        openTargets = values.optionValues("open")
    }
}
