import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension AppCommand {
    // MARK: - List Applications

    @MainActor

    struct ListSubcommand: InjectedRuntimeBackedCommand {
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
                if !includeHidden, app.isHidden {
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
                    let is_active: Bool
                    let is_hidden: Bool
                }

                struct ListResult: Codable {
                    let count: Int
                    let apps: [AppInfo]
                }

                let data = ListResult(
                    count: filtered.count,
                    apps: filtered.map { app in
                        AppInfo(
                            name: app.name,
                            bundle_id: app.bundleIdentifier ?? "unknown",
                            pid: app.processIdentifier,
                            is_active: app.isActive,
                            is_hidden: app.isHidden
                        )
                    }
                )
                AutomationEventLogger.log(
                    .app,
                    "list count=\(filtered.count) includeHidden=\(self.includeHidden) "
                        + "includeBackground=\(self.includeBackground)"
                )

                output(data) {
                    print("Running Applications (\(filtered.count)):")
                    for app in filtered {
                        let status = app.isActive ? " [active]" : app.isHidden ? " [hidden]" : ""
                        print("  • \(app.name)\(status)")
                        print("    Bundle: \(app.bundleIdentifier ?? "unknown")")
                        print("    PID: \(app.processIdentifier)")
                    }
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }
}
