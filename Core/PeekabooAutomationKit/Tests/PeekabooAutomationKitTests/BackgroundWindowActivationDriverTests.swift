import Testing
@testable import PeekabooAutomationKit

@MainActor
struct BackgroundWindowActivationDriverTests {
    @Test
    func `target-only record names one exact window and no front-process operation`() {
        let record = BackgroundWindowActivationDriver.eventRecord(windowID: 0x1234_5678)
        #expect(record.count == 0xF8)
        #expect(record[0x04] == 0xF8)
        #expect(record[0x08] == 0x0D)
        #expect(record[0x8A] == 1)
        #expect(Array(record[0x3C..<0x40]) == [0x78, 0x56, 0x34, 0x12])
        let populated: Set = [0x04, 0x08, 0x8A, 0x3C, 0x3D, 0x3E, 0x3F]
        #expect(record.indices.allSatisfy { populated.contains($0) || record[$0] == 0 })
    }
}
