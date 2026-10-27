import PeekabooAutomationKit
import Testing

@Suite("Duration formatting")
struct DurationFormattingTests {
    @Test(arguments: [
        (59.95, "1m 0s"),
        (59.96, "1m 0s"),
        (59.94, "59.9s"),
        (60.0, "1m 0s"),
        (90.0, "1m 30s"),
        (5.1, "5.1s"),
        (1.25, "1.2s"),
        (2.75, "2.8s"),
        (1.0, "1.0s"),
        (0.9995, "1.0s"),
        (0.9994, "999ms"),
        (0.0625, "62ms"),
        (0.001, "1ms"),
        (0.0009995, "1ms"),
        (0.0009994, "999µs"),
        (0.0, "0µs"),
    ])
    func `finite duration labels stay inside the unit they claim`(seconds: Double, expected: String) {
        #expect(formatDuration(seconds) == expected)
    }

    @Test(arguments: [
        (59.95, "1min 0s"),
        (59.96, "1min 0s"),
        (60.0, "1min 0s"),
        (90.0, "1min 30s"),
        (5.1, "5.1s"),
        (0.9995, "1.0s"),
        (0.0009995, "1ms"),
    ])
    func `detailed duration labels use the same unit boundaries`(seconds: Double, expected: String) {
        #expect(formatDetailedDuration(seconds) == expected)
    }

    @Test(arguments: [
        Double.nan,
        Double.infinity,
        -Double.infinity,
        Double.greatestFiniteMagnitude,
        60 * Double(Int.max),
    ])
    func `unrepresentable durations stay readable`(seconds: Double) {
        #expect(formatDuration(seconds) == "an unknown duration")
        #expect(formatDetailedDuration(seconds) == "an unknown duration")
    }
}
