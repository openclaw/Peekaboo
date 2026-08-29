import Darwin
import Foundation
import OSLog
import PeekabooAutomationKit
import PeekabooFoundation
import Security

extension PeekabooBridgeHost {
    nonisolated static func handleClient(
        fd: Int32,
        connection: PeekabooBridgeConnectionLiveness,
        context: PeekabooBridgeClientContext) async
    {
        do {
            guard let liveIdentity = try? context.authentication.liveIdentity(fd) else {
                try await self.writeUnauthorizedResponse(fd: fd, context: context)
                return
            }
            let hasProvisionalSession = context.operationReceiptAuthority?.hasProvisionalSession(
                for: liveIdentity) == true
            let initialColdPeer = hasProvisionalSession
                ? nil
                : context.authentication.coldPeer(liveIdentity, context.allowedTeamIDs)
            guard hasProvisionalSession || initialColdPeer != nil else {
                try await self.writeUnauthorizedResponse(fd: fd, context: context)
                return
            }
            guard await self.waitForCapacityPermit(
                connection: connection,
                limiter: context.bodyReadLimiter,
                timeoutSec: context.requestTimeoutSec)
            else {
                try await self.writePreDecodeBusyResponse(fd: fd, context: context)
                return
            }
            var holdsBodyReadPermit = true
            defer {
                if holdsBodyReadPermit {
                    context.bodyReadLimiter.finish()
                }
            }

            let readDeadline = Date().addingTimeInterval(context.requestTimeoutSec)
            let requestData = try await PeekabooBridgeBlockingIO.run {
                try PeekabooBridgeSocketIO.readAll(
                    fd: fd,
                    maxBytes: context.maxMessageBytes,
                    deadline: readDeadline)
            }
            let request: PeekabooBridgeRequest
            do {
                request = try await context.server.decodeRequest(requestData)
            } catch {
                let responseData = await context.server.encodeDecodingFailure(error)
                try await self.writeResponse(
                    fd: fd,
                    data: responseData,
                    deadline: Date().addingTimeInterval(context.requestTimeoutSec))
                return
            }
            context.bodyReadLimiter.finish()
            holdsBodyReadPermit = false

            let peer: PeekabooBridgePeer?
            let authorizationPin: PeekabooBridgeOperationReceiptAuthority.SessionAuthorizationPin?
            if case let .attestedOperation(payload) = request {
                let authorization = context.operationReceiptAuthority?.authorizeSession(
                    sessionID: payload.sessionID,
                    liveIdentity: liveIdentity)
                // After a listener restart there is no provisional session. Let the cold-authenticated peer reach
                // the receipt authority so it can return the canonical listener/session refusal used for reconnect.
                // If some provisional session did match, an absent exact session is a foreign-session mismatch and
                // must never cold-rebind.
                peer = authorization?.peer ?? (hasProvisionalSession ? nil : initialColdPeer)
                authorizationPin = authorization?.pin
            } else {
                // Handshakes and receiptless legacy requests always repeat the full certificate/team authorization.
                peer = initialColdPeer ?? context.authentication.coldPeer(
                    liveIdentity,
                    context.allowedTeamIDs)
                authorizationPin = nil
            }
            guard let peer else {
                try await self.writeUnauthorizedResponse(fd: fd, context: context)
                return
            }

            var transferredAuthorizationPin = false
            defer {
                if !transferredAuthorizationPin {
                    authorizationPin?.release()
                }
            }
            guard let trackedRequest = context.requestTracker.begin() else {
                guard await self.waitForCapacityPermit(
                    connection: connection,
                    limiter: context.admissionRefusalLimiter,
                    timeoutSec: context.requestTimeoutSec)
                else {
                    try await self.writeRefusalOverflowResponse(fd: fd, context: context)
                    return
                }
                defer { context.admissionRefusalLimiter.finish() }
                let responseData = await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(
                    context.operationReceiptAuthority)
                {
                    await context.server.encodeAdmissionRefusal(request, peer: peer)
                }
                try await self.writeResponse(
                    fd: fd,
                    data: responseData,
                    deadline: Date().addingTimeInterval(context.requestTimeoutSec))
                return
            }
            var transferredRequestAdmission = false
            defer {
                if !transferredRequestAdmission {
                    context.requestTracker.finish(trackedRequest)
                }
            }

            transferredAuthorizationPin = true
            transferredRequestAdmission = true
            guard let responseData = await PeekabooBridgeConnectedRequest.handle(
                request: request,
                trackedRequest: trackedRequest,
                context: .init(
                    server: context.server,
                    peer: peer,
                    connection: connection,
                    requestTracker: context.requestTracker,
                    operationReceiptAuthority: context.operationReceiptAuthority,
                    operationSessionAuthorizationPin: authorizationPin))
            else {
                return
            }

            try await self.writeResponse(
                fd: fd,
                data: responseData,
                deadline: Date().addingTimeInterval(context.requestTimeoutSec))
        } catch {
            self.logger.error("bridge socket request failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    private nonisolated static func writeResponse(fd: Int32, data: Data, deadline: Date) async throws {
        try await PeekabooBridgeBlockingIO.run {
            try PeekabooBridgeSocketIO.writeAll(fd: fd, data: data, deadline: deadline)
        }
    }

    private nonisolated static func waitForCapacityPermit(
        connection: PeekabooBridgeConnectionLiveness,
        limiter: PeekabooBridgeCapacityLimiter,
        timeoutSec: TimeInterval) async -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSec))
        while !Task.isCancelled {
            if limiter.begin() {
                return true
            }
            guard ContinuousClock.now < deadline,
                  connection.canReceiveResponse()
            else { return false }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return false
            }
        }
        return false
    }

    private nonisolated static func writePreDecodeBusyResponse(
        fd: Int32,
        context: PeekabooBridgeClientContext) async throws
    {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .serverBusy,
            message: "Bridge request body admission is temporarily saturated",
            details: "No request body was decoded or dispatched.",
            operationMayHaveCompleted: false)
        try await self.writeResponse(
            fd: fd,
            data: PeekabooBridgeResponse.encodeError(envelope),
            deadline: Date().addingTimeInterval(context.requestTimeoutSec))
    }

    private nonisolated static func writeRefusalOverflowResponse(
        fd: Int32,
        context: PeekabooBridgeClientContext) async throws
    {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .serverBusy,
            message: "Bridge refusal-signing capacity is temporarily saturated",
            details: "The decoded request was not claimed or dispatched.",
            operationMayHaveCompleted: false)
        try await self.writeResponse(
            fd: fd,
            data: PeekabooBridgeResponse.encodeError(envelope),
            deadline: Date().addingTimeInterval(context.requestTimeoutSec))
    }

    private nonisolated static func writeUnauthorizedResponse(
        fd: Int32,
        context: PeekabooBridgeClientContext) async throws
    {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .unauthorizedClient,
            message: "Bridge client is not authorized",
            details: """
            The host rejected the client before processing the request. Ensure the client is signed by an \
            allowlisted TeamID (\(context.allowedTeamIDs.sorted()
                .joined(separator: ", "))) or launch the host with \
            PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 for local development.
            """)
        try await self.writeResponse(
            fd: fd,
            data: PeekabooBridgeResponse.encodeError(envelope),
            deadline: Date().addingTimeInterval(context.requestTimeoutSec))
    }

    nonisolated static func peerInfoIfAllowed(
        fd: Int32,
        allowedTeamIDs: Set<String>,
        signingIdentityProvider: (PeekabooBridgePeerAuditIdentity) -> PeerSigningIdentity? = {
            PeekabooBridgeHost.signingIdentity(auditIdentity: $0)
        }) -> PeekabooBridgePeer?
    {
        guard let liveIdentity = try? PeekabooBridgeSocketIO.livePeerIdentity(fd: fd) else { return nil }
        return self.peerInfoIfAllowed(
            liveIdentity: liveIdentity,
            allowedTeamIDs: allowedTeamIDs,
            signingIdentityProvider: signingIdentityProvider)
    }

    nonisolated static func peerInfoIfAllowed(
        liveIdentity: PeekabooBridgeLivePeerIdentity,
        allowedTeamIDs: Set<String>,
        signingIdentityProvider: (PeekabooBridgePeerAuditIdentity) -> PeerSigningIdentity? = {
            PeekabooBridgeHost.signingIdentity(auditIdentity: $0)
        },
        allowUnsignedSocketClients: Bool = PeekabooBridgeHost.allowUnsignedSocketClients) -> PeekabooBridgePeer?
    {
        guard let auditIdentity = liveIdentity.auditIdentity else { return nil }
        guard SystemIdentityResolver.processStartIdentity(auditIdentity.processIdentifier) ==
            liveIdentity.processStartIdentity
        else {
            return nil
        }
        let signingIdentity: PeerSigningIdentity?
        if let candidate = signingIdentityProvider(auditIdentity) {
            if let liveHash = liveIdentity.codeSignatureHash,
               !liveHash.isEmpty,
               let candidateHash = candidate.codeSignatureHash,
               !candidateHash.isEmpty
            {
                guard candidateHash == liveHash else { return nil }
                signingIdentity = candidate
            } else {
                // Metadata that cannot be bound to this exact live executable is untrusted. Same-UID legacy or
                // explicit DEBUG access may still proceed, but only as an unsigned peer with no team/bundle claims.
                signingIdentity = nil
            }
        } else {
            signingIdentity = nil
        }
        let pid = liveIdentity.processIdentifier
        let callerUID = liveIdentity.effectiveUserIdentifier

        if allowedTeamIDs.isEmpty, callerUID == getuid() {
            return self.peer(
                liveIdentity: liveIdentity,
                signingIdentity: signingIdentity,
                teamIdentifier: signingIdentity?.teamIdentifier)
        }

        let teamID = signingIdentity?.teamIdentifier
        if let teamID, allowedTeamIDs.contains(teamID) {
            return self.peer(
                liveIdentity: liveIdentity,
                signingIdentity: signingIdentity,
                teamIdentifier: teamID)
        }

        #if DEBUG
        if allowUnsignedSocketClients, callerUID == getuid() {
            self.logger.warning(
                "allowing unsigned bridge client pid=\(pid, privacy: .public) (debug override)")
            return self.peer(
                liveIdentity: liveIdentity,
                signingIdentity: signingIdentity,
                teamIdentifier: nil)
        }
        #endif

        self.logger.error("bridge client rejected pid=\(pid, privacy: .public) uid=\(callerUID, privacy: .public)")
        return nil
    }

    private nonisolated static var allowUnsignedSocketClients: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS"] == "1"
        #else
        false
        #endif
    }

    private nonisolated static func peer(
        liveIdentity: PeekabooBridgeLivePeerIdentity,
        signingIdentity: PeerSigningIdentity?,
        teamIdentifier: String?) -> PeekabooBridgePeer
    {
        PeekabooBridgePeer(
            liveIdentity: liveIdentity,
            bundleIdentifier: signingIdentity?.bundleIdentifier,
            teamIdentifier: teamIdentifier)
    }

    nonisolated static func signingIdentity(
        auditIdentity: PeekabooBridgePeerAuditIdentity,
        systemCall: PeekabooBridgeCodeSignatureIdentity.AuditTokenCDHashSystemCall,
        staticSigningInformationProvider:
        PeekabooBridgeCodeSignatureIdentity.StaticSigningInformationProvider,
        anchoredSignatureValidationProvider:
        PeekabooBridgeCodeSignatureIdentity.AnchoredSignatureValidationProvider) -> PeerSigningIdentity?
    {
        guard let information = PeekabooBridgeCodeSignatureIdentity.signingInformation(
            auditIdentity: auditIdentity,
            systemCall: systemCall,
            staticSigningInformationProvider: staticSigningInformationProvider,
            anchoredSignatureValidationProvider: anchoredSignatureValidationProvider)
        else { return nil }
        return self.signingIdentity(information: information)
    }

    nonisolated static func signingIdentity(
        auditIdentity: PeekabooBridgePeerAuditIdentity) -> PeerSigningIdentity?
    {
        guard let information = PeekabooBridgeCodeSignatureIdentity.signingInformation(
            auditIdentity: auditIdentity)
        else { return nil }
        return self.signingIdentity(information: information)
    }

    nonisolated static func signingIdentity(
        pid: pid_t,
        signingInformationProvider: PeerSigningInformationProvider = signingInformation) -> PeerSigningIdentity?
    {
        guard pid == getpid() else { return nil }
        guard let info = signingInformationProvider(pid) else { return nil }
        return self.signingIdentity(information: info)
    }

    private nonisolated static func signingIdentity(
        information info: [String: Any]) -> PeerSigningIdentity
    {
        let teamIdentifier: String? = if let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String {
            teamID
        } else if let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
                  let appIdentifier = entitlements["application-identifier"] as? String,
                  let prefix = appIdentifier.split(separator: ".").first
        {
            String(prefix)
        } else {
            nil
        }
        return PeerSigningIdentity(
            bundleIdentifier: info[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: teamIdentifier,
            codeSignatureHash: (info[kSecCodeInfoUnique as String] as? Data)?
                .map { String(format: "%02x", $0) }.joined(),
            sourceCommit: (info[kSecCodeInfoPList as String] as? [String: Any])
                .flatMap { SourceProvenance.exactCommit($0["PeekabooSourceCommit"] as? String) })
    }

    private nonisolated static func signingInformation(pid: pid_t) -> [String: Any]? {
        guard pid == getpid() else { return nil }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let information = information as? [String: Any]
        else { return nil }
        return information
    }
}
