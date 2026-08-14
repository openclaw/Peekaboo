/// A desktop action's payload and its canonical execution receipt.
///
/// The outcome remains optional only at compatibility boundaries that can talk to an older
/// runtime. Current local services and Bridge hosts always return a canonical outcome.
public struct DesktopActionResult<Payload: Sendable>: Sendable {
    public let payload: Payload
    public let outcome: DesktopActionOutcome?

    public init(payload: Payload, outcome: DesktopActionOutcome?) {
        self.payload = payload
        self.outcome = outcome
    }
}

extension DesktopActionResult where Payload == Void {
    public init(outcome: DesktopActionOutcome?) {
        self.init(payload: (), outcome: outcome)
    }
}
