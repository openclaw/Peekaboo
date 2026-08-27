import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

private enum PeekabooBridgeBrowserCapabilityReference {
    static func isCanonicalPage(_ value: String) -> Bool {
        let prefix = "bp1_"
        guard value.hasPrefix(prefix) else { return false }
        let token = value.dropFirst(prefix.count)
        return token.count == 32 && token.allSatisfy { character in
            guard let ascii = character.asciiValue else { return false }
            return (48...57).contains(ascii) || (97...102).contains(ascii)
        }
    }
}

/// The authenticated local process identity that owns one browser capability namespace.
public struct PeekabooBridgeBrowserCapabilityPrincipal: Codable, Equatable, Sendable {
    public let effectiveUserIdentifier: UInt32
    public let teamIdentifier: String
    public let bundleIdentifier: String
    public let codeSignatureHash: String

    public init(
        effectiveUserIdentifier: UInt32,
        teamIdentifier: String,
        bundleIdentifier: String,
        codeSignatureHash: String)
    {
        self.effectiveUserIdentifier = effectiveUserIdentifier
        self.teamIdentifier = teamIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.codeSignatureHash = codeSignatureHash
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case effectiveUserIdentifier
        case teamIdentifier
        case bundleIdentifier
        case codeSignatureHash
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser capability principal")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.effectiveUserIdentifier = try container.decode(UInt32.self, forKey: .effectiveUserIdentifier)
        self.teamIdentifier = try container.decode(String.self, forKey: .teamIdentifier)
        self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        self.codeSignatureHash = try container.decode(String.self, forKey: .codeSignatureHash)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.effectiveUserIdentifier, forKey: .effectiveUserIdentifier)
        try container.encode(self.teamIdentifier, forKey: .teamIdentifier)
        try container.encode(self.bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(self.codeSignatureHash, forKey: .codeSignatureHash)
    }
}

/// Listener-signed authority for one reusable, caller-owned browser capability namespace.
public struct PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let namespaceID: UUID
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String
    public let registryGenerationID: UUID
    public let principal: PeekabooBridgeBrowserCapabilityPrincipal
    public let issuedAtUnixMilliseconds: Int64
    public let expiresAtUnixMilliseconds: Int64

    public init(
        schemaVersion: Int = 1,
        namespaceID: UUID,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String,
        registryGenerationID: UUID,
        principal: PeekabooBridgeBrowserCapabilityPrincipal,
        issuedAtUnixMilliseconds: Int64,
        expiresAtUnixMilliseconds: Int64)
    {
        self.schemaVersion = schemaVersion
        self.namespaceID = namespaceID
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
        self.registryGenerationID = registryGenerationID
        self.principal = principal
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case namespaceID
        case listenerInstanceID
        case listenerPublicKeySHA256
        case registryGenerationID
        case principal
        case issuedAtUnixMilliseconds
        case expiresAtUnixMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser capability namespace receipt payload")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.namespaceID = try container.decode(UUID.self, forKey: .namespaceID)
        self.listenerInstanceID = try container.decode(UUID.self, forKey: .listenerInstanceID)
        self.listenerPublicKeySHA256 = try container.decode(String.self, forKey: .listenerPublicKeySHA256)
        self.registryGenerationID = try container.decode(UUID.self, forKey: .registryGenerationID)
        self.principal = try container.decode(PeekabooBridgeBrowserCapabilityPrincipal.self, forKey: .principal)
        self.issuedAtUnixMilliseconds = try container.decode(Int64.self, forKey: .issuedAtUnixMilliseconds)
        self.expiresAtUnixMilliseconds = try container.decode(Int64.self, forKey: .expiresAtUnixMilliseconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.namespaceID, forKey: .namespaceID)
        try container.encode(self.listenerInstanceID, forKey: .listenerInstanceID)
        try container.encode(self.listenerPublicKeySHA256, forKey: .listenerPublicKeySHA256)
        try container.encode(self.registryGenerationID, forKey: .registryGenerationID)
        try container.encode(self.principal, forKey: .principal)
        try container.encode(self.issuedAtUnixMilliseconds, forKey: .issuedAtUnixMilliseconds)
        try container.encode(self.expiresAtUnixMilliseconds, forKey: .expiresAtUnixMilliseconds)
    }
}

public struct PeekabooBridgeBrowserCapabilityNamespaceReceipt: Codable, Equatable, Sendable {
    public let payload: PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload
    public let signature: Data

    public init(
        payload: PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload,
        signature: Data)
    {
        self.payload = payload
        self.signature = signature
    }

    /// Exact bytes covered by ``signature`` after canonical Bridge encoding.
    public var unsignedPayload: PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload {
        self.payload
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case payload
        case signature
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser capability namespace receipt")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.payload = try container.decode(
            PeekabooBridgeBrowserCapabilityNamespaceReceiptPayload.self,
            forKey: .payload)
        self.signature = try container.decode(Data.self, forKey: .signature)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.payload, forKey: .payload)
        try container.encode(self.signature, forKey: .signature)
    }
}

/// Empty today so later namespace-creation options can be additive without changing the request case.
public struct PeekabooBridgeBrowserCapabilityNamespaceCreateRequest: Codable, Equatable, Sendable {
    public init() {}

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            [],
            from: decoder,
            description: "Browser capability namespace create request")
    }

    public func encode(to encoder: any Encoder) throws {
        _ = encoder.container(keyedBy: EmptyCodingKey.self)
    }

    private enum EmptyCodingKey: String, CodingKey {}
}

/// Per-call authority. A namespace never permanently acquires foreground permission.
public enum PeekabooBridgeBrowserCapabilityExecutionMode: String, Codable, Equatable, Sendable {
    case backgroundOnly = "background_only"
    case foregroundAllowed = "foreground_allowed"
}

/// Closed high-level browser surface carried by protocol 1.38 namespaces.
///
/// Provider tool names are deliberately absent. Adding a high-level action requires a protocol review instead of
/// silently extending the legacy raw ``PeekabooBridgeBrowserExecuteRequest`` escape hatch.
public enum PeekabooBridgeBrowserHighLevelAction: String, Codable, CaseIterable, Equatable, Sendable {
    case status
    case connect
    case disconnect
    case listPages = "list_pages"
    case selectPage = "select_page"
    case closePage = "close_page"
    case newPage = "new_page"
    case navigate
    case waitFor = "wait_for"
    case snapshot
    case click
    case fill
    case fillForm = "fill_form"
    case drag
    case hover
    case type
    case pressKey = "press_key"
    case uploadFile = "upload_file"
    case handleDialog = "handle_dialog"
    case console
    case network
    case screenshot
    case performanceTrace = "performance_trace"
}

public struct PeekabooBridgeBrowserHighLevelActionRequest: Codable, Equatable, Sendable {
    public let action: PeekabooBridgeBrowserHighLevelAction
    public let arguments: [String: PeekabooBridgeJSONValue]

    public init(
        action: PeekabooBridgeBrowserHighLevelAction,
        arguments: [String: PeekabooBridgeJSONValue] = [:])
    {
        self.action = action
        self.arguments = arguments
    }

    /// Canonical high-level BrowserTool arguments. The typed action always wins over dictionary input.
    public var toolArguments: [String: PeekabooBridgeJSONValue] {
        var arguments = self.arguments
        arguments["action"] = .string(self.action.rawValue)
        return arguments
    }

    public var isReadOnly: Bool {
        switch self.action {
        case .status, .disconnect, .listPages, .waitFor, .snapshot, .console, .network, .screenshot:
            true
        case .selectPage:
            self.booleanArgument("bring_to_front") != true
        case .performanceTrace:
            (self.stringArgument("trace_action") ?? "start") != "start" ||
                self.booleanArgument("reload") == false
        case .connect, .closePage, .newPage, .navigate, .click, .fill, .fillForm, .drag, .hover, .type,
             .pressKey, .uploadFile, .handleDialog:
            false
        }
    }

    var requestsForegroundDelivery: Bool {
        switch self.action {
        case .connect:
            true
        case .selectPage:
            self.booleanArgument("bring_to_front") == true
        case .newPage:
            // The high-level BrowserTool adapter normalizes omission to background=true before provider dispatch.
            // This wire carries that adapter contract, not the provider's raw new_page default.
            self.booleanArgument("background") == false
        default:
            false
        }
    }

    private func booleanArgument(_ name: String) -> Bool? {
        guard case let .bool(value)? = self.arguments[name] else { return nil }
        return value
    }

    private func stringArgument(_ name: String) -> String? {
        guard case let .string(value)? = self.arguments[name] else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case action
        case arguments
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser high-level action request")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(PeekabooBridgeBrowserHighLevelAction.self, forKey: .action)
        self.arguments = try container.decode([String: PeekabooBridgeJSONValue].self, forKey: .arguments)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.action, forKey: .action)
        try container.encode(self.arguments, forKey: .arguments)
    }
}

public struct PeekabooBridgeBrowserBindWindowRequest: Codable, Equatable, Sendable {
    public let pageID: String
    public let processIdentifier: Int32
    public let windowID: UInt32

    public init(pageID: String, processIdentifier: Int32, windowID: UInt32) {
        self.pageID = pageID
        self.processIdentifier = processIdentifier
        self.windowID = windowID
    }

    public var toolArguments: [String: PeekabooBridgeJSONValue] {
        [
            "action": .string("bind_window"),
            "page_id": .string(self.pageID),
            "pid": .int(Int(self.processIdentifier)),
            "window_id": .int(Int(self.windowID)),
        ]
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pageID = "page_id"
        case processIdentifier = "pid"
        case windowID = "window_id"
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser native-window binding request")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pageID = try container.decode(String.self, forKey: .pageID)
        self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        self.windowID = try container.decode(UInt32.self, forKey: .windowID)
        guard PeekabooBridgeBrowserCapabilityReference.isCanonicalPage(self.pageID),
              self.processIdentifier > 0,
              self.windowID > 0
        else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Browser native-window binding selectors are not canonical"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.pageID, forKey: .pageID)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(self.windowID, forKey: .windowID)
    }
}

public enum PeekabooBridgeBrowserCapabilityNamespaceAction: Codable, Equatable, Sendable {
    case bindWindow(PeekabooBridgeBrowserBindWindowRequest)
    case executeAction(PeekabooBridgeBrowserHighLevelActionRequest)

    public var toolArguments: [String: PeekabooBridgeJSONValue] {
        switch self {
        case let .bindWindow(request):
            request.toolArguments
        case let .executeAction(request):
            request.toolArguments
        }
    }

    public var isReadOnly: Bool {
        switch self {
        case .bindWindow:
            true
        case let .executeAction(request):
            request.isReadOnly
        }
    }

    var requestsForegroundDelivery: Bool {
        switch self {
        case .bindWindow:
            false
        case let .executeAction(request):
            request.requestsForegroundDelivery
        }
    }

    private enum CodingKeys: String, CodingKey {
        case bindWindow
        case executeAction
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.bindWindow), !container.contains(.executeAction) {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                [CodingKeys.bindWindow.stringValue],
                from: decoder,
                description: "Browser capability namespace action")
            self = try .bindWindow(container.decode(PeekabooBridgeBrowserBindWindowRequest.self, forKey: .bindWindow))
        } else if container.contains(.executeAction), !container.contains(.bindWindow) {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                [CodingKeys.executeAction.stringValue],
                from: decoder,
                description: "Browser capability namespace action")
            self = try .executeAction(container.decode(
                PeekabooBridgeBrowserHighLevelActionRequest.self,
                forKey: .executeAction))
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Browser capability namespace action must carry exactly one closed case"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bindWindow(request):
            try container.encode(request, forKey: .bindWindow)
        case let .executeAction(request):
            try container.encode(request, forKey: .executeAction)
        }
    }
}

public struct PeekabooBridgeBrowserCapabilityNamespaceRequest: Codable, Equatable, Sendable {
    public let namespaceReceipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt
    public let executionMode: PeekabooBridgeBrowserCapabilityExecutionMode
    public let action: PeekabooBridgeBrowserCapabilityNamespaceAction

    public init(
        namespaceReceipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt,
        executionMode: PeekabooBridgeBrowserCapabilityExecutionMode = .backgroundOnly,
        action: PeekabooBridgeBrowserCapabilityNamespaceAction)
    {
        self.namespaceReceipt = namespaceReceipt
        self.executionMode = executionMode
        self.action = action
    }

    public var toolArguments: [String: PeekabooBridgeJSONValue] {
        self.action.toolArguments
    }

    public var isReadOnly: Bool {
        self.action.isReadOnly
    }

    var requestsForegroundDelivery: Bool {
        self.action.requestsForegroundDelivery
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case namespaceReceipt
        case executionMode
        case action
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser capability namespace request")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.namespaceReceipt = try container.decode(
            PeekabooBridgeBrowserCapabilityNamespaceReceipt.self,
            forKey: .namespaceReceipt)
        self.executionMode = try container.decode(
            PeekabooBridgeBrowserCapabilityExecutionMode.self,
            forKey: .executionMode)
        self.action = try container.decode(PeekabooBridgeBrowserCapabilityNamespaceAction.self, forKey: .action)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.namespaceReceipt, forKey: .namespaceReceipt)
        try container.encode(self.executionMode, forKey: .executionMode)
        try container.encode(self.action, forKey: .action)
    }
}

public struct PeekabooBridgeBrowserCapabilityNamespaceCloseRequest: Codable, Equatable, Sendable {
    public let namespaceReceipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt

    public init(namespaceReceipt: PeekabooBridgeBrowserCapabilityNamespaceReceipt) {
        self.namespaceReceipt = namespaceReceipt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case namespaceReceipt
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser capability namespace close request")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.namespaceReceipt = try container.decode(
            PeekabooBridgeBrowserCapabilityNamespaceReceipt.self,
            forKey: .namespaceReceipt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.namespaceReceipt, forKey: .namespaceReceipt)
    }
}

/// Sanitized exact native-window evidence returned by binding and every subsequently bound mutation.
public struct PeekabooBridgeBrowserNativeWindowReceipt: Codable, Equatable, Sendable {
    public enum Quality: String, Codable, Equatable, Sendable {
        case exact
    }

    public let pageReference: String
    public let processIdentifier: Int32
    public let processStartIdentityDecimal: String
    public let windowID: UInt32
    public let bounds: CGRect
    public let quality: Quality

    public init(
        pageReference: String,
        processIdentifier: Int32,
        processStartIdentityDecimal: String,
        windowID: UInt32,
        bounds: CGRect,
        quality: Quality = .exact)
    {
        self.pageReference = pageReference
        self.processIdentifier = processIdentifier
        self.processStartIdentityDecimal = processStartIdentityDecimal
        self.windowID = windowID
        self.bounds = bounds
        self.quality = quality
    }

    var targetEvidence: DesktopTargetIdentity.Evidence? {
        guard PeekabooBridgeBrowserCapabilityReference.isCanonicalPage(self.pageReference),
              self.processIdentifier > 0,
              let processStartIdentity = UInt64(self.processStartIdentityDecimal),
              processStartIdentity > 0,
              String(processStartIdentity) == self.processStartIdentityDecimal,
              self.windowID > 0,
              self.bounds.origin.x.isFinite,
              self.bounds.origin.y.isFinite,
              self.bounds.width.isFinite,
              self.bounds.height.isFinite,
              self.bounds.width > 0,
              self.bounds.height > 0
        else { return nil }
        let identity = WindowMutationIdentity(
            windowID: Int(self.windowID),
            ownerProcessIdentifier: self.processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: self.bounds)
        guard let exactWindow = try? UIAutomationTarget.ExactWindow(identity: identity, bounds: self.bounds) else {
            return nil
        }
        return .init(target: DesktopTargetIdentity(exactWindow: exactWindow))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pageReference
        case processIdentifier
        case processStartIdentityDecimal
        case windowID
        case bounds
        case quality
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser native-window receipt")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pageReference = try container.decode(String.self, forKey: .pageReference)
        self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        self.processStartIdentityDecimal = try container.decode(String.self, forKey: .processStartIdentityDecimal)
        self.windowID = try container.decode(UInt32.self, forKey: .windowID)
        self.bounds = try container.decode(CGRect.self, forKey: .bounds)
        self.quality = try container.decode(Quality.self, forKey: .quality)
        guard self.targetEvidence != nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Browser native-window receipt is not canonical exact target evidence"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.pageReference, forKey: .pageReference)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(self.processStartIdentityDecimal, forKey: .processStartIdentityDecimal)
        try container.encode(self.windowID, forKey: .windowID)
        try container.encode(self.bounds, forKey: .bounds)
        try container.encode(self.quality, forKey: .quality)
    }
}

/// Sanitized BrowserTool response. Provider endpoints, target IDs, page integers, and raw connection receipts are
/// intentionally not representable in this protocol-1.38 response.
public struct PeekabooBridgeBrowserCapabilityNamespaceActionResponse: Codable, Equatable, Sendable {
    public let content: [PeekabooBridgeJSONValue]
    public let isError: Bool
    public let meta: PeekabooBridgeJSONValue?
    public let structuredContent: PeekabooBridgeJSONValue?
    public let nativeWindowReceipt: PeekabooBridgeBrowserNativeWindowReceipt?

    public init(
        content: [PeekabooBridgeJSONValue],
        isError: Bool,
        meta: PeekabooBridgeJSONValue? = nil,
        structuredContent: PeekabooBridgeJSONValue? = nil,
        nativeWindowReceipt: PeekabooBridgeBrowserNativeWindowReceipt? = nil)
    {
        self.content = content
        self.isError = isError
        self.meta = meta
        self.structuredContent = structuredContent
        self.nativeWindowReceipt = nativeWindowReceipt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case content
        case isError
        case meta
        case structuredContent
        case nativeWindowReceipt
    }

    public init(from decoder: any Decoder) throws {
        let typedContainer = try decoder.container(keyedBy: CodingKeys.self)
        var expectedKeys: Set<String> = [
            CodingKeys.content.stringValue,
            CodingKeys.isError.stringValue,
        ]
        for key in [CodingKeys.meta, .structuredContent, .nativeWindowReceipt]
            where typedContainer.contains(key)
        {
            expectedKeys.insert(key.stringValue)
        }
        try PeekabooBridgeClosedPayload.requireExactKeys(
            expectedKeys,
            from: decoder,
            description: "Browser capability namespace action response")
        let container = typedContainer
        self.content = try container.decode([PeekabooBridgeJSONValue].self, forKey: .content)
        self.isError = try container.decode(Bool.self, forKey: .isError)
        self.meta = try container.decodeIfPresent(PeekabooBridgeJSONValue.self, forKey: .meta)
        self.structuredContent = try container.decodeIfPresent(
            PeekabooBridgeJSONValue.self,
            forKey: .structuredContent)
        self.nativeWindowReceipt = try container.decodeIfPresent(
            PeekabooBridgeBrowserNativeWindowReceipt.self,
            forKey: .nativeWindowReceipt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.content, forKey: .content)
        try container.encode(self.isError, forKey: .isError)
        try container.encodeIfPresent(self.meta, forKey: .meta)
        try container.encodeIfPresent(self.structuredContent, forKey: .structuredContent)
        try container.encodeIfPresent(self.nativeWindowReceipt, forKey: .nativeWindowReceipt)
    }
}

public struct PeekabooBridgeBrowserCapabilityNamespaceCloseResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case closed
    }

    public let namespaceID: UUID
    public let status: Status

    public init(namespaceID: UUID, status: Status = .closed) {
        self.namespaceID = namespaceID
        self.status = status
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case namespaceID
        case status
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Browser capability namespace close response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.namespaceID = try container.decode(UUID.self, forKey: .namespaceID)
        self.status = try container.decode(Status.self, forKey: .status)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.namespaceID, forKey: .namespaceID)
        try container.encode(self.status, forKey: .status)
    }
}
