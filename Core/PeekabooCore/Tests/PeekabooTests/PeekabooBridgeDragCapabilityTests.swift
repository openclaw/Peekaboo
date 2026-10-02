import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing

struct PeekabooBridgeDragCapabilityTests {
    private static let requiredCapabilities = [
        PeekabooBridgeHostCapability.exactWindowDrag,
        PeekabooBridgeHostCapability.attestedOperationReceipts,
    ]

    @Test(arguments: [38, 39, 40])
    func `drag support preserves every negotiated gate`(minor: Int) {
        let capabilities: [(names: [String]?, complete: Bool)] = [
            (nil, false),
            ([], false),
            ([PeekabooBridgeHostCapability.exactWindowDrag], false),
            ([PeekabooBridgeHostCapability.attestedOperationReceipts], false),
            (Self.requiredCapabilities, true),
        ]
        let enabledOptions: [[PeekabooBridgeOperation]?] = [nil, [], [.drag], [.exactWindowDrag]]
        for advertised in [false, true] {
            let supported: [PeekabooBridgeOperation] = advertised ? [.drag, .exactWindowDrag] : [.drag]
            for enabled in enabledOptions where advertised || enabled != [.exactWindowDrag] {
                for capability in capabilities {
                    let handshake = BridgeTestFixtures.handshake(
                        negotiatedVersion: .init(major: 1, minor: minor),
                        supportedOperations: supported,
                        enabledOperations: enabled,
                        hostCapabilities: capability.names)
                    let expected = minor >= 39 && capability.complete && advertised &&
                        (enabled == nil || enabled == [.exactWindowDrag])
                    #expect(handshake.supportsExactWindowDrag == expected)
                }
            }
        }
    }

    @Test
    func `an enabled but unadvertised drag cannot grant support`() throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 39),
            supportedOperations: [.exactWindowDrag],
            enabledOperations: [.exactWindowDrag],
            hostCapabilities: Self.requiredCapabilities)
        var wire = try JSONDecoder().decode(
            [String: PeekabooBridgeJSONValue].self,
            from: JSONEncoder().encode(handshake))
        wire["supportedOperations"] = .array([])
        let malformed = try JSONDecoder().decode(
            PeekabooBridgeHandshakeResponse.self,
            from: JSONEncoder().encode(wire))

        #expect(!malformed.supportsExactWindowDrag)
    }

    @Test(arguments: [false, true])
    func `derived support keeps wire shape and omitted enabled fallback`(explicitlyDisabled: Bool) throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 39),
            supportedOperations: [.exactWindowDrag],
            enabledOperations: explicitlyDisabled ? [] : nil,
            hostCapabilities: Self.requiredCapabilities)
        let data = try JSONEncoder().encode(handshake)
        let wire = try JSONDecoder().decode([String: PeekabooBridgeJSONValue].self, from: data)
        let decoded = try JSONDecoder().decode(PeekabooBridgeHandshakeResponse.self, from: data)

        #expect(wire["supportsExactWindowDrag"] == nil)
        #expect((wire["enabledOperations"] != nil) == explicitlyDisabled)
        #expect(decoded.supportsExactWindowDrag == !explicitlyDisabled)
    }
}
