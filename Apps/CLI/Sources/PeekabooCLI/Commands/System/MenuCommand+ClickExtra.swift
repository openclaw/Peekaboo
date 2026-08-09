import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension MenuCommand {
    // MARK: - Click System Menu Extra

    @MainActor
    struct ClickExtraSubcommand: OutputFormattable, InjectedRuntimeBackedCommand {
        @Option(help: "Title of the menu extra (e.g., 'WiFi', 'Bluetooth')")
        var title: String

        @Option(help: "Reserved for future nested menu support; currently rejected")
        var item: String?

        @Flag(help: "Verify the menu extra popover opens after clicking")
        var verify: Bool = false
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                guard self.item == nil else {
                    throw ValidationError(
                        "--item is not supported by menu click-extra; open the extra first, then use another interaction command"
                    )
                }
                let verifier = MenuBarClickVerifier(services: self.services)
                let verifyTarget = self.verify ? try await self.resolveVerificationTarget() : nil
                let preFocus = self.verify ? try await verifier.captureFocusSnapshot() : nil
                self.resolvedRuntime.beginInteractionMutation()
                let clickResult = try await MenuServiceBridge
                    .clickMenuBarItem(named: self.title, menu: self.services.menu)

                let verification: MenuBarClickVerification?
                if self.verify {
                    guard let verifyTarget else {
                        throw PeekabooError
                            .operationError(message: "Menu extra verification requested but no target resolved")
                    }
                    verification = try await verifier.verifyClick(
                        target: verifyTarget,
                        preFocus: preFocus,
                        clickLocation: clickResult.location
                    )
                } else {
                    verification = nil
                }

                if self.jsonOutput {
                    let data = MenuExtraClickResult(
                        action: "menu_extra_click",
                        menu_extra: title,
                        clicked_item: self.title,
                        location: clickResult.location.map { ["x": $0.x, "y": $0.y] },
                        verified: verification?.verified
                    )
                    outputSuccessCodable(data: data, logger: self.outputLogger)
                } else {
                    if let location = clickResult.location {
                        print("✓ Clicked menu extra: \(self.title) at (\(Int(location.x)), \(Int(location.y)))")
                    } else {
                        print("✓ Clicked menu extra: \(self.title)")
                    }
                    if let verification {
                        print("🔎 Verified menu extra click (\(verification.method))")
                    }
                }

            } catch let error as Commander.ValidationError {
                if self.jsonOutput {
                    outputError(message: error.localizedDescription, code: .INVALID_INPUT, logger: self.outputLogger)
                } else {
                    fputs("Error: \(error.localizedDescription)\n", stderr)
                }
                throw ExitCode(1)
            } catch let error as MenuError {
                MenuErrorOutputSupport.renderMenuError(
                    error,
                    jsonOutput: self.jsonOutput,
                    details: "Failed to click menu extra",
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            } catch {
                MenuErrorOutputSupport.renderGenericError(
                    error,
                    jsonOutput: self.jsonOutput,
                    details: "Menu extra operation failed",
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            }
        }

        private func resolveVerificationTarget() async throws -> MenuBarVerifyTarget {
            let items = try await MenuServiceBridge.listMenuBarItems(
                menu: self.services.menu,
                includeRaw: true
            )
            let normalized = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let item = matchMenuBarItem(named: normalized, items: items) else {
                throw PeekabooError.operationError(message: "Unable to resolve '\(self.title)' for verification")
            }

            return MenuBarVerifyTarget(
                title: item.title ?? item.rawTitle ?? normalized,
                ownerPID: item.rawOwnerPID,
                ownerName: item.ownerName,
                bundleIdentifier: item.bundleIdentifier,
                preferredX: item.frame?.midX
            )
        }
    }
}
