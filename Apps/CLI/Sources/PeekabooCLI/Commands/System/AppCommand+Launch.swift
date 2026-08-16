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
            abstract: "Verify a running app or explicitly launch it in the foreground",
            discussion: """
            Without --foreground, this command is a read-only exact no-op that succeeds only
            when the selected app is already running. Cold launch, open targets, and new instances
            require --foreground because macOS may activate the target.

            KEY OPTIONS:
              --bundle-id <id>       Launch by bundle identifier instead of name/path
              --open <path-or-url>   Repeatable; pass documents/URLs to the app right after launch
              --new-instance         Launch a distinct process even if the app is already running
              --wait-ready           Wait until LaunchServices reports startup complete
              --wait-for-window      Wait for a real AX or WindowServer window
              --foreground           Required for cold launch, open targets, or a new instance

            EXAMPLES:
              peekaboo app launch "Safari"
              peekaboo app launch "Safari" --open https://example.com --foreground
              peekaboo app launch "Preview" --open ~/Desktop/report.pdf --foreground
              peekaboo app launch "TextEdit" --new-instance --wait-ready --foreground
              peekaboo app launch "Safari" --foreground
              peekaboo app launch --bundle-id com.apple.Notes --wait-ready --foreground
            """
        )

        @Argument(help: "Application name or path")
        var app: String?

        @Option(help: "Launch by bundle identifier instead of name")
        var bundleId: String?

        @Flag(name: .customLong("wait-ready"), help: "Wait for the application to be ready")
        var waitUntilReady = false

        @Flag(help: "Wait for the application to expose an exact WindowServer window")
        var waitForWindow = false

        @Flag(help: "Launch a distinct process even if the app is already running")
        var newInstance = false

        @Flag(help: "Required for cold launch, open targets, or a new instance")
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
                self.logger.verbose(
                    self.foreground
                        ? "Launching application: \(self.requestedAppIdentifier)"
                        : "Verifying already-running application: \(self.requestedAppIdentifier)"
                )
                if self.noFocus {
                    self.logger.warn("--no-focus is deprecated because app launch is background by default")
                }
                if self.foreground {
                    self.resolvedRuntime.beginInteractionMutation()
                }
                let launch = try await launchApplication()
                if self.foreground {
                    await self.invalidateSnapshotsAfterLaunch()
                }
                self.renderLaunchSuccess(
                    app: launch.result.payload,
                    outcome: launch.result.outcome,
                    isSafeBackgroundNoOp: launch.request.isSafeBackgroundNoOp
                )
            } catch {
                handleError(error, customCode: applicationLaunchErrorCode(for: error))
                throw ExitCode(1)
            }
        }

        private mutating func prepare(using runtime: CommandRuntime) {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)
        }

        private func validateInputs() throws {
            guard self.app?.isEmpty == false || self.bundleId?.isEmpty == false else {
                throw PeekabooError.invalidInput("Provide an application name/path or --bundle-id")
            }
            guard !(self.app?.isEmpty == false && self.bundleId?.isEmpty == false) else {
                throw PeekabooError.invalidInput(
                    "Provide the application either positionally or with --bundle-id, not both"
                )
            }
            guard !(self.foreground && self.noFocus) else {
                throw PeekabooError.invalidInput("--foreground cannot be combined with deprecated --no-focus")
            }
            if !self.foreground, self.newInstance {
                throw ApplicationLifecycleRefusalError.backgroundLaunch(
                    "Background new-instance launch is refused before dispatch because a new app process can activate."
                )
            }
            if !self.foreground, !self.openTargets.isEmpty {
                throw ApplicationLifecycleRefusalError.backgroundLaunch(
                    "Background URL or document delivery is refused before dispatch because the target app " +
                        "can activate."
                )
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

        private func renderLaunchSuccess(
            app: ServiceApplicationInfo,
            outcome: DesktopActionOutcome?,
            isSafeBackgroundNoOp: Bool
        ) {
            struct LaunchResult: Codable {
                let action: String
                let app_name: String
                let bundle_id: String
                let pid: Int32
                let process_start_identity: UInt64?
                let process_start_identity_decimal: String?
                let is_ready: Bool
                let window_count: Int
                let window_ready: Bool
                let window_ids: [Int]?
                let window_identity: String
                let new_instance: Bool
            }

            let exactWindowIDs = app.windowIDs
            let refreshedWindowCount = exactWindowIDs?.count ?? app.windowCount
            let data = LaunchResult(
                action: "launch",
                app_name: app.name,
                bundle_id: app.bundleIdentifier ?? "unknown",
                pid: app.processIdentifier,
                process_start_identity: app.processStartIdentity,
                process_start_identity_decimal: app.processStartIdentity.map(String.init),
                is_ready: app.isFinishedLaunching ?? !self.waitUntilReady,
                window_count: refreshedWindowCount,
                window_ready: refreshedWindowCount > 0,
                window_ids: exactWindowIDs,
                window_identity: exactWindowIDs == nil ? "unknown" : "exact",
                new_instance: self.newInstance
            )
            AutomationEventLogger.log(
                .app,
                "launch app=\(data.app_name) bundle=\(data.bundle_id) pid=\(data.pid) ready=\(data.is_ready)"
            )

            output(data, outcome: outcome) {
                if isSafeBackgroundNoOp || outcome?.state == .confirmedNoChange {
                    print("✓ Already running: \(app.name) (PID: \(app.processIdentifier)); no launch dispatched")
                } else {
                    print("✓ Launched \(app.name) (PID: \(app.processIdentifier))")
                }
            }
        }

        private func launchApplication() async throws -> (
            request: ApplicationLaunchRequest,
            result: DesktopActionResult<ServiceApplicationInfo>
        ) {
            let urls = try openTargets.map { try Self.resolveOpenTarget($0) }
            let applicationIdentifier = self.bundleId == nil
                ? self.app.map { ApplicationIdentifierResolver.resolve($0) }
                : nil
            let request = ApplicationLaunchRequest(
                applicationIdentifier: applicationIdentifier,
                applicationBundleIdentifier: self.bundleId,
                openURLs: urls,
                activates: self.shouldFocusAfterLaunch,
                waitUntilReady: self.waitUntilReady,
                waitForWindow: self.waitForWindow,
                createsNewInstance: self.newInstance
            )
            let result = try await ApplicationServiceBridge.launchApplication(
                applications: self.services.applications,
                request: request
            )
            return (request, result)
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

extension AppCommand.LaunchSubcommand: AsyncRuntimeCommand, ConfirmedActionOutputFormattable, ErrorHandlingCommand,
OutputFormattable {}

@MainActor
extension AppCommand.LaunchSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        app = try values.decodeOptionalPositional(0, label: "app")
        bundleId = values.singleOption("bundleId")
        waitUntilReady = values.flag("waitUntilReady")
        waitForWindow = values.flag("waitForWindow")
        newInstance = values.flag("newInstance")
        foreground = values.flag("foreground")
        noFocus = values.flag("noFocus")
        openTargets = values.optionValues("open")
    }
}
