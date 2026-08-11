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
    static func rejection(tool: any MCPTool, arguments: ToolArguments) -> ToolResponse? {
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"]
        else {
            return nil
        }

        do {
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
            return nil
        } catch let error as MCPToolArgumentValueError {
            return ToolResponse.error(
                error.localizedDescription,
                meta: .object([
                    "mutation_dispatched": .bool(false),
                    "retry_safe": .bool(true),
                ]))
        } catch {
            return ToolResponse.error(
                "Invalid numeric tool argument: \(error.localizedDescription)",
                meta: .object([
                    "mutation_dispatched": .bool(false),
                    "retry_safe": .bool(true),
                ]))
        }
    }
}
