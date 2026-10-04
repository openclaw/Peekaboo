import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
protocol OutputFormattable {
    var jsonOutput: Bool { get }
    var outputLogger: Logger { get }
}

extension OutputFormattable {
    func output(
        _ data: some Encodable,
        effect: ActionEffect? = nil,
        outcome: DesktopActionOutcome? = nil,
        targetIdentity: DesktopTargetIdentity? = nil,
        humanReadable: () -> Void
    ) {
        if jsonOutput {
            outputSuccessCodable(
                data: data,
                effect: effect ?? (self as? any ActionOutputFormattable)?.defaultEffect,
                outcome: outcome,
                targetIdentity: targetIdentity,
                logger: self.outputLogger
            )
        } else {
            humanReadable()
        }
    }
}
