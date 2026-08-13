import Foundation

struct BridgeExplicitSocketUnavailableError: LocalizedError, ResultEnvelopeError {
    let socketPath: String
    let failureMessage: String?
    let failureHint: String?

    init(socketPath: String, failureMessage: String? = nil, failureHint: String? = nil) {
        self.socketPath = socketPath
        self.failureMessage = failureMessage
        self.failureHint = failureHint
    }

    var errorDescription: String? {
        let reason = self.failureMessage ?? "the host did not satisfy Peekaboo runtime requirements"
        return "Explicit Bridge socket '\(self.socketPath)' is unavailable: \(reason)"
    }

    var envelopeCode: ErrorCode? {
        .BRIDGE_UNAVAILABLE
    }

    var envelopeEffect: ActionEffect? {
        nil
    }

    var envelopeHint: String? {
        self.failureHint ??
            "Start or relaunch the requested Bridge host, correct --bridge-socket, " +
            "or pass --no-remote to explicitly use the local runtime."
    }
}
