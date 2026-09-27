import ApplicationServices
import Foundation
import os.log

enum AXObservationReadDiagnostics {
    enum Kind: String {
        case descriptorBatch
        case childrenBatch
        case attribute
        case actions
        case valueSettable
    }

    private static let log = OSLog(subsystem: "boo.peekaboo.core", category: "AXObservation")

    static func start() -> ContinuousClock.Instant? {
        self.log.isEnabled(type: .debug) ? .now : nil
    }

    static func record(
        _ kind: Kind,
        startedAt: ContinuousClock.Instant?,
        node: Int = 0,
        error: AXError,
        attributes: @autoclosure () -> (names: [String], values: [Any]?) = ([], nil),
        disposition: DetachedAXMultiAttributeReadDisposition? = nil)
    {
        guard let startedAt else { return }
        let elapsedMilliseconds = self.milliseconds(since: startedAt)
        guard self.shouldRecord(
            elapsedMilliseconds: elapsedMilliseconds,
            error: error,
            disposition: disposition)
        else { return }
        let attributes = attributes()
        let embedded = self.embeddedErrorDescriptions(names: attributes.names, values: attributes.values)
            .joined(separator: ",")
        os_log(
            .debug,
            log: self.log,
            """
            ax_read kind=%{public}@ node=%{public}ld elapsed_ms=%{public}.3f error=%{public}d \
            disposition=%{public}@ attribute=%{public}@ requested=%{public}ld returned=%{public}ld embedded=%{public}@
            """,
            kind.rawValue,
            node,
            elapsedMilliseconds,
            error.rawValue,
            disposition.map { String(describing: $0) } ?? "not_batched",
            attributes.names.count == 1 ? attributes.names[0] : "",
            attributes.names.count,
            attributes.values?.count ?? 0,
            embedded)
    }

    static func recordObservation(startedAt: ContinuousClock.Instant?, processIdentifier: Int32, windowID: Int?) {
        guard let startedAt else { return }
        os_log(
            .debug,
            log: self.log,
            "ax_observation pid=%{public}d window=%{public}ld elapsed_ms=%{public}.3f",
            processIdentifier,
            windowID ?? 0,
            self.milliseconds(since: startedAt))
    }

    static func shouldRecord(
        elapsedMilliseconds: Double,
        error: AXError,
        disposition: DetachedAXMultiAttributeReadDisposition?) -> Bool
    {
        elapsedMilliseconds >= 50 || AXAttributeReadCompletenessPolicy.isIncomplete(error: error) ||
            disposition == .incomplete || disposition == .fallback
    }

    static func embeddedErrorDescriptions(names: [String], values: [Any]?) -> [String] {
        guard let values else { return [] }
        // Attribute names come from the worker's fixed read lists; never stringify returned UI values.
        return zip(names, values).compactMap { name, value in
            guard let error = AXAttributeReadCompletenessPolicy.embeddedError(in: value),
                  AXAttributeReadCompletenessPolicy.isIncomplete(error: error)
            else { return nil }
            return "\(name):\(error.rawValue)"
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
