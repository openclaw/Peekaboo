import Foundation
import Testing
@testable import PeekabooBridge

@Suite("Bridge process-generation observation contract")
struct ProcessGenerationObservationContractTests {
    @Test
    func `Protocol and allowlist fail closed before 1.32`() {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 31)
        #expect(PeekabooBridgeConstants.protocolVersion >=
            PeekabooBridgeConstants.processGenerationObservationVersion)
        #expect(!PeekabooBridgeOperation.compatible([.observeProcessGeneration], with: previous)
            .contains(.observeProcessGeneration))
        #expect(PeekabooBridgeOperation.compatible(
            [.observeProcessGeneration],
            with: PeekabooBridgeConstants.processGenerationObservationVersion)
            .contains(.observeProcessGeneration))
        #expect(PeekabooBridgeOperation.remoteDefaultAllowlist.contains(.observeProcessGeneration))
        #expect(PeekabooBridgeOperation.observeProcessGeneration.requiredPermissions.isEmpty)
    }

    @Test
    func `Observation is read only receipt bound and targetless`() {
        let request = PeekabooBridgeRequest.observeProcessGeneration(Self.request())
        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)
        #expect(request.minimumNegotiatedProtocolVersion ==
            PeekabooBridgeConstants.processGenerationObservationVersion)
        #expect(!request.mayMutateDesktop)
        #expect(plan.contract.completion == .readOnly)
        #expect(plan.contract.targetPolicy == .notApplicable)
        #expect(plan.responseFamilies == [.processGenerationObservation])
        #expect(plan.operationPolicy.typedResponse == .processGenerationObservation)
    }

    @Test
    func `Request wire is closed and cannot carry identity claims or an expected disposition`() throws {
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(Self.request())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "expected"])
        let expected = try #require(object["expected"] as? [String: Any])
        #expect(Set(expected.keys) == ["processIdentifier", "processStartIdentity"])
        #expect(expected["processStartIdentity"] as? String == "18446744073709551615")
        #expect(object["teamIdentifier"] == nil)
        #expect(object["signingIdentifier"] == nil)
        #expect(object["codeSignatureHash"] == nil)
        #expect(object["expectedDisposition"] == nil)
        #expect(object["digest"] == nil)
        #expect(object["file"] == nil)
    }

    @Test
    func `Closed request decoder rejects outer and nested unknown keys`() throws {
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let outer = Data(
            #"{"schemaVersion":1,"expected":{"processIdentifier":42,"processStartIdentity":"99"},"digest":"forbidden"}"#
                .utf8)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(PeekabooBridgeProcessGenerationObservationRequest.self, from: outer)
        }

        let nestedJSON = #"{"schemaVersion":1,"expected":{"processIdentifier":42,"# +
            #""processStartIdentity":"99","teamIdentifier":"FWJYW4S8P8"}}"#
        let nested = Data(nestedJSON.utf8)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(PeekabooBridgeProcessGenerationObservationRequest.self, from: nested)
        }
    }

    @Test
    func `Missing malformed and nonpositive identities fail closed`() throws {
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let missing = Data(#"{"schemaVersion":1,"expected":{"processIdentifier":42}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(PeekabooBridgeProcessGenerationObservationRequest.self, from: missing)
        }
        let numericStart = Data(#"{"schemaVersion":1,"expected":{"processIdentifier":42,"processStartIdentity":99}}"#
            .utf8)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(PeekabooBridgeProcessGenerationObservationRequest.self, from: numericStart)
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try PeekabooBridgeProcessGenerationObservationRequest(
                expected: .init(processIdentifier: 0, processStartIdentity: 99)).validate()
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try PeekabooBridgeProcessGenerationObservationRequest(
                schemaVersion: 2,
                expected: .init(processIdentifier: 42, processStartIdentity: 99)).validate()
        }
    }

    @Test
    func `All three dispositions have one exact identity shape and explicit null carriage`() throws {
        let request = PeekabooBridgeProcessGenerationObservationRequest(
            expected: .init(processIdentifier: 42, processStartIdentity: 99))
        let alive = Self.response(request: request, disposition: .sameGenerationAlive, observedStart: 99)
        let absent = Self.response(request: request, disposition: .exactGenerationAbsent, observedStart: nil)
        let reused = Self.response(request: request, disposition: .pidReused, observedStart: 100)
        try alive.validate(request: request)
        try absent.validate(request: request)
        try reused.validate(request: request)

        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let absentData = try encoder.encode(absent)
        let absentObject = try #require(JSONSerialization.jsonObject(with: absentData) as? [String: Any])
        #expect(Set(absentObject.keys) == [
            "schemaVersion", "expected", "disposition", "observed",
            "observationStartedAtUnixMilliseconds", "observationCompletedAtUnixMilliseconds",
        ])
        #expect(absentObject["observed"] is NSNull)
        #expect(try decoder.decode(
            PeekabooBridgeProcessGenerationObservationResponse.self,
            from: absentData) == absent)

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try Self.response(request: request, disposition: .sameGenerationAlive, observedStart: 100)
                .validate(request: request)
        }
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try Self.response(request: request, disposition: .exactGenerationAbsent, observedStart: 99)
                .validate(request: request)
        }
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try Self.response(request: request, disposition: .pidReused, observedStart: 99)
                .validate(request: request)
        }
    }

    private static func request() -> PeekabooBridgeProcessGenerationObservationRequest {
        .init(expected: .init(
            processIdentifier: 42,
            processStartIdentity: UInt64.max))
    }

    private static func response(
        request: PeekabooBridgeProcessGenerationObservationRequest,
        disposition: PeekabooBridgeProcessGenerationDisposition,
        observedStart: UInt64?) -> PeekabooBridgeProcessGenerationObservationResponse
    {
        .init(
            expected: request.expected,
            disposition: disposition,
            observed: observedStart.map {
                .init(processIdentifier: request.expected.processIdentifier, processStartIdentity: $0)
            },
            observationStartedAtUnixMilliseconds: 1000,
            observationCompletedAtUnixMilliseconds: 1001)
    }
}
