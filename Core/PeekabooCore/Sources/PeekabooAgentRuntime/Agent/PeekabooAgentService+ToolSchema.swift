import Foundation
import MCP
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    // MARK: - MCP Schema Conversion

    func convertMCPSchemaToAgentSchema(_ mcpSchema: Value) -> AgentToolParameters {
        guard case let .object(schemaDict) = mcpSchema,
              let propertiesValue = schemaDict["properties"],
              case let .object(properties) = propertiesValue
        else {
            return AgentToolParameters(properties: [:], required: [])
        }

        var agentProperties: [String: AgentToolParameterProperty] = [:]
        for (key, value) in properties {
            guard let property = self.makeAgentToolProperty(name: key, value: value) else { continue }
            agentProperties[key] = property
        }

        return AgentToolParameters(
            properties: agentProperties,
            required: self.requiredFields(from: schemaDict, properties: agentProperties))
    }

    private func requiredFields(
        from schemaDict: [String: Value],
        properties: [String: AgentToolParameterProperty]) -> [String]
    {
        guard case let .array(requiredValues) = schemaDict["required"] else { return [] }
        let declaredRequired = requiredValues.compactMap { value in
            if case let .string(str) = value {
                str
            } else {
                nil
            }
        }
        return declaredRequired.filter { properties[$0] != nil }
    }

    private func makeAgentToolProperty(name: String, value: Value) -> AgentToolParameterProperty? {
        guard case let .object(propDict) = value else {
            return nil
        }

        // MCP schemas can express unions with anyOf/oneOf and no top-level type.
        // Keep those properties visible so strict providers do not see orphan required entries.
        let paramType = self.parameterType(from: propDict)

        let description = self.descriptionValue(from: propDict["description"])
        let enumValues = self.enumValues(from: propDict["enum"])
        let items = self.itemsDefinition(for: paramType, itemsValue: propDict["items"])

        return AgentToolParameterProperty(
            name: name,
            type: paramType,
            description: description,
            enumValues: enumValues,
            items: items)
    }

    private func descriptionValue(from value: Value?) -> String {
        guard case let .string(description) = value else { return "" }
        return description
    }

    private func enumValues(from value: Value?) -> [String]? {
        guard case let .array(enumArray) = value else { return nil }
        let values = enumArray.compactMap { element -> String? in
            if case let .string(str) = element {
                str
            } else {
                nil
            }
        }
        return values.isEmpty ? nil : values
    }

    private func itemsDefinition(
        for parameterType: AgentToolParameterProperty.ParameterType,
        itemsValue: Value?) -> AgentToolParameterItems?
    {
        guard parameterType == .array else { return nil }

        guard case let .object(itemsDict) = itemsValue else {
            return AgentToolParameterItems(type: AgentToolParameterProperty.ParameterType.string.rawValue)
        }

        let itemType = self.parameterType(from: itemsDict)

        return AgentToolParameterItems(
            type: itemType.rawValue,
            description: self.descriptionValue(from: itemsDict["description"]))
    }

    private func parameterType(
        from schema: [String: Value],
        fallback: AgentToolParameterProperty.ParameterType = .string)
        -> AgentToolParameterProperty.ParameterType
    {
        if case let .string(typeString) = schema["type"],
           let resolved = AgentToolParameterProperty.ParameterType(rawValue: typeString)
        {
            return resolved
        }

        for unionKey in ["oneOf", "anyOf"] {
            guard case let .array(variants) = schema[unionKey] else { continue }
            let types = Set(variants.compactMap { variant -> AgentToolParameterProperty.ParameterType? in
                guard case let .object(variantSchema) = variant else { return nil }
                return self.parameterType(from: variantSchema)
            })
            if types.count == 1, let type = types.first {
                return type
            }
        }

        return fallback
    }
}
