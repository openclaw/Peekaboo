import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

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

    /// Builds the pre-canonical Bridge error shape for compatibility tests.
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

    public static func actionFailureResponse(
        code: PeekabooBridgeErrorCode = .internalError,
        failure: DesktopActionFailure,
        details: String? = nil,
        permission: PeekabooBridgePermissionKind? = nil,
        kind: PeekabooBridgeErrorKind? = nil,
        context: String? = nil) -> PeekabooBridgeResponse
    {
        .error(PeekabooBridgeErrorEnvelope(
            code: code,
            actionFailure: failure,
            details: details,
            permission: permission,
            kind: kind,
            context: context))
    }

    /// Builds the canonical legacy response paired with a desktop-action outcome in projection tests.
    ///
    /// Confirmed outcomes retain the historical success shape. Every other outcome retains the historical
    /// error shape, including the conservative compatibility bit that old clients understand.
    public static func actionResponse(for outcome: DesktopActionOutcome) -> PeekabooBridgeResponse {
        guard !outcome.isConfirmed else { return .ok }
        return self.errorResponse(
            code: .internalError,
            message: "Fixture \(outcome.state.rawValue)",
            details: "Fixture details \(outcome.state.rawValue)",
            permission: .accessibility,
            kind: .appNotFound,
            context: "fixture:\(outcome.state.rawValue)",
            operationMayHaveCompleted: outcome.projection.mutationDispatched)
    }

    /// Wraps the canonical legacy response and its matching action projection in the additive current carriage.
    public static func projectedActionResponse(for outcome: DesktopActionOutcome) -> PeekabooBridgeResponse {
        let legacyResponse = self.actionResponse(for: outcome)
        let response: PeekabooBridgeResponse
        if case let .error(error) = legacyResponse {
            guard let failure = DesktopActionFailure(
                outcome: outcome,
                message: error.message)
            else {
                preconditionFailure("A confirmed outcome cannot produce a fixture error response")
            }
            response = self.actionFailureResponse(
                code: error.code,
                failure: failure,
                details: error.details,
                permission: error.permission,
                kind: error.kind,
                context: error.context)
        } else {
            response = legacyResponse
        }
        return .projectedAction(.init(
            response: response,
            outcome: outcome.projection))
    }
}
