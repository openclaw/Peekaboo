import Foundation

nonisolated enum ActionEffect: String, Codable, Sendable {
    case confirmed
    case partial
    case unverifiable
    case suspectedNoop = "suspected_noop"
    case refused
}

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
    var envelopeEffect: ActionEffect? { get }
    var envelopeHint: String? { get }
}

struct ActionRefusalError: LocalizedError, ResultEnvelopeError {
    let message: String
    let hint: String?

    nonisolated var errorDescription: String? {
        self.message
    }

    nonisolated var envelopeEffect: ActionEffect? {
        .refused
    }

    nonisolated var envelopeHint: String? {
        self.hint
    }
}

enum ResultEnvelopeContext {
    @TaskLocal static var isActionCommand = false
}

let jsonEncodingFailureEnvelope =
    #"{"success":false,"data":null,"error":{"code":"INTERNAL_SWIFT_ERROR","# +
    #""message":"Failed to encode JSON response"},"debug_logs":[]}"#

struct ResultEnvelope<Payload> {
    let success: Bool
    var effect: ActionEffect?
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

    init(message: String, code: ErrorCode, hint: String? = nil, details: String? = nil) {
        self.init(message: message, code: code.rawValue, hint: hint, details: details)
    }

    init(message: String, code: String, hint: String? = nil, details: String? = nil) {
        let presentation = splitErrorHint(from: message)
        self.code = code
        self.message = presentation.message
        self.hint = hint ?? presentation.hint
        self.details = details
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

enum ErrorCode: String, Codable {
    case PERMISSION_ERROR_SCREEN_RECORDING, PERMISSION_ERROR_ACCESSIBILITY
    case PERMISSION_ERROR_EVENT_SYNTHESIZING, PERMISSION_ERROR_APPLESCRIPT, PERMISSION_DENIED
    case APP_NOT_FOUND, AMBIGUOUS_APP_IDENTIFIER, WINDOW_NOT_FOUND, CAPTURE_FAILED, FILE_IO_ERROR
    case INVALID_ARGUMENT, SIPS_ERROR, INTERNAL_SWIFT_ERROR, UNKNOWN_ERROR, WINDOW_MANIPULATION_ERROR
    case VALIDATION_ERROR, MENU_BAR_NOT_FOUND, MENU_ITEM_NOT_FOUND, DOCK_NOT_FOUND, NO_ACTIVE_DIALOG
    case ELEMENT_NOT_FOUND, SESSION_NOT_FOUND, SNAPSHOT_NOT_FOUND, SNAPSHOT_STALE, APPLICATION_NOT_FOUND
    case NO_POINT_SPECIFIED, INVALID_COORDINATES, DOCK_LIST_NOT_FOUND, DOCK_ITEM_NOT_FOUND
    case POSITION_NOT_FOUND, SCRIPT_ERROR, MISSING_API_KEY, AGENT_ERROR, INTERACTION_FAILED, TIMEOUT
    case INVALID_INPUT
}

func outputSuccessCodable(
    data: some Codable,
    messages: [String]? = nil,
    effect: ActionEffect? = nil,
    logger: Logger
) {
    let response = ResultEnvelope(
        success: true,
        effect: effect,
        data: data,
        messages: messages,
        debug_logs: logger.getDebugLogs()
    )
    outputJSONCodable(response, logger: logger)
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
    logger: Logger
) {
    let response = ResultEnvelope<Empty?>(
        success: false,
        effect: effect ?? (ResultEnvelopeContext.isActionCommand ? defaultActionErrorEffect(code) : nil),
        data: nil,
        debug_logs: logger.getDebugLogs(),
        error: ErrorInfo(message: message, code: code, hint: hint, details: details)
    )
    outputJSONCodable(response, logger: logger)
}

func defaultActionErrorEffect(_ code: ErrorCode) -> ActionEffect {
    switch code {
    case .INVALID_ARGUMENT, .VALIDATION_ERROR, .INVALID_INPUT,
         .PERMISSION_DENIED, .PERMISSION_ERROR_SCREEN_RECORDING, .PERMISSION_ERROR_ACCESSIBILITY,
         .PERMISSION_ERROR_EVENT_SYNTHESIZING, .PERMISSION_ERROR_APPLESCRIPT,
         .APP_NOT_FOUND, .AMBIGUOUS_APP_IDENTIFIER, .WINDOW_NOT_FOUND, .ELEMENT_NOT_FOUND,
         .APPLICATION_NOT_FOUND, .SESSION_NOT_FOUND, .SNAPSHOT_NOT_FOUND, .SNAPSHOT_STALE,
         .NO_POINT_SPECIFIED, .INVALID_COORDINATES, .NO_ACTIVE_DIALOG,
         .MENU_BAR_NOT_FOUND, .MENU_ITEM_NOT_FOUND, .DOCK_NOT_FOUND, .DOCK_LIST_NOT_FOUND,
         .DOCK_ITEM_NOT_FOUND, .POSITION_NOT_FOUND:
        .refused
    default:
        .unverifiable
    }
}

struct Empty: Codable {}
