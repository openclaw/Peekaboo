import Foundation
import PeekabooFoundation

typealias ActionEffect = DesktopActionOutcome.Effect

protocol ActionOutputFormattable {
    var defaultEffect: ActionEffect? { get }
}

extension ActionOutputFormattable {
    var defaultEffect: ActionEffect? {
        .unverifiable
    }
}

protocol ConfirmedActionOutputFormattable: ActionOutputFormattable {}
extension ConfirmedActionOutputFormattable { var defaultEffect: ActionEffect? {
    .confirmed
} }

nonisolated protocol ResultEnvelopeError: Error, Sendable {
    var envelopeCode: ErrorCode? { get }
    var envelopeEffect: ActionEffect? { get }
    var envelopeHint: String? { get }
    var envelopeRetrySafe: Bool? { get }
    var envelopeMutationDispatched: Bool? { get }
    var envelopeActionFailure: DesktopActionFailure? { get }
}

extension ResultEnvelopeError {
    nonisolated var envelopeCode: ErrorCode? {
        nil
    }

    nonisolated var envelopeRetrySafe: Bool? {
        nil
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        nil
    }

    nonisolated var envelopeActionFailure: DesktopActionFailure? {
        nil
    }
}

struct ActionErrorEnvelopeMetadata {
    let failure: DesktopActionFailure?
    let effect: ActionEffect?
    let retrySafe: Bool?
    let mutationDispatched: Bool?
}

func actionErrorEnvelopeMetadata(
    for error: any Error,
    isActionCommand: Bool
) -> ActionErrorEnvelopeMetadata {
    guard isActionCommand else {
        return ActionErrorEnvelopeMetadata(
            failure: nil,
            effect: nil,
            retrySafe: nil,
            mutationDispatched: nil
        )
    }

    let envelopeError = error as? any ResultEnvelopeError
    let failure = (error as? DesktopActionFailure) ?? envelopeError?.envelopeActionFailure
    return ActionErrorEnvelopeMetadata(
        failure: failure,
        effect: failure?.outcome.effect ?? envelopeError?.envelopeEffect,
        retrySafe: failure.map { $0.outcome.retrySafety == .safe } ?? envelopeError?.envelopeRetrySafe,
        mutationDispatched: failure?.outcome.dispatchState.mutationDispatched ??
            envelopeError?.envelopeMutationDispatched
    )
}

struct PreDispatchActionError: LocalizedError, ResultEnvelopeError {
    let failure: DesktopActionFailure
    let code: ErrorCode
    let hint: String?

    init(
        message: String,
        code: ErrorCode,
        hint: String?,
        reason: DesktopActionOutcome.RefusalReason
    ) {
        self.failure = .refused(reason: reason, message: message)
        self.code = code
        self.hint = hint
    }

    nonisolated var errorDescription: String? {
        self.failure.message
    }

    nonisolated var envelopeCode: ErrorCode? {
        self.code
    }

    nonisolated var envelopeEffect: ActionEffect? {
        self.failure.outcome.effect
    }

    nonisolated var envelopeHint: String? {
        self.hint
    }

    nonisolated var envelopeRetrySafe: Bool? {
        self.failure.outcome.retrySafety == .safe
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        self.failure.outcome.dispatchState.mutationDispatched
    }

    nonisolated var envelopeActionFailure: DesktopActionFailure? {
        self.failure
    }
}

enum ResultEnvelopeContext {
    @TaskLocal static var isActionCommand = false
    @TaskLocal static var isPreDispatchFailure = false
}

let jsonEncodingFailureEnvelope =
    #"{"success":false,"data":null,"error":{"code":"INTERNAL_SWIFT_ERROR","# +
    #""message":"Failed to encode JSON response"},"debug_logs":[]}"#

struct ResultEnvelope<Payload> {
    let success: Bool
    var effect: ActionEffect?
    var outcome: DesktopActionOutcome.Projection?
    let data: Payload
    var messages: [String]?
    var debug_logs: [String] = []
    var error: ErrorInfo?
}

extension ResultEnvelope: Encodable where Payload: Encodable {}
extension ResultEnvelope: Decodable where Payload: Decodable {}

typealias JSONResponse = ResultEnvelope<Empty?>
typealias CodableJSONResponse<Payload: Codable> = ResultEnvelope<Payload>

struct ErrorInfo: Codable {
    let code: String
    let message: String
    let hint: String?
    let details: String?
    let retry_safe: Bool?
    let mutation_dispatched: Bool?

    init(
        message: String,
        code: ErrorCode,
        hint: String? = nil,
        details: String? = nil,
        retrySafe: Bool? = nil,
        mutationDispatched: Bool? = nil
    ) {
        self.init(
            message: message,
            code: code.rawValue,
            hint: hint,
            details: details,
            retrySafe: retrySafe,
            mutationDispatched: mutationDispatched
        )
    }

    init(
        message: String,
        code: String,
        hint: String? = nil,
        details: String? = nil,
        retrySafe: Bool? = nil,
        mutationDispatched: Bool? = nil
    ) {
        let presentation = splitErrorHint(from: message)
        self.code = code
        self.message = presentation.message
        self.hint = hint ?? presentation.hint
        self.details = details
        self.retry_safe = retrySafe
        self.mutation_dispatched = mutationDispatched
    }
}

func splitErrorHint(from text: String) -> (message: String, hint: String?) {
    let markers = [
        (". Use ", "Use "), ("; use ", "Use "),
        (". Try ", "Try "), ("; try ", "Try "),
        (". Run ", "Run "), ("; run ", "Run "),
        (". Add ", "Add "), ("; add ", "Add "),
    ]
    for (marker, prefix) in markers {
        guard let range = text.range(of: marker) else { continue }
        let message = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (message.hasSuffix(".") ? message : message + ".", prefix + suffix)
    }
    return (text, nil)
}

nonisolated enum ErrorCode: String, Codable, Sendable {
    case PERMISSION_ERROR_SCREEN_RECORDING, PERMISSION_ERROR_ACCESSIBILITY
    case PERMISSION_ERROR_EVENT_SYNTHESIZING, PERMISSION_ERROR_APPLESCRIPT, PERMISSION_DENIED
    case APP_NOT_FOUND, AMBIGUOUS_APP_IDENTIFIER, WINDOW_NOT_FOUND, CAPTURE_FAILED, FILE_IO_ERROR
    case INVALID_ARGUMENT, SIPS_ERROR, INTERNAL_SWIFT_ERROR, UNKNOWN_ERROR, WINDOW_MANIPULATION_ERROR
    case VALIDATION_ERROR, MENU_BAR_NOT_FOUND, MENU_ITEM_NOT_FOUND, DOCK_NOT_FOUND, NO_ACTIVE_DIALOG
    case ELEMENT_NOT_FOUND, SESSION_NOT_FOUND, SNAPSHOT_NOT_FOUND, SNAPSHOT_STALE, APPLICATION_NOT_FOUND
    case NO_POINT_SPECIFIED, INVALID_COORDINATES, DOCK_LIST_NOT_FOUND, DOCK_ITEM_NOT_FOUND
    case POSITION_NOT_FOUND, SCRIPT_ERROR, MISSING_API_KEY, AGENT_ERROR, INTERACTION_FAILED, TIMEOUT
    case INVALID_INPUT, ACCESSIBILITY_INCOMPLETE
    case CAPTURE_NO_VALID_FRAMES
}

func outputSuccessCodable(
    data: some Codable,
    messages: [String]? = nil,
    effect: ActionEffect? = nil,
    outcome: DesktopActionOutcome? = nil,
    logger: Logger
) {
    let response = makeSuccessEnvelope(
        data: data,
        messages: messages,
        effect: effect,
        outcome: outcome,
        debugLogs: logger.getDebugLogs()
    )
    outputJSONCodable(response, logger: logger)
}

func makeSuccessEnvelope<Payload>(
    data: Payload,
    messages: [String]? = nil,
    effect: ActionEffect? = nil,
    outcome: DesktopActionOutcome? = nil,
    debugLogs: [String] = []
) -> ResultEnvelope<Payload> {
    let projection = outcome?.projection
    return ResultEnvelope(
        success: true,
        effect: projection?.effect ?? effect,
        outcome: projection,
        data: data,
        messages: messages,
        debug_logs: debugLogs
    )
}

func outputJSONCodable(_ response: ResultEnvelope<some Encodable>, logger: Logger) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted
    do {
        let data = try encoder.encode(response)
        if let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        }
    } catch {
        logger.error("Failed to encode JSON response: \(error)")
        let fallback = makeJSONEncodingFailureEnvelope(effect: response.effect)
        if let data = try? encoder.encode(fallback), let jsonString = String(data: data, encoding: .utf8) {
            print(jsonString)
        } else {
            print(jsonEncodingFailureEnvelope)
        }
    }
}

func makeJSONEncodingFailureEnvelope(effect: ActionEffect?) -> ResultEnvelope<Empty?> {
    ResultEnvelope(
        success: false,
        effect: effect == nil ? nil : .unverifiable,
        data: nil,
        error: ErrorInfo(message: "Failed to encode JSON response", code: .INTERNAL_SWIFT_ERROR)
    )
}

func outputError(
    message: String,
    code: ErrorCode,
    hint: String? = nil,
    details: String? = nil,
    effect: ActionEffect? = nil,
    retrySafe: Bool? = nil,
    mutationDispatched: Bool? = nil,
    actionFailure: DesktopActionFailure? = nil,
    logger: Logger
) {
    let response = makeErrorEnvelope(
        message: message,
        code: code,
        hint: hint,
        details: details,
        effect: effect,
        retrySafe: retrySafe,
        mutationDispatched: mutationDispatched,
        actionFailure: actionFailure,
        debugLogs: logger.getDebugLogs()
    )
    outputJSONCodable(response, logger: logger)
}

func makeErrorEnvelope(
    message: String,
    code: ErrorCode,
    hint: String? = nil,
    details: String? = nil,
    effect: ActionEffect? = nil,
    retrySafe: Bool? = nil,
    mutationDispatched: Bool? = nil,
    actionFailure: DesktopActionFailure? = nil,
    debugLogs: [String] = []
) -> ResultEnvelope<Empty?> {
    let suppliedOutcome = actionFailure?.outcome.projection
    let resolvedEffect = suppliedOutcome?.effect ?? effect ??
        (ResultEnvelopeContext.isActionCommand ? defaultActionErrorEffect(code) : nil)
    let resolvedOutcome = suppliedOutcome ?? defaultActionRefusalProjection(effect: resolvedEffect, code: code)
    return ResultEnvelope(
        success: false,
        effect: resolvedOutcome?.effect ?? resolvedEffect,
        outcome: resolvedOutcome,
        data: nil,
        debug_logs: debugLogs,
        error: ErrorInfo(
            message: message,
            code: code,
            hint: hint,
            details: details,
            retrySafe: resolvedOutcome?.retrySafe ?? retrySafe,
            mutationDispatched: resolvedOutcome?.mutationDispatched ?? mutationDispatched
        )
    )
}

func defaultActionRefusalProjection(
    effect: ActionEffect?,
    code: ErrorCode
) -> DesktopActionOutcome.Projection? {
    guard ResultEnvelopeContext.isActionCommand,
          ResultEnvelopeContext.isPreDispatchFailure,
          effect == .refused,
          let reason = defaultActionRefusalReason(code)
    else {
        return nil
    }
    return DesktopActionOutcome.refused(reason: reason).projection
}

func defaultActionRefusalReason(_ code: ErrorCode) -> DesktopActionOutcome.RefusalReason? {
    switch code {
    case .INVALID_ARGUMENT, .VALIDATION_ERROR, .INVALID_INPUT, .AMBIGUOUS_APP_IDENTIFIER,
         .NO_POINT_SPECIFIED, .INVALID_COORDINATES:
        .invalidRequest
    case .PERMISSION_DENIED, .PERMISSION_ERROR_SCREEN_RECORDING, .PERMISSION_ERROR_ACCESSIBILITY,
         .PERMISSION_ERROR_EVENT_SYNTHESIZING, .PERMISSION_ERROR_APPLESCRIPT:
        .permissionDenied
    case .APP_NOT_FOUND, .WINDOW_NOT_FOUND, .ELEMENT_NOT_FOUND,
         .APPLICATION_NOT_FOUND, .SESSION_NOT_FOUND, .SNAPSHOT_NOT_FOUND, .SNAPSHOT_STALE,
         .NO_ACTIVE_DIALOG, .MENU_BAR_NOT_FOUND, .MENU_ITEM_NOT_FOUND, .DOCK_NOT_FOUND,
         .DOCK_LIST_NOT_FOUND, .DOCK_ITEM_NOT_FOUND, .POSITION_NOT_FOUND:
        .targetUnavailable
    default:
        nil
    }
}

func defaultActionErrorEffect(_ code: ErrorCode) -> ActionEffect {
    defaultActionRefusalReason(code) == nil ? .unverifiable : .refused
}

struct Empty: Codable {}
