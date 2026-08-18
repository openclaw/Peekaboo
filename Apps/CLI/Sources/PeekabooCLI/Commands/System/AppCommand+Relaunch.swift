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

        @Option(help: "Wait between quit and launch (bare values are milliseconds; default: 2s)")
        var wait: CLIDuration = .seconds(2)

        @Flag(help: "Force quit (doesn't save changes)")
        var force = false

        @Flag(help: "Wait until the app is ready after launch")
        var waitUntilReady = false

        @Flag(help: "Required explicit foreground consent for relaunch")
        var foreground = false
        @RuntimeStorage var runtime: CommandRuntime?

        /// Quit the target app, wait if requested, relaunch it, and report success metrics.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            do {
                guard self.foreground else {
                    throw ApplicationLifecycleRefusalError.backgroundLaunch(
                        "Background app relaunch is refused before quit because terminating and launching " +
                            "an app can interrupt the user."
                    )
                }
                guard self.resolvedRuntime.applicationRelaunchAllowed else {
                    throw PeekabooError.serviceUnavailable(
                        "Relaunch requires a surviving daemon host; the selected bridge is unavailable or GUI-hosted"
                    )
                }

                // Find the application first
                let appIdentifier = try resolveApplicationIdentifier()
                let appInfo = try await resolveApplicationForMutation(appIdentifier, services: services)
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
                guard self.wait.seconds.isFinite, self.wait.seconds >= 0 else {
                    throw PeekabooError.invalidInput("Relaunch wait must be a finite, non-negative number of seconds")
                }
                let launchIdentifier = appInfo.bundlePath ?? (appInfo.bundleIdentifier == nil ? appInfo.name : nil)
                let launchBundleIdentifier = appInfo.bundlePath == nil ? appInfo.bundleIdentifier : nil
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await ApplicationServiceBridge.relaunchApplication(
                    applications: services.applications,
                    request: ApplicationRelaunchRequest(
                        targetIdentifier: processIdentifier,
                        expectedTargetIdentity: originalProcessIdentity,
                        launchRequest: ApplicationLaunchRequest(
                            applicationIdentifier: launchIdentifier,
                            applicationBundleIdentifier: launchBundleIdentifier,
                            activates: self.foreground,
                            waitUntilReady: self.waitUntilReady
                        ),
                        force: self.force,
                        waitSeconds: self.wait.seconds
                    )
                )
                let launchedApp = actionResult.payload
                await InteractionObservationInvalidator.invalidateAfterMutation(
                    targets: self.resolvedRuntime.interactionMutationTargets,
                    logger: self.logger,
                    reason: "app relaunch"
                )

                struct RelaunchResult: Codable {
                    let action: String
                    let app_name: String
                    let old_pid: Int32
                    let previous_process_start_identity_decimal: String
                    let new_pid: Int32
                    let new_process_start_identity: UInt64?
                    let new_process_start_identity_decimal: String?
                    let bundle_id: String?
                    let quit_forced: Bool
                    let wait_time: TimeInterval
                    let launch_success: Bool
                }

                let data = RelaunchResult(
                    action: "relaunch",
                    app_name: appInfo.name,
                    old_pid: originalPID,
                    previous_process_start_identity_decimal: String(originalProcessIdentity.processStartIdentity),
                    new_pid: launchedApp.processIdentifier,
                    new_process_start_identity: launchedApp.processStartIdentity,
                    new_process_start_identity_decimal: launchedApp.processStartIdentity.map(String.init),
                    bundle_id: appInfo.bundleIdentifier,
                    quit_forced: self.force,
                    wait_time: self.wait.seconds,
                    launch_success: !self.waitUntilReady || launchedApp.isFinishedLaunching == true
                )

                output(data, outcome: actionResult.outcome) {
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

extension AppCommand.RelaunchSubcommand: AsyncRuntimeCommand, ConfirmedActionOutputFormattable, ErrorHandlingCommand,
    OutputFormattable,
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
        if let wait: CLIDuration = try values.decodeOption("wait", as: CLIDuration.self) {
            self.wait = wait
        }
        force = values.flag("force")
        waitUntilReady = values.flag("waitUntilReady")
        foreground = values.flag("foreground")
    }
}
