import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct ToolResultNumericSafetyTests {
    @Test(arguments: [
        Double.nan,
        Double.infinity,
        -Double.infinity,
        1e100,
        -1e100,
        Double(Int.max),
        Double(Int.min).nextDown,
    ])
    func `unrepresentable numbers are skipped in every result representation`(_ number: Double) {
        #expect(ToolResultExtractor.int("count", from: ["count": number]) == nil)
        #expect(ToolResultExtractor.int("count", from: ["count": ["value": number]]) == nil)
        #expect(ToolResultExtractor.int("count", from: ["data": ["count": number]]) == nil)
        #expect(ToolResultExtractor.coordinates(from: ["x": number, "y": 1]) == nil)
        #expect(ToolResultExtractor.coordinates(from: ["x": 1, "y": ["value": number]]) == nil)
        let pointer = UIAutomationToolFormatter(toolType: .move)
        #expect(pointer.formatResultSummary(result: ["target_location": ["x": number, "y": 1]]) == "→ Moved cursor")
    }

    @Test
    func `finite integer and fractional compatibility is preserved`() {
        #expect(ToolResultExtractor.int("count", from: ["count": Int.max]) == Int.max)
        #expect(ToolResultExtractor.int("count", from: ["count": Int.min]) == Int.min)
        #expect(ToolResultExtractor.int("count", from: ["count": Double(Int.min)]) == Int.min)
        #expect(ToolResultExtractor.int("count", from: ["count": Double(Int.max).nextDown]) == Int.max - 1023)
        #expect(ToolResultExtractor.int("count", from: ["count": 3.7]) == 3)
        #expect(ToolResultExtractor.int("count", from: ["count": -3.7]) == -3)
        #expect(ToolResultExtractor.int("count", from: ["count": "7"]) == 7)
        for number in [Int.min, Int.max] {
            #expect(ToolResultExtractor.int("count", from: ["count": ["value": number]]) == number)
            #expect(ToolResultExtractor.int("count", from: ["data": ["count": number]]) == number)
            #expect(ToolResultExtractor.coordinates(from: ["x": number, "y": ["value": number]])?.x == number)
        }
    }

    @Test
    func `valid JSON huge numeric count does not crash the public formatter`() throws {
        let data = Data(#"{"count":1e100}"#.utf8)
        let result = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let formatter = BaseToolFormatter(toolType: .listElements)
        #expect(formatter.formatResultSummary(result: result).isEmpty)
    }

    @Test(arguments: ["nan", "inf", "1e100", "-1e100"])
    func `invalid element frame coordinates omit position without losing the element`(_ coordinate: String) {
        let formatter = ElementToolFormatter(toolType: .findElement)
        let summary = formatter.formatResultSummary(result: [
            "found": true, "text": "owned fixture",
            "frame": ["x": coordinate, "y": "2", "width": "10", "height": "20"],
        ])
        #expect(summary.contains("owned fixture"))
        #expect(!summary.contains(" at "))
    }

    @Test
    func `element and pointer consumers preserve their different rounding policies`() {
        let element = ElementToolFormatter(toolType: .findElement)
        let pointer = UIAutomationToolFormatter(toolType: .move)
        for coordinate in [2.5, -2.5] {
            let rounded = coordinate > 0 ? 3 : -3
            let truncated = coordinate > 0 ? 2 : -2
            for value: Any in [coordinate, String(coordinate)] {
                let summary = element.formatResultSummary(result: [
                    "found": true, "text": "owned fixture",
                    "frame": ["x": value, "y": "2", "width": "10", "height": "20"],
                ])
                #expect(summary.contains("at (\(rounded), 2)"))
            }
            #expect(pointer.formatResultSummary(result: ["target_location": ["x": coordinate, "y": 2]]) ==
                "→ Moved cursor to (\(truncated), 2)")
        }
    }

    @Test
    func `pointer coordinates do not gain string wrapped or nested lookup`() {
        let formatter = UIAutomationToolFormatter(toolType: .move)
        let locations: [[String: Any]] = [
            ["x": "7", "y": "8"],
            ["x": ["value": 7], "y": ["value": 8]],
            ["data": ["x": 7, "y": 8]],
            ["metadata": ["x": 7, "y": 8]],
        ]
        for location in locations {
            #expect(formatter.formatResultSummary(result: ["target_location": location]) == "→ Moved cursor")
        }
        #expect(ToolResultExtractor.coordinates(from: ["x": "7", "y": ["value": "8"]])?.y == 8)
        #expect(ToolResultExtractor.coordinates(from: ["data": ["x": 7, "y": 8]]) == nil)
    }

    @Test
    func `invalid direct values retain lookup precedence instead of finding alternate metadata`() {
        #expect(ToolResultExtractor.int("count", from: [
            "count": Double.infinity, "data": ["count": 4], "metadata": ["count": "5"],
        ]) == nil)
        #expect(ToolResultExtractor.int("count", from: ["metadata": ["count": 4]]) == nil)
        #expect(ToolResultExtractor.int("count", from: ["metadata": ["count": "4"]]) == 4)
        #expect(ToolResultExtractor.int("count", from: [
            "count": ["value": 3.7], "metadata": ["count": "8"],
        ]) == 8)
    }

    @Test(arguments: [
        #"{"exitCode":1e100}"#, #"{"exitCode":{"value":1e100}}"#,
        #"{"data":{"exitCode":1e100}}"#, #"{"metadata":{"exitCode":"1e100"}}"#,
    ])
    func `unusable supplied exit codes cannot become successful shell summaries`(_ json: String) throws {
        var result = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let formatter = SystemToolFormatter(toolType: .shell)
        #expect(formatter.formatResultSummary(result: result) == "→ Exit status unavailable")
        #expect(formatter.formatCompleted(result: result, duration: 1) == "→ Exit status unavailable")
        let completion = formatter.formatCompleted(result: result, duration: 6)
        #expect(completion.contains("exit status unavailable"))
        #expect(!completion.contains("success"))
        #expect(!ToolResultExtractor.isSuccess(result))
        result["output"] = "owned output"
        let output = formatter.formatResultSummary(result: result)
        #expect(output.contains("• Output: owned output"))
        #expect(!output.contains("• Error:"))
    }

    @Test
    func `shell summaries preserve absent zero and nonzero exit codes`() {
        let formatter = SystemToolFormatter(toolType: .shell)
        for result: [String: Any] in [[:], ["exitCode": 0], ["data": ["exitCode": 0]]] {
            #expect(formatter.formatResultSummary(result: result) == "→ Success")
            #expect(formatter.formatCompleted(result: result, duration: 6).contains("successfully"))
            #expect(ToolResultExtractor.isSuccess(result))
        }
        #expect(formatter.formatResultSummary(result: ["exitCode": 7]) == "→ Failed (exit code: 7)")
        #expect(formatter.formatCompleted(result: ["exitCode": 7], duration: 6).contains("Command failed"))
        #expect(!ToolResultExtractor.isSuccess(["exitCode": 7]))
        #expect(ToolResultExtractor.isSuccess(["success": true, "exitCode": Double.infinity]))
        #expect(!ToolResultExtractor.isSuccess(["success": false, "exitCode": 0]))
        #expect(!ToolResultExtractor.isSuccess(["error": "owned failure", "exitCode": 0]))
    }

    @Test(arguments: [
        (#"{"metadata":{"exitCode":0}}"#, 0),
        (#"{"metadata":{"exitCode":1}}"#, 1),
        (#"{"metadata":{"exitCode":2.7}}"#, 2),
    ])
    func `numeric metadata exit codes remain available to shell consumers`(_ json: String, expected: Int) throws {
        let result = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let formatter = SystemToolFormatter(toolType: .shell)
        #expect(ToolResultExtractor.shellExitCode(from: result) == expected)
        #expect(ToolResultExtractor.isSuccess(result) == (expected == 0))
        let summary = formatter.formatResultSummary(result: result)
        #expect(summary == (expected == 0 ? "→ Success" : "→ Failed (exit code: \(expected))"))
    }

    @Test
    func `metadata fallback cannot replace a supplied invalid higher priority exit code`() {
        let invalid: [[String: Any]] = [
            ["exitCode": Double.infinity], ["exitCode": ["value": Double.infinity]],
            ["data": ["exitCode": Double.infinity]],
        ]
        for var result in invalid {
            result["metadata"] = ["exitCode": 0]
            #expect(ToolResultExtractor.shellExitCode(from: result) == nil)
        }
        #expect(ToolResultExtractor.shellExitCode(from: ["metadata": ["exitCode": Double.infinity]]) == nil)
        #expect(ToolResultExtractor.shellExitCode(from: ["metadata": ["exitCode": ["value": 0]]]) == nil)
        #expect(ToolResultExtractor.int("count", from: ["metadata": ["count": 4]]) == nil)
    }

    @Test(arguments: ["\n", "\r\n"])
    func `unavailable shell exit status does not label empty lines as error output`(_ output: String) {
        let formatter = SystemToolFormatter(toolType: .shell)
        #expect(formatter.formatResultSummary(result: ["exitCode": Double.infinity, "output": output]) ==
            "→ Exit status unavailable")
    }
}
