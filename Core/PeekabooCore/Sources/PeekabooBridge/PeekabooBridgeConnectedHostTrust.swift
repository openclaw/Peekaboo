import Foundation

enum PeekabooBridgeConnectedHostTrust {
    static func validate(
        _ host: PeekabooBridgeConnectedHostIdentity?,
        socketPath: String,
        trustedTeamIDs: Set<String>) throws
    {
        let failedCheck: String
        if let host {
            if let liveHash = host.liveIdentity.codeSignatureHash, !liveHash.isEmpty {
                if let signing = host.signingIdentity {
                    if signing.codeSignatureHash != liveHash {
                        failedCheck = "signed executable CDHash does not match the live socket peer"
                    } else if let team = signing.teamIdentifier, trustedTeamIDs.contains(team) {
                        return
                    } else {
                        failedCheck = "signing Team ID is missing or not trusted"
                    }
                } else {
                    failedCheck = "Apple-anchored signing identity could not be bound to the live peer"
                }
            } else {
                failedCheck = "live kernel CDHash is unavailable"
            }
        } else {
            failedCheck = "connected socket peer identity is unavailable"
        }
        let peer = host.map { " (PID \($0.liveIdentity.processIdentifier))" } ?? ""
        var error = PeekabooBridgeErrorEnvelope(
            code: .unauthorizedClient,
            message: "Bridge host authentication failed at '\(socketPath)'\(peer): \(failedCheck). " +
                "Relaunch the released signed host at this socket; if its executable was replaced, " +
                "stop the old host process and restart it from the current signed app or CLI. " +
                "Chrome approval and browser receipts have not been checked.",
            context: "connectedHostAuthentication")
        error.isLocalHostAuthenticationFailure = true
        throw error
    }
}
