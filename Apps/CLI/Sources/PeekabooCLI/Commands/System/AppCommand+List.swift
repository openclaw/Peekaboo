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
            canonical v4 process inventory command; JSON emits `count` and `apps`. Pass
            --include-installed to add a separate installed-but-not-running sidecar without
            manufacturing process identity.
            """
        )

        @Flag(help: "Include hidden apps")
        var includeHidden = false

        @Flag(help: "Include background apps")
        var includeBackground = false

        @Flag(help: "Include installed but not running apps")
        var includeInstalled = false
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

        static func filteredInstalledApplications(
            _ applications: [ServiceInstalledApplicationInfo],
            includeBackground: Bool
        ) -> [ServiceInstalledApplicationInfo] {
            guard !includeBackground else { return applications }
            return applications.filter { $0.declaredPresentation == .regular }
        }

        /// Enumerate running applications, apply filtering flags, and emit the chosen output representation.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            do {
                typealias InstalledOutput = UnifiedToolOutput<ServiceInstalledApplicationListData>
                let catalog: (any InstalledApplicationCatalogProviding)?
                if self.includeInstalled {
                    guard let provider = self.services.applications as? any InstalledApplicationCatalogProviding,
                          provider.supportsInstalledApplicationCatalog
                    else {
                        throw PeekabooError.serviceUnavailable(
                            "The selected runtime host does not support installed application discovery"
                        )
                    }
                    catalog = provider
                } else {
                    catalog = nil
                }
                let appsOutput = try await self.services.applications.listApplications()
                let hasIdentityPoorRunningApplications =
                    InstalledApplicationReconciler.hasIdentityPoorRunningApplications(
                        appsOutput.data.applications
                    )
                let installedResultsOmitted = self.includeInstalled && hasIdentityPoorRunningApplications
                let installedOutput: InstalledOutput? = if let catalog, !hasIdentityPoorRunningApplications {
                    try await catalog.listInstalledApplications()
                } else {
                    nil
                }

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

                struct InstalledAppInfo: Codable {
                    let name: String
                    let bundle_id: String
                    let launch_path: String
                    let declared_presentation: String
                }

                struct ListResult: Codable {
                    let count: Int
                    let apps: [AppInfo]
                    let installed_count: Int?
                    let installed_apps: [InstalledAppInfo]?
                    let warnings: [String]
                    let schema_capabilities: [String]
                }

                let installedApplications: [ServiceInstalledApplicationInfo]? = if self.includeInstalled {
                    installedOutput.map { output in
                        Self.filteredInstalledApplications(
                            InstalledApplicationReconciler.installedButNotRunning(
                                catalog: output.data.applications,
                                running: appsOutput.data.applications
                            ),
                            includeBackground: self.includeBackground
                        )
                    } ?? []
                } else {
                    nil
                }
                var combinedWarnings = appsOutput.metadata.warnings + (installedOutput?.metadata.warnings ?? [])
                if installedResultsOmitted {
                    combinedWarnings.append(
                        "Installed-but-not-running results were omitted because a live application lacked " +
                            "bundle identity metadata"
                    )
                }
                let warnings = Array(Set(combinedWarnings)).sorted()

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
                    installed_count: installedApplications?.count,
                    installed_apps: installedApplications?.map { application in
                        InstalledAppInfo(
                            name: application.name,
                            bundle_id: application.bundleIdentifier,
                            launch_path: application.launchPath,
                            declared_presentation: application.declaredPresentation.rawValue
                        )
                    },
                    warnings: warnings,
                    schema_capabilities: self.includeInstalled
                        ? Self.schemaCapabilities + ["installedApplicationSidecar"]
                        : Self.schemaCapabilities
                )
                AutomationEventLogger.log(
                    .app,
                    "list count=\(filtered.count) includeHidden=\(self.includeHidden) "
                        + "includeBackground=\(self.includeBackground)"
                        + " includeInstalled=\(self.includeInstalled)"
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
                    if installedResultsOmitted {
                        print("Installed Application Status: omitted because live bundle identity was incomplete")
                    } else if let installedApplications {
                        print("Installed Applications, Not Running (\(installedApplications.count)):")
                        for application in installedApplications {
                            print("  • \(application.name)")
                            print("    Bundle: \(application.bundleIdentifier)")
                            print("    Launch path: \(application.launchPath)")
                            print("    Declared presentation: \(application.declaredPresentation.rawValue)")
                        }
                    }
                    for warning in warnings {
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
