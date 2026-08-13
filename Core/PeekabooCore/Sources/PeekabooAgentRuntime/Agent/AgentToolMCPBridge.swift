import Foundation
import ImageIO
import MCP
import PeekabooAutomation
import Tachikoma
import TachikomaMCP
import UniformTypeIdentifiers

// MARK: - Type Conversion Extensions

extension ToolArguments {
    /// Initialize from AgentToolArguments.
    init(from arguments: AgentToolArguments) {
        var dict: [String: Any] = [:]
        for key in arguments.keys {
            guard let value = arguments[key], let json = try? value.toJSON() else { continue }
            dict[key] = json
        }
        self.init(raw: dict)
    }

    /// Initialize from dictionary.
    init(from dict: [String: Any]) {
        self.init(raw: dict)
    }
}

// MARK: - MCP response bridge

struct AgentToolMCPBridgeResult: Sendable {
    let value: AnyAgentToolValue
    let images: [ModelMessage.ContentPart.ImageContent]
    let failure: AgentToolExecutionFailure?

    func executionValue() throws -> AnyAgentToolValue {
        if let failure {
            throw failure
        }
        return self.value
    }
}

enum AgentToolMCPBridge {
    static let incompleteVisualEvidenceMarker =
        "Peekaboo evidence status: screenshot unavailable and accessibility incomplete."

    static let maxImageDimension = 1600
    static let maxImageBytes = 4 * 1024 * 1024
    static let maxImagesPerResponse = 1
    static let maxSourceDimension = 16384
    static let maxSourceFrameCount = 32
    static let maxSourcePixelCount = 64 * 1024 * 1024
    static let maxSourceTotalPixelCount = 128 * 1024 * 1024

    private static let maxErrorContentItems = 64
    private static let maxSourceImageBytes = 24 * 1024 * 1024
    private static let maxTextBytes = 100_000
    private static let maxStructuredDepth = 8
    private static let maxStructuredInputItems = 1024
    private static let maxStructuredItems = 128
    private static let maxStructuredKeyBytes = 256
    private static let maxStructuredNodes = 2048
    private static let maxStructuredTextBytes = 200_000

    static func convert(
        _ response: ToolResponse,
        allowsModelImages: Bool = true,
        imageOmissionReason: String? = nil) -> AgentToolMCPBridgeResult
    {
        if response.isError {
            return self.convertErrorResponse(response)
        }

        var preparedImages: [Int: ModelMessage.ContentPart.ImageContent] = [:]
        if allowsModelImages {
            for (index, content) in response.content.enumerated() {
                guard preparedImages.count < Self.maxImagesPerResponse else { break }
                guard case let .image(data, mimeType, _, _) = content,
                      let image = Self.makeModelImage(data: data, mimeType: mimeType)
                else {
                    continue
                }
                preparedImages[index] = image
            }
        }

        var values: [AnyAgentToolValue] = []
        var images: [ModelMessage.ContentPart.ImageContent] = []
        let hasInlineImage = response.content.contains { content in
            if case .image = content {
                return true
            }
            return false
        }
        let screenshotAttachmentDescription = if !allowsModelImages {
            imageOmissionReason ?? "not delivered to this text-only model; do not infer visual state from this result"
        } else if preparedImages.isEmpty {
            "inline image unavailable"
        } else {
            "inline image attached"
        }

        for (index, content) in response.content.enumerated() {
            switch content {
            case .image:
                guard let image = preparedImages[index] else {
                    let reason = if !allowsModelImages {
                        imageOmissionReason ?? "agent model does not accept images"
                    } else if images.count >= Self.maxImagesPerResponse {
                        "per-response image limit reached"
                    } else {
                        "invalid or oversized inline data"
                    }
                    values.append(Self.omittedContent(type: "image", reason: reason))
                    continue
                }
                guard images.count < Self.maxImagesPerResponse else {
                    values.append(Self.omittedContent(type: "image", reason: "per-response image limit reached"))
                    continue
                }
                images.append(image)
            default:
                values.append(Self.convertNonImageContent(
                    content,
                    screenshotAttachmentDescription: hasInlineImage ? screenshotAttachmentDescription : nil,
                    hasUndeliveredImage: hasInlineImage && preparedImages.isEmpty))
            }
        }

        let value: AnyAgentToolValue = switch values.count {
        case 0:
            AnyAgentToolValue(string: images.isEmpty ? "Success" : "Image attached.")
        case 1:
            values[0]
        default:
            AnyAgentToolValue(array: values)
        }
        let valueWithReceipt = Self.attachingVerificationReceipt(from: response, to: value)
        return AgentToolMCPBridgeResult(
            value: Self.attachingResponseMetadata(
                from: response,
                contentValue: value,
                receiptValue: valueWithReceipt),
            images: images,
            failure: nil)
    }

    private static func convertErrorResponse(_ response: ToolResponse) -> AgentToolMCPBridgeResult {
        var content = response.content.prefix(Self.maxErrorContentItems).map { item in
            switch item {
            case .image:
                Self.omittedContent(type: "image", reason: "error response image omitted from transcript")
            default:
                Self.convertNonImageContent(
                    item,
                    screenshotAttachmentDescription: nil,
                    hasUndeliveredImage: false)
            }
        }
        if response.content.count > Self.maxErrorContentItems {
            content.append(Self.omittedContent(
                type: "content",
                reason: "error response item limit reached; " +
                    "\(response.content.count - Self.maxErrorContentItems) item(s) omitted"))
        }

        let message = Self.errorMessage(from: response.content.prefix(Self.maxErrorContentItems))
        let metadataFields = MCPToolResponseMetadataProjector.agentFields(from: response.meta)
        let metadata = metadataFields.isEmpty
            ? nil
            : Self.agentValue(.object(metadataFields))
        let structuredValue = response.structuredContent.map(Self.agentValue)
        var payload: [String: AnyAgentToolValue] = [
            "error": AnyAgentToolValue(string: message),
            "success": AnyAgentToolValue(bool: false),
        ]
        for (key, value) in metadata?.objectValue ?? [:] {
            payload[key] = value
        }
        return AgentToolMCPBridgeResult(
            value: AnyAgentToolValue(object: payload),
            images: [],
            failure: AgentToolExecutionFailure(
                message: message,
                content: content,
                structuredValue: structuredValue,
                metadata: metadata))
    }

    private static func attachingResponseMetadata(
        from response: ToolResponse,
        contentValue: AnyAgentToolValue,
        receiptValue: AnyAgentToolValue) -> AnyAgentToolValue
    {
        guard let metadata = response.meta else { return receiptValue }

        var payload: [String: AnyAgentToolValue] = [
            "result": contentValue,
            "meta": TypedValueBridge.anyAgentValue(from: metadata),
        ]
        for (key, value) in MCPToolResponseMetadataProjector.agentFields(from: response.meta) {
            payload[key] = TypedValueBridge.anyAgentValue(from: value)
        }
        if let text = contentValue.stringValue {
            payload["text"] = AnyAgentToolValue(string: text)
        }
        if let receipt = receiptValue.objectValue?["verification_receipt"] {
            payload["content"] = contentValue
            payload["verification_receipt"] = receipt
        }
        return AnyAgentToolValue(object: payload)
    }

    private static func convertNonImageContent(
        _ content: MCP.Tool.Content,
        screenshotAttachmentDescription: String?,
        hasUndeliveredImage: Bool) -> AnyAgentToolValue
    {
        switch content {
        case let .text(text, _, _):
            var safeText = screenshotAttachmentDescription.map {
                Self.redactScreenshotPath(in: text, attachmentDescription: $0)
            } ?? text
            if hasUndeliveredImage, Self.hasIncompleteAccessibilityEvidence(safeText) {
                safeText += "\n\(Self.incompleteVisualEvidenceMarker) Missing text or elements do not prove " +
                    "absence. Use verify_state for an exact native postcondition or report the state as unverified."
            }
            return AnyAgentToolValue(string: Self.boundedText(safeText))
        case let .resource(resource, _, _):
            var object: [String: AnyAgentToolValue] = [
                "type": AnyAgentToolValue(string: "resource"),
                "uri": AnyAgentToolValue(string: Self.safeResourceURI(resource.uri)),
            ]
            if let mimeType = resource.mimeType {
                object["mime_type"] = AnyAgentToolValue(string: Self.boundedText(mimeType))
            }
            if let text = resource.text {
                object["text"] = AnyAgentToolValue(string: Self.boundedText(text))
            }
            if let blob = resource.blob {
                object["blob_omitted"] = AnyAgentToolValue(bool: true)
                object["encoded_byte_count"] = AnyAgentToolValue(int: blob.utf8.count)
            }
            return AnyAgentToolValue(object: object)
        case let .resourceLink(uri, name, title, description, mimeType, _):
            var object: [String: AnyAgentToolValue] = [
                "type": AnyAgentToolValue(string: "resource_link"),
                "uri": AnyAgentToolValue(string: Self.safeResourceURI(uri)),
                "name": AnyAgentToolValue(string: Self.boundedText(name)),
            ]
            if let title {
                object["title"] = AnyAgentToolValue(string: Self.boundedText(title))
            }
            if let description {
                object["description"] = AnyAgentToolValue(string: Self.boundedText(description))
            }
            if let mimeType {
                object["mime_type"] = AnyAgentToolValue(string: Self.boundedText(mimeType))
            }
            return AnyAgentToolValue(object: object)
        case let .audio(data, mimeType, _, _):
            return AnyAgentToolValue(object: [
                "type": AnyAgentToolValue(string: "audio"),
                "mime_type": AnyAgentToolValue(string: Self.boundedText(mimeType)),
                "data_omitted": AnyAgentToolValue(bool: true),
                "encoded_byte_count": AnyAgentToolValue(int: data.utf8.count),
            ])
        case .image:
            preconditionFailure("Image content is handled separately")
        }
    }

    private static func hasIncompleteAccessibilityEvidence(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("warning: ax tree incomplete") ||
            normalized.contains("warning: ax tree truncated")
    }

    private static func errorText(_ content: MCP.Tool.Content) -> String? {
        switch content {
        case let .text(text, _, _):
            text
        case let .resource(resource, _, _) where resource.text != nil:
            resource.text
        default:
            nil
        }
    }

    private static func errorMessage(from content: ArraySlice<MCP.Tool.Content>) -> String {
        var message = ""
        var foundMessage = false
        var remainingBytes = Self.maxTextBytes
        var truncated = false

        for item in content {
            guard let text = Self.errorText(item), !text.isEmpty else { continue }
            if foundMessage {
                guard remainingBytes > 0 else {
                    truncated = true
                    break
                }
                message.append("\n")
                remainingBytes -= 1
            }
            foundMessage = true

            let textBytes = text.utf8.count
            guard textBytes > remainingBytes else {
                message.append(text)
                remainingBytes -= textBytes
                continue
            }
            message.append(Self.utf8Prefix(text, maximumBytes: remainingBytes))
            truncated = true
            break
        }

        guard foundMessage else { return "Tool execution failed" }
        if truncated {
            message += "\n[Content truncated by Peekaboo agent safety limit]"
        }
        return message
    }

    private static func makeModelImage(
        data encodedData: String,
        mimeType: String) -> ModelMessage.ContentPart.ImageContent?
    {
        let normalizedMIMEType = mimeType.lowercased()
        let supportedMIMETypes = ["image/png", "image/jpeg", "image/gif", "image/webp"]
        guard supportedMIMETypes.contains(normalizedMIMEType) else { return nil }

        let maxEncodedBytes = ((Self.maxSourceImageBytes + 2) / 3) * 4
        guard encodedData.utf8.count <= maxEncodedBytes,
              let sourceData = Data(base64Encoded: encodedData),
              sourceData.count <= Self.maxSourceImageBytes,
              !sourceData.isEmpty,
              let source = CGImageSourceCreateWithData(
                  sourceData as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source),
              let detectedMIMEType = UTType(sourceType as String)?.preferredMIMEType?.lowercased(),
              supportedMIMETypes.contains(detectedMIMEType),
              let firstFrame = Self.validatedSourceFrames(source)
        else {
            return nil
        }

        if max(firstFrame.width, firstFrame.height) <= Self.maxImageDimension,
           sourceData.count <= Self.maxImageBytes
        {
            return ModelMessage.ContentPart.ImageContent(data: encodedData, mimeType: detectedMIMEType)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxImageDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let outputData = output as Data
        guard outputData.count <= Self.maxImageBytes else { return nil }
        return ModelMessage.ContentPart.ImageContent(
            data: outputData.base64EncodedString(),
            mimeType: "image/jpeg")
    }

    private static func validatedSourceFrames(_ source: CGImageSource) -> (width: Int, height: Int)? {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= Self.maxSourceFrameCount else { return nil }

        var dimensions: [(width: UInt64, height: UInt64)] = []
        dimensions.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value
            else {
                return nil
            }
            dimensions.append((width: width, height: height))
        }

        guard Self.sourceFrameDimensionsAreSafe(dimensions), let first = dimensions.first else { return nil }
        return (width: Int(first.width), height: Int(first.height))
    }

    static func sourceFrameDimensionsAreSafe(
        _ dimensions: [(width: UInt64, height: UInt64)]) -> Bool
    {
        guard !dimensions.isEmpty, dimensions.count <= self.maxSourceFrameCount else { return false }
        var totalPixels: UInt64 = 0

        for frame in dimensions {
            guard frame.width > 0,
                  frame.height > 0,
                  frame.width <= UInt64(Self.maxSourceDimension),
                  frame.height <= UInt64(Self.maxSourceDimension)
            else {
                return false
            }
            let (pixels, pixelOverflow) = frame.width.multipliedReportingOverflow(by: frame.height)
            guard !pixelOverflow, pixels <= UInt64(Self.maxSourcePixelCount) else { return false }
            let (updatedTotal, totalOverflow) = totalPixels.addingReportingOverflow(pixels)
            guard !totalOverflow, updatedTotal <= UInt64(Self.maxSourceTotalPixelCount) else { return false }
            totalPixels = updatedTotal
        }

        return true
    }

    private static func boundedText(_ text: String) -> String {
        guard text.utf8.count > self.maxTextBytes else { return text }
        return self.utf8Prefix(text, maximumBytes: self.maxTextBytes) +
            "\n[Content truncated by Peekaboo agent safety limit]"
    }

    private static func redactScreenshotPath(in text: String, attachmentDescription: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                line.hasPrefix("Screenshot: ") ? "Screenshot: \(attachmentDescription)" : line
            }
            .joined(separator: "\n")
    }

    private static func safeResourceURI(_ value: String) -> String {
        guard var components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else {
            return "<resource>"
        }
        guard scheme == "http" || scheme == "https" else {
            return scheme == "file" ? "<local resource>" : "\(scheme):<resource>"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string.map(Self.boundedText) ?? "<resource>"
    }

    private static func omittedContent(type: String, reason: String) -> AnyAgentToolValue {
        AnyAgentToolValue(object: [
            "type": AnyAgentToolValue(string: type),
            "attached": AnyAgentToolValue(bool: false),
            "reason": AnyAgentToolValue(string: reason),
        ])
    }

    private static func attachingVerificationReceipt(
        from response: ToolResponse,
        to value: AnyAgentToolValue) -> AnyAgentToolValue
    {
        guard case let .object(metadata)? = response.meta,
              let status = metadata["status"]?.stringValue,
              ["satisfied", "unsatisfied", "unknown"].contains(status),
              case let .array(predicates)? = metadata["predicates"]
        else {
            return value
        }

        var receipt: [String: AnyAgentToolValue] = [
            "status": AnyAgentToolValue(string: status),
            "predicates": AnyAgentToolValue(array: predicates.map(Self.agentValue)),
        ]
        if let target = metadata["target"] {
            receipt["target"] = Self.agentValue(target)
        }
        for key in ["application", "reason"] {
            if let string = metadata[key]?.stringValue {
                receipt[key] = AnyAgentToolValue(string: string)
            }
        }
        for key in ["pid", "window_id", "sample_count", "stable_samples", "required_stable_samples"] {
            if let int = metadata[key]?.intValue {
                receipt[key] = AnyAgentToolValue(int: int)
            }
        }
        return AnyAgentToolValue(object: [
            "content": value,
            "verification_receipt": AnyAgentToolValue(object: receipt),
        ])
    }

    private struct StructuredValueBudget {
        var remainingNodes = AgentToolMCPBridge.maxStructuredNodes
        var remainingTextBytes = AgentToolMCPBridge.maxStructuredTextBytes
    }

    private static func agentValue(_ value: Value) -> AnyAgentToolValue {
        var budget = StructuredValueBudget()
        return self.agentValue(value, depth: 0, budget: &budget)
    }

    private static func agentValue(
        _ value: Value,
        depth: Int,
        budget: inout StructuredValueBudget) -> AnyAgentToolValue
    {
        guard budget.remainingNodes > 0 else {
            return AnyAgentToolValue(string: "<omitted-node-budget>")
        }
        budget.remainingNodes -= 1
        guard depth <= self.maxStructuredDepth else {
            return AnyAgentToolValue(string: "<omitted-depth>")
        }

        switch value {
        case .null:
            return AnyAgentToolValue(null: ())
        case let .bool(value):
            return AnyAgentToolValue(bool: value)
        case let .int(value):
            return AnyAgentToolValue(int: value)
        case let .double(value):
            return value.isFinite
                ? AnyAgentToolValue(double: value)
                : AnyAgentToolValue(string: "<omitted-non-finite-number>")
        case let .string(value):
            return AnyAgentToolValue(string: Self.boundedStructuredText(value, budget: &budget))
        case let .data(mimeType, data):
            return AnyAgentToolValue(object: [
                "data_omitted": AnyAgentToolValue(bool: true),
                "mime_type": AnyAgentToolValue(string: Self.boundedStructuredText(
                    mimeType ?? "application/octet-stream",
                    budget: &budget)),
                "byte_count": AnyAgentToolValue(int: data.count),
            ])
        case let .array(values):
            var converted = values.prefix(Self.maxStructuredItems).map {
                Self.agentValue($0, depth: depth + 1, budget: &budget)
            }
            if values.count > Self.maxStructuredItems {
                converted.append(AnyAgentToolValue(object: [
                    "items_omitted": AnyAgentToolValue(int: values.count - Self.maxStructuredItems),
                ]))
            }
            return AnyAgentToolValue(array: converted)
        case let .object(values):
            guard values.count <= Self.maxStructuredInputItems else {
                return AnyAgentToolValue(object: [
                    "__peekaboo_omission_reason": AnyAgentToolValue(string: "object_field_limit"),
                    "__peekaboo_omitted_fields": AnyAgentToolValue(int: values.count),
                ])
            }
            var converted: [String: AnyAgentToolValue] = [:]
            for (key, item) in Self.boundedSortedEntries(values) {
                converted[key] = Self.agentValue(
                    item,
                    depth: depth + 1,
                    budget: &budget)
            }
            if values.count > converted.count {
                converted["__peekaboo_omitted_fields"] = AnyAgentToolValue(
                    int: values.count - converted.count)
            }
            return AnyAgentToolValue(object: converted)
        }
    }

    private static func boundedSortedEntries(
        _ values: [String: Value]) -> [(String, Value)]
    {
        var candidates: [String: Value] = [:]
        var collisions: Set<String> = []
        candidates.reserveCapacity(min(values.count, Self.maxStructuredItems))
        for (key, value) in values {
            let boundedKey = Self.utf8Prefix(key, maximumBytes: Self.maxStructuredKeyBytes)
            if candidates.removeValue(forKey: boundedKey) != nil || collisions.contains(boundedKey) {
                collisions.insert(boundedKey)
            } else {
                candidates[boundedKey] = value
            }
        }
        return candidates.keys.sorted().prefix(Self.maxStructuredItems).compactMap { key in
            candidates[key].map { (key, $0) }
        }
    }

    private static func boundedStructuredText(
        _ value: String,
        budget: inout StructuredValueBudget) -> String
    {
        guard budget.remainingTextBytes > 0 else {
            return "<omitted-text-budget>"
        }
        let byteCount = value.utf8.prefix(budget.remainingTextBytes + 1).count
        guard byteCount > budget.remainingTextBytes else {
            budget.remainingTextBytes -= byteCount
            return value
        }
        let retained = Self.utf8Prefix(value, maximumBytes: budget.remainingTextBytes)
        budget.remainingTextBytes = 0
        return retained + "\n[Content truncated by Peekaboo agent safety limit]"
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        var bytes = Array(value.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) {
                return value
            }
            bytes.removeLast()
        }
        return ""
    }
}

actor AgentToolMCPImageStore {
    enum Admission: Equatable, Sendable {
        case admitted
        case rejected(RejectionReason)
    }

    enum RejectionReason: Equatable, Sendable {
        case executionNotActive
        case capacityReached
        case duplicateKey
        case emptyImages

        var omissionReason: String {
            switch self {
            case .executionNotActive:
                "image execution is not active or already closed; image omitted from model context"
            case .capacityReached:
                "transient image capacity reached; image omitted from model context"
            case .duplicateKey:
                "image result is already pending for this tool call; duplicate image omitted"
            case .emptyImages:
                "image result contained no deliverable image data"
            }
        }
    }

    struct Key: Hashable, Sendable {
        let sessionID: String
        let executionID: String
        let stepIndex: Int
        let toolCallID: String
    }

    static let defaultMaximumEntries = 8
    static let shared = AgentToolMCPImageStore()
    private struct Entry {
        let images: [ModelMessage.ContentPart.ImageContent]
    }

    private var entries: [Key: Entry] = [:]
    private var activeExecutionIDs: Set<String> = []
    private let maximumEntries: Int

    init(maximumEntries: Int = defaultMaximumEntries) {
        self.maximumEntries = max(0, maximumEntries)
    }

    /// Execution IDs are UUID-unique in production. Registering an already-active ID is rejected; a closed ID may
    /// be registered again only by explicit test code, and never by a late result because store cannot register.
    func register(executionID: String) -> Bool {
        self.activeExecutionIDs.insert(executionID).inserted
    }

    func isActive(executionID: String) -> Bool {
        self.activeExecutionIDs.contains(executionID)
    }

    func store(_ images: [ModelMessage.ContentPart.ImageContent], for key: Key) -> Admission {
        guard self.activeExecutionIDs.contains(key.executionID) else {
            return .rejected(.executionNotActive)
        }
        guard !images.isEmpty else {
            return .rejected(.emptyImages)
        }
        guard self.entries[key] == nil else {
            return .rejected(.duplicateKey)
        }
        guard self.entries.count < self.maximumEntries else {
            return .rejected(.capacityReached)
        }
        self.entries[key] = Entry(images: images)
        return .admitted
    }

    func take(for key: Key) -> [ModelMessage.ContentPart.ImageContent] {
        self.entries.removeValue(forKey: key)?.images ?? []
    }

    /// Atomically tombstones this execution for future stores and removes every pending entry it owns.
    /// No tombstone set is retained: removing the active UUID is sufficient because production never reuses it.
    func close(executionID: String) {
        self.activeExecutionIDs.remove(executionID)
        let keys = self.entries.keys.filter { $0.executionID == executionID }
        for key in keys {
            self.entries.removeValue(forKey: key)
        }
    }
}

@available(macOS 14.0, *)
extension PeekabooAgentService {
    func appendAgentToolImageContext(
        toolCalls: [AgentToolCall],
        context: ToolHandlingContext,
        stepIndex: Int,
        imageStore: AgentToolMCPImageStore = .shared,
        to messages: inout [ModelMessage]) async
    {
        var delivered: [(call: AgentToolCall, images: [ModelMessage.ContentPart.ImageContent])] = []
        for call in toolCalls {
            let key = AgentToolMCPImageStore.Key(
                sessionID: context.sessionId,
                executionID: context.imageContextID,
                stepIndex: stepIndex,
                toolCallID: call.id)
            let storedImages = await imageStore.take(for: key)
            if !storedImages.isEmpty {
                delivered.append((call: call, images: storedImages))
            }
        }

        guard context.supportsVision, !delivered.isEmpty else { return }
        messages.removeConsumedAgentToolImageContext()
        var content: [ModelMessage.ContentPart] = []
        for item in delivered {
            for (index, image) in item.images.enumerated() {
                content.append(.text(
                    "Visual output from Peekaboo tool '\(item.call.name)' " +
                        "(call ID \(item.call.id)), image \(index + 1) of \(item.images.count)."))
                content.append(.image(image))
            }
        }
        messages.append(ModelMessage(
            role: .user,
            content: content,
            metadata: MessageMetadata(customData: [
                "peekaboo.agent.transient_tool_images": "true",
            ])))
    }
}

extension [ModelMessage] {
    func removingConsumedAgentToolImageContext() -> [ModelMessage] {
        self.filter { message in
            message.metadata?.customData?["peekaboo.agent.transient_tool_images"] != "true"
        }
    }

    mutating func removeConsumedAgentToolImageContext() {
        self = self.removingConsumedAgentToolImageContext()
    }
}

// MARK: - Compatibility entry points

@preconcurrency
func convertToolResponseToAgentToolResult(_ response: ToolResponse) -> AnyAgentToolValue {
    AgentToolMCPBridge.convert(response).value
}

@preconcurrency
func convertToolResponseToAgentToolResultAsync(_ response: ToolResponse) async -> AnyAgentToolValue {
    AgentToolMCPBridge.convert(response).value
}

@preconcurrency
func convertToolResponseToAgentToolResultAsync(
    _ response: ToolResponse,
    executionContext: ToolExecutionContext,
    imageStore: AgentToolMCPImageStore = .shared) async -> AnyAgentToolValue
{
    let result = await prepareToolResponseForAgentExecution(
        response,
        executionContext: executionContext,
        imageStore: imageStore)
    return result.value
}

func convertToolResponseToAgentToolExecutionValueAsync(
    _ response: ToolResponse,
    executionContext: ToolExecutionContext,
    imageStore: AgentToolMCPImageStore = .shared) async throws -> AnyAgentToolValue
{
    let result = await prepareToolResponseForAgentExecution(
        response,
        executionContext: executionContext,
        imageStore: imageStore)
    return try result.executionValue()
}

private func prepareToolResponseForAgentExecution(
    _ response: ToolResponse,
    executionContext: ToolExecutionContext,
    imageStore: AgentToolMCPImageStore) async -> AgentToolMCPBridgeResult
{
    let toolCallID = executionContext.metadata["toolCallId"]
    let executionID = executionContext.metadata["imageContextId"]
    let allowsModelImages = executionContext.metadata["supportsVision"] != "false" &&
        toolCallID != nil && executionID != nil
    let result = AgentToolMCPBridge.convert(response, allowsModelImages: allowsModelImages)
    if let toolCallID,
       let executionID,
       !result.images.isEmpty
    {
        let key = AgentToolMCPImageStore.Key(
            sessionID: executionContext.sessionId,
            executionID: executionID,
            stepIndex: executionContext.stepIndex,
            toolCallID: toolCallID)
        let admission = await imageStore.store(result.images, for: key)
        guard case .admitted = admission else {
            let reason: String = if case let .rejected(rejection) = admission {
                rejection.omissionReason
            } else {
                "image omitted from model context"
            }
            return AgentToolMCPBridge.convert(
                response,
                allowsModelImages: false,
                imageOmissionReason: reason)
        }
    }
    return result
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
