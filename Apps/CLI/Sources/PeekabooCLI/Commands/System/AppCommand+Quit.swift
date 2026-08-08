import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension AppCommand {
    // MARK: - Quit Application

    @MainActor
    struct QuitSubcommand {
        static let commandDescription = CommandDescription(
            commandName: "quit",
            abstract: "Quit one or more applications"
        )

        @Option(help: "Application to quit")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?

        @Flag(help: "Quit all applications")
        var all = false

        @Option(help: "Comma-separated list of apps to exclude when using --all")
        var except: String?

        @Flag(help: "Force quit (doesn't save changes)")
        var force = false
        @RuntimeStorage private var runtime: CommandRuntime?

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        private var logger: Logger {
            self.resolvedRuntime.logger
        }

        @MainActor private var services: any PeekabooServiceProviding {
            self.resolvedRuntime.services
        }

        var outputLogger: Logger {
            self.logger
        }

        var jsonOutput: Bool {
            self.resolvedRuntime.configuration.jsonOutput
        }

        /// Resolve the targeted applications, issue quit or force-quit requests, and report results per app.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let logger = self.logger

            do {
                if self.all {
                    if self.app != nil || self.pid != nil {
                        throw ValidationError("Cannot combine --all with --app or --pid")
                    }
                } else {
                    if let except = self.except,
                       !except.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw ValidationError("--except requires --all")
                    }
                    if self.app != nil && self.pid != nil {
                        throw ValidationError("Cannot combine --app with --pid")
                    }
                    if self.app == nil && self.pid == nil {
                        throw ValidationError("Either --app, --pid, or --all must be specified")
                    }
                }

                var quitApps: [AppQuitTarget] = []

                if self.all {
                    // Get all apps except system/excluded ones
                    let excluded = Set((except ?? "").split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespaces) }
                    )
                    let systemApps = Set(["Finder", "Dock", "SystemUIServer", "WindowServer"])

                    let runningApps = try await self.services.applications.listApplications().data.applications
                    for runningApp in runningApps {
                        guard runningApp.activationPolicy ?? .regular == .regular,
                              !systemApps.contains(runningApp.name),
                              !excluded.contains(runningApp.name) else { continue }

                        quitApps.append(AppQuitTarget(appInfo: runningApp))
                    }
                } else if let appName = app {
                    // Find specific app
                    let appInfo = try await resolveApplication(appName, services: self.services)
                    quitApps.append(AppQuitTarget(appInfo: appInfo))
                } else if let pid = self.pid {
                    let appInfo = try await self.services.applications.findApplication(identifier: "PID:\(pid)")
                    quitApps.append(AppQuitTarget(appInfo: appInfo))
                } else {
                    throw ValidationError("Either --app, --pid, or --all must be specified")
                }

                // Quit the apps
                struct AppQuitInfo: Codable {
                    let app_name: String
                    let pid: Int32
                    let success: Bool
                }

                var results: [AppQuitInfo] = []
                for target in quitApps {
                    if target.pid == self.resolvedRuntime.selectedRemoteHostProcessIdentifier {
                        throw PeekabooError.invalidInput(
                            "Cannot quit the daemon host executing this command; use a different runtime host"
                        )
                    }
                    self.resolvedRuntime.beginInteractionMutation()
                    let success = await (try? self.services.applications.quitApplication(
                        identifier: target.identifier,
                        force: self.force
                    )) ?? false
                    results.append(AppQuitInfo(
                        app_name: target.name,
                        pid: target.pid,
                        success: success
                    ))

                    // Log additional debug info when quit fails
                    if !success && !self.jsonOutput {
                        // Check if app might be in a modal state or have unsaved changes
                        if !self.force {
                            logger
                                .debug(
                                    """
                                    Quit failed for \(target.name) (PID: \(target.pid)). \
                                    The app may have unsaved changes or be showing a dialog. \
                                    Try --force to force quit.
                                    """
                                )
                        } else {
                            logger
                                .debug(
                                    """
                                    Force quit failed for \(target.name) (PID: \(target.pid)). \
                                    The app may be unresponsive or protected.
                                    """
                                )
                        }
                    }
                }

                struct QuitResult: Codable {
                    let action: String
                    let force: Bool
                    let results: [AppQuitInfo]
                }

                let data = QuitResult(
                    action: "quit",
                    force: force,
                    results: results
                )
                let allSucceeded = results.allSatisfy(\.success)

                if self.jsonOutput {
                    let response = CodableJSONResponse(
                        success: allSucceeded,
                        data: data,
                        messages: nil,
                        debug_logs: self.outputLogger.getDebugLogs()
                    )
                    outputJSONCodable(response, logger: self.outputLogger)
                } else {
                    for result in results {
                        if result.success {
                            print("✓ Quit \(result.app_name)")
                        } else {
                            print("✗ Failed to quit \(result.app_name) (PID: \(result.pid))")
                            if !self.force {
                                print(
                                    "  💡 Tip: The app may have unsaved changes or be showing a dialog. " +
                                        "Try --force to force quit."
                                )
                            }
                        }
                    }
                }
                for result in results {
                    AutomationEventLogger.log(
                        .app,
                        "quit app=\(result.app_name) pid=\(result.pid) success=\(result.success) force=\(self.force)"
                    )
                }
                if !allSucceeded {
                    throw ExitCode.failure
                }

            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }
}

private struct AppQuitTarget {
    let name: String
    let pid: Int32
    let identifier: String

    init(appInfo: ServiceApplicationInfo) {
        self.name = appInfo.name
        self.pid = appInfo.processIdentifier
        self.identifier = "PID:\(appInfo.processIdentifier)"
    }
}

extension AppCommand.QuitSubcommand: AsyncRuntimeCommand, ErrorHandlingCommand, OutputFormattable,
    ApplicationResolvable,
    ApplicationResolver {}

@MainActor
extension AppCommand.QuitSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.all = values.flag("all")
        self.except = values.singleOption("except")
        self.force = values.flag("force")
    }
}
