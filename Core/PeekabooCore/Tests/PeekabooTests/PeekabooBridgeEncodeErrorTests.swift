import Foundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeEncodeErrorTests {
    private enum EncodingFailure: Error {
        case forced
    }

    @Test
    func `encodeError preserves arbitrary JSON control characters`() throws {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .decodingFailed,
            message: "Failed \"decode\" \\ \u{0000} \u{0008} \u{000C}\n",
            details: "unexpected\tend\r")

        let data = PeekabooBridgeResponse.encodeError(envelope)

        #expect(!data.isEmpty)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .error(decodedEnvelope) = decoded else {
            Issue.record("Expected error response, got \(decoded)")
            return
        }
        #expect(decodedEnvelope.code == .decodingFailed)
        #expect(decodedEnvelope.message == envelope.message)
        #expect(decodedEnvelope.details == envelope.details)
    }

    @Test
    func `encodeError uses decodable fallback when encoding throws`() throws {
        let envelope = PeekabooBridgeErrorEnvelope(code: .decodingFailed, message: "Ignored")

        let data = PeekabooBridgeResponse.encodeError(envelope) { _ in
            throw EncodingFailure.forced
        }

        try self.expectFallback(data)
    }

    @Test
    func `encodeError uses decodable fallback when encoding returns empty data`() throws {
        let envelope = PeekabooBridgeErrorEnvelope(code: .decodingFailed, message: "Ignored")

        let data = PeekabooBridgeResponse.encodeError(envelope) { _ in Data() }

        try self.expectFallback(data)
    }

    private func expectFallback(_ data: Data) throws {
        #expect(!data.isEmpty)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .error(envelope) = decoded else {
            Issue.record("Expected fallback error response, got \(decoded)")
            return
        }
        #expect(envelope.code == .internalError)
        #expect(envelope.message == "Failed to encode bridge error response")
        #expect(envelope.details == nil)
        #expect(!envelope.operationMayHaveCompleted)
    }

    @Test
    func `decodeAndHandle never returns empty data for malformed request`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }

        let responseData = await server.decodeAndHandle(Data("not-json".utf8), peer: nil)

        #expect(!responseData.isEmpty)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        guard case let .error(envelope) = decoded else {
            Issue.record("Expected error response for malformed request, got \(decoded)")
            return
        }
        #expect(envelope.code == .decodingFailed)
    }

    @Test
    func `only element and snapshot not-found kinds are classified pre-dispatch`() {
        #expect(Self.envelope(kind: .elementNotFound).failedBeforeDispatchingDesktopEvent)
        #expect(Self.envelope(kind: .snapshotNotFound).failedBeforeDispatchingDesktopEvent)
        // Host raises snapshotStale from action execution, so it is not pre-dispatch.
        #expect(!Self.envelope(kind: .snapshotStale).failedBeforeDispatchingDesktopEvent)
        // Dock/menu menuNotFound arrives as a generic notFound/internal envelope with no kind and
        // must NOT be trusted as pre-dispatch.
        #expect(!Self.envelope(code: .notFound, kind: nil).failedBeforeDispatchingDesktopEvent)
        #expect(!Self.envelope(code: .internalError, kind: nil).failedBeforeDispatchingDesktopEvent)
    }

    @Test
    func `operationMayHaveCompleted overrides an otherwise pre-dispatch kind`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .notFound,
            message: "elem",
            kind: .elementNotFound,
            operationMayHaveCompleted: true)
        #expect(!envelope.failedBeforeDispatchingDesktopEvent)
    }

    private static func envelope(
        code: PeekabooBridgeErrorCode = .notFound,
        kind: PeekabooBridgeErrorKind?) -> PeekabooBridgeErrorEnvelope
    {
        PeekabooBridgeErrorEnvelope(code: code, message: "test", kind: kind)
    }
}
