import Testing
@testable import PeekabooFoundation

struct CaptureErrorDescriptionTests {
    @Test
    func `subsecond detection timeout keeps millisecond precision and current CLI spelling`() throws {
        let description = try #require(CaptureError.detectionTimedOut(0.2).errorDescription)

        #expect(description.contains("after 200ms"))
        #expect(description.contains("peekaboo see --timeout 30s"))
        #expect(!description.contains("after 0s"))
        #expect(!description.contains("--timeout-seconds"))
    }

    @Test(arguments: [
        (2.5, "2.5s"),
        (20.0, "20s"),
    ])
    func `detection timeout formats whole and fractional seconds`(_ seconds: Double, _ expected: String) throws {
        let description = try #require(CaptureError.detectionTimedOut(seconds).errorDescription)

        #expect(description.contains("after \(expected)"))
    }
}
