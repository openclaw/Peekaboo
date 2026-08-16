import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

enum ObservationActionResultSupport {
    static func preservingFailure(
        _ error: any Error,
        after result: UIAutomationActionResult<some Sendable>?,
        operation: String) -> any Error
    {
        guard let result else { return error }
        return ObservationActionResultSemantics.preservingFailure(
            error,
            after: result,
            operation: operation)
    }

    static func metadata(
        merging base: [String: Value],
        result: UIAutomationActionResult<some Sendable>) throws -> Value?
    {
        var fields = base
        if let targetReceipt = result.actionTargetReceipt {
            fields["target_receipt"] = try Value(targetReceipt)
        }
        return try MCPToolResponseMetadataProjector.metadata(
            merging: fields,
            outcome: result.outcome)
    }

    static func standardErrorFields(_ error: any Error) -> [String: Value] {
        guard let error = error as? PeekabooError else { return [:] }
        let code: StandardErrorCode? = switch error {
        case .accessibilityIncomplete:
            .accessibilityIncomplete
        case .timeout:
            .timeout
        default:
            nil
        }
        return code.map { ["error_code": .string($0.rawValue)] } ?? [:]
    }
}
