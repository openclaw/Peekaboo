import Commander
import Foundation
import PeekabooBridge
import PeekabooCore

/// Shared permission checking and formatting utilities
enum PermissionHelpers {
    struct PermissionInfo: Codable {
        let name: String
        let isRequired: Bool
        let isGranted: Bool
        let grantInstructions: String
    }

    struct PermissionStatusResponse: Codable {
        let source: String
        let permissions: [PermissionInfo]
    }

    struct PermissionSourceStatus: Codable {
        let source: String
        let displayName: String
        let isSelected: Bool
        let permissions: [PermissionInfo]
    }

    struct PermissionSourcesResponse: Codable {
        let selectedSource: String
        let sources: [PermissionSourceStatus]
    }

    struct EventSynthesizingPermissionRequestResult: Codable {
        let action: String
        let source: String
        let already_granted: Bool
        let prompt_triggered: Bool
        let granted: Bool?
    }

    static let remoteEventSynthesizingUnsupportedMessage = """
    Remote bridge host cannot request Event Synthesizing permission. \
    Update the host or run with --no-remote to request it for the local CLI.
    """

    /// Get current permission status for all Peekaboo permissions
    static func getCurrentPermissions(
        services: any PeekabooServiceProviding
    ) async throws -> [PermissionInfo] {
        let response = try await getCurrentPermissionsWithSource(services: services)
        return response.permissions
    }

    /// Read one complete snapshot from the runtime-selected execution host.
    static func getCurrentPermissionsWithSource(
        services: any PeekabooServiceProviding
    ) async throws -> PermissionStatusResponse {
        let status = try await services.permissionsStatus()
        let source = services is RemotePeekabooServices ? "bridge" : "local"
        return PermissionStatusResponse(source: source, permissions: self.permissionList(from: status))
    }

    static func getAllPermissionSources(
        services: any PeekabooServiceProviding
    ) async throws -> PermissionSourcesResponse {
        let selectedStatus = try await services.permissionsStatus()
        let selectedSource = services is RemotePeekabooServices ? "bridge" : "local"
        var sources: [PermissionSourceStatus] = []

        if selectedSource == "bridge" {
            sources.append(PermissionSourceStatus(
                source: "bridge",
                displayName: "Peekaboo Bridge",
                isSelected: true,
                permissions: self.permissionList(from: selectedStatus)
            ))
            let localStatus = try await PermissionsService().permissionsStatus()
            sources.append(PermissionSourceStatus(
                source: "local",
                displayName: "local runtime",
                isSelected: false,
                permissions: self.permissionList(from: localStatus)
            ))
        } else {
            sources.append(PermissionSourceStatus(
                source: "local",
                displayName: "local runtime",
                isSelected: true,
                permissions: self.permissionList(from: selectedStatus)
            ))
        }

        return PermissionSourcesResponse(selectedSource: selectedSource, sources: sources)
    }

    private static func permissionList(from status: PermissionsStatus) -> [PermissionInfo] {
        [
            PermissionInfo(
                name: "Screen Recording",
                isRequired: true,
                isGranted: status.screenRecording,
                grantInstructions: "System Settings > Privacy & Security > Screen Recording"
            ),
            PermissionInfo(
                name: "Accessibility",
                isRequired: true,
                isGranted: status.accessibility,
                grantInstructions: "System Settings > Privacy & Security > Accessibility"
            ),
            PermissionInfo(
                name: "Event Synthesizing",
                isRequired: false,
                isGranted: status.postEvent,
                grantInstructions: "System Settings > Privacy & Security > Accessibility"
            )
        ]
    }

    @MainActor
    static func requestEventSynthesizingPermission(
        services: any PeekabooServiceProviding,
        runtime: CommandRuntime
    ) async throws -> EventSynthesizingPermissionRequestResult {
        if let remoteServices = services as? RemotePeekabooServices {
            let status = try await remoteServices.permissionsStatus()
            if status.postEvent {
                return .init(
                    action: "request-event-synthesizing",
                    source: "bridge",
                    already_granted: true,
                    prompt_triggered: false,
                    granted: true
                )
            }

            do {
                let granted = try await self.performInteractivePermissionRequest(using: runtime) {
                    try await remoteServices.requestPostEventPermission()
                }
                return .init(
                    action: "request-event-synthesizing",
                    source: "bridge",
                    already_granted: false,
                    prompt_triggered: true,
                    granted: granted
                )
            } catch let envelope as PeekabooBridgeErrorEnvelope where envelope.code == .operationNotSupported {
                throw ValidationError(self.remoteEventSynthesizingUnsupportedMessage)
            }
        }

        let permissions = services.permissions
        if permissions.checkPostEventPermission() {
            return .init(
                action: "request-event-synthesizing",
                source: "local",
                already_granted: true,
                prompt_triggered: false,
                granted: true
            )
        }

        let granted = await self.performInteractivePermissionRequest(using: runtime) {
            permissions.requestPostEventPermission(interactive: true)
        }
        return .init(
            action: "request-event-synthesizing",
            source: "local",
            already_granted: false,
            prompt_triggered: true,
            granted: granted
        )
    }

    @MainActor
    static func performInteractivePermissionRequest<T>(
        using runtime: CommandRuntime,
        _ request: @MainActor () async throws -> T
    ) async rethrows -> T {
        runtime.beginInteractionMutation()
        return try await request()
    }

    /// Format permission status for display
    static func formatPermissionStatus(_ permission: PermissionInfo) -> String {
        let status = permission.isGranted ? "Granted" : "Not Granted"
        let requirement = permission.isRequired ? "Required" : "Optional"
        return "\(permission.name) (\(requirement)): \(status)"
    }

    /// Bridge-sourced denials are the most common support confusion: the TCC grant must live on the
    /// host app that answered, not on the CLI or the calling terminal. `grantInstructions` only names
    /// the System Settings pane, so without this hint a denial sends people to grant the wrong bundle
    /// and the status never changes. Covers every denied permission, not just Screen Recording.
    static func bridgeDeniedPermissionsHint(for response: PermissionStatusResponse) -> String? {
        guard response.source == "bridge" else { return nil }
        let denied = response.permissions.filter { !$0.isGranted }
        guard !denied.isEmpty else { return nil }

        var hint = "Hint: status came from the selected Peekaboo Bridge host. Grant " +
            "\(denied.map(\.name).joined(separator: ", ")) to that host app — granting the CLI or your " +
            "terminal will not change this status. Run peekaboo bridge status to see which host answered, " +
            "or pass --no-remote to use the local runtime instead."
        if denied.contains(where: { $0.name == "Screen Recording" }) {
            hint += " For capture, --no-remote --capture-engine cg works when the caller process already " +
                "has permission."
        }
        return hint
    }
}
