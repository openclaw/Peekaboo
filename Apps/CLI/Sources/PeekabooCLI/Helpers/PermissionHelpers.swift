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

    /// Try to fetch permissions from a remote Peekaboo Bridge host; falls back to local services on failure.
    @MainActor
    private static func remotePermissionsStatus(
        services: any PeekabooServiceProviding,
        socketPath override: String? = nil
    ) async -> PermissionsStatus? {
        let environment = ProcessInfo.processInfo.environment
        let envSocket = environment["PEEKABOO_BRIDGE_SOCKET"]
        let resolvedOverride = override ?? envSocket

        if resolvedOverride == nil,
           let remoteServices = services as? RemotePeekabooServices,
           let status = try? await remoteServices.permissionsStatus() {
            return status
        }

        let candidates = self.remotePermissionSocketPaths(
            explicitSocket: resolvedOverride,
            environment: environment
        )

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: Host.current().name
        )

        for socketPath in candidates {
            let client = PeekabooBridgeClient(socketPath: socketPath)
            do {
                let handshake = try await client.handshake(client: identity, requestedHost: nil)
                if resolvedOverride == nil {
                    guard let role = DaemonLaunchPolicy.implicitRuntimeCandidateRole(
                        socketPath: socketPath,
                        daemonSocketPath: DaemonLaunchPolicy.daemonSocketPath(environment: environment)
                    ) else {
                        continue
                    }
                    let daemonStatus = handshake.hostKind == .gui
                        ? nil
                        : await DaemonControlClient(socketPath: socketPath).fetchStatus()
                    guard DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
                        role: role,
                        handshake: handshake,
                        daemonStatus: daemonStatus
                    ) else {
                        continue
                    }
                }
                guard handshake.supportedOperations.contains(.permissionsStatus) else { continue }
                return try await client.permissionsStatus()
            } catch {
                continue
            }
        }
        return nil
    }

    static func remotePermissionSocketPaths(
        explicitSocket: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        if let explicitSocket, !explicitSocket.isEmpty {
            return [explicitSocket]
        }
        let daemonPath = DaemonLaunchPolicy.daemonSocketPath(environment: environment)
        guard DaemonLaunchPolicy.shouldMigrateLegacyDaemon(targetSocketPath: daemonPath) else {
            return [daemonPath]
        }
        return [daemonPath, PeekabooBridgeConstants.peekabooSocketPath]
    }

    /// Get current permission status for all Peekaboo permissions
    static func getCurrentPermissions(
        services: any PeekabooServiceProviding,
        allowRemote: Bool = true,
        socketPath: String? = nil
    ) async -> [PermissionInfo] {
        let response = await self.getCurrentPermissionsWithSource(
            services: services,
            allowRemote: allowRemote,
            socketPath: socketPath
        )
        return response.permissions
    }

    /// Get current permission status along with whether a remote helper responded.
    static func getCurrentPermissionsWithSource(
        services: any PeekabooServiceProviding,
        allowRemote: Bool = true,
        socketPath: String? = nil
    ) async -> PermissionStatusResponse {
        // Prefer remote host when available so sandboxes can reuse existing TCC grants.
        let remoteStatus = allowRemote
            ? await self.remotePermissionsStatus(services: services, socketPath: socketPath)
            : nil

        let status: PermissionsStatus
        let source: String
        if let remoteStatus {
            status = remoteStatus
            source = "bridge"
        } else {
            status = await self.localPermissionsStatus(services: services)
            source = "local"
        }
        return PermissionStatusResponse(source: source, permissions: self.permissionList(from: status))
    }

    static func getAllPermissionSources(
        services: any PeekabooServiceProviding,
        allowRemote: Bool = true,
        socketPath: String? = nil
    ) async -> PermissionSourcesResponse {
        let remoteStatus = allowRemote
            ? await self.remotePermissionsStatus(services: services, socketPath: socketPath)
            : nil
        let localStatus = await self.localPermissionsStatus(services: services)
        let selectedSource = remoteStatus != nil ? "bridge" : "local"
        var sources: [PermissionSourceStatus] = []

        if let remoteStatus {
            sources.append(PermissionSourceStatus(
                source: "bridge",
                displayName: "Peekaboo Bridge",
                isSelected: selectedSource == "bridge",
                permissions: self.permissionList(from: remoteStatus)
            ))
        }

        sources.append(PermissionSourceStatus(
            source: "local",
            displayName: "local runtime",
            isSelected: selectedSource == "local",
            permissions: self.permissionList(from: localStatus)
        ))

        return PermissionSourcesResponse(selectedSource: selectedSource, sources: sources)
    }

    private static func localPermissionsStatus(services: any PeekabooServiceProviding) async -> PermissionsStatus {
        await Task { @MainActor in
            let localServices: any PeekabooServiceProviding = services is RemotePeekabooServices
                ? PeekabooServices()
                : services
            let screenRecording = await localServices.screenCapture.hasScreenRecordingPermission()
            let accessibility = await localServices.automation.hasAccessibilityPermission()
            let postEvent = localServices.permissions.checkPostEventPermission()
            return PermissionsStatus(
                screenRecording: screenRecording,
                accessibility: accessibility,
                postEvent: postEvent
            )
        }.value
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
        services: any PeekabooServiceProviding
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
                let granted = try await remoteServices.requestPostEventPermission()
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

        let granted = permissions.requestPostEventPermission(interactive: true)
        return .init(
            action: "request-event-synthesizing",
            source: "local",
            already_granted: false,
            prompt_triggered: true,
            granted: granted
        )
    }

    /// Format permission status for display
    static func formatPermissionStatus(_ permission: PermissionInfo) -> String {
        let status = permission.isGranted ? "Granted" : "Not Granted"
        let requirement = permission.isRequired ? "Required" : "Optional"
        return "\(permission.name) (\(requirement)): \(status)"
    }

    static func bridgeScreenRecordingHint(for response: PermissionStatusResponse) -> String? {
        guard response.source == "bridge",
              response.permissions.contains(where: { permission in
                  permission.name == "Screen Recording" && !permission.isGranted
              })
        else { return nil }

        return "Hint: status came from the selected Peekaboo Bridge host. Grant Screen Recording to that " +
            "host app, or run capture commands with --no-remote --capture-engine cg when the caller " +
            "process already has permission."
    }

    /// Format permissions for help display with dynamic status
    static func formatPermissionsForHelp(
        services: any PeekabooServiceProviding
    ) async -> String {
        // Format permissions for help display with dynamic status
        let permissions = await self.getCurrentPermissions(services: services)
        var output = ["PERMISSIONS:"]

        for permission in permissions {
            output.append("  \(self.formatPermissionStatus(permission))")

            // Only show grant instructions if permission is not granted
            if !permission.isGranted {
                output.append("    Grant via: \(permission.grantInstructions)")
            }
        }

        output.append("")
        output.append("Check detailed permission status:")
        output.append("  peekaboo permissions")

        return output.joined(separator: "\n")
    }
}
