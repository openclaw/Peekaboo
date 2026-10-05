import Foundation
import Testing
@testable import PeekabooAgentRuntime

struct ToolResultNumericSafetyTests {
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, 1e100, -1e100, Double(Int.max)])
    func `unrepresentable numbers are skipped in every result representation`(_ number: Double) {
        #expect(ToolResultExtractor.int("count", from: ["count": number]) == nil)
        #expect(ToolResultExtractor.int("count", from: ["count": ["value": number]]) == nil)
        #expect(ToolResultExtractor.int("count", from: ["data": ["count": number]]) == nil)
        #expect(ToolResultExtractor.coordinates(from: ["x": number, "y": 1]) == nil)
    }

    @Test
    func `finite integer and fractional compatibility is preserved`() {
        #expect(ToolResultExtractor.int("count", from: ["count": Int.max]) == Int.max)
        #expect(ToolResultExtractor.int("count", from: ["count": 3.7]) == 3)
        #expect(ToolResultExtractor.int("count", from: ["count": -3.7]) == -3)
        #expect(ToolResultExtractor.int("count", from: ["count": "7"]) == 7)
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
}
