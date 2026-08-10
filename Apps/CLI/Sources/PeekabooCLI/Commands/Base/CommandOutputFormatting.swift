import Foundation
import PeekabooCore

@MainActor
protocol OutputFormattable {
    var jsonOutput: Bool { get }
    var outputLogger: Logger { get }
}

extension OutputFormattable {
    func output(_ data: some Codable, effect: ActionEffect? = nil, humanReadable: () -> Void) {
        if jsonOutput {
            outputSuccessCodable(
                data: data,
                effect: effect ?? (self as? any ActionOutputFormattable)?.defaultEffect,
                logger: self.outputLogger
            )
        } else {
            humanReadable()
        }
    }
}
