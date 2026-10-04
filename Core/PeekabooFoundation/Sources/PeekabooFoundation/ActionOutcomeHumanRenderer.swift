/// Human presentation of reported action evidence, without creating an outcome or receipt.
public enum ActionOutcomeHumanRenderer {
    public static func statusLine(for outcome: DesktopActionOutcome?, operation: String) -> String {
        guard let outcome else {
            return "⚠️ \(operation) request completed; receiver effect was not reported; " +
                "observe the target before retrying"
        }
        return switch outcome.state {
        case .confirmedChange:
            "✅ \(operation) confirmed"
        case .confirmedNoChange:
            "✅ \(operation) confirmed; no change was needed"
        case .partial:
            "⚠️ \(operation) partially completed; recover the remaining side effect before another attempt"
        case .dispatchedUnverified:
            "⚠️ \(operation) dispatched but not verified; observe the target before retrying"
        case .suspectedNoop:
            "⚠️ \(operation) may have had no effect; refresh the target before retrying"
        case .refused:
            "⛔ \(operation) refused before dispatch; \(self.refusalGuidance(for: outcome.escalation))"
        case .indeterminate:
            "⚠️ \(operation) outcome is indeterminate; observe the target before retrying"
        }
    }

    private static func refusalGuidance(for escalation: DesktopActionOutcome.Escalation) -> String {
        switch escalation {
        case .correctRequest:
            "correct the request before retrying"
        case .grantPermission:
            "grant the required permission before retrying"
        case .refreshTarget:
            "refresh the target before retrying"
        case .updateRuntime:
            "verify the selected runtime before retrying"
        case .reconnectSession:
            "reconnect the Bridge session before retrying"
        case .recoverSideEffect:
            "recover the remaining side effect before retrying"
        case .observeBeforeRetry:
            "observe the target before retrying"
        case .none:
            "review the refusal before retrying"
        }
    }
}
