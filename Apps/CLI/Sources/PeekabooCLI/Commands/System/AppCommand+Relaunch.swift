import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension AppCommand {
    // MARK: - Relaunch Application

    @MainActor
    struct RelaunchSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "relaunch",
            abstract: "Quit and relaunch an application"
        )

        @Argument(help: "Application name, bundle ID, or 'PID:12345' for process ID")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?

        @Option(help: "Wait time in seconds between quit and launch (default: 2)")
        var wait: TimeInterval = 2.0

        @Flag(help: "Force quit (doesn't save changes)")
        var force = false

        @Flag(help: "Wait until the app is ready after launch")
        var waitUntilReady = false

        @Flag(help: "Bring the app to the foreground after relaunching")
        var foreground = false
        @RuntimeStorage var runtime: CommandRuntime?

        /// Quit the target app, wait if requested, relaunch it, and report success metrics.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            do {
                guard self.resolvedRuntime.applicationRelaunchAllowed else {
                    throw PeekabooError.serviceUnavailable(
                        "Relaunch requires a surviving daemon host; the selected bridge is unavailable or GUI-hosted"
                    )
                }

                // Find the application first
                let appIdentifier = try resolveApplicationIdentifier()
                let appInfo = try await resolveApplication(appIdentifier, services: services)
                let originalPID = appInfo.processIdentifier
                guard originalPID != self.resolvedRuntime.selectedRemoteHostProcessIdentifier else {
                    throw PeekabooError.serviceUnavailable(
                        "Cannot relaunch the selected daemon through itself; use another bridge host"
                    )
                }
                let processIdentifier = "PID:\(originalPID)"
                guard let originalProcessIdentity = appInfo.processIdentity else {
                    throw PeekabooError.commandFailed(
                        "Application discovery did not return a process-generation identity for atomic relaunch"
                    )
                }
                guard self.wait.isFinite, self.wait >= 0 else {
                    throw PeekabooError.invalidInput("Relaunch wait must be a finite, non-negative number of seconds")
                }
                let launchIdentifier = appInfo.bundleIdentifier == nil ? (appInfo.bundlePath ?? appInfo.name) : nil
                self.resolvedRuntime.beginInteractionMutation()
                let launchedApp = try await services.applications.relaunchApplication(
                    request: ApplicationRelaunchRequest(
                        targetIdentifier: processIdentifier,
                        expectedTargetIdentity: originalProcessIdentity,
                        launchRequest: ApplicationLaunchRequest(
                            applicationIdentifier: launchIdentifier,
                            applicationBundleIdentifier: appInfo.bundleIdentifier,
                            activates: self.foreground,
                            waitUntilReady: self.waitUntilReady
                        ),
                        force: self.force,
                        waitSeconds: self.wait
                    )
                )
                await InteractionObservationInvalidator.invalidateAfterMutation(
                    targets: self.resolvedRuntime.interactionMutationTargets,
                    logger: self.logger,
                    reason: "app relaunch"
                )

                struct RelaunchResult: Codable {
                    let action: String
                    let app_name: String
                    let old_pid: Int32
                    let new_pid: Int32
                    let new_process_start_identity: UInt64?
                    let bundle_id: String?
                    let quit_forced: Bool
                    let wait_time: TimeInterval
                    let launch_success: Bool
                }

                let data = RelaunchResult(
                    action: "relaunch",
                    app_name: appInfo.name,
                    old_pid: originalPID,
                    new_pid: launchedApp.processIdentifier,
                    new_process_start_identity: launchedApp.processStartIdentity,
                    bundle_id: appInfo.bundleIdentifier,
                    quit_forced: self.force,
                    wait_time: self.wait,
                    launch_success: !self.waitUntilReady || launchedApp.isFinishedLaunching == true
                )

                output(data) {
                    print("✓ Relaunched \(appInfo.name)")
                    print("  Old PID: \(originalPID) → New PID: \(launchedApp.processIdentifier)")
                    if self.waitUntilReady {
                        print("  Status: \(launchedApp.isFinishedLaunching == true ? "Ready" : "Launching...")")
                    }
                }

            } catch {
                handleError(error, customCode: applicationLaunchErrorCode(for: error))
                throw ExitCode(1)
            }
        }
    }
}

extension AppCommand.RelaunchSubcommand: AsyncRuntimeCommand, ErrorHandlingCommand, OutputFormattable,
    ApplicationResolvable,
    ApplicationResolver {}

@MainActor
extension AppCommand.RelaunchSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        app = try AppCommand.resolveAppArgument(values, optionLabel: "app")
        pid = try values.decodeOption("pid", as: Int32.self)
        guard app != nil || pid != nil else {
            throw CommanderBindingError.missingArgument(label: "app or --pid")
        }
        if let wait: TimeInterval = try values.decodeOption("wait", as: TimeInterval.self) {
            self.wait = wait
        }
        force = values.flag("force")
        waitUntilReady = values.flag("waitUntilReady")
        foreground = values.flag("foreground")
    }
}
