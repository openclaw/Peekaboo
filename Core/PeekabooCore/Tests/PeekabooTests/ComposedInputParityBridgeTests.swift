import Testing
@testable import PeekabooBridge

struct ComposedInputParityBridgeTests {
    @Test
    func `protocol 1 33 exclusively advertises composed input parity operations`() {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 32)
        let current = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let operations: Set<PeekabooBridgeOperation> = [
            .permissionsStatus,
            .exactWindowPixelFocusType,
            .foregroundModifierClick,
        ]

        #expect(PeekabooBridgeConstants.protocolVersion == current)
        #expect(PeekabooBridgeConstants.composedInputParityVersion == current)
        #expect(PeekabooBridgeOperation.compatible(operations, with: previous) == [.permissionsStatus])
        #expect(PeekabooBridgeOperation.compatible(operations, with: current) == operations)
    }
}
