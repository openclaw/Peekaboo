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

    private nonisolated static func peerInfoIfAllowed(
        fd: Int32,
        allowedTeamIDs: Set<String>) -> PeekabooBridgePeer?
    {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize)
        guard result == 0, pid > 0 else { return nil }

        let signingIdentity = self.signingIdentity(pid: pid)

        if allowedTeamIDs.isEmpty, let callerUID = self.uid(for: pid), callerUID == getuid() {
            return self.peer(
                pid: pid,
                uid: callerUID,
                signingIdentity: signingIdentity,
                teamIdentifier: signingIdentity?.teamIdentifier)
        }

        let teamID = signingIdentity?.teamIdentifier
        if let teamID, allowedTeamIDs.contains(teamID) {
            return self.peer(
                pid: pid,
                uid: self.uid(for: pid),
                signingIdentity: signingIdentity,
                teamIdentifier: teamID)
        }

        #if DEBUG
        let environment = ProcessInfo.processInfo.environment["PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS"]
        if environment == "1", let callerUID = self.uid(for: pid), callerUID == getuid() {
            self.logger.warning(
                "allowing unsigned bridge client pid=\(pid, privacy: .public) (debug override)")
            return self.peer(
                pid: pid,
                uid: callerUID,
                signingIdentity: signingIdentity,
                teamIdentifier: nil)
        }
        #endif

        if let callerUID = self.uid(for: pid) {
            self.logger.error("bridge client rejected pid=\(pid, privacy: .public) uid=\(callerUID, privacy: .public)")
        } else {
            self.logger.error("bridge client rejected pid=\(pid, privacy: .public) (uid unknown)")
        }
        return nil
    }

    private nonisolated static func peer(
        pid: pid_t,
        uid: uid_t?,
        signingIdentity: PeerSigningIdentity?,
        teamIdentifier: String?) -> PeekabooBridgePeer
    {
        PeekabooBridgePeer(
            processIdentifier: pid,
            processStartIdentity: SystemIdentityResolver.processStartIdentity(pid),
            codeSignatureHash: signingIdentity?.codeSignatureHash,
            userIdentifier: uid,
            bundleIdentifier: signingIdentity?.bundleIdentifier,
            teamIdentifier: teamIdentifier)
    }

    private nonisolated static func uid(for pid: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout.size(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let ok = mib.withUnsafeMutableBufferPointer { mibPointer -> Bool in
            sysctl(mibPointer.baseAddress, u_int(mibPointer.count), &info, &size, nil, 0) == 0
        }
        return ok ? info.kp_eproc.e_ucred.cr_uid : nil
    }

    nonisolated static func signingIdentity(
        pid: pid_t,
        signingInformationProvider: PeerSigningInformationProvider = signingInformation) -> PeerSigningIdentity?
    {
        guard let info = signingInformationProvider(pid) else { return nil }

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
