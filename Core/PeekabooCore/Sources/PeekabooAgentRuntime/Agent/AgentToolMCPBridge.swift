import Foundation
import MCP
import PeekabooAutomation
import Tachikoma
import TachikomaMCP

// MARK: - Type Conversion Extensions

// MARK: ToolArguments Extension

extension ToolArguments {
    /// Initialize from AgentToolArguments
    init(from arguments: AgentToolArguments) {
        // Convert AgentToolArguments to [String: Any]
        var dict: [String: Any] = [:]
        for key in arguments.keys {
            guard let value = arguments[key], let json = try? value.toJSON() else { continue }
            dict[key] = json
        }
        self.init(raw: dict)
    }

    /// Initialize from dictionary
    init(from dict: [String: Any]) {
        self.init(raw: dict)
    }
}

// MARK: - Extension implementations moved to TypedValueBridge.swift

// All Value and AnyAgentToolValue conversion extensions are now centralized in TypedValueBridge
// to eliminate code duplication and use the unified TypedValue system

// MARK: - Helper function to convert ToolResponse to AnyAgentToolValue

private func convertToolResponseContent(_ content: MCP.Tool.Content) -> AnyAgentToolValue {
    switch content {
    case let .text(text, _, _):
        return AnyAgentToolValue(string: text)
    case let .image(data, mimeType, _, _):
        // For images, return a descriptive string
        return AnyAgentToolValue(string: "[Image: \(mimeType), size: \(data.count) bytes]")
    case let .resource(resource, _, _):
        // For resources, return the text content if available
        return AnyAgentToolValue(string: resource.text ?? "[Resource: \(resource.uri)]")
    case let .resourceLink(uri, name, _, _, mimeType, _):
        let mimeTypeDescription = mimeType.map { ", mimeType: \($0)" } ?? ""
        return AnyAgentToolValue(string: "[Resource Link: \(name), uri: \(uri)\(mimeTypeDescription)]")
    case let .audio(data, mimeType, _, _):
        return AnyAgentToolValue(string: "[Audio: \(mimeType), size: \(data.count) bytes]")
    }
}

@preconcurrency
func convertToolResponseToAgentToolResult(_ response: ToolResponse) -> AnyAgentToolValue {
    // If there's an error, return error message
    if response.isError {
        let errorMessage = response.content.compactMap { content -> String? in
            if case let .text(text, _, _) = content {
                return text
            }
            return nil
        }.joined(separator: "\n")

        return AnyAgentToolValue(string: "Error: \(errorMessage)")
    }

    let contentValue: AnyAgentToolValue = if response.content.isEmpty {
        AnyAgentToolValue(string: "Success")
    } else if response.content.count == 1 {
        convertToolResponseContent(response.content[0])
    } else {
        AnyAgentToolValue(array: response.content.map { convertToolResponseContent($0) })
    }

    guard let meta = response.meta else {
        return contentValue
    }

    var payload: [String: AnyAgentToolValue] = [
        "result": contentValue,
        "meta": TypedValueBridge.anyAgentValue(from: meta),
    ]

    if let text = contentValue.stringValue {
        payload["text"] = AnyAgentToolValue(string: text)
    }

    return AnyAgentToolValue(object: payload)
}

@preconcurrency
func convertToolResponseToAgentToolResultAsync(_ response: ToolResponse) async -> AnyAgentToolValue {
    convertToolResponseToAgentToolResult(response)
}

func makeToolArguments(from arguments: AgentToolArguments) -> ToolArguments {
    ToolArguments(from: arguments)
}

func makeToolArguments(fromDict dict: [String: Any]) -> ToolArguments {
    ToolArguments(from: dict)
}

func dictionaryFromArguments(_ arguments: AgentToolArguments) -> [String: AnyAgentToolValue] {
    var dict: [String: AnyAgentToolValue] = [:]
    for key in arguments.keys {
        if let value = arguments[key] {
            dict[key] = value
        }
    }
    return dict
}
