import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

extension PermissionCommand {
    struct RequestScreenRecordingSubcommand: OutputFormattable, InjectedRuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "request-screen-recording",
                    abstract: "Trigger screen recording permission prompt"
                )
            }
        }

        @RuntimeStorage var runtime: CommandRuntime?

        /// Trigger the screen recording permission prompt using the best available mechanism.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            if await self.renderIfAlreadyGranted() {
                return
            }
            let result = await PermissionHelpers.performInteractivePermissionRequest(using: runtime) {
                await self.requestScreenRecordingPermission()
            }
            self.render(result: result)
        }

        private mutating func prepare(using runtime: CommandRuntime) {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)
        }

        private func renderIfAlreadyGranted() async -> Bool {
            let hasPermission = await self.services.screenCapture.hasScreenRecordingPermission()
            guard hasPermission else { return false }
            let payload = AgentPermissionActionResult(
                action: "request-screen-recording",
                already_granted: true,
                prompt_triggered: false,
                granted: true
            )
            self.render(result: payload)
            return true
        }

        private func requestScreenRecordingPermission() async -> AgentPermissionActionResult {
            if !self.jsonOutput {
                print("Requesting Screen Recording permission...\n")
                print("Triggering permission prompt...\n")
            }

            if #available(macOS 10.15, *) {
                return self.handleModernPrompt()
            } else {
                return self.handleLegacyPrompt()
            }
        }

        private func handleModernPrompt() -> AgentPermissionActionResult {
            let granted = CGRequestScreenCaptureAccess()
            if !self.jsonOutput {
                self.printModernResult(granted: granted)
            }
            return AgentPermissionActionResult(
                action: "request-screen-recording",
                already_granted: false,
                prompt_triggered: true,
                granted: granted
            )
        }

        private func handleLegacyPrompt() -> AgentPermissionActionResult {
            // Minimum supported macOS is 15+, so reuse the modern path.
            self.handleModernPrompt()
        }

        private func printModernResult(granted: Bool) {
            guard !self.jsonOutput else { return }
            if granted {
                print("✅ Screen Recording permission granted!")
                return
            }

            print("❌ Screen Recording permission denied\n")
            print("To grant manually:")
            print("1. Open System Settings")
            print("2. Go to Privacy & Security > Screen Recording")
            print("3. Enable Peekaboo")
        }

        private func render(result: AgentPermissionActionResult) {
            if self.jsonOutput {
                outputSuccessCodable(data: result, logger: self.logger)
            } else if result.already_granted {
                print("✅ Screen Recording permission is already granted!")
            }
        }
    }

    struct RequestAccessibilitySubcommand: OutputFormattable, InjectedRuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "request-accessibility",
                    abstract: "Request accessibility permission"
                )
            }
        }

        @RuntimeStorage var runtime: CommandRuntime?

        /// Prompt the user to grant accessibility permission and open the relevant System Settings pane.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            if await self.renderIfAlreadyGranted() {
                return
            }
            let granted = await PermissionHelpers.performInteractivePermissionRequest(using: runtime) {
                self.promptAccessibilityDialog()
            }
            self.renderAccessibilityResult(granted: granted)
        }

        private mutating func prepare(using runtime: CommandRuntime) {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)
        }

        private func renderIfAlreadyGranted() async -> Bool {
            let hasPermission = await AutomationServiceBridge
                .hasAccessibilityPermission(automation: self.services.automation)
            guard hasPermission else { return false }
            let payload = AgentPermissionActionResult(
                action: "request-accessibility",
                already_granted: true,
                prompt_triggered: false,
                granted: true
            )
            self.renderAccessibilityResult(payload: payload)
            return true
        }

        private func promptAccessibilityDialog() -> Bool {
            if !self.jsonOutput {
                print("Requesting Accessibility permission...\n")
                print("Opening System Settings to Accessibility permissions...\n")
            }

            return self.services.permissions.requestAccessibilityPermission(interactive: true)
        }

        private func renderAccessibilityResult(granted: Bool) {
            let payload = AgentPermissionActionResult(
                action: "request-accessibility",
                already_granted: false,
                prompt_triggered: true,
                granted: granted
            )
            self.renderAccessibilityResult(payload: payload)
        }

        private func renderAccessibilityResult(payload: AgentPermissionActionResult) {
            if self.jsonOutput {
                outputSuccessCodable(data: payload, logger: self.logger)
                return
            }

            guard !payload.already_granted else {
                print("✅ Accessibility permission is already granted!")
                return
            }

            if payload.granted == true {
                print("✅ Accessibility permission granted!")
            } else {
                print("A dialog should have appeared.\n")
                print("To grant permission:")
                print("1. Click 'Open System Settings' in the dialog")
                print("2. Enable Peekaboo in the Accessibility list")
                print("3. You may need to restart Peekaboo after granting")
            }
        }
    }

    struct RequestEventSynthesizingSubcommand: ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "request-event-synthesizing",
                    abstract: "Request event-synthesizing permission for background input"
                )
            }
        }

        @RuntimeStorage var runtime: CommandRuntime?

        /// Prompt macOS for event-posting access used by process-targeted hotkeys.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            do {
                let payload = try await self.requestEventSynthesizingPermission()
                self.renderEventSynthesizingResult(payload: payload)
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }

        private mutating func prepare(using runtime: CommandRuntime) {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)
        }

        private func requestEventSynthesizingPermission() async throws -> AgentPermissionActionResult {
            let result = try await PermissionHelpers.requestEventSynthesizingPermission(
                services: self.services,
                runtime: self.resolvedRuntime
            )
            return AgentPermissionActionResult(
                action: result.action,
                source: result.source,
                already_granted: result.already_granted,
                prompt_triggered: result.prompt_triggered,
                granted: result.granted
            )
        }

        private func renderEventSynthesizingResult(payload: AgentPermissionActionResult) {
            if self.jsonOutput {
                outputSuccessCodable(data: payload, logger: self.logger)
                return
            }

            guard !payload.already_granted else {
                print("✅ Event Synthesizing permission is already granted!")
                return
            }

            if payload.granted == true {
                print("✅ Event Synthesizing permission granted!")
            } else {
                print("❌ Event Synthesizing permission denied\n")
                print("To grant manually:")
                print("1. Open System Settings")
                print("2. Go to Privacy & Security > Accessibility")
                if payload.source == "bridge" {
                    print("3. Enable the process that showed the prompt")
                } else {
                    print("3. Enable Peekaboo")
                }
            }
        }
    }
}

private struct AgentPermissionActionResult: Codable {
    let action: String
    let source: String?
    let already_granted: Bool
    let prompt_triggered: Bool
    let granted: Bool?

    init(
        action: String,
        source: String? = nil,
        already_granted: Bool,
        prompt_triggered: Bool,
        granted: Bool?
    ) {
        self.action = action
        self.source = source
        self.already_granted = already_granted
        self.prompt_triggered = prompt_triggered
        self.granted = granted
    }
}

extension PermissionCommand.RequestScreenRecordingSubcommand: ParsableCommand {}

extension PermissionCommand.RequestScreenRecordingSubcommand: AsyncRuntimeCommand {}

extension PermissionCommand.RequestAccessibilitySubcommand: ParsableCommand {}

extension PermissionCommand.RequestAccessibilitySubcommand: AsyncRuntimeCommand {}

extension PermissionCommand.RequestEventSynthesizingSubcommand: ParsableCommand {}

extension PermissionCommand.RequestEventSynthesizingSubcommand: AsyncRuntimeCommand {}
