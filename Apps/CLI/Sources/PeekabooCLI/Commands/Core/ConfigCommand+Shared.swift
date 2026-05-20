//
//  ConfigCommand+Shared.swift
//  PeekabooCLI
//

import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
protocol ConfigRuntimeCommand {
    var runtime: CommandRuntime? { get set }

    mutating func prepare(using runtime: CommandRuntime)
}

extension ConfigRuntimeCommand {
    /// Lazily unwrap the command runtime or crash fast during development.
    var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    var logger: Logger {
        self.resolvedRuntime.logger
    }

    var jsonOutput: Bool {
        self.resolvedRuntime.configuration.jsonOutput
    }

    mutating func prepare(using runtime: CommandRuntime) {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        // Align Tachikoma profile dir with Peekaboo storage
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

struct SuccessOutput: Encodable {
    let success: Bool
    let data: [String: Any]
    let debugLogs: [String]

    init(success: Bool, data: [String: Any], debugLogs: [String] = []) {
        self.success = success
        self.data = data
        self.debugLogs = debugLogs
    }

    func withDebugLogs(_ debugLogs: [String]) -> Self {
        Self(success: self.success, data: self.data, debugLogs: debugLogs)
    }

    enum CodingKeys: String, CodingKey {
        case success, data
        case debugLogs = "debug_logs"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.success, forKey: .success)
        try container.encode(JSONValue(self.data), forKey: .data)
        try container.encode(self.debugLogs, forKey: .debugLogs)
    }
}

struct ErrorOutput: Encodable {
    let success = false
    let error: ConfigErrorInfo
    let debugLogs: [String]

    init(error _: Bool = true, code: String, message: String, details: String?, debugLogs: [String] = []) {
        self.error = ConfigErrorInfo(code: code, message: message, details: details)
        self.debugLogs = debugLogs
    }

    enum CodingKeys: String, CodingKey {
        case success, error
        case debugLogs = "debug_logs"
    }

    func withDebugLogs(_ debugLogs: [String]) -> Self {
        Self(
            code: self.error.code,
            message: self.error.message,
            details: self.error.details,
            debugLogs: debugLogs
        )
    }
}

struct ConfigErrorInfo: Encodable {
    let code: String
    let message: String
    let details: String?
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

func outputJSON(_ value: SuccessOutput, logger: Logger) {
    writeConfigJSON(value.withDebugLogs(logger.getDebugLogs()), logger: logger)
}

func outputJSON(_ value: ErrorOutput, logger: Logger) {
    writeConfigJSON(value.withDebugLogs(logger.getDebugLogs()), logger: logger)
}

func outputJSON(_ value: some Encodable, logger: Logger) {
    writeConfigJSON(value, logger: logger)
}

private func writeConfigJSON(_ value: some Encodable, logger: Logger) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(value)
        if let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    } catch {
        logger.error("Failed to encode config JSON output: \(error.localizedDescription)")
        print("{\n  \"success\": false,\n  \"error\": {\n    \"message\": \"Failed to encode JSON response\"\n  }\n}")
    }
}
