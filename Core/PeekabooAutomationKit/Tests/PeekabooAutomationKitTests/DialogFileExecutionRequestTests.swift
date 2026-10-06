import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DialogFileExecutionRequestTests {
    @Test
    func `file execution round trips all selector and focus constraints`() throws {
        let request = try DialogFileExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 42, windowID: 700),
            path: "/owned fixture",
            filename: "résumé.txt",
            actionButton: "Save",
            ensureExpanded: true,
            focus: DialogForegroundFocusPolicy(
                autoFocus: false, timeout: 1.25, retryCount: 2, switchSpace: true, bringToCurrentSpace: true))
        #expect(try JSONDecoder().decode(
            DialogFileExecutionRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test
    func `exact file execution rejects an absent target`() throws {
        let target = try DialogTargetSelector()
        #expect(throws: DesktopActionFailure.self) {
            try DialogFileExecutionRequest(target: target)
        }
    }

    @Test(arguments: [0.0, -1.0, .infinity, .nan])
    func `file focus policy rejects invalid timeouts`(timeout: Double) throws {
        let target = try DialogTargetSelector(processIdentifier: 42)
        #expect(throws: PeekabooError.self) {
            try DialogFileExecutionRequest(target: target, focus: .init(timeout: timeout))
        }
    }

    @Test
    func `decoding cannot bypass selector or focus validation`() throws {
        let request = try DialogFileExecutionRequest(target: DialogTargetSelector(processIdentifier: 42))
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var noTarget = object
        noTarget["target"] = [:] as [String: Any]
        var invalidFocus = object
        var focus = try #require(object["focus"] as? [String: Any])
        focus["retryCount"] = 0
        invalidFocus["focus"] = focus
        for invalid in [noTarget, invalidFocus] {
            let encoded = try JSONSerialization.data(withJSONObject: invalid)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(DialogFileExecutionRequest.self, from: encoded)
            }
        }
    }
}
