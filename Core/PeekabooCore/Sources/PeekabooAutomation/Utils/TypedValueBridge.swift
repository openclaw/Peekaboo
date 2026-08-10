import MCP
import Tachikoma

package enum TypedValueBridge {
    package static func anyAgentValue(from value: MCP.Value) -> AnyAgentToolValue {
        switch value {
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
        default:
            AnyAgentToolValue(null: ())
        }
    }
}
