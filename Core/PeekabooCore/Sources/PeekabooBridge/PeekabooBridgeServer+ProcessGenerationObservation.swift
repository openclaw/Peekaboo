import Darwin
import Foundation

@MainActor
extension PeekabooBridgeServer {
    typealias ProcessBSDInfoProvider = (pid_t) -> proc_bsdinfo?
    typealias ProcessAbsenceProvider = (pid_t) -> Bool

    nonisolated static let certificationCallerTeamIdentifier = "FWJYW4S8P8"

    nonisolated static func observeProcessPresence(
        _ processIdentifier: pid_t,
        processInfoProvider: ProcessBSDInfoProvider = { processIdentifier in
            var info = proc_bsdinfo()
            let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            guard proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                &info,
                expectedSize) == expectedSize
            else { return nil }
            return info
        },
        absenceProvider: ProcessAbsenceProvider = { processIdentifier in
            Darwin.kill(processIdentifier, 0) == -1 && errno == ESRCH
        }) -> Bool?
    {
        guard processIdentifier > 0 else { return nil }
        if let info = processInfoProvider(processIdentifier) {
            // A zombie retains both its PID and start identity until waitpid reaps it. It is
            // terminal evidence, never a live generation.
            return info.pbi_status == SZOMB ? nil : true
        }
        // ESRCH is useful negative evidence after process metadata disappeared. Every positive
        // or permission-limited result remains ambiguous rather than proving life.
        return absenceProvider(processIdentifier) ? false : nil
    }

    func requireCertificationCaller(_ peer: PeekabooBridgePeer?) throws {
        guard let peer,
              let liveIdentity = peer.liveIdentity,
              peer.bundleIdentifier == PeekabooBridgeConstants.cliBundleIdentifier,
              peer.teamIdentifier == Self.certificationCallerTeamIdentifier,
              peer.userIdentifier == geteuid(),
              peer.processIdentifier > 0,
              peer.processIdentifier == liveIdentity.processIdentifier,
              peer.auditTokenProcessIdentifierVersion == liveIdentity.processIdentifierVersion,
              peer.processStartIdentity == liveIdentity.processStartIdentity,
              let codeSignatureHash = peer.codeSignatureHash,
              !codeSignatureHash.isEmpty,
              codeSignatureHash == liveIdentity.codeSignatureHash
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .unauthorizedClient,
                message: "Certification operations require the authenticated Foundation-signed Peekaboo CLI")
        }
    }

    func handleProcessGenerationObservation(
        _ request: PeekabooBridgeProcessGenerationObservationRequest) throws
        -> PeekabooBridgeProcessGenerationObservationResponse
    {
        try request.validate()
        let startedAt = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        let before = self.processStartIdentityProvider(request.expected.processIdentifier)
        let presence = self.processPresenceProvider(request.expected.processIdentifier)
        let after = self.processStartIdentityProvider(request.expected.processIdentifier)
        let completedAt = max(startedAt, PeekabooBridgeOperationReceiptCoding.unixMilliseconds())

        let disposition: PeekabooBridgeProcessGenerationDisposition
        let observed: PeekabooBridgeProcessGenerationIdentity?
        switch (before, presence, after) {
        case let (before?, true, after?) where before == after:
            observed = .init(
                processIdentifier: request.expected.processIdentifier,
                processStartIdentity: after)
            disposition = after == request.expected.processStartIdentity ? .sameGenerationAlive : .pidReused
        case (nil, false, nil):
            observed = nil
            disposition = .exactGenerationAbsent
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "The exact process generation changed or could not be observed unambiguously")
        }

        let response = PeekabooBridgeProcessGenerationObservationResponse(
            expected: request.expected,
            disposition: disposition,
            observed: observed,
            observationStartedAtUnixMilliseconds: startedAt,
            observationCompletedAtUnixMilliseconds: completedAt)
        try response.validate(request: request)
        return response
    }
}
