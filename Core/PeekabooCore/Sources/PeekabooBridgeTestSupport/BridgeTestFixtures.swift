import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

/// Canonical builders for Bridge protocol and transport tests.
public enum BridgeTestFixtures {
    public static let authenticatedHostTeamIdentifier = "PEEKABOO-TEST-HOST"

    public struct ScrollHandshakeCase: Sendable, CustomStringConvertible {
        public let name: String
        public let handshake: PeekabooBridgeHandshakeResponse
        public let targetedScroll: Bool
        public let requestPinnedScroll: Bool
        public let coordinateScroll: Bool

        public var description: String {
            self.name
        }
    }

    /// Shared expectations for negotiated scroll support, independent of live host admission.
    public static var scrollHandshakeCases: [ScrollHandshakeCase] {
        let attested = PeekabooBridgeHostCapability.attestedOperationReceipts
        let pinned = PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt
        let coordinates = PeekabooBridgeHostCapability.backgroundCoordinateScroll
        let complete = [attested, pinned, coordinates]
        func fixture(
            _ name: String,
            minor: Int,
            capabilities: [String]?,
            supported: [PeekabooBridgeOperation] = [.targetedScroll],
            enabled: [PeekabooBridgeOperation]? = [.targetedScroll],
            expected: (targeted: Bool, receipt: Bool, coordinate: Bool)) -> ScrollHandshakeCase
        {
            ScrollHandshakeCase(
                name: name,
                handshake: Self.handshake(
                    negotiatedVersion: .init(major: 1, minor: minor),
                    supportedOperations: supported,
                    enabledOperations: enabled,
                    hostCapabilities: capabilities),
                targetedScroll: expected.targeted,
                requestPinnedScroll: expected.receipt,
                coordinateScroll: expected.coordinate)
        }
        return [
            fixture(
                "before targeted scroll",
                minor: 10,
                capabilities: complete,
                expected: (false, false, false)),
            fixture(
                "targeted scroll boundary",
                minor: 11,
                capabilities: complete,
                expected: (true, false, false)),
            fixture(
                "before pinned receipts",
                minor: 34,
                capabilities: complete,
                expected: (true, false, false)),
            fixture(
                "pinned receipt boundary",
                minor: 35,
                capabilities: complete,
                expected: (true, true, false)),
            fixture(
                "before coordinate scroll",
                minor: 42,
                capabilities: complete,
                expected: (true, true, false)),
            fixture(
                "coordinate scroll boundary",
                minor: 43,
                capabilities: complete,
                expected: (true, true, true)),
            fixture(
                "newer protocol",
                minor: 44,
                capabilities: complete,
                expected: (true, true, true)),
            fixture(
                "missing attested receipts",
                minor: 43,
                capabilities: [pinned, coordinates],
                expected: (true, false, false)),
            fixture(
                "missing pinned receipts",
                minor: 43,
                capabilities: [attested, coordinates],
                expected: (true, false, false)),
            fixture(
                "missing coordinate capability",
                minor: 43,
                capabilities: [attested, pinned],
                expected: (true, true, false)),
            fixture(
                "omitted capabilities",
                minor: 43,
                capabilities: nil,
                expected: (true, false, false)),
            fixture(
                "empty capabilities",
                minor: 43,
                capabilities: [],
                expected: (true, false, false)),
            fixture(
                "unsupported operation",
                minor: 43,
                capabilities: complete,
                supported: [],
                enabled: nil,
                expected: (false, false, false)),
            fixture(
                "explicitly disabled operation",
                minor: 43,
                capabilities: complete,
                enabled: [],
                expected: (false, false, false)),
            fixture(
                "legacy enabled list omitted",
                minor: 43,
                capabilities: complete,
                enabled: nil,
                expected: (true, true, true)),
        ]
    }

    #if DEBUG
    /// Creates a client that authenticates a real test listener by its audit-token-bound live CDHash.
    ///
    /// Production clients additionally require an Apple-anchored signing Team ID. SwiftPM test
    /// executables are ad-hoc signed, so this factory replaces only that certificate claim while
    /// retaining the live socket peer, process generation, and executable hash checks.
    public static func authenticatedClient(
        socketPath: String,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String> = [BridgeTestFixtures.authenticatedHostTeamIdentifier],
        signingTeamIdentifier: String = BridgeTestFixtures.authenticatedHostTeamIdentifier)
        -> PeekabooBridgeClient
    {
        PeekabooBridgeClient.authenticatedTestClient(
            socketPath: socketPath,
            maxResponseBytes: maxResponseBytes,
            requestTimeoutSec: requestTimeoutSec,
            operationReceiptExportDirectory: operationReceiptExportDirectory,
            operationClientInstanceID: operationClientInstanceID,
            trustedHostTeamIDs: trustedHostTeamIDs,
            signingTeamIdentifier: signingTeamIdentifier)
    }
    #endif

    /// Mirrors the canonical type-action accounting used by the real automation service and Bridge receipts.
    public static func typeResult(for actions: [TypeAction]) -> TypeResult {
        var totalCharacters = 0
        var keyPresses = 0
        var specialKeyPresses = 0
        for action in actions {
            switch action {
            case let .text(text):
                totalCharacters += text.count
                keyPresses += text.count
            case .key:
                keyPresses += 1
                specialKeyPresses += 1
            case .clear:
                keyPresses += 2
                specialKeyPresses += 2
            }
        }
        return TypeResult(
            totalCharacters: totalCharacters,
            keyPresses: keyPresses,
            specialKeyPresses: specialKeyPresses)
    }

    /// Builds one wire-coherent handshake while keeping protocol versions explicit at every call site.
    ///
    /// Protocol 1.29 fixtures that model a receipt-capable handshake must pass both the stable listener
    /// attestation and its peer-bound logical operation session. Older and deliberately incomplete fixtures
    /// leave both fields `nil`.
    public static func handshake(
        negotiatedVersion: PeekabooBridgeProtocolVersion,
        hostKind: PeekabooBridgeHostKind = .onDemand,
        build: String? = nil,
        supportedOperations: [PeekabooBridgeOperation],
        permissions: PermissionsStatus? = nil,
        enabledOperations: [PeekabooBridgeOperation]? = nil,
        permissionTags: [String: [PeekabooBridgePermissionKind]] = [:],
        hostIdentity: PeekabooBridgeHostIdentity? = nil,
        hostCapabilities: [String]? = nil,
        operationAttestation: PeekabooBridgeListenerAttestation? = nil,
        operationSessionAttestation: PeekabooBridgeOperationSessionAttestation? = nil)
        -> PeekabooBridgeHandshakeResponse
    {
        if let enabledOperations {
            precondition(
                Set(enabledOperations).isSubset(of: Set(supportedOperations)),
                "Enabled Bridge operations must be a subset of supported operations")
        }
        precondition(
            (operationAttestation == nil) == (operationSessionAttestation == nil),
            "Bridge operation listener and session attestations must be supplied together")
        return PeekabooBridgeHandshakeResponse(
            negotiatedVersion: negotiatedVersion,
            hostKind: hostKind,
            build: build,
            supportedOperations: supportedOperations,
            permissions: permissions,
            enabledOperations: enabledOperations,
            permissionTags: permissionTags,
            hostIdentity: hostIdentity,
            hostCapabilities: hostCapabilities,
            operationAttestation: operationAttestation,
            operationSessionAttestation: operationSessionAttestation)
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
