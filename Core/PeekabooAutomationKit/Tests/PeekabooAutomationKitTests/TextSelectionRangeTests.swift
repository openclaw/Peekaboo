import ApplicationServices
import Foundation
import Testing
@testable import PeekabooAutomationKit

struct TextSelectionRangeTests {
    @Test
    func `native and JSON ranges use UTF16 and preserve a collapsed caret`() throws {
        for pair in [(1, 2), (4, 0)] {
            var native = CFRange(location: pair.0, length: pair.1)
            let value = try #require(AXValueCreate(.cfRange, &native))
            let range = try #require(TextSelectionRange(nativeValue: value))
            #expect(range.location == pair.0)
            #expect(range.length == pair.1)
            #expect(range.nativeRange.location == pair.0)
            #expect(range.nativeRange.length == pair.1)
            #expect(try JSONDecoder().decode(TextSelectionRange.self, from: JSONEncoder().encode(range)) == range)
        }
        let range = try #require(TextSelectionRange(location: 1, length: 2))
        #expect(("A😀B" as NSString).substring(with: NSRange(location: range.location, length: range.length)) == "😀")
    }

    @Test
    func `malformed unknown and overflowing ranges are rejected at every decode boundary`() throws {
        for pair in [(-1, 0), (0, -1), (NSNotFound, 0), (0, NSNotFound), (Int.max - 1, 2)] {
            #expect(TextSelectionRange(location: pair.0, length: pair.1) == nil)
            var native = CFRange(location: pair.0, length: pair.1)
            #expect(TextSelectionRange(nativeValue: AXValueCreate(.cfRange, &native)) == nil)
            let data = try JSONSerialization.data(withJSONObject: ["location": pair.0, "length": pair.1])
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(TextSelectionRange.self, from: data) }
        }
        var point = CGPoint(x: 1, y: 2)
        #expect(TextSelectionRange(nativeValue: AXValueCreate(.cgPoint, &point)) == nil)
        #expect(TextSelectionRange(nativeValue: "1,2" as CFString) == nil)
        #expect(TextSelectionRange(nativeValue: nil) == nil)
    }

    @Test
    func `selection attributes are typed without changing the stored element shape`() throws {
        let field = DetectedElement(
            id: "field",
            type: .textField,
            value: "A😀B",
            bounds: CGRect(x: 1, y: 2, width: 50, height: 20),
            attributes: ["role": "AXTextField", "isFocused": "true"])
        let range = try #require(TextSelectionRange(location: 1, length: 2))
        let selected = field.replacingSelectedTextRange(range)
        #expect(selected.selectedTextRange == range)
        #expect(selected.value == field.value)
        #expect(selected.bounds == field.bounds)
        let decoded = try JSONDecoder().decode(DetectedElement.self, from: JSONEncoder().encode(selected))
        #expect(decoded.selectedTextRange == range)
        #expect(decoded.replacingSelectedTextRange(nil).attributes == field.attributes)
        for attributes in [
            ["selectedTextRangeLocation": "1"],
            ["selectedTextRangeLocation": "0", "selectedTextRangeLength": "-1"],
            ["selectedTextRangeLocation": "invalid", "selectedTextRangeLength": "2"],
        ] {
            let invalid = DetectedElement(
                id: "field",
                type: .textField,
                bounds: field.bounds,
                attributes: field.attributes.merging(attributes) { _, new in new })
            #expect(invalid.selectedTextRange == nil)
        }
    }

    @Test(arguments: ["role", "subrole", "isFocused"])
    func `secure and unfocused fields never project stored selection`(key: String) {
        var attributes = [
            "role": "AXTextField",
            "isFocused": "true",
            "selectedTextRangeLocation": "1",
            "selectedTextRangeLength": "2",
        ]
        attributes[key] = key == "isFocused" ? "false" : "AXSecureTextField"
        let element = DetectedElement(
            id: "field",
            type: .textField,
            bounds: CGRect(x: 1, y: 2, width: 50, height: 20),
            attributes: attributes)
        #expect(element.selectedTextRange == nil)
    }
}
