import Foundation
import PeekabooCore
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
    var envelopeActionOutcome: DesktopActionOutcome? { get }
    var envelopeTargetIdentity: DesktopTargetIdentity? { get }
    var envelopeTargetReceipt: DesktopActionTargetReceipt? { get }
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

    nonisolated var envelopeActionOutcome: DesktopActionOutcome? {
        self.envelopeActionFailure?.outcome
    }

    nonisolated var envelopeTargetIdentity: DesktopTargetIdentity? {
        nil
    }

    nonisolated var envelopeTargetReceipt: DesktopActionTargetReceipt? {
        self.envelopeActionFailure?.targetReceipt
    }
}

struct ActionErrorEnvelopeMetadata {
    let failure: DesktopActionFailure?
    let outcome: DesktopActionOutcome?
    let effect: ActionEffect?
    let retrySafe: Bool?
    let mutationDispatched: Bool?
    let targetIdentity: DesktopTargetIdentity?
    let targetReceipt: DesktopActionTargetReceipt?
}

func actionErrorEnvelopeMetadata(
    for error: any Error,
    isActionCommand: Bool
) -> ActionErrorEnvelopeMetadata {
    guard isActionCommand else {
        return ActionErrorEnvelopeMetadata(
            failure: nil,
            outcome: nil,
            effect: nil,
            retrySafe: nil,
            mutationDispatched: nil,
            targetIdentity: nil,
            targetReceipt: nil
        )
    }

    let envelopeError = error as? any ResultEnvelopeError
    let failure = (error as? DesktopActionFailure) ?? envelopeError?.envelopeActionFailure
    let outcome = envelopeError?.envelopeActionOutcome ?? failure?.outcome
    return ActionErrorEnvelopeMetadata(
        failure: failure,
        outcome: outcome,
        effect: outcome?.effect ?? envelopeError?.envelopeEffect,
        retrySafe: envelopeError?.envelopeRetrySafe ?? outcome.map { $0.retrySafety == .safe },
        mutationDispatched: envelopeError?.envelopeMutationDispatched ??
            outcome?.dispatchState.mutationDispatched,
        targetIdentity: envelopeError?.envelopeTargetIdentity,
        targetReceipt: envelopeError?.envelopeTargetReceipt ?? failure?.targetReceipt
    )
}

private struct ActionResultEnvelopeFailure: LocalizedError, ResultEnvelopeError {
    let failure: DesktopActionFailure
    let targetIdentity: DesktopTargetIdentity?

    nonisolated var errorDescription: String? {
        self.failure.message
    }

    nonisolated var envelopeCode: ErrorCode? {
        .INTERACTION_FAILED
    }

    nonisolated var envelopeEffect: ActionEffect? {
        self.failure.outcome.effect
    }

    nonisolated var envelopeHint: String? {
        self.failure.hint
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

    nonisolated var envelopeTargetIdentity: DesktopTargetIdentity? {
        self.targetIdentity
    }
}

private struct PostDispatchActionResultEnvelopeFailure: LocalizedError, ResultEnvelopeError {
    let outcome: DesktopActionOutcome
    let failure: DesktopActionFailure?
    let targetIdentity: DesktopTargetIdentity?
    let targetReceipt: DesktopActionTargetReceipt?
    let message: String
    let hint: String
    let causeDescription: String

    nonisolated var errorDescription: String? {
        self.message
    }

    nonisolated var envelopeCode: ErrorCode? {
        .INTERACTION_FAILED
    }

    nonisolated var envelopeEffect: ActionEffect? {
        self.outcome.effect
    }

    nonisolated var envelopeHint: String? {
        self.hint
    }

    nonisolated var envelopeRetrySafe: Bool? {
        self.outcome.state == .confirmedNoChange || self.outcome.retrySafety == .safe
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        self.outcome.dispatchState.mutationDispatched
    }

    nonisolated var envelopeActionFailure: DesktopActionFailure? {
        self.failure
    }

    nonisolated var envelopeActionOutcome: DesktopActionOutcome? {
        self.outcome
    }

    nonisolated var envelopeTargetIdentity: DesktopTargetIdentity? {
        self.targetIdentity
    }

    nonisolated var envelopeTargetReceipt: DesktopActionTargetReceipt? {
        self.targetReceipt
    }
}

struct PreDispatchActionError: LocalizedError, ResultEnvelopeError {
    let failure: DesktopActionFailure
    let code: ErrorCode
    let hint: String?

    init(
        message: String,
        code: ErrorCode,
        hint: String?,
        reason: DesktopActionOutcome.RefusalReason,
        screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic? = nil
    ) {
        self.failure = DesktopActionFailure.preDispatchRefusal(reason: reason, message: message, hint: hint)
            .preservingScreenCaptureKitDiagnostic(screenCaptureKitOwnershipDiagnostic)
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
    var target_identity: DesktopTargetIdentity.Projection?
    var target_receipt: DesktopActionTargetReceipt?
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
    let screen_capture_kit_ownership_diagnostic: ScreenCaptureKitOwnershipDiagnostic?

    init(
        message: String,
        code: ErrorCode,
        hint: String? = nil,
        details: String? = nil,
        retrySafe: Bool? = nil,
        mutationDispatched: Bool? = nil,
        screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic? = nil
    ) {
        self.init(
            message: message,
            code: code.rawValue,
            hint: hint,
            details: details,
            retrySafe: retrySafe,
            mutationDispatched: mutationDispatched,
            screenCaptureKitOwnershipDiagnostic: screenCaptureKitOwnershipDiagnostic
        )
    }

    init(
        message: String,
        code: String,
        hint: String? = nil,
        details: String? = nil,
        retrySafe: Bool? = nil,
        mutationDispatched: Bool? = nil,
        screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic? = nil
    ) {
        let presentation = splitErrorHint(from: message)
        self.code = code
        self.message = presentation.message
        self.hint = hint ?? presentation.hint
        self.details = details
        self.retry_safe = retrySafe
        self.mutation_dispatched = mutationDispatched
        self.screen_capture_kit_ownership_diagnostic = screenCaptureKitOwnershipDiagnostic
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
    case CAPTURE_NO_VALID_FRAMES, BRIDGE_UNAVAILABLE
}

func outputSuccessCodable(
    data: some Codable,
    messages: [String]? = nil,
    effect: ActionEffect? = nil,
    outcome: DesktopActionOutcome? = nil,
    targetIdentity: DesktopTargetIdentity? = nil,
    logger: Logger
) {
    let response = makeSuccessEnvelope(
        data: data,
        messages: messages,
        effect: effect,
        outcome: outcome,
        targetIdentity: targetIdentity,
        debugLogs: logger.getDebugLogs()
    )
    outputJSONCodable(response, logger: logger)
}

func makeSuccessEnvelope<Payload>(
    data: Payload,
    messages: [String]? = nil,
    effect: ActionEffect? = nil,
    outcome: DesktopActionOutcome? = nil,
    targetIdentity: DesktopTargetIdentity? = nil,
    debugLogs: [String] = []
) -> ResultEnvelope<Payload> {
    let projection = outcome?.projection
    return ResultEnvelope(
        success: true,
        effect: projection?.effect ?? effect,
        outcome: projection,
        data: data,
        target_identity: targetIdentity.map(\.projection),
        target_receipt: targetIdentity?.actionTargetReceipt,
        messages: messages,
        debug_logs: debugLogs
    )
}

func validatedActionResultTargetIdentity(
    _ result: UIAutomationActionResult<some Sendable>,
    operation: String,
    requiresTarget: Bool
) throws -> DesktopTargetIdentity? {
    try UIAutomationActionResultSemantics.validateTarget(
        result.targetIdentity,
        outcome: result.outcome,
        requirement: requiresTarget ? .required : .optional,
        operation: operation,
        message: "\(operation) returned without its resolved target identity."
    )
    return result.targetIdentity
}

func validatedSuccessfulActionResult(
    _ result: UIAutomationActionResult<some Sendable>,
    operation: String,
    requiresTarget: Bool
) throws -> DesktopTargetIdentity? {
    let targetIdentity = try validatedActionResultTargetIdentity(
        result,
        operation: operation,
        requiresTarget: requiresTarget
    )
    try validateSuccessfulActionOutcome(
        result.outcome,
        targetIdentity: targetIdentity,
        operation: operation
    )
    return targetIdentity
}

func canonicalActionOutcomeAfterSuccessfulVerification(
    _ outcome: DesktopActionOutcome?,
    observedChange: Bool? = nil
) -> DesktopActionOutcome? {
    outcome?.confirmingDispatchedOutcome(observedChange: observedChange)
}

func postDispatchActionResultError(
    _ error: any Error,
    actionResult: UIAutomationActionResult<some Sendable>,
    targetIdentity: DesktopTargetIdentity?,
    operation: String
) -> any Error {
    let targetReceipt = targetIdentity?.actionTargetReceipt
    let outcome = actionResult.outcome ?? DesktopActionOutcome.indeterminate(
        route: .local,
        evidence: .completionUnknown,
        unitCount: nil
    )
    return postResultProcessingError(
        error,
        outcome: outcome,
        targetReceipt: targetReceipt,
        targetIdentity: targetIdentity,
        operation: operation,
        message: "\(operation) was dispatched, but post-dispatch processing failed.",
        hint: "Observe the target before retrying; replaying may repeat the completed action."
    )
}

func postResultProcessingError(
    _ error: any Error,
    outcome: DesktopActionOutcome,
    targetReceipt: DesktopActionTargetReceipt?,
    targetIdentity: DesktopTargetIdentity? = nil,
    operation: String,
    message: String? = nil,
    hint: String? = nil
) -> any Error {
    let resolvedMessage = message ?? "\(operation) failed after its canonical action result was returned."
    let resolvedHint = hint ?? "Observe the target before deciding whether to retry \(operation)."
    let causeDescription = errorMessage(for: error)
    let failure = DesktopActionFailure(
        outcome: outcome,
        message: resolvedMessage,
        hint: resolvedHint,
        causeDescription: causeDescription,
        targetReceipt: targetReceipt
    )
    return PostDispatchActionResultEnvelopeFailure(
        outcome: outcome,
        failure: failure,
        targetIdentity: targetIdentity,
        targetReceipt: targetReceipt,
        message: resolvedMessage,
        hint: resolvedHint,
        causeDescription: causeDescription
    )
}

func withPreservedActionResultOnFailure<Prepared>(
    _ actionResult: UIAutomationActionResult<some Sendable>,
    targetIdentity: DesktopTargetIdentity?,
    operation: String,
    prepare: () throws -> Prepared
) throws -> Prepared {
    do {
        return try prepare()
    } catch {
        throw postDispatchActionResultError(
            error,
            actionResult: actionResult,
            targetIdentity: targetIdentity,
            operation: operation
        )
    }
}

func withPreservedActionResultOnFailure<Prepared>(
    _ actionResult: UIAutomationActionResult<some Sendable>,
    targetIdentity: DesktopTargetIdentity?,
    operation: String,
    prepare: () async throws -> Prepared
) async throws -> Prepared {
    do {
        return try await prepare()
    } catch {
        throw postDispatchActionResultError(
            error,
            actionResult: actionResult,
            targetIdentity: targetIdentity,
            operation: operation
        )
    }
}

func validateSuccessfulActionOutcome(
    _ outcome: DesktopActionOutcome?,
    targetIdentity: DesktopTargetIdentity?,
    operation: String
) throws {
    do {
        _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            outcome,
            policy: .confirmedOrDispatched,
            operation: operation,
            targetReceipt: targetIdentity?.actionTargetReceipt,
            rejectedOutcomeMessage: "\(operation) did not return a successful outcome."
        )
    } catch let failure as DesktopActionFailure {
        throw ActionResultEnvelopeFailure(failure: failure, targetIdentity: targetIdentity)
    }
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
    actionOutcome: DesktopActionOutcome? = nil,
    actionFailure: DesktopActionFailure? = nil,
    targetReceipt: DesktopActionTargetReceipt? = nil,
    targetIdentity: DesktopTargetIdentity? = nil,
    screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic? = nil,
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
        actionOutcome: actionOutcome,
        actionFailure: actionFailure,
        targetReceipt: targetReceipt,
        targetIdentity: targetIdentity,
        screenCaptureKitOwnershipDiagnostic: screenCaptureKitOwnershipDiagnostic,
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
    actionOutcome: DesktopActionOutcome? = nil,
    actionFailure: DesktopActionFailure? = nil,
    targetReceipt: DesktopActionTargetReceipt? = nil,
    targetIdentity: DesktopTargetIdentity? = nil,
    screenCaptureKitOwnershipDiagnostic: ScreenCaptureKitOwnershipDiagnostic? = nil,
    debugLogs: [String] = []
) -> ResultEnvelope<Empty?> {
    let suppliedOutcome = actionOutcome?.projection ?? actionFailure?.outcome.projection
    let resolvedEffect = suppliedOutcome?.effect ?? effect ??
        (ResultEnvelopeContext.isActionCommand ? defaultActionErrorEffect(code) : nil)
    let resolvedOutcome = suppliedOutcome ?? defaultActionRefusalProjection(
        effect: resolvedEffect,
        code: code,
        retrySafe: retrySafe,
        mutationDispatched: mutationDispatched
    )
    let resolvedRetrySafe = actionOutcome == nil
        ? resolvedOutcome?.retrySafe ?? retrySafe
        : retrySafe ?? resolvedOutcome?.retrySafe
    let resolvedMutationDispatched = actionOutcome == nil
        ? resolvedOutcome?.mutationDispatched ?? mutationDispatched
        : mutationDispatched ?? resolvedOutcome?.mutationDispatched
    return ResultEnvelope(
        success: false,
        effect: resolvedOutcome?.effect ?? resolvedEffect,
        outcome: resolvedOutcome,
        data: nil,
        target_identity: targetIdentity.map(\.projection),
        target_receipt: actionFailure?.targetReceipt ?? targetReceipt ??
            targetIdentity?.actionTargetReceipt,
        debug_logs: debugLogs,
        error: ErrorInfo(
            message: message,
            code: code,
            hint: hint,
            details: details,
            retrySafe: resolvedRetrySafe,
            mutationDispatched: resolvedMutationDispatched,
            screenCaptureKitOwnershipDiagnostic: screenCaptureKitOwnershipDiagnostic ??
                actionFailure?.screenCaptureKitOwnershipDiagnostic
        )
    )
}

func defaultActionRefusalProjection(
    effect: ActionEffect?,
    code: ErrorCode,
    retrySafe: Bool? = nil,
    mutationDispatched: Bool? = nil
) -> DesktopActionOutcome.Projection? {
    guard ResultEnvelopeContext.isActionCommand,
          effect == .refused,
          let reason = defaultActionRefusalReason(code)
    else {
        return nil
    }
    if ResultEnvelopeContext.isPreDispatchFailure {
        return DesktopActionOutcome.preDispatchRefusalProjection(reason: reason)
    }
    return DesktopActionOutcome.preDispatchRefusalProjection(
        reason: reason,
        legacyRetrySafe: retrySafe,
        legacyMutationDispatched: mutationDispatched
    )
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
