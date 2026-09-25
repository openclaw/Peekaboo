import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeSetValueVerificationWireTests {
    @Test
    func `signed integer coercion rejects rounded fractional and underflowed text`() throws {
        let cases: [(String, Int)] = [
            ("9007199254740993.0", 9_007_199_254_740_992),
            ("1.0000000000000001", 1), ("1e-400", 0), ("0x1p2", 4),
        ]
        for (text, rounded) in cases {
            let witness = ElementValueVerification(attribute: .value, resolvedKind: .int, readback: .int(rounded))
            let bundle = try SetValueVerificationReceiptFixture.bundle(
                requested: Self.request(.string(text)), response: Self.response(witness: witness))
            try bundle.receipt.validateSignature(publicKey: bundle.operationAttestation.publicKey)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) { try bundle.validateIntegrity() }
        }
    }

    @Test
    func `signed fractional numeric readbacks cannot attest Boolean success`() throws {
        for readback in [0.5, -0.5, 1.5] {
            let witness = ElementValueVerification(
                attribute: .value, resolvedKind: .bool, readback: .double(readback))
            let bundle = try SetValueVerificationReceiptFixture.bundle(
                requested: Self.request(.bool(readback >= 1)), response: Self.response(witness: witness))
            try bundle.receipt.validateSignature(publicKey: bundle.operationAttestation.publicKey)
            #expect(throws: PeekabooBridgeOperationReceiptError.self) { try bundle.validateIntegrity() }
        }
    }

    @Test
    func `legacy numeric boolean readbacks retain valid signed old decoder bytes`() throws {
        for requested in [false, true] {
            let witness = ElementValueVerification(
                attribute: .value,
                resolvedKind: .double,
                readback: .double(requested ? 1 : 0),
                legacyPresentation: String(requested))
            let request = Self.request(.bool(requested))
            let projected = try Self.response(witness: witness).projectingSetValueVerification(
                offered: false, request: request)
            let bundle = try SetValueVerificationReceiptFixture.bundle(requested: request, response: projected)
            try bundle.validateIntegrity()
            let old = try JSONDecoder.peekabooBridgeDecoder().decode(OldResponse.self, from: bundle.canonicalResponse)
            #expect(try PeekabooBridgeOperationReceiptCoding.sha256(old) == bundle.receipt.payload.responseSHA256)
        }
    }

    @Test
    func `signed native readbacks round trip without losing their primitive kind`() throws {
        let cases: [(UIElementValue, ElementValueVerification)] = [
            (.int(58), .init(attribute: .value, resolvedKind: .double, readback: .double(57.99999999999999))),
            (.string("58"), .init(attribute: .value, resolvedKind: .double, readback: .double(57.99999999999999))),
            (.double(58), .init(attribute: .value, resolvedKind: .double, readback: .double(58))),
            (.double(-0.0), .init(attribute: .value, resolvedKind: .double, readback: .double(-0.0))),
            (.string("-0.0"), .init(attribute: .value, resolvedKind: .string, readback: .string("-0.0"))),
            (.int(9_007_199_254_740_993), .init(
                attribute: .value, resolvedKind: .int, readback: .int(9_007_199_254_740_993))),
            (.string("9007199254740993.0"), .init(
                attribute: .value, resolvedKind: .int, readback: .int(9_007_199_254_740_993))),
            (.string("\(Int.max).0"), .init(attribute: .value, resolvedKind: .int, readback: .int(Int.max))),
            (.string("10e-1"), .init(attribute: .value, resolvedKind: .int, readback: .int(1))),
            (.bool(true), .init(attribute: .selected, resolvedKind: .bool, readback: .bool(true))),
            (.string("58.00"), .init(attribute: .value, resolvedKind: .double, readback: .double(58))),
        ]
        for (requested, witness) in cases {
            let response = Self.response(witness: witness)
            let bundle = try SetValueVerificationReceiptFixture.bundle(
                requested: Self.request(requested), response: response)
            try bundle.validateIntegrity()
            let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationReceiptBundle.self, from: bundle.canonicalEncodedData())
            try decoded.validateIntegrity()
            #expect(decoded == bundle)
            let decodedResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self, from: decoded.canonicalResponse)
            guard case let .projectedAction(projected) = decodedResponse,
                  case let .elementActionResult(result) = projected.response
            else {
                Issue.record("Expected a projected element result")
                continue
            }
            #expect(result.valueVerification == witness)
            #expect(result.newValue == witness.displayString)
        }
    }

    @Test
    func `signed legacy exact readback remains valid without witness`() throws {
        let response = Self.response(result: .init(
            target: "slider", actionName: "AXSetValue", anchorPoint: nil, newValue: "58"))
        let bundle = try SetValueVerificationReceiptFixture.bundle(
            requested: Self.request(.int(58)), response: response)
        try bundle.validateIntegrity()
        let legacyJSON = try #require(String(bytes: bundle.canonicalResponse, encoding: .utf8))
        #expect(!legacyJSON.contains("valueVerification"))
    }

    @Test
    func `signed malformed witness cannot override request or presentation`() throws {
        let malformedResults: [ElementActionResult] = [
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "58",
                valueVerification: .init(attribute: .value, resolvedKind: .double, readback: .double(59))),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "59",
                valueVerification: .init(attribute: .value, resolvedKind: .double, readback: .double(59))),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "58",
                valueVerification: .init(attribute: .value, resolvedKind: .double, readback: .string("58"))),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "true",
                valueVerification: .init(attribute: .selected, resolvedKind: .bool, readback: .bool(true))),
        ]
        for result in malformedResults {
            let bundle = try SetValueVerificationReceiptFixture.bundle(
                requested: Self.request(.int(58)), response: Self.response(result: result))
            try bundle.receipt.validateSignature(publicKey: bundle.operationAttestation.publicKey)
            #expect(throws: PeekabooBridgeOperationReceiptError
                .receiptMismatch("set-value response request semantics"))
            {
                try bundle.validateIntegrity()
            }
        }
        let largeInteger = 9_007_199_254_740_993
        let rounded = Self.response(witness: .init(
            attribute: .value, resolvedKind: .int, readback: .int(largeInteger - 1)))
        let bundle = try SetValueVerificationReceiptFixture.bundle(
            requested: Self.request(.int(largeInteger)), response: rounded)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) { try bundle.validateIntegrity() }
        let normalizedText = try SetValueVerificationReceiptFixture.bundle(
            requested: Self.request(.string("-0.0")),
            response: Self.response(witness: .init(
                attribute: .value, resolvedKind: .string, readback: .string("0"))))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) { try normalizedText.validateIntegrity() }
    }

    @Test
    func `changing witness and matching presentation cannot reuse signed receipt`() throws {
        let witness = ElementValueVerification(attribute: .value, resolvedKind: .double, readback: .double(58))
        let bundle = try SetValueVerificationReceiptFixture.bundle(
            requested: Self.request(.int(58)), response: Self.response(witness: witness))
        try bundle.validateIntegrity()
        let changed = Self.response(witness: .init(
            attribute: .value, resolvedKind: .double, readback: .double(58.00001)))
        let alteredBundle = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: bundle.operationAttestation,
            operationSessionAttestation: bundle.operationSessionAttestation,
            receipt: bundle.receipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: bundle.canonicalReceiptPayload,
            canonicalRequest: bundle.canonicalRequest,
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(changed))

        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch("the exported verification bundle")) {
            try alteredBundle.validateIntegrity()
        }
        let changedLegacy = Self.response(witness: .init(
            attribute: .value, resolvedKind: .double, readback: .double(58), legacyPresentation: "58"))
        let legacyTampered = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: bundle.operationAttestation,
            operationSessionAttestation: bundle.operationSessionAttestation,
            receipt: bundle.receipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: bundle.canonicalReceiptPayload,
            canonicalRequest: bundle.canonicalRequest,
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(changedLegacy))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) { try legacyTampered.validateIntegrity() }
    }

    @Test
    func `projection keeps raw and receiptless results canonical for old decoders`() throws {
        let witness = ElementValueVerification(attribute: .value, resolvedKind: .int, readback: .int(58))
        let projected = Self.response(witness: witness)
        guard case let .projectedAction(wrapper) = projected else {
            Issue.record("Expected projected fixture")
            return
        }
        for response in [wrapper.response, projected] {
            let offered = try response.projectingSetValueVerification(offered: true, request: Self.request(.int(58)))
            let unoffered = try response.projectingSetValueVerification(offered: false, request: Self.request(.int(58)))
            let offeredBytes = try PeekabooBridgeOperationReceiptCoding.canonicalData(offered)
            let oldOffered = try JSONDecoder.peekabooBridgeDecoder().decode(OldResponse.self, from: offeredBytes)
            #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(oldOffered) != offeredBytes)
            let unofferedBytes = try PeekabooBridgeOperationReceiptCoding.canonicalData(unoffered)
            let oldUnoffered = try JSONDecoder.peekabooBridgeDecoder().decode(OldResponse.self, from: unofferedBytes)
            #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(oldUnoffered) == unofferedBytes)
            let unofferedJSON = try #require(String(bytes: unofferedBytes, encoding: .utf8))
            #expect(!unofferedJSON.contains("valueVerification"))
            #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(offered) ==
                PeekabooBridgeOperationReceiptCoding.canonicalData(response))
        }
        let bundle = try SetValueVerificationReceiptFixture.bundle(
            requested: Self.request(.int(58)),
            response: projected.projectingSetValueVerification(offered: false, request: Self.request(.int(58))))
        try bundle.validateIntegrity()
        let oldResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            OldResponse.self, from: bundle.canonicalResponse)
        #expect(try PeekabooBridgeOperationReceiptCoding.sha256(oldResponse) == bundle.receipt.payload.responseSHA256)
    }

    private static func request(_ value: UIElementValue) -> PeekabooBridgeRequest {
        .projectedAction(.init(request: .setValue(.init(
            target: "slider", value: value, snapshotId: "synthetic-snapshot"))))
    }

    private static func response(witness: ElementValueVerification) -> PeekabooBridgeResponse {
        self.response(result: .init(
            target: "slider",
            actionName: witness.attribute == .selected ? "AXSelected" : "AXSetValue",
            anchorPoint: nil,
            oldValue: "50",
            newValue: witness.displayString,
            valueVerification: witness))
    }

    private static func response(result: ElementActionResult) -> PeekabooBridgeResponse {
        .projectedAction(.init(
            response: .elementActionResult(result),
            outcome: DesktopActionOutcome.confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .one).projection))
    }

    private indirect enum OldResponse: Codable {
        case elementActionResult(OldElementActionResult)
        case projectedAction(OldProjectedResponse)
    }

    private struct OldProjectedResponse: Codable {
        let response: OldResponse
        let outcome: DesktopActionOutcome.Projection?
    }

    private struct OldElementActionResult: Codable {
        let target: String
        let actionName: String?
        let anchorPoint: CGPoint?
        let oldValue: String?
        let newValue: String?
    }
}
