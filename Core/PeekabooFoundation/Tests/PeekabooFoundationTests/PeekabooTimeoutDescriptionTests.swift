import PeekabooFoundation
import Testing

struct PeekabooTimeoutDescriptionTests {
    @Test(arguments: [
        (0.2, "200 milliseconds"),
        (1.5, "1.5 seconds"),
        (20.0, "20 seconds"),
    ])
    func `timeout factory preserves the configured deadline`(duration: Double, expected: String) throws {
        let error = PeekabooError.timeout(operation: "Window readback", duration: duration)
        let description = try #require(error.errorDescription)
        #expect(description == "Operation timed out: Operation 'Window readback' timed out after \(expected)")
        #expect(error.code == .timeout)
        #expect(error.category == .automation)
        #expect(error.context["reason"]?.contains(expected) == true)
    }
}
