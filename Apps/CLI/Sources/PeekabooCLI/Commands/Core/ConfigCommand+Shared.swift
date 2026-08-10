import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
protocol ConfigRuntimeCommand: InjectedRuntimeBackedCommand {
    mutating func prepare(using runtime: CommandRuntime)
}

extension ConfigRuntimeCommand {
    mutating func prepare(using runtime: CommandRuntime) {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        PeekabooCore.ConfigurationManager.configureTachikomaProfileDirectory()
    }

    var output: ConfigCommandOutput {
        ConfigCommandOutput(logger: self.logger, jsonOutput: self.jsonOutput)
    }

    var configManager: ConfigurationManager {
        ConfigurationManager.shared
    }

    var configPath: String {
        ConfigurationManager.configPath
    }

    var credentialsPath: String {
        ConfigurationManager.credentialsPath
    }

    var baseDir: String {
        ConfigurationManager.baseDir
    }

    func defaultEditor(from environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["EDITOR"] ?? "nano"
    }
}

@MainActor
struct ConfigCommandOutput {
    let logger: Logger
    let jsonOutput: Bool

    func success(message: String, data: [String: Any] = [:], textLines: [String]? = nil) {
        if self.jsonOutput {
            outputJSONCodable(
                SuccessOutput(
                    success: true,
                    data: self.messagePayload(message: message, data: data),
                    debugLogs: self.logger.getDebugLogs()
                ),
                logger: self.logger
            )
            return
        }

        (textLines ?? [message]).forEach { print($0) }
    }

    func error(code: String, message: String, details: String? = nil, textLines: [String]? = nil) {
        if self.jsonOutput {
            outputJSONCodable(
                ErrorOutput(error: true, code: code, message: message, details: details),
                logger: self.logger
            )
            return
        }

        (textLines ?? ["\(message)"]).forEach { print($0) }
    }

    func info(_ lines: [String]) {
        guard !self.jsonOutput else { return }
        lines.forEach { print($0) }
    }

    private func messagePayload(message: String, data: [String: Any]) -> [String: Any] {
        var payload = data
        if payload["message"] == nil {
            payload["message"] = message
        }
        return payload
    }
}

func SuccessOutput(
    success: Bool,
    data: [String: Any],
    debugLogs: [String] = []
) -> ResultEnvelope<JSONValue> {
    ResultEnvelope(success: success, data: JSONValue(data), debug_logs: debugLogs)
}

func ErrorOutput(
    error _: Bool = true,
    code: String,
    message: String,
    details: String?,
    debugLogs: [String] = []
) -> ResultEnvelope<Empty?> {
    ResultEnvelope(
        success: false,
        data: nil,
        debug_logs: debugLogs,
        error: ErrorInfo(message: message, code: code, details: details)
    )
}

struct JSONValue: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self.value {
        case let val as String:
            try container.encode(val)
        case let val as Int:
            try container.encode(val)
        case let val as Double:
            try container.encode(val)
        case let val as Bool:
            try container.encode(val)
        case let val as [String: Any]:
            try container.encode(Self.encodeDictionary(val))
        case let val as [Any]:
            try container.encode(Self.encodeArray(val))
        case is NSNull:
            try container.encodeNil()
        default:
            let description = String(describing: self.value)
            try container.encode(description)
        }
    }

    private static func encodeDictionary(_ dictionary: [String: Any]) -> [String: JSONValue] {
        dictionary.mapValues { JSONValue($0) }
    }

    private static func encodeArray(_ array: [Any]) -> [JSONValue] {
        array.map { JSONValue($0) }
    }
}

func outputJSON(_ value: ResultEnvelope<JSONValue>, logger: Logger) {
    outputJSONCodable(
        ResultEnvelope(
            success: value.success,
            effect: value.effect,
            data: value.data,
            messages: value.messages,
            debug_logs: logger.getDebugLogs(),
            error: value.error
        ),
        logger: logger
    )
}

func outputJSON(_ value: ResultEnvelope<Empty?>, logger: Logger) {
    outputJSONCodable(
        ResultEnvelope<Empty?>(
            success: value.success,
            effect: value.effect,
            data: value.data,
            messages: value.messages,
            debug_logs: logger.getDebugLogs(),
            error: value.error
        ),
        logger: logger
    )
}
