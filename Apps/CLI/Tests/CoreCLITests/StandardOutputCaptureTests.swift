import Foundation
import Testing

@Suite(.serialized)
struct StandardOutputCaptureTests {
    @Test
    func `Overlapping captures keep their output separate`() async throws {
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<10 {
                group.addTask {
                    let output = try await captureStandardOutputText {
                        print("start-\(index)")
                        await Task.yield()
                        print("end-\(index)")
                    }
                    return (index, output)
                }
            }
            var results: [(Int, String)] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }
        #expect(results.count == 10)
        for (index, output) in results {
            #expect(output == "start-\(index)\nend-\(index)\n")
        }
    }

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
