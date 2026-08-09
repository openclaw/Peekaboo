import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension PermissionCommand {
    struct StatusSubcommand: OutputFormattable, InjectedRuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "status",
                    abstract: "Check current permission status"
                )
            }
        }

        @RuntimeStorage var runtime: CommandRuntime?

        /// Summarize the current permission state for the agent-centric workflow.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            let status = await self.fetchPermissionStatus()
            self.render(status: status)
        }

        private mutating func prepare(using runtime: CommandRuntime) {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)
        }

        @MainActor
        private func fetchPermissionStatus() async -> AgentPermissionStatusPayload {
            if let remoteServices = self.services as? RemotePeekabooServices,
               let status = try? await remoteServices.permissionsStatus() {
                return AgentPermissionStatusPayload(
                    screen_recording: status.screenRecording,
                    accessibility: status.accessibility,
                    event_synthesizing: status.postEvent
                )
            }

            let screenRecording = await self.services.screenCapture.hasScreenRecordingPermission()
            let accessibility = await AutomationServiceBridge
                .hasAccessibilityPermission(automation: self.services.automation)
            let eventSynthesizing = self.services.permissions.checkPostEventPermission()
            return AgentPermissionStatusPayload(
                screen_recording: screenRecording,
                accessibility: accessibility,
                event_synthesizing: eventSynthesizing
            )
        }

        private func render(status: AgentPermissionStatusPayload) {
            if self.jsonOutput {
                outputSuccessCodable(data: status, logger: self.logger)
                return
            }

            print("Peekaboo Permission Status")
            print("==========================\n")
            self.printStatusLine(label: "Screen Recording", granted: status.screen_recording)
            self.printStatusLine(label: "Accessibility", granted: status.accessibility)
            self.printStatusLine(label: "Event Synthesizing", granted: status.event_synthesizing)

            if !status.screen_recording || !status.accessibility {
                print("\nTo grant missing required permissions:")
                if !status.screen_recording {
                    print("- Run: peekaboo agent permission request-screen-recording")
                }
                if !status.accessibility {
                    print("- Run: peekaboo agent permission request-accessibility")
                }
            }

            if !status.event_synthesizing {
                print("\nOptional for background input:")
                print("- Run: peekaboo agent permission request-event-synthesizing")
            }
        }

        private func printStatusLine(label: String, granted: Bool) {
            let state = granted ? "✅ Granted" : "❌ Not granted"
            print("\(label): \(state)")
        }
    }
}

private struct AgentPermissionStatusPayload: Codable {
    let screen_recording: Bool
    let accessibility: Bool
    let event_synthesizing: Bool
}

extension PermissionCommand.StatusSubcommand: ParsableCommand {}

extension PermissionCommand.StatusSubcommand: AsyncRuntimeCommand {}
