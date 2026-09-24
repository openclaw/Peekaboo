import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DialogHierarchyAttributeTests {
    @Test(arguments: [AXError.attributeUnsupported, .noValue])
    func `unsupported or absent optional attributes stay absent`(_ error: AXError) throws {
        let title: String? = try DialogHierarchyReader.attributeValue(nil, error: error)
        let modal: Bool? = try DialogHierarchyReader.attributeValue(nil, error: error)
        let children: [AXUIElement]? = try DialogHierarchyReader.attributeValue(nil, error: error)

        #expect(title == nil)
        #expect(modal == nil)
        #expect(children == nil)
    }

    @Test(arguments: [AXError.attributeUnsupported, .noValue])
    func `absence status never admits a supplied payload`(_ error: AXError) throws {
        let title: String? = try DialogHierarchyReader.attributeValue("stale title" as CFString, error: error)
        let children: [AXUIElement]? = try DialogHierarchyReader.attributeValue(NSNull(), error: error)

        #expect(title == nil)
        #expect(children == nil)
    }

    @Test(arguments: [
        AXError.cannotComplete,
        .apiDisabled,
        .failure,
        .invalidUIElement,
        .illegalArgument,
        .notImplemented,
        .parameterizedAttributeUnsupported,
    ])
    func `AX read errors are unreadable rather than absent`(_ error: AXError) {
        Self.expectUnreadable(String.self, error: error)
        Self.expectUnreadable([AXUIElement].self, error: error)
    }

    @Test(arguments: [AXError.cannotComplete, .apiDisabled, .failure])
    func `failed read never admits an otherwise valid payload`(_ error: AXError) {
        Self.expectUnreadable(String.self, value: "AXSheet" as CFString, error: error)
        Self.expectUnreadable([AXUIElement].self, value: NSArray(), error: error)
    }

    @Test
    func `successful typed values preserve their contents`() throws {
        let title: String? = try DialogHierarchyReader.attributeValue("  Confirmation  " as CFString, error: .success)
        let emptyTitle: String? = try DialogHierarchyReader.attributeValue("" as CFString, error: .success)
        let modal: Bool? = try DialogHierarchyReader.attributeValue(kCFBooleanTrue, error: .success)
        let modeless: Bool? = try DialogHierarchyReader.attributeValue(kCFBooleanFalse, error: .success)
        let children: [AXUIElement]? = try DialogHierarchyReader.attributeValue(NSArray(), error: .success)

        #expect(title == "  Confirmation  ")
        #expect(emptyTitle?.isEmpty == true)
        #expect(modal == true)
        #expect(modeless == false)
        let resolvedChildren = try #require(children)
        #expect(resolvedChildren.isEmpty)
    }

    @Test
    func `successful status with no payload is unreadable for every attribute shape`() {
        Self.expectUnreadable(String.self)
        Self.expectUnreadable(Bool.self)
        Self.expectUnreadable([AXUIElement].self)
    }

    @Test
    func `null values are not optional absence after a successful read`() {
        Self.expectUnreadable(String.self, value: NSNull())
        Self.expectUnreadable(Bool.self, value: NSNull())
        Self.expectUnreadable([AXUIElement].self, value: NSNull())
    }

    @Test
    func `successful scalar reads reject incompatible payload types`() {
        Self.expectUnreadable(String.self, value: NSNumber(value: 42))
        Self.expectUnreadable(String.self, value: NSArray(array: ["AXSheet"]))
        Self.expectUnreadable(Bool.self, value: "true" as CFString)
        Self.expectUnreadable(Bool.self, value: NSNumber(value: 1))
        Self.expectUnreadable(Bool.self, value: NSDictionary())
    }

    @Test
    func `successful children read requires an array containing only AX elements`() {
        Self.expectUnreadable([AXUIElement].self, value: "AXSheet" as CFString)
        Self.expectUnreadable([AXUIElement].self, value: NSDictionary())
        Self.expectUnreadable([AXUIElement].self, value: NSArray(array: ["not an AX element"]))
        Self.expectUnreadable([AXUIElement].self, value: NSArray(array: [NSNull()]))
    }

    private static func expectUnreadable<Value>(
        _: Value.Type,
        value: CFTypeRef? = nil,
        error: AXError = .success)
    {
        let failure = #expect(throws: PeekabooError.self) {
            let _: Value? = try DialogHierarchyReader.attributeValue(value, error: error)
        }
        guard let failure else { return }
        guard case .accessibilityIncomplete = failure else {
            Issue.record("Expected an unreadable attribute failure, received \(failure)")
            return
        }
    }
}
