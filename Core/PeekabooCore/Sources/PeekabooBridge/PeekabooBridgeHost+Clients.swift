import Darwin
import Foundation
import OSLog
import PeekabooAutomationKit
import Security

extension PeekabooBridgeHost {
    nonisolated static func handleClient(
        fd: Int32,
        connection: PeekabooBridgeConnectionLiveness,
        context: PeekabooBridgeClientContext) async
    {
        let peer = self.peerInfoIfAllowed(fd: fd, allowedTeamIDs: context.allowedTeamIDs)

        do {
            let requestData = try PeekabooBridgeSocketIO.readAll(
                fd: fd,
                maxBytes: context.maxMessageBytes,
                deadline: Date().addingTimeInterval(context.requestTimeoutSec))

            guard let peer else {
                let envelope = PeekabooBridgeErrorEnvelope(
                    code: .unauthorizedClient,
                    message: "Bridge client is not authorized",
                    details: """
                    The host rejected the client before processing the request. Ensure the client is signed by an \
                    allowlisted TeamID (\(context.allowedTeamIDs.sorted()
                        .joined(separator: ", "))) or launch the host with \
                    PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 for local development.
                    """)

                let responseData = PeekabooBridgeResponse.encodeError(envelope)
                try PeekabooBridgeSocketIO.writeAll(
                    fd: fd,
                    data: responseData,
                    deadline: Date().addingTimeInterval(context.requestTimeoutSec))
                return
            }

            guard let responseData = await PeekabooBridgeConnectedRequest.handle(
                requestData: requestData,
                context: .init(
                    server: context.server,
                    peer: peer,
                    connection: connection,
                    requestTracker: context.requestTracker,
                    operationReceiptAuthority: context.operationReceiptAuthority))
            else {
                return
            }

            try PeekabooBridgeSocketIO.writeAll(
                fd: fd,
                data: responseData,
                deadline: Date().addingTimeInterval(context.requestTimeoutSec))
        } catch {
            self.logger.error("bridge socket request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func peerInfoIfAllowed(
        fd: Int32,
        allowedTeamIDs: Set<String>,
        signingIdentityProvider: (PeekabooBridgePeerAuditIdentity) -> PeerSigningIdentity? = {
            PeekabooBridgeHost.signingIdentity(auditIdentity: $0)
        }) -> PeekabooBridgePeer?
    {
        guard let auditIdentity = try? PeekabooBridgeSocketIO.peerAuditIdentity(fd: fd),
              let processStartIdentity = SystemIdentityResolver.processStartIdentity(
                  auditIdentity.processIdentifier)
        else { return nil }
        let signingIdentity = signingIdentityProvider(auditIdentity)
        let pid = auditIdentity.processIdentifier
        let callerUID = auditIdentity.effectiveUserIdentifier

        if allowedTeamIDs.isEmpty, callerUID == getuid() {
            return self.peer(
                auditIdentity: auditIdentity,
                processStartIdentity: processStartIdentity,
                signingIdentity: signingIdentity,
                teamIdentifier: signingIdentity?.teamIdentifier)
        }

        let teamID = signingIdentity?.teamIdentifier
        if let teamID, allowedTeamIDs.contains(teamID) {
            return self.peer(
                auditIdentity: auditIdentity,
                processStartIdentity: processStartIdentity,
                signingIdentity: signingIdentity,
                teamIdentifier: teamID)
        }

        #if DEBUG
        let environment = ProcessInfo.processInfo.environment["PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS"]
        if environment == "1", callerUID == getuid() {
            self.logger.warning(
                "allowing unsigned bridge client pid=\(pid, privacy: .public) (debug override)")
            return self.peer(
                auditIdentity: auditIdentity,
                processStartIdentity: processStartIdentity,
                signingIdentity: signingIdentity,
                teamIdentifier: nil)
        }
        #endif

        self.logger.error("bridge client rejected pid=\(pid, privacy: .public) uid=\(callerUID, privacy: .public)")
        return nil
    }

    private nonisolated static func peer(
        auditIdentity: PeekabooBridgePeerAuditIdentity,
        processStartIdentity: UInt64,
        signingIdentity: PeerSigningIdentity?,
        teamIdentifier: String?) -> PeekabooBridgePeer
    {
        PeekabooBridgePeer(
            processIdentifier: auditIdentity.processIdentifier,
            auditTokenProcessIdentifierVersion: auditIdentity.processIdentifierVersion,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: signingIdentity?.codeSignatureHash,
            userIdentifier: auditIdentity.effectiveUserIdentifier,
            bundleIdentifier: signingIdentity?.bundleIdentifier,
            teamIdentifier: teamIdentifier)
    }

    private nonisolated static func signingIdentity(
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
                .map { String(format: "%02x", $0) }.joined())
    }

    private nonisolated static func signingInformation(pid: pid_t) -> [String: Any]? {
        let attributes: NSDictionary = [kSecGuestAttributePid: pid]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
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
