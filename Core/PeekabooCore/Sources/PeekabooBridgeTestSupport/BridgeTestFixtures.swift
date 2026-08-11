import PeekabooAutomationKit
import PeekabooBridge

/// Canonical builders for Bridge protocol and transport tests.
public enum BridgeTestFixtures {
    /// Builds one internally coherent handshake while keeping protocol versions explicit at every call site.
    public static func handshake(
        negotiatedVersion: PeekabooBridgeProtocolVersion,
        hostKind: PeekabooBridgeHostKind = .onDemand,
        build: String? = nil,
        supportedOperations: [PeekabooBridgeOperation],
        permissions: PermissionsStatus? = nil,
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        permissionTags: [String: [PeekabooBridgePermissionKind]] = [:],
        hostIdentity: PeekabooBridgeHostIdentity? = nil,
        hostCapabilities: [String]? = nil) -> PeekabooBridgeHandshakeResponse
    {
        if let enabledOperations {
            precondition(
                Set(enabledOperations).isSubset(of: Set(supportedOperations)),
                "Enabled Bridge operations must be a subset of supported operations")
        }
        return PeekabooBridgeHandshakeResponse(
            negotiatedVersion: negotiatedVersion,
            hostKind: hostKind,
            build: build,
            supportedOperations: supportedOperations,
            permissions: permissions,
            enabledOperations: enabledOperations,
            permissionTags: permissionTags,
            hostIdentity: hostIdentity,
            hostCapabilities: hostCapabilities)
    }

    public static func errorResponse(
        code: PeekabooBridgeErrorCode,
        message: String,
        details: String? = nil,
        permission: PeekabooBridgePermissionKind? = nil,
        kind: PeekabooBridgeErrorKind? = nil,
        context: String? = nil,
        operationMayHaveCompleted: Bool = false) -> PeekabooBridgeResponse
    {
        .error(PeekabooBridgeErrorEnvelope(
            code: code,
            message: message,
            details: details,
            permission: permission,
            kind: kind,
            context: context,
            operationMayHaveCompleted: operationMayHaveCompleted))
    }
}
