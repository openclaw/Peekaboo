import CoreGraphics
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

@Suite("Bridge certification observer semantic payload", .serialized)
struct PeekabooBridgeCertificationObserverSemanticPayloadTests {
    @Test
    func `Three consecutive signed readbacks prove observation and restoration`() async throws {
        let fixture = try await Self.fixture()
        try fixture.payload.validate(context: fixture.context)
        for bundle in fixture.payload.readbackBundles {
            try bundle.validate(trustAnchor: .listenerAttestation(fixture.context.listenerAttestation))
            #expect(bundle.receipt.payload.operation == .getFocusedElement)
            #expect(bundle.receipt.payload.target == .process(fixture.payload.target.processIdentity))
        }
    }

    @Test
    func `Foreign listener reordered readbacks and witness drift fail closed`() async throws {
        let fixture = try await Self.fixture()
        let bundles = fixture.payload.readbackBundles

        let foreignAuthority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/private/tmp/pb-observer-foreign-\(UUID().uuidString.lowercased()).sock")
        let original = bundles[1]
        let foreignBundle = PeekabooBridgeOperationReceiptBundle(
            operationAttestation: foreignAuthority.attestation,
            operationSessionAttestation: original.operationSessionAttestation,
            receipt: original.receipt,
            canonicalListenerAttestationPayload: original.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: original.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: original.canonicalReceiptPayload,
            canonicalRequest: original.canonicalRequest,
            canonicalResponse: original.canonicalResponse)
        let foreign = Self.payload(
            target: fixture.payload.target,
            focusedElement: fixture.payload.focusedElement,
            bundles: [bundles[0], foreignBundle, bundles[2]])
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try foreign.validate(context: fixture.context)
        }

        let reordered = Self.payload(
            target: fixture.payload.target,
            focusedElement: fixture.payload.focusedElement,
            bundles: [bundles[0], bundles[2], bundles[1]])
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try reordered.validate(context: fixture.context)
        }

        let driftedTarget = WindowMutationIdentity(
            windowID: fixture.payload.target.windowID + 1,
            ownerProcessIdentifier: fixture.payload.target.ownerProcessIdentifier,
            ownerProcessStartIdentity: fixture.payload.target.ownerProcessStartIdentity,
            capturedBounds: fixture.payload.target.capturedBounds,
            isMinimized: false)
        let drifted = Self.payload(
            target: driftedTarget,
            focusedElement: fixture.payload.focusedElement,
            bundles: bundles)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try drifted.validate(context: fixture.context)
        }

        let staleMarker = "peekaboo-foreground-postcondition:\(String(repeating: "d", count: 64))"
        let replayedRun = try await Self.fixture(readbackMarker: staleMarker)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try replayedRun.payload.validate(context: replayedRun.context)
        }
    }

    @Test
    func `Digest and path injection cannot substitute signed readback values`() async throws {
        let fixture = try await Self.fixture()
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let encoded = try encoder.encode(fixture.payload)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["observedValueSHA256"] = String(repeating: "f", count: 64)
        let digestDrift = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let decodedDrift = try decoder.decode(
            PeekabooBridgeCertificationObserverSemanticPayload.self,
            from: digestDrift)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try decodedDrift.validate(context: fixture.context)
        }

        object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["observationPath"] = "/private/tmp/caller-selected.json"
        let pathInjection = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(PeekabooBridgeCertificationObserverSemanticPayload.self, from: pathInjection)
        }
    }

    private struct Fixture {
        let payload: PeekabooBridgeCertificationObserverSemanticPayload
        let context: PeekabooBridgeCertificationPayloadValidationContext
    }

    private static func fixture(readbackMarker: String = Self.marker) async throws -> Fixture {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/private/tmp/pb-observer-fixture-\(UUID().uuidString.lowercased()).sock")
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let producer = session.attestation.client
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let target = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: producer.processIdentifier,
            ownerProcessStartIdentity: producer.processStartIdentity,
            capturedBounds: bounds,
            isMinimized: false)
        let request = PeekabooBridgeRequest.getFocusedElement(.init(
            targetProcessIdentifier: producer.processIdentifier,
            expectedProcessIdentity: target.processIdentity))
        let values = ["before", readbackMarker, "before"]
        var bundles: [PeekabooBridgeOperationReceiptBundle] = []
        var focusedElement: FocusedElementIdentity?
        for (index, value) in values.enumerated() {
            let focus = UIFocusInfo(
                role: "AXTextField",
                title: "Certification field",
                value: value,
                frame: CGRect(x: 20, y: 30, width: 300, height: 40),
                applicationName: "Peekaboo Playground",
                bundleIdentifier: "boo.peekaboo.playground",
                processId: Int(producer.processIdentifier),
                windowID: target.windowID,
                identifier: "certification-field")
            focusedElement = FocusedElementIdentity(
                processIdentifier: producer.processIdentifier,
                windowID: target.windowID,
                role: focus.role,
                title: focus.title,
                identifier: focus.identifier,
                frame: focus.frame)
            let bundle = try await session.signedBundle(
                authority: authority,
                sequence: UInt64(index),
                request: request,
                response: .focusedElement(focus),
                target: .process(target.processIdentity))
            try bundle.validateIntegrity()
            bundles.append(bundle)
        }
        let identity = try #require(focusedElement)
        let payload = Self.payload(
            target: target,
            focusedElement: identity,
            bundles: bundles,
            marker: readbackMarker)
        let attestationRequest = PeekabooBridgeCertificationProducerAttestationRequest(
            kind: .observerSemantic,
            executionNonce: Self.executionNonce,
            monitorInstanceID: Self.monitorInstanceID,
            producerSocketPath: "/private/tmp/observer-producer.sock",
            expectedProducer: .init(
                processIdentifier: producer.processIdentifier,
                processStartIdentity: producer.processStartIdentity,
                codeSignatureHash: producer.codeSignatureHash),
            timeoutMilliseconds: 1000,
            maximumResponseBytes: 1024 * 1024)
        let context = PeekabooBridgeCertificationPayloadValidationContext(
            request: attestationRequest,
            producer: .init(
                processIdentifier: producer.processIdentifier,
                processIdentifierVersion: 1,
                processStartIdentity: producer.processStartIdentity,
                codeSignatureHash: producer.codeSignatureHash,
                signingIdentifier: PeekabooBridgeCertificationProducerAttestationKind.observerSemantic
                    .expectedSigningIdentifier,
                teamIdentifier: PeekabooBridgeCertificationValidation.foundationTeamIdentifier,
                sourceCommit: String(repeating: "a", count: 40),
                executableSHA256: String(repeating: "b", count: 64)),
            listenerAttestation: authority.attestation)
        return Fixture(payload: payload, context: context)
    }

    private static func payload(
        target: WindowMutationIdentity,
        focusedElement: FocusedElementIdentity,
        bundles: [PeekabooBridgeOperationReceiptBundle],
        marker: String = Self.marker) -> PeekabooBridgeCertificationObserverSemanticPayload
    {
        let observed = bundles.count > 1 ? bundles[1].receipt.payload : bundles[0].receipt.payload
        return .init(
            target: target,
            focusedElement: focusedElement,
            observationInterval: .init(
                startedAtUnixMilliseconds: observed.startedAtUnixMilliseconds,
                completedAtUnixMilliseconds: observed.completedAtUnixMilliseconds),
            requestMarker: marker,
            beforeValue: "before",
            expectedValue: marker,
            observedValue: marker,
            restoredValue: "before",
            readbackBundles: bundles)
    }

    private static let executionNonce = String(repeating: "c", count: 64)
    private static let monitorInstanceID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private static let marker = "peekaboo-foreground-postcondition:\(executionNonce)"
}
