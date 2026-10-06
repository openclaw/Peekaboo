import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct ExactFileDialogWireTests {
    @Test
    func `typed file payload round trips the full selector and focus policy`() throws {
        let execution = try DialogFileExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            path: "/tmp/fixture",
            filename: "receipt.txt",
            actionButton: "Save",
            ensureExpanded: true,
            focus: DialogForegroundFocusPolicy(
                autoFocus: false,
                timeout: 2.5,
                retryCount: 4,
                switchSpace: true,
                bringToCurrentSpace: false))
        let wire = PeekabooBridgeRequest.dialogHandleFile(.init(execution: execution))
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(wire)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)

        guard case let .dialogHandleFile(payload) = decoded else {
            Issue.record("Expected the existing dialogHandleFile operation with a typed body")
            return
        }
        #expect(payload.execution == execution)
        #expect(payload.path == nil)
        #expect(payload.appName == nil)
        #expect(decoded.requiresExactFileDialogExecution)
        #expect(decoded.minimumNegotiatedProtocolVersion == PeekabooBridgeConstants.exactFileDialogExecutionVersion)
        #expect(PeekabooBridgeConstants.exactFileDialogExecutionVersion == .init(major: 1, minor: 43))
        #expect(PeekabooBridgeHostCapability.exactFileDialogExecution == "exactFileDialogExecution")
    }

    @Test
    func `legacy file payload keeps its original wire shape`() throws {
        let data = Data(#"{"path":"/tmp","filename":"old.txt","ensureExpanded":true,"appName":"Fixture"}"#.utf8)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeDialogHandleFileRequest.self, from: data)
        #expect(decoded.execution == nil)
        #expect(decoded.path == "/tmp")
        #expect(decoded.filename == "old.txt")
        #expect(decoded.ensureExpanded == true)
        #expect(decoded.appName == "Fixture")
        let encoded = try JSONEncoder.peekabooBridgeEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["execution"] == nil)
        #expect(Set(object.keys) == ["path", "filename", "ensureExpanded", "appName"])
        #expect(!PeekabooBridgeRequest.dialogHandleFile(decoded).requiresExactFileDialogExecution)
    }

    @Test
    func `typed file payload rejects null execution and mixed legacy keys`() throws {
        let execution = try DialogFileExecutionRequest(target: DialogTargetSelector(windowID: 700))
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeDialogHandleFileRequest(execution: execution))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for legacyKey in ["path", "filename", "actionButton", "ensureExpanded", "appName"] {
            var mixed = object
            mixed[legacyKey] = NSNull()
            let mixedData = try JSONSerialization.data(withJSONObject: mixed)
            #expect(throws: (any Error).self) {
                try JSONDecoder.peekabooBridgeDecoder().decode(
                    PeekabooBridgeDialogHandleFileRequest.self, from: mixedData)
            }
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeDialogHandleFileRequest.self, from: Data(#"{"execution":null}"#.utf8))
        }
    }

    @Test
    func `typed file success semantics are exact foreground and counted without enabling legacy success`() throws {
        let execution = try DialogFileExecutionRequest(target: DialogTargetSelector(windowID: 700))
        let typed = PeekabooBridgeOperationResultSemantics.semanticPlan(
            for: .dialogHandleFile(.init(execution: execution)))
        let legacy = PeekabooBridgeOperationResultSemantics.semanticPlan(
            for: .dialogHandleFile(.init(
                path: nil, filename: nil, actionButton: nil, ensureExpanded: nil, appName: nil)))

        #expect(typed.contract.targetPolicy == .responseResolved)
        #expect(typed.successResponsePolicy == .ordinary)
        #expect(typed.allowedSuccessStates == [.confirmedChange, .dispatchedUnverified])
        #expect(legacy.successResponsePolicy == .errorOnly)
        #expect(typed.successfulDeliveryRules.count == 6)
        for rule in typed.successfulDeliveryRules {
            #expect(rule.delivery.mode == .foreground)
            #expect(rule.units == .positive)
            #expect(!rule.units.acceptsSuccessful(nil))
            #expect(rule.units.acceptsSuccessful(.init(3)))
        }
        #expect(typed.deliveryRule(for: .init(mechanism: .accessibilityValue, mode: .background)) == nil)
    }
}
