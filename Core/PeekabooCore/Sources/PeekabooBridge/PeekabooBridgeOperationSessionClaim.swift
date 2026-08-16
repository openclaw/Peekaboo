import Foundation

/// One accepted sequence claim. It retains everything required to complete a receipt after its
/// session has retired or left the bounded registry.
final class PeekabooBridgeOperationSessionClaim: @unchecked Sendable {
    let requestID: UUID
    let sessionID: UUID
    let sessionSequence: PeekabooBridgeOperationSessionSequence
    let sessionAttestation: PeekabooBridgeOperationSessionAttestation
    let remainingClaimCount: Int

    private let lock = NSLock()
    private var state = State.pending

    init(
        requestID: UUID,
        sessionID: UUID,
        sessionSequence: PeekabooBridgeOperationSessionSequence,
        sessionAttestation: PeekabooBridgeOperationSessionAttestation,
        remainingClaimCount: Int)
    {
        self.requestID = requestID
        self.sessionID = sessionID
        self.sessionSequence = sessionSequence
        self.sessionAttestation = sessionAttestation
        self.remainingClaimCount = remainingClaimCount
    }

    func beginSigning() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state == .pending else { return false }
        self.state = .signed
        return true
    }

    func beginCompletion() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.state != .complete else { return false }
        self.state = .complete
        return true
    }

    private enum State {
        case pending
        case signed
        case complete
    }
}

enum PeekabooBridgeOperationSessionClaimResult: Sendable {
    case accepted(PeekabooBridgeOperationSessionClaim)
    case rolloverRequired(PeekabooBridgeOperationSessionRefusal)
}
