import Foundation
import MCP
import Tachikoma

package enum TypedValueBridge {
    static func typedValue(from value: MCP.Value) -> Tachikoma.TypedValue {
        switch value {
        case .null:
            .null
        case let .bool(v):
            .bool(v)
        case let .int(v):
            .int(v)
        case let .double(v):
            .double(v)
        case let .string(v):
            .string(v)
        case let .array(values):
            .array(values.map { self.typedValue(from: $0) })
        case let .object(dict):
            .object(dict.mapValues { self.typedValue(from: $0) })
        default:
            .null
        }
    }

    static func mcpValue(from typedValue: Tachikoma.TypedValue) -> MCP.Value {
        switch typedValue {
        case .null:
            .null
        case let .bool(v):
            .bool(v)
        case let .int(v):
            .int(v)
        case let .double(v):
            .double(v)
        case let .string(v):
            .string(v)
        case let .array(values):
            .array(values.map { self.mcpValue(from: $0) })
        case let .object(dict):
            .object(dict.mapValues { self.mcpValue(from: $0) })
        }
    }

    static func typedValue(from anyAgentValue: AnyAgentToolValue) throws -> Tachikoma.TypedValue {
        let json = try anyAgentValue.toJSON()
        return try Tachikoma.TypedValue.fromJSON(json)
    }

    static func anyAgentValue(from typedValue: Tachikoma.TypedValue) -> AnyAgentToolValue {
        switch typedValue {
        case .null:
            AnyAgentToolValue(null: ())
        case let .bool(v):
            AnyAgentToolValue(bool: v)
        case let .int(v):
            AnyAgentToolValue(int: v)
        case let .double(v):
            AnyAgentToolValue(double: v)
        case let .string(v):
            AnyAgentToolValue(string: v)
        case let .array(values):
            AnyAgentToolValue(array: values.map { self.anyAgentValue(from: $0) })
        case let .object(dict):
            AnyAgentToolValue(object: dict.mapValues { self.anyAgentValue(from: $0) })
        }
    }

    package static func anyAgentValue(from value: MCP.Value) -> AnyAgentToolValue {
        self.anyAgentValue(from: self.typedValue(from: value))
    }

    static func anyAgentValue(fromAny any: Any) -> AnyAgentToolValue {
        do {
            let typedValue = try Tachikoma.TypedValue.fromJSON(any)
            return self.anyAgentValue(from: typedValue)
        } catch {
            return AnyAgentToolValue(string: String(describing: any))
        }
    }

    static func mcpValue(from anyAgentValue: AnyAgentToolValue) -> MCP.Value {
        let typedValue = (try? typedValue(from: anyAgentValue)) ?? .null
        return self.mcpValue(from: typedValue)
    }

    static func any(from anyAgentValue: AnyAgentToolValue) -> Any {
        do {
            return try anyAgentValue.toJSON()
        } catch {
            return String(describing: anyAgentValue)
        }
    }
}
