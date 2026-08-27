import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct BrowserCapabilityNamespaceWireTests {
    private static let namespaceOperations = PeekabooBridgeOperation.browserCapabilityNamespaceOperations
    private static let pageReference = "bp1_0123456789abcdef0123456789abcdef"

    @Test
    func `protocol 1 38 owns the closed namespace vocabulary`() {
        let legacy = PeekabooBridgeProtocolVersion(major: 1, minor: 37)

        #expect(PeekabooBridgeConstants.protocolVersion >= .init(major: 1, minor: 38))
        #expect(PeekabooBridgeConstants.browserCapabilityNamespaceVersion == .init(major: 1, minor: 38))
        #expect(PeekabooBridgeHostCapability.browserCapabilityNamespaces == "browserCapabilityNamespaces")
        #expect(PeekabooBridgeHostCapability.nativeBrowserWindowBinding == "nativeBrowserWindowBinding")
        #expect(PeekabooBridgeClientCapability.browserCapabilityNamespaces == "browserCapabilityNamespaces")
        #expect(PeekabooBridgeClientCapability.nativeBrowserWindowBinding == "nativeBrowserWindowBinding")
        #expect(PeekabooBridgeOperation.compatible(Self.namespaceOperations, with: legacy).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            Self.namespaceOperations,
            with: PeekabooBridgeConstants.protocolVersion) == Self.namespaceOperations)
        #expect(Self.namespaceOperations.isDisjoint(with: PeekabooBridgeOperation.remoteDefaultAllowlist))
        #expect(Self.namespaceOperations.isDisjoint(with: PeekabooBridgeOperation.embeddedDefaultAllowlist))
        #expect(Self.namespaceOperations.isSubset(of: PeekabooBridgeOperation.onDemandDefaultAllowlist))
    }

    @Test
    func `signed namespace receipt round trips without private browser identifiers`() throws {
        let receipt = Self.receipt()
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(receipt)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeBrowserCapabilityNamespaceReceipt.self,
            from: data)
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(decoded == receipt)
        #expect(decoded.unsignedPayload == receipt.payload)
        #expect(!encoded.contains("webSocketDebuggerURL"))
        #expect(!encoded.contains("devToolsBrowserID"))
        #expect(!encoded.contains("targetID"))
        #expect(!encoded.contains("providerSessionEpoch"))
    }

    @Test
    func `signed namespace receipt rejects unknown authority keys at every level`() throws {
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(Self.receipt())
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        var receiptWithUnknown = root
        receiptWithUnknown["unknown"] = true

        var payloadWithUnknown = root
        var payload = try #require(payloadWithUnknown["payload"] as? [String: Any])
        payload["unknown"] = true
        payloadWithUnknown["payload"] = payload

        var principalWithUnknown = root
        var principalPayload = try #require(principalWithUnknown["payload"] as? [String: Any])
        var principal = try #require(principalPayload["principal"] as? [String: Any])
        principal["unknown"] = true
        principalPayload["principal"] = principal
        principalWithUnknown["payload"] = principalPayload

        for object in [receiptWithUnknown, payloadWithUnknown, principalWithUnknown] {
            let altered = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                    PeekabooBridgeBrowserCapabilityNamespaceReceipt.self,
                    from: altered)
            }
        }
    }

    @Test
    func `typed bind action encodes only public selectors and namespace authority`() throws {
        let payload = PeekabooBridgeBrowserCapabilityNamespaceRequest(
            namespaceReceipt: Self.receipt(),
            action: .bindWindow(.init(
                pageID: Self.pageReference,
                processIdentifier: 4242,
                windowID: 77)))
        let request = PeekabooBridgeRequest.browserCapabilityNamespace(payload)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)

        guard case let .browserCapabilityNamespace(decodedPayload) = decoded,
              case let .bindWindow(binding) = decodedPayload.action
        else {
            Issue.record("Expected typed namespace bind action")
            return
        }
        #expect(decoded.operation == .browserCapabilityNamespace)
        #expect(decodedPayload.executionMode == .backgroundOnly)
        #expect(binding == .init(pageID: Self.pageReference, processIdentifier: 4242, windowID: 77))
        #expect(decodedPayload.toolArguments == [
            "action": .string("bind_window"),
            "page_id": .string(Self.pageReference),
            "pid": .int(4242),
            "window_id": .int(77),
        ])
    }

    @Test
    func `high level action carriage has no raw provider escape hatch`() throws {
        #expect(!PeekabooBridgeBrowserHighLevelAction.allCases.map(\.rawValue).contains("call"))
        let request = PeekabooBridgeBrowserHighLevelActionRequest(
            action: .click,
            arguments: [
                "action": .string("call"),
                "page_id": .string(Self.pageReference),
                "uid": .string("be1_element"),
            ])
        #expect(request.toolArguments["action"] == .string("click"))

        let invalid = Data(#"{"action":"call","arguments":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeBrowserHighLevelActionRequest.self,
                from: invalid)
        }
    }

    @Test
    func `namespace response vocabulary carries only sanitized tool fields`() throws {
        let response = PeekabooBridgeResponse.browserCapabilityNamespaceAction(.init(
            content: [.string("clicked")],
            isError: false,
            meta: .object(["browser_page_refs": .array([.string(Self.pageReference)])]),
            structuredContent: .object(["state": .string("complete")])))
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)

        guard case let .browserCapabilityNamespaceAction(payload) = decoded else {
            Issue.record("Expected namespace action response")
            return
        }
        #expect(payload.content == [.string("clicked")])
        #expect(payload.structuredContent == .object(["state": .string("complete")]))
    }

    @Test
    func `native-window response receipt converts to exact target evidence`() throws {
        let nativeReceipt = PeekabooBridgeBrowserNativeWindowReceipt(
            pageReference: Self.pageReference,
            processIdentifier: 4242,
            processStartIdentityDecimal: "9001",
            windowID: 77,
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
        let response = PeekabooBridgeBrowserCapabilityNamespaceActionResponse(
            content: [.string("bound")],
            isError: false,
            nativeWindowReceipt: nativeReceipt)
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(response)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeBrowserCapabilityNamespaceActionResponse.self,
            from: data)
        let evidence = try #require(decoded.nativeWindowReceipt?.targetEvidence)
        let request = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: Self.receipt(),
            action: .executeAction(.init(
                action: .click,
                arguments: ["page_id": .string(Self.pageReference)]))))
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
        let projectedEvidence = PeekabooBridgeResponse.browserCapabilityNamespaceAction(decoded)
            .operationTargetEvidence(for: plan)

        #expect(evidence.processIdentifier == 4242)
        #expect(evidence.processIdentity?.processStartIdentity == 9001)
        #expect(evidence.windowID == 77)
        #expect(evidence.windowBounds == CGRect(x: 10, y: 20, width: 800, height: 600))
        #expect(projectedEvidence == [evidence])
    }

    @Test
    func `namespace operation envelopes reject unknown signed fields`() throws {
        let request = PeekabooBridgeBrowserCapabilityNamespaceRequest(
            namespaceReceipt: Self.receipt(),
            action: .executeAction(.init(action: .listPages)))
        let response = PeekabooBridgeBrowserCapabilityNamespaceActionResponse(
            content: [],
            isError: false)
        var requestObject = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder.peekabooBridgeEncoder().encode(request)) as? [String: Any])
        requestObject["unknown"] = true
        let alteredRequest = try JSONSerialization.data(withJSONObject: requestObject)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeBrowserCapabilityNamespaceRequest.self,
                from: alteredRequest)
        }

        var responseObject = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder.peekabooBridgeEncoder().encode(response)) as? [String: Any])
        responseObject["unknown"] = true
        let alteredResponse = try JSONSerialization.data(withJSONObject: responseObject)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeBrowserCapabilityNamespaceActionResponse.self,
                from: alteredResponse)
        }
    }

    @Test
    func `namespace request descriptors preserve read and mutation boundaries`() {
        let receipt = Self.receipt()
        let bind = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: receipt,
            action: .bindWindow(.init(
                pageID: Self.pageReference,
                processIdentifier: 4242,
                windowID: 77))))
        let list = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: receipt,
            action: .executeAction(.init(action: .listPages))))
        let click = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: receipt,
            action: .executeAction(.init(action: .click))))
        let connect = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: receipt,
            executionMode: .foregroundAllowed,
            action: .executeAction(.init(action: .connect))))
        let unauthorizedConnect = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: receipt,
            action: .executeAction(.init(action: .connect))))
        let defaultNewPage = PeekabooBridgeRequest.browserCapabilityNamespace(.init(
            namespaceReceipt: receipt,
            action: .executeAction(.init(action: .newPage))))

        #expect(!PeekabooBridgeOperationResultSemantics.contract(for: bind).completion.mutatesDesktop)
        #expect(!PeekabooBridgeOperationResultSemantics.contract(for: list).completion.mutatesDesktop)
        #expect(PeekabooBridgeOperationResultSemantics.contract(for: click).completion.fixedDelivery == .init(
            mechanism: .browserProtocol,
            mode: .background))
        #expect(PeekabooBridgeOperationResultSemantics.contract(for: connect).completion.fixedDelivery == .init(
            mechanism: .browserProtocol,
            mode: .foreground))
        #expect(PeekabooBridgeOperationResultSemantics.contract(
            for: unauthorizedConnect).completion.fixedDelivery == .init(
            mechanism: .browserProtocol,
            mode: .foreground))
        #expect(throws: DesktopActionFailure.self) {
            try unauthorizedConnect.validateBrowserCapabilityExecutionMode()
        }
        #expect(PeekabooBridgeOperationResultSemantics.contract(
            for: defaultNewPage).completion.fixedDelivery == .init(
            mechanism: .browserProtocol,
            mode: .background))
        #expect(throws: Never.self) {
            try defaultNewPage.validateBrowserCapabilityExecutionMode()
        }
        #expect(!PeekabooBridgeOperationResultSemantics.contract(
            for: .browserCreateCapabilityNamespace(.init())).completion.mutatesDesktop)
        #expect(!PeekabooBridgeOperationResultSemantics.contract(
            for: .browserCloseCapabilityNamespace(.init(namespaceReceipt: receipt))).completion.mutatesDesktop)
    }

    @Test(arguments: Self.negotiationRefusals)
    func `namespace negotiation fails closed for every incomplete matrix row`(
        row: NegotiationRow)
    {
        #expect(!PeekabooBridgeBrowserCapabilityNamespaceNegotiation.sessionCanNegotiateCapabilities(.init(
            host: .init(
                hostKind: row.hostKind,
                maximumProtocolVersion: row.version,
                allowedOperations: row.operations,
                supportsBrowserCapabilityNamespaces: row.supportsNamespaces,
                supportsNativeBrowserWindowBinding: row.supportsBinding),
            usesAttestedOperationReceipts: row.usesReceipts,
            clientCapabilities: row.clientCapabilities)))
    }

    @Test
    func `complete on demand attested matrix negotiates both session claims`() {
        let capabilities: Set<String> = [
            PeekabooBridgeClientCapability.browserCapabilityNamespaces,
            PeekabooBridgeClientCapability.nativeBrowserWindowBinding,
        ]
        #expect(PeekabooBridgeBrowserCapabilityNamespaceNegotiation.sessionCanNegotiateCapabilities(.init(
            host: .init(
                hostKind: .onDemand,
                maximumProtocolVersion: PeekabooBridgeConstants.protocolVersion,
                allowedOperations: Self.namespaceOperations,
                supportsBrowserCapabilityNamespaces: true,
                supportsNativeBrowserWindowBinding: true),
            usesAttestedOperationReceipts: true,
            clientCapabilities: capabilities)))
        #expect(PeekabooBridgeNegotiatedSessionCapabilities.current.browserCapabilityNamespaces)
        #expect(PeekabooBridgeNegotiatedSessionCapabilities.current.nativeBrowserWindowBinding)
    }

    @Test
    func `client rejects namespace handshake missing native binding capability`() {
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: Array(Self.namespaceOperations),
            enabledOperations: Array(Self.namespaceOperations),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.browserCapabilityNamespaces,
            ])

        #expect(!PeekabooBridgeClient.supportsBrowserCapabilityNamespaces(handshake))
        #expect(!PeekabooBridgeClient.supportsNativeBrowserWindowBinding(handshake))
    }

    private static let completeClientCapabilities: Set<String> = [
        PeekabooBridgeClientCapability.browserCapabilityNamespaces,
        PeekabooBridgeClientCapability.nativeBrowserWindowBinding,
    ]

    static let negotiationRefusals: [NegotiationRow] = [
        .init(version: .init(major: 1, minor: 37)),
        .init(hostKind: .gui),
        .init(hostKind: .helper),
        .init(hostKind: .inProcess),
        .init(usesReceipts: false),
        .init(clientCapabilities: []),
        .init(clientCapabilities: [PeekabooBridgeClientCapability.browserCapabilityNamespaces]),
        .init(clientCapabilities: [PeekabooBridgeClientCapability.nativeBrowserWindowBinding]),
        .init(operations: [.browserCreateCapabilityNamespace, .browserCapabilityNamespace]),
        .init(supportsNamespaces: false),
        .init(supportsBinding: false),
    ]

    struct NegotiationRow: Sendable, CustomTestStringConvertible {
        let version: PeekabooBridgeProtocolVersion
        let hostKind: PeekabooBridgeHostKind
        let usesReceipts: Bool
        let clientCapabilities: Set<String>
        let operations: Set<PeekabooBridgeOperation>
        let supportsNamespaces: Bool
        let supportsBinding: Bool

        init(
            version: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion,
            hostKind: PeekabooBridgeHostKind = .onDemand,
            usesReceipts: Bool = true,
            clientCapabilities: Set<String> = BrowserCapabilityNamespaceWireTests.completeClientCapabilities,
            operations: Set<PeekabooBridgeOperation> = BrowserCapabilityNamespaceWireTests.namespaceOperations,
            supportsNamespaces: Bool = true,
            supportsBinding: Bool = true)
        {
            self.version = version
            self.hostKind = hostKind
            self.usesReceipts = usesReceipts
            self.clientCapabilities = clientCapabilities
            self.operations = operations
            self.supportsNamespaces = supportsNamespaces
            self.supportsBinding = supportsBinding
        }

        var testDescription: String {
            "v=\(self.version.major).\(self.version.minor) host=\(self.hostKind.rawValue) " +
                "receipts=\(self.usesReceipts) client=\(self.clientCapabilities.sorted()) " +
                "operations=\(self.operations.map(\.rawValue).sorted()) " +
                "service=\(self.supportsNamespaces)/\(self.supportsBinding)"
        }
    }

    private static func receipt() -> PeekabooBridgeBrowserCapabilityNamespaceReceipt {
        .init(
            payload: .init(
                namespaceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                listenerInstanceID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                listenerPublicKeySHA256: String(repeating: "a", count: 64),
                registryGenerationID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
                principal: .init(
                    effectiveUserIdentifier: 501,
                    teamIdentifier: "TEAMID1234",
                    bundleIdentifier: "boo.peekaboo.peekaboo",
                    codeSignatureHash: String(repeating: "b", count: 40)),
                issuedAtUnixMilliseconds: 1_800_000_000_000,
                expiresAtUnixMilliseconds: 1_800_000_300_000),
            signature: Data(repeating: 0x5A, count: 64))
    }
}
