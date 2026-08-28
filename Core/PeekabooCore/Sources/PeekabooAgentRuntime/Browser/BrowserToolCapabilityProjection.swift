import Foundation
import MCP
import TachikomaMCP

enum BrowserToolCapabilityProjection {
    struct ProviderProjection {
        let pageMappings: [String: String]
        let structuralElementMappings: [String: String]
        let issueElementMappings: [String: String]
        let phraseElementMappings: [String: String]
        let calls: [BrowserMCPMappedCall]
        let thirdPartyMessage: (raw: String, projected: String)?
    }

    struct ContentProjection {
        let responseProjection: BrowserMCPToolCapabilityContract.ResponseProjection
        let provider: ProviderProjection
        let thirdPartyElementMappings: [String: String]
        let mayContainSnapshot: Bool
    }

    private static let thirdPartySnapshotMarker = "\n## Latest page snapshot"

    static func replacingPageIDs(in text: String, mappings: [String: String]) -> String {
        guard !mappings.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var value = String(line)
            if let separator = value.firstIndex(of: ":") {
                let prefix = String(value[..<separator])
                if let replacement = mappings[prefix] {
                    value = replacement + value[separator...]
                }
            }
            if value.hasPrefix("Note: ") {
                for (providerID, reference) in mappings.sorted(by: { $0.key.count > $1.key.count }) {
                    value = value.replacingOccurrences(of: "Page \(providerID) ", with: "Page \(reference) ")
                    value = value.replacingOccurrences(of: "page \(providerID) ", with: "page \(reference) ")
                }
            }
            return value
        }.joined(separator: "\n")
    }

    static func replacingElementUIDs(in text: String, mappings: [String: String]) -> String {
        guard !mappings.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let value = String(line)
            let contentStart = value.firstIndex(where: { !$0.isWhitespace }) ?? value.endIndex
            let content = value[contentStart...]
            guard content.hasPrefix("uid=") else { return value }
            let uidStart = content.index(content.startIndex, offsetBy: 4)
            let uidEnd = content[uidStart...].firstIndex(where: \.isWhitespace) ?? content.endIndex
            let providerUID = String(content[uidStart..<uidEnd])
            guard let reference = mappings[providerUID] else { return value }
            return String(value[..<contentStart]) + "uid=\(reference)" + String(content[uidEnd...])
        }.joined(separator: "\n")
    }

    static func projectingThirdPartyJSON(
        _ text: String,
        mappings: [String: String]) -> String?
    {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        func project(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                if dictionary.count == 1, let providerUID = dictionary["uid"] as? String {
                    return mappings[providerUID].map { ["uid": $0] } ?? dictionary
                }
                return dictionary.mapValues(project)
            }
            if let array = value as? [Any] {
                return array.map(project)
            }
            return value
        }
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: project(object),
            options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    static func thirdPartySnapshotSection(in text: String) -> String? {
        guard let markerRange = text.range(of: self.thirdPartySnapshotMarker) else { return nil }
        return String(text[markerRange.lowerBound...])
    }

    static func replacingElementUIDsInThirdPartySnapshot(
        in text: String,
        mappings: [String: String]) -> String
    {
        guard let markerRange = text.range(of: self.thirdPartySnapshotMarker) else { return text }
        let prefix = text[..<markerRange.lowerBound]
        let snapshot = self.replacingElementUIDs(
            in: String(text[markerRange.lowerBound...]),
            mappings: mappings)
        return String(prefix) + snapshot
    }

    static func replacingThirdPartyResultUIDs(
        in text: String,
        mappings: [String: String],
        rawStructuredMessage: String?,
        projectedStructuredMessage: String?) -> String
    {
        if let rawStructuredMessage,
           let projectedStructuredMessage,
           text.contains(rawStructuredMessage)
        {
            return text.replacingOccurrences(of: rawStructuredMessage, with: projectedStructuredMessage)
        }
        if let range = self.thirdPartyJSONRange(in: text),
           let projected = self.projectingThirdPartyJSON(String(text[range]), mappings: mappings)
        {
            return String(text[..<range.lowerBound]) + projected + String(text[range.upperBound...])
        }
        var result = text
        for (providerUID, reference) in mappings.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(
                of: #""uid":"\#(providerUID)""#,
                with: #""uid":"\#(reference)""#)
            result = result.replacingOccurrences(
                of: #""uid": "\#(providerUID)""#,
                with: #""uid": "\#(reference)""#)
        }
        return result
    }

    static func replacingUploadResponse(
        in text: String,
        calls: [BrowserMCPMappedCall]) -> String
    {
        guard let sourcePath = calls.last(where: { $0.toolName == "upload_file" })?
            .arguments["filePath"] as? String
        else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let value = String(line)
            guard value.hasPrefix("File uploaded from "), value.hasSuffix(".") else { return value }
            return "File uploaded from \(sourcePath)."
        }.joined(separator: "\n")
    }

    static func projectingProviderMessages(
        in value: Value?,
        projection: ProviderProjection) -> Value?
    {
        guard let value else { return nil }
        let issueProjected = self.projectingIssueResourceFields(
            in: value,
            mappings: projection.issueElementMappings)
        return self.projectingProviderFields(in: issueProjected) { text in
            var projected = self.replacingPageIDs(in: text, mappings: projection.pageMappings)
            projected = self.replacingUploadResponse(in: projected, calls: projection.calls)
            if let thirdPartyMessage = projection.thirdPartyMessage {
                projected = projected.replacingOccurrences(
                    of: thirdPartyMessage.raw,
                    with: thirdPartyMessage.projected)
            }
            projected = self.replacingElementUIDs(
                in: projected,
                mappings: projection.structuralElementMappings)
            projected = self.replacingIssueResourceUIDs(
                in: projected,
                mappings: projection.issueElementMappings)
            projected = self.replacingElementUIDPhrases(
                in: projected,
                mappings: projection.phraseElementMappings)
            return projected
        }
    }

    static func sanitizingProviderError(_ response: ToolResponse) -> ToolResponse {
        let safeMetadata = MCPToolResponseMetadataProjector.externalFields(
            from: response.meta,
            toolName: "browser")
        return ToolResponse(
            content: [.text(
                text: "Browser provider returned an error; provider diagnostics were withheld because they can " +
                    "contain process-local page or element identifiers.",
                annotations: nil,
                _meta: nil)],
            isError: response.isError,
            meta: safeMetadata.isEmpty ? nil : .object(safeMetadata),
            structuredContent: nil)
    }

    static func replacingElementUIDPhrases(
        in text: String,
        mappings: [String: String]) -> String
    {
        var result = text
        for (providerUID, reference) in mappings.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(
                of: "uid \"\(providerUID)\"",
                with: "uid \"\(reference)\"")
            result = result.replacingOccurrences(
                of: "uid '\(providerUID)'",
                with: "uid '\(reference)'")
            result = result.replacingOccurrences(
                of: "uid \(providerUID).",
                with: "uid \(reference).")
            result = result.replacingOccurrences(
                of: "uid \(providerUID) ",
                with: "uid \(reference) ")
        }
        return result
    }

    static func replacingIssueResourceUIDs(
        in text: String,
        mappings: [String: String]) -> String
    {
        guard !mappings.isEmpty,
              let marker = text.range(of: "### Affected resources", options: .backwards)
        else { return text }
        let prefix = text[..<marker.upperBound]
        let suffix = self.replacingElementUIDs(
            in: String(text[marker.upperBound...]),
            mappings: mappings)
        return String(prefix) + suffix
    }

    static func containsUnmappedIssueResourceUID(
        in text: String,
        mappings: [String: String]) -> Bool
    {
        guard let marker = text.range(of: "### Affected resources", options: .backwards) else { return false }
        for line in text[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.drop(while: \.isWhitespace)
            guard content.hasPrefix("uid=") else { continue }
            let uid = String(content.dropFirst(4).prefix(while: { !$0.isWhitespace }))
            if self.isProviderUID(uid), mappings[uid] == nil {
                return true
            }
        }
        return false
    }

    static func containsUnmappedIssueResourceUID(
        in value: Value?,
        mappings: [String: String]) -> Bool
    {
        guard let value else { return false }
        switch value {
        case let .object(fields):
            for (key, child) in fields {
                if key == "affectedResources", case let .array(resources) = child {
                    for resource in resources {
                        if case let .object(resourceFields) = resource,
                           let uid = resourceFields["uid"]?.stringValue,
                           self.isProviderUID(uid),
                           mappings[uid] == nil
                        {
                            return true
                        }
                    }
                }
                if self.containsUnmappedIssueResourceUID(in: child, mappings: mappings) {
                    return true
                }
            }
            return false
        case let .array(values):
            return values.contains { self.containsUnmappedIssueResourceUID(in: $0, mappings: mappings) }
        case .string, .int, .double, .bool, .null, .data:
            return false
        }
    }

    static func snapshotRowsAreUnambiguous(
        in text: String,
        mappings: [String: String]) -> Bool
    {
        guard !text.contains(where: { $0.isNewline && $0 != "\n" }) else { return false }
        var counts: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.drop(while: \.isWhitespace)
            guard content.hasPrefix("uid=") else { continue }
            let value = String(content.dropFirst(4).prefix(while: { !$0.isWhitespace }))
            guard mappings[value] != nil else { return false }
            counts[value, default: 0] += 1
        }
        return Set(counts.keys) == Set(mappings.keys) && counts.values.allSatisfy { $0 == 1 }
    }

    static func containsUnmappedThirdPartyProviderUID(
        _ text: String,
        mappings: [String: String]) -> Bool
    {
        let candidate: String = if let range = self.thirdPartyJSONRange(in: text) {
            String(text[range])
        } else {
            text
        }
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }

        func containsUnmapped(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                if dictionary.count == 1,
                   let uid = dictionary["uid"] as? String,
                   self.isProviderUID(uid)
                {
                    return mappings[uid] == nil
                }
                return dictionary.values.contains(where: containsUnmapped)
            }
            if let array = value as? [Any] {
                return array.contains(where: containsUnmapped)
            }
            return false
        }
        return containsUnmapped(object)
    }

    private static func isProviderUID(_ value: String) -> Bool {
        if value.hasPrefix("stashed-") {
            return self.isASCIIDigits(value.dropFirst("stashed-".count))
        }
        let components = value.split(separator: "_", omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy(self.isASCIIDigits)
    }

    private static func isASCIIDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    static func projectingMetadata(
        _ metadata: Metadata?,
        transform: (String) -> String) -> Metadata?
    {
        guard let metadata else { return nil }
        return Metadata(additionalFields: metadata.fields.mapValues {
            self.replacingStrings(in: $0, transform: transform)
        })
    }

    static func projectingProviderMetadata(
        _ metadata: Metadata?,
        transform: (String) -> String) -> Metadata?
    {
        guard let metadata,
              case let .object(fields) = self.projectingProviderFields(
                  in: .object(metadata.fields),
                  transform: transform)
        else { return metadata }
        return Metadata(additionalFields: fields)
    }

    static func projectingContentItem(
        _ item: Tool.Content,
        transform: (String) -> String,
        projectAllMetadata: Bool = true) -> Tool.Content
    {
        func projectMetadata(_ value: Metadata?) -> Metadata? {
            projectAllMetadata
                ? self.projectingMetadata(value, transform: transform)
                : self.projectingProviderMetadata(value, transform: transform)
        }
        return switch item {
        case let .text(text, annotations, metadata):
            .text(
                text: transform(text),
                annotations: annotations,
                _meta: projectMetadata(metadata))
        case let .image(data, mimeType, annotations, metadata):
            .image(
                data: data,
                mimeType: mimeType,
                annotations: annotations,
                _meta: projectMetadata(metadata))
        case let .audio(data, mimeType, annotations, metadata):
            .audio(
                data: data,
                mimeType: mimeType,
                annotations: annotations,
                _meta: projectMetadata(metadata))
        case let .resource(resource, annotations, metadata):
            if let text = resource.text {
                .resource(
                    resource: .text(
                        transform(text),
                        uri: transform(resource.uri),
                        mimeType: resource.mimeType,
                        _meta: projectMetadata(resource._meta)),
                    annotations: annotations,
                    _meta: projectMetadata(metadata))
            } else if let blob = resource.blob, let data = Data(base64Encoded: blob) {
                .resource(
                    resource: .binary(
                        data,
                        uri: transform(resource.uri),
                        mimeType: resource.mimeType,
                        _meta: projectMetadata(resource._meta)),
                    annotations: annotations,
                    _meta: projectMetadata(metadata))
            } else {
                .resource(
                    resource: .binary(
                        Data(),
                        uri: transform(resource.uri),
                        mimeType: resource.mimeType,
                        _meta: projectMetadata(resource._meta)),
                    annotations: annotations,
                    _meta: projectMetadata(metadata))
            }
        case let .resourceLink(uri, name, title, description, mimeType, annotations):
            .resourceLink(
                uri: transform(uri),
                name: transform(name),
                title: title.map(transform),
                description: description.map(transform),
                mimeType: mimeType.map(transform),
                annotations: annotations)
        }
    }

    static func projectingContent(
        _ content: [Tool.Content],
        projection: ContentProjection) -> [Tool.Content]
    {
        func projectMetadataString(_ value: String) -> String {
            var projected = self.replacingPageIDs(in: value, mappings: projection.provider.pageMappings)
            projected = self.replacingUploadResponse(in: projected, calls: projection.provider.calls)
            if projection.responseProjection == .thirdPartySnapshot {
                projected = self.replacingThirdPartyResultUIDs(
                    in: projected,
                    mappings: projection.thirdPartyElementMappings,
                    rawStructuredMessage: projection.provider.thirdPartyMessage?.raw,
                    projectedStructuredMessage: projection.provider.thirdPartyMessage?.projected)
            }
            projected = self.replacingElementUIDs(
                in: projected,
                mappings: projection.provider.structuralElementMappings)
            projected = self.replacingIssueResourceUIDs(
                in: projected,
                mappings: projection.provider.issueElementMappings)
            return self.replacingElementUIDPhrases(
                in: projected,
                mappings: projection.provider.phraseElementMappings)
        }

        return content.map { item in
            guard case let .text(text, annotations, metadata) = item else {
                return self.projectingContentItem(
                    item,
                    transform: projectMetadataString,
                    projectAllMetadata: false)
            }
            var projected = self.replacingPageIDs(in: text, mappings: projection.provider.pageMappings)
            projected = self.replacingUploadResponse(in: projected, calls: projection.provider.calls)
            if projection.mayContainSnapshot {
                if projection.responseProjection == .thirdPartySnapshot {
                    projected = self.replacingThirdPartyResultUIDs(
                        in: projected,
                        mappings: projection.thirdPartyElementMappings,
                        rawStructuredMessage: projection.provider.thirdPartyMessage?.raw,
                        projectedStructuredMessage: projection.provider.thirdPartyMessage?.projected)
                    projected = self.replacingElementUIDsInThirdPartySnapshot(
                        in: projected,
                        mappings: projection.provider.structuralElementMappings)
                } else {
                    projected = self.replacingElementUIDs(
                        in: projected,
                        mappings: projection.provider.structuralElementMappings)
                }
            }
            projected = self.replacingIssueResourceUIDs(
                in: projected,
                mappings: projection.provider.issueElementMappings)
            projected = self.replacingElementUIDPhrases(
                in: projected,
                mappings: projection.provider.phraseElementMappings)
            return .text(
                text: projected,
                annotations: annotations,
                _meta: self.projectingProviderMetadata(metadata, transform: projectMetadataString))
        }
    }

    private static func thirdPartyJSONRange(in text: String) -> Range<String.Index>? {
        let upperBound = text.range(of: self.thirdPartySnapshotMarker)?.lowerBound ?? text.endIndex
        var candidate = text.startIndex
        while candidate < upperBound {
            let lineEnd = text[candidate..<upperBound].firstIndex(of: "\n") ?? upperBound
            let first = text[candidate..<lineEnd].firstIndex(where: { !$0.isWhitespace })
            if let first, text[first] == "{" || text[first] == "[",
               let end = self.balancedJSONEnd(in: text, from: first, limit: upperBound)
            {
                let range = first..<end
                if let data = String(text[range]).data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil
                {
                    return range
                }
            }
            guard lineEnd < upperBound else { break }
            candidate = text.index(after: lineEnd)
        }
        return nil
    }

    private static func balancedJSONEnd(
        in text: String,
        from start: String.Index,
        limit: String.Index) -> String.Index?
    {
        var stack: [Character] = []
        var index = start
        var inString = false
        var escaping = false
        while index < limit {
            let character = text[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{", "[":
                    stack.append(character)
                case "}":
                    guard stack.popLast() == "{" else { return nil }
                case "]":
                    guard stack.popLast() == "[" else { return nil }
                default:
                    break
                }
                if stack.isEmpty {
                    return text.index(after: index)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func replacingStrings(
        in value: Value,
        transform: (String) -> String) -> Value
    {
        switch value {
        case let .object(fields):
            .object(fields.mapValues { self.replacingStrings(in: $0, transform: transform) })
        case let .array(values):
            .array(values.map { self.replacingStrings(in: $0, transform: transform) })
        case let .string(string):
            .string(transform(string))
        case .int, .double, .bool, .null, .data:
            value
        }
    }

    private static func projectingProviderFields(
        in value: Value,
        transform: (String) -> String) -> Value
    {
        let messageKeys = Set(["message", "provider_message", "provider_diagnostic", "error", "hint"])
        switch value {
        case let .object(fields):
            var projected: [String: Value] = [:]
            for (key, child) in fields {
                projected[key] = messageKeys.contains(key)
                    ? self.replacingStrings(in: child, transform: transform)
                    : self.projectingProviderFields(in: child, transform: transform)
            }
            return .object(projected)
        case let .array(values):
            return .array(values.map { self.projectingProviderFields(in: $0, transform: transform) })
        case .string, .int, .double, .bool, .null, .data:
            return value
        }
    }

    private static func projectingIssueResourceFields(
        in value: Value,
        mappings: [String: String]) -> Value
    {
        guard !mappings.isEmpty else { return value }
        switch value {
        case let .object(fields):
            var projected: [String: Value] = [:]
            for (key, child) in fields {
                if key == "affectedResources", case let .array(resources) = child {
                    projected[key] = .array(resources.map { resource in
                        guard case var .object(resourceFields) = resource,
                              let providerUID = resourceFields["uid"]?.stringValue,
                              let reference = mappings[providerUID]
                        else { return self.projectingIssueResourceFields(in: resource, mappings: mappings) }
                        resourceFields["uid"] = .string(reference)
                        return .object(resourceFields)
                    })
                } else {
                    projected[key] = self.projectingIssueResourceFields(in: child, mappings: mappings)
                }
            }
            return .object(projected)
        case let .array(values):
            return .array(values.map { self.projectingIssueResourceFields(in: $0, mappings: mappings) })
        case .string, .int, .double, .bool, .null, .data:
            return value
        }
    }
}
