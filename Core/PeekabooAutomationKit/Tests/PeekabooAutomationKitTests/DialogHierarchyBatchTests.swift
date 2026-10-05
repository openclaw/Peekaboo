import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DialogHierarchyBatchTests {
    private let structuralNames = ["AXRole", "AXSubrole", "AXSheets", "AXChildren"]
    private let descriptorNames = ["AXRoleDescription", "AXIdentifier", "AXTitle", "AXModal"]

    @Test
    func `ordinary controls use one batch without losing sheet or child order`() throws {
        let sheet = AXUIElementCreateApplication(948_001)
        let child = AXUIElementCreateApplication(948_002)
        var batches: [[String]] = []
        let node = try DialogHierarchyReader.readBatchedNode(
            budget: self.budget(),
            copyAttributes: { names in
                batches.append(names)
                return (NSArray(array: ["AXGroup", self.errorValue(.noValue), [sheet], [child, sheet]]), .success)
            },
            copyAttribute: { _ in
                Issue.record("Complete batch must not use individual reads")
                return (nil, .failure)
            })
        #expect(batches == [self.structuralNames])
        #expect(node.evidence.role == "AXGroup")
        #expect(node.children.count == 3)
        #expect(CFEqual(node.children[0].element, sheet))
        #expect(CFEqual(node.children[1].element, child))
        #expect(CFEqual(node.children[2].element, sheet))
    }

    @Test(arguments: [("AXGroup", "AXAlert"), ("AXWindow", ""), ("AXUnknown", "")])
    func `eligible nodes add one descriptor batch`(role: String, subrole: String) throws {
        var batches: [[String]] = []
        let node = try DialogHierarchyReader.readBatchedNode(
            budget: self.budget(),
            copyAttributes: { names in
                batches.append(names)
                if names == self.structuralNames {
                    return (NSArray(array: [role, subrole, [], []]), .success)
                }
                return (NSArray(array: ["dialog", "NSOpenPanel", "Open", kCFBooleanTrue!]), .success)
            },
            copyAttribute: { _ in
                Issue.record("Complete batch must not use individual reads")
                return (nil, .failure)
            })
        #expect(batches == [self.structuralNames, self.descriptorNames])
        #expect(node.evidence.title == "Open")
        #expect(node.evidence.isModal == true)
    }

    @Test(arguments: [AXError.noValue, .attributeUnsupported])
    func `embedded optional absence does not need clarification`(_ error: AXError) throws {
        let node = try self.readGroup(subrole: self.errorValue(error)) { _ in
            Issue.record("Embedded AX errors already establish the exact absence status")
            return (nil, .failure)
        }
        #expect(node.evidence.subrole.isEmpty)
    }

    @Test(arguments: [AXError.cannotComplete, .failure, .notImplemented, .parameterizedAttributeUnsupported])
    func `per-slot errors retain strict dialog semantics`(_ error: AXError) throws {
        #expect(throws: PeekabooError.self) {
            try self.readGroup(subrole: self.errorValue(error)) { _ in
                Issue.record("Hard per-slot errors must not be retried")
                return (nil, .noValue)
            }
        }
    }

    @Test(arguments: [AXError.noValue, .attributeUnsupported])
    func `ambiguous null clarifies only its own slot`(_ error: AXError) throws {
        var reads: [String] = []
        let node = try self.readGroup(subrole: NSNull()) { name in
            reads.append(name)
            return (nil, error)
        }
        #expect(reads == ["AXSubrole"])
        #expect(node.evidence.subrole.isEmpty)
    }

    @Test(arguments: [AXError.success, .cannotComplete, .failure])
    func `null clarification cannot hide malformed success or transport failure`(_ error: AXError) throws {
        #expect(throws: PeekabooError.self) {
            try self.readGroup(subrole: NSNull()) { _ in (NSNull(), error) }
        }
    }

    @Test(arguments: [AXError.attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented])
    func `unsupported batch APIs use the existing individual contract`(_ error: AXError) throws {
        try self.expectSingleReadFallback(value: nil, error: error)
    }

    @Test
    func `missing malformed and short successful arrays cannot shift attribute positions`() throws {
        for value: CFTypeRef? in [nil, NSNull(), "not an array" as CFString, NSArray(array: ["AXGroup"])] {
            try self.expectSingleReadFallback(value: value, error: .success)
        }
    }

    @Test(arguments: [AXError.noValue, .failure, .cannotComplete, .apiDisabled, .illegalArgument])
    func `hard outer failures never fall back to new AX requests`(_ error: AXError) throws {
        #expect(throws: PeekabooError.self) {
            try DialogHierarchyReader.readBatchedNode(
                budget: self.budget(),
                copyAttributes: { _ in (nil, error) },
                copyAttribute: { _ in
                    Issue.record("Outer failure must refuse, not retry individual attributes")
                    return (nil, .noValue)
                })
        }
    }

    @Test
    func `expired batch deadline prevents every fallback read`() throws {
        let budget = try DialogOperationDeadline.bounded(timeoutSeconds: 0.01, operationName: "batch timeout")
        #expect(throws: PeekabooError.self) {
            try DialogHierarchyReader.readBatchedNode(
                budget: budget,
                copyAttributes: { _ in
                    Thread.sleep(forTimeInterval: 0.02)
                    return (nil, .notImplemented)
                },
                copyAttribute: { _ in
                    Issue.record("An expired batch must not start fallback work")
                    return (nil, .noValue)
                })
        }
    }

    @Test
    func `batched payloads still pass through typed validation`() throws {
        for subrole: CFTypeRef in [NSNumber(value: 1), NSArray(), NSDictionary()] {
            #expect(throws: PeekabooError.self) {
                try self.readGroup(subrole: subrole) { _ in (nil, .noValue) }
            }
        }
        #expect(throws: PeekabooError.self) {
            try DialogHierarchyReader.readBatchedNode(
                budget: self.budget(),
                copyAttributes: { names in
                    if names == self.structuralNames {
                        return (NSArray(array: ["AXWindow", "", [], ["not an AX element"]]), .success)
                    }
                    return (NSArray(array: ["dialog", "", "Save", NSNumber(value: 1)]), .success)
                },
                copyAttribute: { _ in (nil, .noValue) })
        }
    }

    private func readGroup(
        subrole: CFTypeRef,
        copyAttribute: (String) -> DialogHierarchyReader.AttributeRead) throws -> DialogHierarchyReader.RawNode
    {
        try DialogHierarchyReader.readBatchedNode(
            budget: self.budget(),
            copyAttributes: { _ in (NSArray(array: ["AXGroup", subrole, [], []]), .success) },
            copyAttribute: copyAttribute)
    }

    private func expectSingleReadFallback(value: CFTypeRef?, error: AXError) throws {
        var reads: [String] = []
        let node = try DialogHierarchyReader.readBatchedNode(
            budget: self.budget(),
            copyAttributes: { _ in (value, error) },
            copyAttribute: { name in
                reads.append(name)
                return name == "AXRole" ? ("AXGroup" as CFString, .success) : (nil, .noValue)
            })
        #expect(reads == self.structuralNames)
        #expect(node.evidence.role == "AXGroup")
    }

    private func errorValue(_ error: AXError) -> AXValue {
        var error = error
        return AXValueCreate(.axError, &error)!
    }

    private func budget() throws -> DialogOperationDeadline {
        try .bounded(timeoutSeconds: 1, operationName: "dialog batch fixture")
    }
}
