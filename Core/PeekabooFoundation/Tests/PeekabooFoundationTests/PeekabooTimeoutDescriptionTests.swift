import PeekabooFoundation
import Testing

struct PeekabooTimeoutDescriptionTests {
    @Test(arguments: [
        (0.0001, "1 milliseconds"),
        (0.0005, "1 milliseconds"),
        (0.0015, "2 milliseconds"),
        (0.2, "200 milliseconds"),
        (0.9996, "1000 milliseconds"),
        (1.0, "1 seconds"),
        (1.5, "1.5 seconds"),
        (20.0, "20 seconds"),
        (0.0, "0 seconds"),
        (-0.25, "-0.25 seconds"),
        (-2.0, "-2 seconds"),
    ])
    func `timeout factory preserves the configured deadline`(duration: Double, expected: String) throws {
        let error = PeekabooError.timeout(operation: "Window readback", duration: duration)
        let description = try #require(error.errorDescription)
        #expect(description == "Operation timed out: Operation 'Window readback' timed out after \(expected)")
        #expect(error.code == .timeout)
        #expect(error.category == .automation)
        #expect(error.context["reason"]?.contains(expected) == true)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude, Double(Int.max)])
    func `diagnostic formatting does not trap on unrepresentable durations`(duration: Double) {
        let error = PeekabooError.timeout(operation: "Synthetic duration", duration: duration)
        #expect(error.errorDescription ==
            "Operation timed out: Operation 'Synthetic duration' timed out after \(duration) seconds")
        #expect(error.code == .timeout)
        #expect(error.category == .automation)
    }
}
