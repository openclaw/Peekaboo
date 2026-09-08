import Foundation
import Testing

@Suite(.serialized)
struct StandardOutputCaptureTests {
    @Test
    func `Output larger than pipe capacity is captured completely`() async throws {
        let payload = String(repeating: "x", count: 1024 * 1024)
        let output = try await captureStandardOutputText {
            print(payload, terminator: "")
        }
        #expect(output == payload)
    }

    @Test
    func `Throwing producers restore stdout for later captures`() async throws {
        enum ExpectedFailure: Error { case failed }
        do {
            _ = try await captureStandardOutputText {
                print("discarded")
                throw ExpectedFailure.failed
            }
            Issue.record("Expected the producer failure")
        } catch ExpectedFailure.failed {}
        let output = try await captureStandardOutputText {
            print("next capture")
        }
        #expect(output == "next capture\n")
    }
}
