import Foundation
import PeekabooFoundation
import Tachikoma
import TachikomaMCP

struct AgentToolArgumentValidationError: LocalizedError, Sendable, Equatable {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

/// Validates the provider-facing Agent schema before execution authority is evaluated.
///
/// Native MCP-backed Agent tools perform the richer MCP semantic validation again at their execution boundary. This
/// first pass prevents an invalid provider payload from being mislabeled as an execution-policy refusal.
enum AgentToolArgumentValidator {
    static func rejection(tool: AgentTool, arguments: AgentToolArguments) -> ToolResponse? {
        do {
            try self.validate(tool: tool, arguments: arguments)
            return nil
        } catch {
            let toolArguments = ToolArguments(from: arguments)
            let effect = MCPToolSnapshotMutationPolicy.effect(toolName: tool.name, arguments: toolArguments)
            let message = "Invalid tool argument: \(error.localizedDescription)"
            switch effect {
            case .conditionalMutation, .mutation, .mutationProducingFreshObservation:
                return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                    message: message,
                    reason: .invalidRequest,
                    additionalFields: ["error_code": .string("VALIDATION_ERROR")])
            case .none, .freshObservation:
                return ToolResponse.error(message)
            }
        }
    }

    private static func validate(tool: AgentTool, arguments: AgentToolArguments) throws {
        let properties = tool.parameters.properties
        // An empty Agent schema is an intentionally open compatibility surface used by injected/custom tools.
        // Native MCP-backed tools and built-in completion tools all publish closed nonempty schemas.
        guard !properties.isEmpty || !tool.parameters.required.isEmpty else { return }
        let unknown = arguments.keys.filter { properties[$0] == nil }.sorted()
        guard unknown.isEmpty else {
            let names = unknown.map(String.init(reflecting:)).joined(separator: ", ")
            throw AgentToolArgumentValidationError(
                message: "Unknown Agent tool properties: \(names).")
        }
        for required in tool.parameters.required where arguments[required] == nil {
            throw AgentToolArgumentValidationError(message: "Missing required property '\(required)'.")
        }
        for key in arguments.keys.sorted() {
            guard let property = properties[key], let value = arguments[key] else { continue }
            try self.validate(value: value.toJSON(), property: property, path: "$.\(key)")
        }
    }

    private static func validate(
        value: Any,
        property: AgentToolParameterProperty,
        path: String) throws
    {
        switch property.type {
        case .string:
            guard let string = value as? String else { try self.throwType(path: path, expected: "string") }
            if let allowed = property.enumValues, !allowed.contains(string) {
                throw AgentToolArgumentValidationError(
                    message: "Property \(path) must be one of: \(allowed.joined(separator: ", ")).")
            }
            if let minimum = property.minLength, string.count < minimum {
                throw AgentToolArgumentValidationError(
                    message: "Property \(path) is shorter than \(minimum) characters.")
            }
            if let maximum = property.maxLength, string.count > maximum {
                throw AgentToolArgumentValidationError(
                    message: "Property \(path) is longer than \(maximum) characters.")
            }
        case .integer:
            guard let integer = self.integer(value) else { try self.throwType(path: path, expected: "integer") }
            try self.validateBounds(Double(integer), property: property, path: path)
        case .number:
            guard let number = self.number(value), number.isFinite else {
                try self.throwType(path: path, expected: "finite number")
            }
            try self.validateBounds(number, property: property, path: path)
        case .boolean:
            guard value is Bool else { try self.throwType(path: path, expected: "boolean") }
        case .array:
            guard let values = value as? [Any] else { try self.throwType(path: path, expected: "array") }
            if let items = property.items {
                for (index, item) in values.enumerated() {
                    try self.validate(value: item, items: items, path: "\(path)[\(index)]")
                }
            }
        case .object:
            guard let object = value as? [String: Any] else { try self.throwType(path: path, expected: "object") }
            try self.validateObject(
                object,
                properties: property.properties,
                required: property.required,
                path: path)
        case .null:
            guard value is NSNull else { try self.throwType(path: path, expected: "null") }
        }
    }

    private static func validate(value: Any, items: AgentToolParameterItems, path: String) throws {
        switch items.type {
        case "string":
            guard let string = value as? String else { try self.throwType(path: path, expected: "string") }
            if let allowed = items.enumValues, !allowed.contains(string) {
                throw AgentToolArgumentValidationError(
                    message: "Property \(path) must be one of: \(allowed.joined(separator: ", ")).")
            }
        case "integer":
            guard self.integer(value) != nil else { try self.throwType(path: path, expected: "integer") }
        case "number":
            guard let number = self.number(value), number.isFinite else {
                try self.throwType(path: path, expected: "finite number")
            }
        case "boolean":
            guard value is Bool else { try self.throwType(path: path, expected: "boolean") }
        case "object":
            guard let object = value as? [String: Any] else { try self.throwType(path: path, expected: "object") }
            try self.validateObject(
                object,
                properties: items.properties,
                required: items.required,
                path: path)
        case "array":
            guard let values = value as? [Any] else { try self.throwType(path: path, expected: "array") }
            if let nested = items.items {
                for (index, item) in values.enumerated() {
                    try self.validate(value: item, items: nested, path: "\(path)[\(index)]")
                }
            }
        case "null":
            guard value is NSNull else { try self.throwType(path: path, expected: "null") }
        default:
            throw AgentToolArgumentValidationError(message: "Property \(path) has an unsupported schema type.")
        }
    }

    private static func validateObject(
        _ object: [String: Any],
        properties: [String: AgentToolParameterProperty]?,
        required: [String]?,
        path: String) throws
    {
        guard let properties else { return }
        let unknown = object.keys.filter { properties[$0] == nil }.sorted()
        guard unknown.isEmpty else {
            let names = unknown.map(String.init(reflecting:)).joined(separator: ", ")
            throw AgentToolArgumentValidationError(
                message: "Unknown properties at \(path): \(names).")
        }
        for key in required ?? [] where object[key] == nil {
            throw AgentToolArgumentValidationError(message: "Missing required property '\(path).\(key)'.")
        }
        for key in object.keys.sorted() {
            guard let property = properties[key], let value = object[key] else { continue }
            try self.validate(value: value, property: property, path: "\(path).\(key)")
        }
    }

    private static func validateBounds(
        _ value: Double,
        property: AgentToolParameterProperty,
        path: String) throws
    {
        if let minimum = property.minimum, value < minimum {
            throw AgentToolArgumentValidationError(message: "Property \(path) must be at least \(minimum).")
        }
        if let maximum = property.maximum, value > maximum {
            throw AgentToolArgumentValidationError(message: "Property \(path) must be at most \(maximum).")
        }
    }

    private static func integer(_ value: Any) -> Int? {
        if value is Bool {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        guard let value = value as? Double, value.isFinite, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    private static func number(_ value: Any) -> Double? {
        if value is Bool {
            return nil
        }
        if let value = value as? Int {
            return Double(value)
        }
        return value as? Double
    }

    private static func throwType(path: String, expected: String) throws -> Never {
        throw AgentToolArgumentValidationError(message: "Property \(path) must be a \(expected).")
    }
}
