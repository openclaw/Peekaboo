import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension AppCommand {
    // MARK: - List Applications

    @MainActor

    struct ListSubcommand: InjectedRuntimeBackedCommand {
        static let schemaCapabilities = ["processStartIdentityDecimal"]

        static let commandDescription = CommandDescription(
            commandName: "list",
            abstract: "List running applications",
            discussion: """
            App-management view of running applications. Hidden and background apps are
            filtered unless --include-hidden or --include-background is passed. This is the
            canonical v4 process inventory command; JSON emits `count` and `apps`.
            """
        )

        @Flag(help: "Include hidden apps")
        var includeHidden = false

        @Flag(help: "Include background apps")
        var includeBackground = false
        @RuntimeStorage var runtime: CommandRuntime?

        static func filteredApplications(
            _ applications: [ServiceApplicationInfo],
            includeHidden: Bool,
            includeBackground: Bool
        ) -> [ServiceApplicationInfo] {
            applications.filter { app in
                // A timed-out metadata read cannot be guessed visible. Keep it out of the default
                // view, but let the explicit inclusive flags expose the row with unknown state.
                if app.isHiddenKnown == false, !includeHidden {
                    return false
                }
                if !includeHidden, app.isHidden {
                    return false
                }
                if app.isHiddenKnown == false,
                   app.activationPolicy == nil,
                   !includeBackground {
                    return false
                }
                if !includeBackground,
                   app.activationPolicy == .accessory || app.activationPolicy == .prohibited {
                    return false
                }
                return true
            }
        }

        /// Enumerate running applications, apply filtering flags, and emit the chosen output representation.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            do {
                let appsOutput = try await self.services.applications.listApplications()

                let filtered = Self.filteredApplications(
                    appsOutput.data.applications,
                    includeHidden: self.includeHidden,
                    includeBackground: self.includeBackground
                )

                struct AppInfo: Codable {
                    let name: String
                    let bundle_id: String
                    let pid: Int32
                    let process_start_identity: UInt64?
                    let process_start_identity_decimal: String?
                    let is_active: Bool
                    let is_hidden: Bool?
                    let metadata_warnings: [String]?
                }

                struct ListResult: Codable {
                    let count: Int
                    let apps: [AppInfo]
                    let warnings: [String]
                    let schema_capabilities: [String]
                }

                let data = ListResult(
                    count: filtered.count,
                    apps: filtered.map { app in
                        AppInfo(
                            name: app.name,
                            bundle_id: app.bundleIdentifier ?? "unknown",
                            pid: app.processIdentifier,
                            process_start_identity: app.processStartIdentity,
                            process_start_identity_decimal: app.processStartIdentity.map(String.init),
                            is_active: app.isActive,
                            is_hidden: app.isHiddenKnown == false ? nil : app.isHidden,
                            metadata_warnings: app.metadataWarnings
                        )
                    },
                    warnings: appsOutput.metadata.warnings,
                    schema_capabilities: Self.schemaCapabilities
                )
                AutomationEventLogger.log(
                    .app,
                    "list count=\(filtered.count) includeHidden=\(self.includeHidden) "
                        + "includeBackground=\(self.includeBackground)"
                )

                output(data) {
                    print("Running Applications (\(filtered.count)):")
                    for app in filtered {
                        let status = if app.isActive {
                            " [active]"
                        } else if app.isHiddenKnown == false {
                            " [hidden state unknown]"
                        } else if app.isHidden {
                            " [hidden]"
                        } else {
                            ""
                        }
                        print("  • \(app.name)\(status)")
                        print("    Bundle: \(app.bundleIdentifier ?? "unknown")")
                        print("    PID: \(app.processIdentifier)")
                    }
                    for warning in appsOutput.metadata.warnings {
                        print("  ⚠ \(warning)")
                    }
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }
}
