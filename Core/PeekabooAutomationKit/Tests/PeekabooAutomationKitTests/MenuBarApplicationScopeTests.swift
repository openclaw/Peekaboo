import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct MenuBarApplicationScopeTests {
    @Test
    func `scope and preparation preserve the explicit selector through coding`() throws {
        let scopes = try [
            MenuBarApplicationScope(applicationIdentifier: "Fixture App"),
            MenuBarApplicationScope(applicationIdentifier: "PID:42"),
            MenuBarApplicationScope(processIdentifier: 42),
        ]
        for scope in scopes {
            let request = try MenuBarItemPreparationRequest(name: "Fixture status", applicationScope: scope)
            let encoded = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(MenuBarItemPreparationRequest.self, from: encoded) == request)
        }
        #expect(scopes[0].explicitProcessIdentifier == nil)
        #expect(scopes[1].explicitProcessIdentifier == 42 && scopes[1].processIdentifier == nil)
        #expect(scopes[2].explicitProcessIdentifier == 42)
    }

    @Test
    func `invalid owner selectors and empty scoped item names refuse`() throws {
        #expect(throws: PeekabooError.self) { try MenuBarApplicationScope(applicationIdentifier: " ") }
        #expect(throws: PeekabooError.self) { try MenuBarApplicationScope(processIdentifier: 0) }
        #expect(throws: PeekabooError.self) { try MenuBarApplicationScope(processIdentifier: -1) }
        #expect(throws: PeekabooError.self) { try MenuBarApplicationScope(applicationIdentifier: "PID:0") }
        #expect(throws: PeekabooError.self) {
            try MenuBarItemPreparationRequest(name: " ", applicationScope: .init(processIdentifier: 42))
        }
        let contradictory = Data(#"{"applicationIdentifier":"Fixture","processIdentifier":42}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MenuBarApplicationScope.self, from: contradictory)
        }
    }

    @Test
    func `legacy requests omit scope while scoped requests reject mismatched PID or index`() throws {
        let evidence = try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: "fixture",
            matchKind: .exact,
            selectedProcessIdentity: .init(processIdentifier: 42, processStartIdentity: 99),
            selectedIndex: 0,
            selectedTitle: "Fixture",
            selectedRole: "AXMenuBarItem",
            selectedFrame: CGRect(x: 1, y: 1, width: 20, height: 20),
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
        let legacy = try MenuBarItemActionRequest(named: "Fixture", expectedLeafEvidence: evidence)
        let encoded = try JSONEncoder().encode(legacy)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["applicationScope"] == nil)
        #expect(try JSONDecoder().decode(MenuBarItemActionRequest.self, from: encoded) == legacy)
        for scope in try [
            MenuBarApplicationScope(processIdentifier: 43),
            MenuBarApplicationScope(applicationIdentifier: "PID:43"),
        ] {
            #expect(throws: PeekabooError.self) {
                try MenuBarItemActionRequest(named: "Fixture", expectedLeafEvidence: evidence, applicationScope: scope)
            }
        }
        let indexed = try MenuBarItemActionRequest(index: 0, expectedLeafEvidence: evidence)
        var indexedJSON = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(indexed)) as? [String: Any])
        indexedJSON["applicationScope"] = ["processIdentifier": 42]
        let scopedIndex = try JSONSerialization.data(withJSONObject: indexedJSON)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MenuBarItemActionRequest.self, from: scopedIndex)
        }
    }
}
