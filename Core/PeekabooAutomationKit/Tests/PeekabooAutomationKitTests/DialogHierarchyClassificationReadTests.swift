import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DialogHierarchyClassificationReadTests {
    @Test(arguments: ["AXGroup", "AXButton", "AXStaticText", "AXTextField"])
    func `ineligible controls omit descriptive reads but preserve descendants`(role: String) throws {
        let child = AXUIElementCreateApplication(947_001)
        var reads: [String] = []
        let node = try DialogHierarchyReader.readNode(budget: self.budget()) { name in
            reads.append(name)
            switch name {
            case "AXRole": return (role as CFString, .success)
            case "AXSubrole": return (nil, .attributeUnsupported)
            case "AXSheets": return ([child] as CFArray, .success)
            case "AXChildren": return (nil, .noValue)
            default:
                Issue.record("Unexpected descriptive read on an ineligible control: \(name)")
                return (nil, .cannotComplete)
            }
        }
        #expect(reads == ["AXRole", "AXSubrole", "AXSheets", "AXChildren"])
        #expect(node.evidence.role == role)
        #expect(node.children.count == 1)
        #expect(CFEqual(node.children[0].element, child))
    }

    @Test(arguments: [("AXGroup", "AXAlert"), ("AXWindow", ""), ("AXUnknown", ""), ("AXSheet", "")])
    func `structural subroles and compatible windows retain classification reads`(
        role: String,
        subrole: String) throws
    {
        var reads: [String] = []
        let node = try DialogHierarchyReader.readNode(budget: self.budget()) { name in
            reads.append(name)
            switch name {
            case "AXRole": return (role as CFString, .success)
            case "AXSubrole": return (subrole as CFString, .success)
            case "AXRoleDescription": return ("dialog" as CFString, .success)
            case "AXIdentifier": return ("NSOpenPanel" as CFString, .success)
            case "AXTitle": return ("Open" as CFString, .success)
            case "AXModal": return (kCFBooleanTrue, .success)
            default: return (nil, .noValue)
            }
        }
        #expect(reads == [
            "AXRole",
            "AXSubrole",
            "AXRoleDescription",
            "AXIdentifier",
            "AXTitle",
            "AXModal",
            "AXSheets",
            "AXChildren",
        ])
        #expect(node.evidence.title == "Open")
        #expect(node.evidence.isModal == true)
    }

    @Test(arguments: ["AXRole", "AXSubrole", "AXSheets", "AXChildren"])
    func `failed required reads cannot hide dialog descendants`(failed: String) throws {
        #expect(throws: PeekabooError.self) {
            try DialogHierarchyReader.readNode(budget: self.budget()) { name in
                if name == failed {
                    return (nil, .cannotComplete)
                }
                if name == "AXRole" {
                    return ("AXGroup" as CFString, .success)
                }
                return (nil, .noValue)
            }
        }
    }

    private func budget() throws -> DialogOperationDeadline {
        try .bounded(timeoutSeconds: 1, operationName: "hierarchy classification fixture")
    }
}
