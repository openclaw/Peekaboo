import Foundation
import MCP
import TachikomaMCP

struct MCPToolArgumentValueError: LocalizedError, Sendable, Equatable {
    enum Expectation: String, Sendable {
        case integer = "an exact integer within the supported range"
        case number = "a finite number"
    }

    let key: String
    let expectation: Expectation

    var errorDescription: String? {
        "Parameter '\(self.key)' must be \(self.expectation.rawValue)."
    }
}

struct MCPToolArgumentSchemaError: LocalizedError, Sendable, Equatable {
    let path: String
    let properties: [String]

    var errorDescription: String? {
        let noun = self.properties.count == 1 ? "property" : "properties"
        let names = self.properties.prefix(8).map { String(reflecting: $0) }.joined(separator: ", ")
        let remainder = self.properties.count > 8 ? " and \(self.properties.count - 8) more" : ""
        return "Unknown \(noun) \(names)\(remainder) at \(self.path)."
    }
}

/// Side-effect-free semantic validation that must complete before execution authority is evaluated.
///
/// JSON Schema catches wire shapes, while individual tools own cross-field and domain-specific rules. Keeping this
/// hook in the shared argument validator ensures malformed input is reported as an invalid request instead of being
/// masked by a stricter execution-policy refusal.
protocol MCPToolArgumentSemanticValidating {
    func validateArgumentSemantics(_ arguments: ToolArguments) throws
}

extension ToolArguments {
    func validatedInt(_ key: String) throws -> Int? {
        guard self.getValue(for: key) != nil else { return nil }
        guard let value = self.getInt(key) else {
            throw MCPToolArgumentValueError(key: key, expectation: .integer)
        }
        return value
    }

    func validatedNumber(_ key: String) throws -> Double? {
        guard self.getValue(for: key) != nil else { return nil }
        guard let value = self.getNumber(key) else {
            throw MCPToolArgumentValueError(key: key, expectation: .number)
        }
        return value
    }
}

enum MCPToolArgumentValidator {
    static func validateClosedProperties(tool: any MCPTool, arguments: ToolArguments) throws {
        try self.validateClosedProperties(
            value: arguments.rawValue,
            schema: tool.inputSchema,
            path: "$")
    }

    static func rejection(
        tool: any MCPTool,
        arguments: ToolArguments,
        snapshotEffect: MCPToolSnapshotEffect) -> ToolResponse?
    {
        do {
            try self.validateClosedProperties(tool: tool, arguments: arguments)

            guard case let .object(schema) = tool.inputSchema,
                  case let .object(properties)? = schema["properties"]
            else {
                return nil
            }

            for key in properties.keys.sorted() where arguments.getValue(for: key) != nil {
                guard case let .object(property)? = properties[key],
                      case let .string(type)? = property["type"]
                else {
                    continue
                }

                switch type {
                case "integer":
                    _ = try arguments.validatedInt(key)
                case "number":
                    _ = try arguments.validatedNumber(key)
                default:
                    continue
                }
            }
            try (tool as? any MCPToolArgumentSemanticValidating)?.validateArgumentSemantics(arguments)
            return nil
        } catch let error as MCPToolArgumentSchemaError {
            return self.rejectionResponse(
                message: error.localizedDescription,
                snapshotEffect: snapshotEffect)
        } catch let error as MCPToolArgumentValueError {
            return self.rejectionResponse(
                message: error.localizedDescription,
                snapshotEffect: snapshotEffect)
        } catch {
            return self.rejectionResponse(
                message: "Invalid tool argument: \(error.localizedDescription)",
                snapshotEffect: snapshotEffect)
        }
    }

    private static func validateClosedProperties(
        value: Value,
        schema: Value,
        path: String) throws
    {
        guard case let .object(schemaFields) = schema else { return }

        if case let .object(argumentFields) = value {
            let propertySchemas = schemaFields["properties"]?.objectValue ?? [:]
            if schemaFields["additionalProperties"] == .bool(false) {
                let unknown = argumentFields.keys.filter { propertySchemas[$0] == nil }.sorted()
                guard unknown.isEmpty else {
                    throw MCPToolArgumentSchemaError(path: path, properties: unknown)
                }
            }

            for key in argumentFields.keys.sorted() {
                guard let propertySchema = propertySchemas[key], let propertyValue = argumentFields[key] else {
                    continue
                }
                try self.validateClosedProperties(
                    value: propertyValue,
                    schema: propertySchema,
                    path: self.appending(key, to: path))
            }
        } else if case let .array(items) = value,
                  let itemSchema = schemaFields["items"]
        {
            for (index, item) in items.enumerated() {
                try self.validateClosedProperties(
                    value: item,
                    schema: itemSchema,
                    path: "\(path)[\(index)]")
            }
        }

        if case let .array(allOf)? = schemaFields["allOf"] {
            for alternative in allOf {
                try self.validateClosedProperties(value: value, schema: alternative, path: path)
            }
        }
        for keyword in ["oneOf", "anyOf"] {
            guard case let .array(alternatives)? = schemaFields[keyword] else { continue }
            try self.validateAtLeastOneAlternative(
                value: value,
                alternatives: alternatives,
                path: path)
        }
    }

    private static func validateAtLeastOneAlternative(
        value: Value,
        alternatives: [Value],
        path: String) throws
    {
        let candidates = self.discriminatorMatches(value: value, alternatives: alternatives)
        var firstError: MCPToolArgumentSchemaError?
        for alternative in candidates {
            do {
                try self.validateClosedProperties(value: value, schema: alternative, path: path)
                return
            } catch let error as MCPToolArgumentSchemaError {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    private static func discriminatorMatches(value: Value, alternatives: [Value]) -> [Value] {
        guard case let .object(argumentFields) = value else { return alternatives }

        let scored = alternatives.map { alternative -> (Value, Int, Bool) in
            guard case let .object(schemaFields) = alternative,
                  case let .object(properties)? = schemaFields["properties"]
            else {
                return (alternative, 0, false)
            }

            var matches = 0
            for (key, propertySchema) in properties {
                guard let argumentValue = argumentFields[key],
                      case let .object(propertyFields) = propertySchema
                else {
                    continue
                }
                if let constant = propertyFields["const"] {
                    guard argumentValue == constant else { return (alternative, 0, true) }
                    matches += 1
                }
                if case let .array(allowed)? = propertyFields["enum"] {
                    guard allowed.contains(argumentValue) else { return (alternative, 0, true) }
                    matches += 1
                }
            }
            return (alternative, matches, false)
        }
        let maximumScore = scored.map(\.1).max() ?? 0
        guard maximumScore > 0 else {
            let nonConflicting = scored.filter { !$0.2 }.map(\.0)
            return nonConflicting.isEmpty ? alternatives : nonConflicting
        }
        return scored.filter { $0.1 == maximumScore && !$0.2 }.map(\.0)
    }

    private static func appending(_ key: String, to path: String) -> String {
        let isIdentifier = !key.isEmpty && key.allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
        return isIdentifier ? "\(path).\(key)" : "\(path)[\(String(reflecting: key))]"
    }

    private static func rejectionResponse(
        message: String,
        snapshotEffect: MCPToolSnapshotEffect) -> ToolResponse
    {
        switch snapshotEffect {
        case .conditionalMutation, .mutation, .mutationProducingFreshObservation:
            MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: message,
                reason: .invalidRequest,
                additionalFields: ["error_code": .string("VALIDATION_ERROR")])
        case .none, .freshObservation:
            ToolResponse.error(message)
        }
    }
}
