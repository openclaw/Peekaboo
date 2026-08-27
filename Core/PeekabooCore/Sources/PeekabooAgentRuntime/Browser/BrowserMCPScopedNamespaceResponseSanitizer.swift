import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// Final defense-in-depth boundary before a scoped browser result reaches Bridge serialization.
///
/// BrowserTool owns semantic page/element projection. This scrubber removes host-only connection fields everywhere in
/// the returned tree and fails closed if a provider capability field survived that projection.
enum BrowserMCPScopedNamespaceResponseSanitizer {
    private enum FieldDisposition {
        case keep
        case removeHostOnly
        case removeUnsafeCapability
    }

    private static let hostOnlyFields: Set<String> = [
        "browserid",
        "browserurl",
        "devtoolsbrowserid",
        "providersessionepoch",
        "websocketdebuggerurl",
    ]

    private static let unsafeCapabilityFields: Set<String> = [
        "cdpbrowserwindowid",
        "cdptargetid",
        "privatebrowserwindowid",
        "privatetargetid",
        "providerpageid",
        "provideruid",
        "targetid",
    ]

    static func result(
        _ response: ToolResponse,
        arguments: ToolArguments,
        policy: BrowserMCPScopedNamespaceExecutionPolicy) -> BrowserMCPScopedNamespaceExecutionResult
    {
        let externalBrowserConnectionReceipt = self.externalBrowserConnectionReceipt(from: response.meta)
        var foundUnsafeCapability = false
        let content = response.content.map {
            self.scrubContent($0, foundUnsafeCapability: &foundUnsafeCapability)
        }
        let meta = response.meta.flatMap {
            self.scrubValue($0, foundUnsafeCapability: &foundUnsafeCapability)
        }
        let structuredContent = response.structuredContent.flatMap {
            self.scrubValue($0, foundUnsafeCapability: &foundUnsafeCapability)
        }
        let scrubbed = ToolResponse(
            content: content,
            isError: response.isError,
            meta: meta,
            structuredContent: structuredContent)
        let nativeWindowReceipt = self.nativeWindowReceipt(
            from: scrubbed.meta,
            requestedPageReference: arguments.getString("page_id"))
        let targetIdentity = nativeWindowReceipt.flatMap(self.targetIdentity) ??
            self.processTargetIdentity(from: scrubbed.meta)

        let sanitized: ToolResponse = if foundUnsafeCapability {
            self.withheldResponse(
                arguments: arguments,
                policy: policy,
                originalMeta: scrubbed.meta)
        } else {
            scrubbed
        }
        let outcome = MCPToolResponseMetadataProjector
            .actionOutcomeResolution(from: sanitized.meta)
            .projection?.outcome
        return BrowserMCPScopedNamespaceExecutionResult(
            response: sanitized,
            targetIdentity: targetIdentity,
            externalBrowserConnectionReceipt: externalBrowserConnectionReceipt,
            outcome: outcome,
            nativeWindowReceipt: nativeWindowReceipt)
    }

    private static func scrubContent(
        _ content: Tool.Content,
        foundUnsafeCapability: inout Bool) -> Tool.Content
    {
        switch content {
        case let .text(text, annotations, metadata):
            return .text(
                text: self.scrubText(text, foundUnsafeCapability: &foundUnsafeCapability),
                annotations: annotations,
                _meta: self.scrubMetadata(metadata, foundUnsafeCapability: &foundUnsafeCapability))
        case let .image(data, mimeType, annotations, metadata):
            return .image(
                data: data,
                mimeType: mimeType,
                annotations: annotations,
                _meta: self.scrubMetadata(metadata, foundUnsafeCapability: &foundUnsafeCapability))
        case let .audio(data, mimeType, annotations, metadata):
            return .audio(
                data: data,
                mimeType: mimeType,
                annotations: annotations,
                _meta: self.scrubMetadata(metadata, foundUnsafeCapability: &foundUnsafeCapability))
        case let .resource(resource, annotations, metadata):
            let sanitizedMetadata = self.scrubMetadata(
                metadata,
                foundUnsafeCapability: &foundUnsafeCapability)
            let sanitizedResourceMetadata = self.scrubMetadata(
                resource._meta,
                foundUnsafeCapability: &foundUnsafeCapability)
            let uri = self.scrubText(resource.uri, foundUnsafeCapability: &foundUnsafeCapability)
            if let text = resource.text {
                return .resource(
                    resource: .text(
                        self.scrubText(text, foundUnsafeCapability: &foundUnsafeCapability),
                        uri: uri,
                        mimeType: resource.mimeType,
                        _meta: sanitizedResourceMetadata),
                    annotations: annotations,
                    _meta: sanitizedMetadata)
            }
            if let blob = resource.blob, let data = Data(base64Encoded: blob) {
                return .resource(
                    resource: .binary(
                        data,
                        uri: uri,
                        mimeType: resource.mimeType,
                        _meta: sanitizedResourceMetadata),
                    annotations: annotations,
                    _meta: sanitizedMetadata)
            }
            return .resource(
                resource: .binary(
                    Data(),
                    uri: uri,
                    mimeType: resource.mimeType,
                    _meta: sanitizedResourceMetadata),
                annotations: annotations,
                _meta: sanitizedMetadata)
        case let .resourceLink(uri, name, title, description, mimeType, annotations):
            return .resourceLink(
                uri: self.scrubText(uri, foundUnsafeCapability: &foundUnsafeCapability),
                name: self.scrubText(name, foundUnsafeCapability: &foundUnsafeCapability),
                title: title.map { self.scrubText($0, foundUnsafeCapability: &foundUnsafeCapability) },
                description: description.map {
                    self.scrubText($0, foundUnsafeCapability: &foundUnsafeCapability)
                },
                mimeType: mimeType,
                annotations: annotations)
        }
    }

    private static func scrubMetadata(
        _ metadata: Metadata?,
        foundUnsafeCapability: inout Bool) -> Metadata?
    {
        guard let metadata,
              case let .object(fields)? = self.scrubValue(
                  .object(metadata.fields),
                  foundUnsafeCapability: &foundUnsafeCapability)
        else { return nil }
        return fields.isEmpty ? nil : Metadata(additionalFields: fields)
    }

    private static func scrubValue(
        _ value: Value,
        path: [String] = [],
        foundUnsafeCapability: inout Bool) -> Value?
    {
        switch value {
        case let .object(fields):
            var result: [String: Value] = [:]
            result.reserveCapacity(fields.count)
            for (key, child) in fields {
                let normalizedKey = self.normalizedField(key)
                switch self.disposition(for: key, value: child, parentPath: path) {
                case .keep:
                    if let scrubbed = self.scrubValue(
                        child,
                        path: path + [normalizedKey],
                        foundUnsafeCapability: &foundUnsafeCapability)
                    {
                        result[key] = scrubbed
                    }
                case .removeHostOnly:
                    continue
                case .removeUnsafeCapability:
                    foundUnsafeCapability = true
                }
            }
            return .object(result)
        case let .array(values):
            if path.last == "browserpagerefs" {
                let references = values.compactMap { value -> Value? in
                    guard case let .string(reference) = value,
                          BrowserToolCapabilityReference.isValid(reference, prefix: "bp1")
                    else {
                        foundUnsafeCapability = true
                        return nil
                    }
                    return value
                }
                return .array(references)
            }
            return .array(values.compactMap {
                self.scrubValue($0, path: path, foundUnsafeCapability: &foundUnsafeCapability)
            })
        case let .string(string):
            return .string(self.scrubText(string, foundUnsafeCapability: &foundUnsafeCapability))
        case .int, .double, .bool, .null, .data:
            return value
        }
    }

    private static func disposition(
        for key: String,
        value: Value,
        parentPath: [String]) -> FieldDisposition
    {
        let normalized = self.normalizedField(key)
        if self.hostOnlyFields.contains(normalized) {
            return .removeHostOnly
        }
        if self.unsafeCapabilityFields.contains(normalized) {
            return .removeUnsafeCapability
        }
        if normalized == "pageid" || normalized == "pageref" {
            guard case let .string(reference) = value,
                  BrowserToolCapabilityReference.isValid(reference, prefix: "bp1")
            else { return .removeUnsafeCapability }
        }
        if normalized == "elementref" {
            guard case let .string(reference) = value,
                  BrowserToolCapabilityReference.isValid(reference, prefix: "be1")
            else { return .removeUnsafeCapability }
        }
        if normalized == "snapshotref" || normalized == "browsersnapshotref" {
            guard case let .string(reference) = value,
                  BrowserToolCapabilityReference.isValid(reference, prefix: "bs1")
            else { return .removeUnsafeCapability }
        }
        if normalized == "id",
           parentPath.last == "pages" || parentPath.last == "extensionpages"
        {
            guard case let .string(reference) = value,
                  BrowserToolCapabilityReference.isValid(reference, prefix: "bp1")
            else { return .removeUnsafeCapability }
        }
        if normalized == "id", parentPath.contains("snapshot") {
            guard case let .string(reference) = value,
                  BrowserToolCapabilityReference.isValid(reference, prefix: "be1")
            else { return .removeUnsafeCapability }
        }
        if normalized == "uid" || normalized == "touid" {
            guard case let .string(reference) = value else { return .keep }
            if BrowserToolCapabilityReference.isValid(reference, prefix: "be1") {
                return .keep
            }
            if self.isProviderUID(reference) {
                return .removeUnsafeCapability
            }
        }
        return .keep
    }

    private static func scrubText(
        _ text: String,
        foundUnsafeCapability: inout Bool) -> String
    {
        if let scrubbedJSON = self.scrubJSONText(
            text,
            foundUnsafeCapability: &foundUnsafeCapability)
        {
            return scrubbedJSON
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var sanitized: [Substring] = []
        sanitized.reserveCapacity(lines.count)
        let mayContainPageRows = text.contains("## Pages") || text.contains("## Extension Pages")
        for line in lines {
            let normalized = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if self.containsAssignment(
                in: normalized,
                names: [
                    "browser_id",
                    "browserid",
                    "browser_url",
                    "browserurl",
                    "devtools_browser_id",
                    "devtoolsbrowserid",
                    "provider_session_epoch",
                    "providersessionepoch",
                    "websocket_debugger_url",
                    "websocketdebuggerurl",
                ])
            {
                continue
            }
            if self.containsAssignment(
                in: normalized,
                names: [
                    "cdp_target_id",
                    "cdptargetid",
                    "private_target_id",
                    "privatetargetid",
                    "provider_page_id",
                    "providerpageid",
                    "provider_uid",
                    "provideruid",
                    "target_id",
                    "targetid",
                ])
            {
                foundUnsafeCapability = true
            }
            if self.containsRawProviderUID(in: normalized) ||
                mayContainPageRows && self.hasRawPageRowPrefix(normalized)
            {
                foundUnsafeCapability = true
            }
            sanitized.append(line)
        }
        return sanitized.map(String.init).joined(separator: "\n")
    }

    private static func containsRawProviderUID(in line: String) -> Bool {
        var searchStart = line.startIndex
        while searchStart < line.endIndex,
              let marker = line.range(of: "uid=", range: searchStart..<line.endIndex)
        {
            let value = line[marker.upperBound...].prefix { character in
                !character.isWhitespace && ![",", ";", "]", "}"].contains(character)
            }
            if self.isProviderUID(String(value)) {
                return true
            }
            searchStart = marker.upperBound
        }
        searchStart = line.startIndex
        while searchStart < line.endIndex,
              let marker = line.range(of: "\"uid\"", range: searchStart..<line.endIndex)
        {
            var valueStart = marker.upperBound
            while valueStart < line.endIndex, line[valueStart].isWhitespace {
                valueStart = line.index(after: valueStart)
            }
            guard valueStart < line.endIndex, line[valueStart] == ":" else {
                searchStart = marker.upperBound
                continue
            }
            valueStart = line.index(after: valueStart)
            while valueStart < line.endIndex, line[valueStart].isWhitespace {
                valueStart = line.index(after: valueStart)
            }
            if valueStart < line.endIndex, line[valueStart] == "\"" {
                valueStart = line.index(after: valueStart)
            }
            let value = line[valueStart...].prefix { character in
                !character.isWhitespace && !["\"", ",", ";", "]", "}"].contains(character)
            }
            if self.isProviderUID(String(value)) {
                return true
            }
            searchStart = marker.upperBound
        }
        return false
    }

    private static func scrubJSONText(
        _ text: String,
        foundUnsafeCapability: inout Bool) -> String?
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let scrubbed = self.scrubValue(
                  Value.from(object),
                  foundUnsafeCapability: &foundUnsafeCapability),
              let jsonObject = try? scrubbed.toAnyAgentToolValue().toJSON(),
              JSONSerialization.isValidJSONObject(jsonObject),
              let encoded = try? JSONSerialization.data(
                  withJSONObject: jsonObject,
                  options: [.sortedKeys])
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private static func containsAssignment(in text: String, names: [String]) -> Bool {
        names.contains { name in
            text.contains("\(name)=") ||
                text.contains("\(name):") ||
                text.contains("\(name) =") ||
                text.contains("\(name) :") ||
                text.contains("\"\(name)\"")
        }
    }

    private static func hasRawPageRowPrefix(_ line: String) -> Bool {
        let content = line.drop(while: \.isWhitespace)
        let digits = content.prefix { character in
            guard let ascii = character.asciiValue else { return false }
            return (48...57).contains(ascii)
        }
        return !digits.isEmpty && content.dropFirst(digits.count).hasPrefix(":")
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

    private static func normalizedField(_ field: String) -> String {
        field.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            let value = scalar.value
            guard (48...57).contains(value) || (97...122).contains(value) else { return }
            result.unicodeScalars.append(scalar)
        }
    }

    private static func withheldResponse(
        arguments: ToolArguments,
        policy: BrowserMCPScopedNamespaceExecutionPolicy,
        originalMeta: Value?) -> ToolResponse
    {
        let message = "Browser provider completed the request, but process-private identifiers were withheld."
        guard MCPToolSnapshotMutationPolicy.effect(toolName: "browser", arguments: arguments) != .none else {
            return ToolResponse.error(message)
        }

        let originalOutcome = MCPToolResponseMetadataProjector
            .actionOutcomeResolution(from: originalMeta)
            .projection?.outcome
        let foreground = policy == .explicitlyForegroundAllowed &&
            MCPToolExecutionPolicy.browserRequiresForegroundAuthority(arguments)
        let failure = DesktopActionFailure.indeterminate(
            route: originalOutcome?.route ?? .local,
            delivery: originalOutcome?.delivery ?? .init(
                mechanism: .browserProtocol,
                mode: foreground ? .foreground : .background),
            evidence: .completionUnknown,
            unitCount: originalOutcome?.dispatchState.unitCount,
            message: message,
            hint: "Observe the browser before retrying; do not reuse prior page or element references.")
        return (try? MCPToolResponseMetadataProjector.errorResponse(
            for: failure,
            invalidatedSnapshotID: nil)) ?? ToolResponse.error(message)
    }

    private static func nativeWindowReceipt(
        from meta: Value?,
        requestedPageReference: String?) -> BrowserMCPScopedNamespaceNativeWindowReceipt?
    {
        guard case let .object(fields)? = meta else { return nil }
        if let binding = fields["browser_window_binding"]?.objectValue,
           let pageReference = binding["page_id"]?.stringValue,
           let receipt = self.nativeWindowReceipt(from: binding, pageReference: pageReference)
        {
            return receipt
        }
        guard let pageReference = requestedPageReference,
              let execution = fields[BrowserMCPExecutionEvidence.metadataKey]?.objectValue,
              let native = execution["native_window_receipt"]?.objectValue
        else { return nil }
        return self.nativeWindowReceipt(from: native, pageReference: pageReference)
    }

    private static func nativeWindowReceipt(
        from fields: [String: Value],
        pageReference: String) -> BrowserMCPScopedNamespaceNativeWindowReceipt?
    {
        guard BrowserToolCapabilityReference.isValid(pageReference, prefix: "bp1"),
              let process = self.processReceipt(from: fields),
              let rawWindowID = fields["window_id"]?.intValue,
              let windowID = UInt32(exactly: rawWindowID),
              windowID > 0,
              let boundsFields = fields["bounds"]?.objectValue,
              let bounds = self.bounds(from: boundsFields),
              fields["quality"]?.stringValue == BrowserMCPScopedNamespaceNativeWindowReceipt.Quality.exact.rawValue
        else { return nil }
        return BrowserMCPScopedNamespaceNativeWindowReceipt(
            pageReference: pageReference,
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity,
            windowID: windowID,
            bounds: bounds,
            quality: .exact)
    }

    private static func targetIdentity(
        from receipt: BrowserMCPScopedNamespaceNativeWindowReceipt) -> DesktopTargetIdentity?
    {
        let identity = WindowMutationIdentity(
            windowID: Int(receipt.windowID),
            ownerProcessIdentifier: receipt.processIdentifier,
            ownerProcessStartIdentity: receipt.processStartIdentity,
            capturedBounds: receipt.bounds)
        guard let exactWindow = try? UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: receipt.bounds)
        else { return nil }
        return DesktopTargetIdentity(exactWindow: exactWindow)
    }

    private static func processTargetIdentity(from meta: Value?) -> DesktopTargetIdentity? {
        guard case let .object(fields)? = meta else { return nil }
        if let receipt = fields["connection_receipt"]?.objectValue,
           let identity = self.processIdentity(from: receipt)
        {
            return identity
        }
        if let execution = fields[BrowserMCPExecutionEvidence.metadataKey]?.objectValue,
           let receipt = execution["connection_receipt"]?.objectValue,
           let identity = self.processIdentity(from: receipt)
        {
            return identity
        }
        if let receipt = fields["target_receipt"]?.objectValue {
            return self.processIdentity(from: receipt)
        }
        return nil
    }

    /// Recovers only a complete exact external-browser receipt from Peekaboo-owned metadata before
    /// host-only endpoint fields are removed from the public namespace response.
    private static func externalBrowserConnectionReceipt(from meta: Value?) -> BrowserMCPConnectionReceipt? {
        guard case let .object(fields)? = meta else { return nil }
        let receiptFields = fields["connection_receipt"]?.objectValue ??
            fields[BrowserMCPExecutionEvidence.metadataKey]?.objectValue?["connection_receipt"]?.objectValue
        guard let receiptFields,
              receiptFields["pid"] == nil,
              receiptFields["process_start_identity"] == nil,
              receiptFields["process_start_identity_decimal"] == nil,
              receiptFields["bundle_id"] == nil,
              let browserURL = receiptFields["browser_url"]?.stringValue,
              let browserID = receiptFields["browser_id"]?.stringValue,
              !browserID.isEmpty,
              let browserVersion = receiptFields["browser_version"]?.stringValue,
              !browserVersion.isEmpty,
              let protocolVersion = receiptFields["protocol_version"]?.stringValue,
              !protocolVersion.isEmpty,
              let endpoint = BrowserLoopbackEndpoint(browserURL: browserURL),
              let webSocketDebuggerURL = self.externalBrowserWebSocketURL(
                  fields: receiptFields,
                  endpoint: endpoint,
                  browserID: browserID)
        else { return nil }
        let channel: BrowserMCPChannel?
        if let rawChannel = receiptFields["channel"]?.stringValue {
            guard let parsed = BrowserMCPChannel(rawValue: rawChannel) else { return nil }
            channel = parsed
        } else {
            channel = nil
        }
        return BrowserMCPConnectionReceipt(
            channel: channel,
            browserURL: endpoint.canonicalBrowserURL,
            webSocketDebuggerURL: webSocketDebuggerURL,
            devToolsBrowserID: browserID,
            browserVersion: browserVersion,
            protocolVersion: protocolVersion)
    }

    private static func externalBrowserWebSocketURL(
        fields: [String: Value],
        endpoint: BrowserLoopbackEndpoint,
        browserID: String) -> String?
    {
        if let published = fields["websocket_debugger_url"]?.stringValue,
           !endpoint.matchesWebSocketDebuggerURL(published, browserID: browserID)
        {
            return nil
        }
        guard var components = URLComponents(string: endpoint.canonicalBrowserURL) else { return nil }
        components.scheme = "ws"
        components.path = "/devtools/browser/\(browserID)"
        guard let synthesized = components.url?.absoluteString,
              endpoint.matchesWebSocketDebuggerURL(synthesized, browserID: browserID)
        else { return nil }
        return synthesized
    }

    private static func processIdentity(from fields: [String: Value]) -> DesktopTargetIdentity? {
        guard let process = self.processReceipt(from: fields) else { return nil }
        return try? DesktopTargetIdentity(processIdentity: process)
    }

    private static func processReceipt(from fields: [String: Value]) -> ApplicationProcessIdentity? {
        guard let rawPID = fields["pid"]?.intValue,
              let pid = Int32(exactly: rawPID),
              pid > 0,
              let generation = self.processGeneration(from: fields),
              generation > 0
        else { return nil }
        return ApplicationProcessIdentity(
            processIdentifier: pid,
            processStartIdentity: generation)
    }

    private static func processGeneration(from fields: [String: Value]) -> UInt64? {
        if let decimal = fields["process_start_identity_decimal"]?.stringValue {
            return UInt64(decimal)
        }
        guard let value = fields["process_start_identity"]?.intValue, value > 0 else { return nil }
        return UInt64(value)
    }

    private static func bounds(from fields: [String: Value]) -> CGRect? {
        guard let x = self.number(fields["x"]),
              let y = self.number(fields["y"]),
              let width = self.number(fields["width"]),
              let height = self.number(fields["height"]),
              x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func number(_ value: Value?) -> Double? {
        switch value {
        case let .double(number):
            number
        case let .int(number):
            Double(number)
        default:
            nil
        }
    }
}
