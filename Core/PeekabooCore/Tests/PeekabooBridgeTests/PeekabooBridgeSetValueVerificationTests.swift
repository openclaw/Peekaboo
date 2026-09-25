import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeSetValueVerificationTests {
    @Test
    func `numeric readback preserves native tolerance`() throws {
        let request = PeekabooBridgeRequest.setValue(.init(
            target: "slider",
            value: .int(58),
            snapshotId: "synthetic-snapshot"))
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
        let witness = ElementValueVerification(
            attribute: .value,
            resolvedKind: .double,
            readback: .double(57.99999999999999))
        let response = PeekabooBridgeResponse.elementActionResult(.init(
            target: "slider",
            actionName: "AXSetValue",
            anchorPoint: nil,
            oldValue: "50",
            newValue: "57.99999999999999",
            valueVerification: witness))

        #expect(witness.matches(
            requested: .int(58),
            newValue: "57.99999999999999",
            actionName: "AXSetValue"))

        try plan.validateBoundTypedResponse(response, outcome: nil)
    }

    @Test
    func `legacy readback still requires exact presentation`() {
        let request = PeekabooBridgeRequest.setValue(.init(
            target: "slider",
            value: .int(58),
            snapshotId: "synthetic-snapshot"))
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
        let response = PeekabooBridgeResponse.elementActionResult(.init(
            target: "slider",
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: "57.99999999999999"))

        #expect(throws: PeekabooBridgeOperationReceiptError.receiptMismatch("set-value response request semantics")) {
            try plan.validateBoundTypedResponse(response, outcome: nil)
        }
    }

    @Test
    func `native witness binds resolved coercion and selected attribute`() throws {
        let cases: [(UIElementValue, ElementValueVerification)] = [
            (.double(58), .init(attribute: .value, resolvedKind: .double, readback: .double(57.99999999999999))),
            (.string("58"), .init(attribute: .value, resolvedKind: .double, readback: .double(57.99999999999999))),
            (.string("58.00"), .init(attribute: .value, resolvedKind: .double, readback: .double(58))),
            (.string(" yes "), .init(attribute: .value, resolvedKind: .bool, readback: .bool(true))),
            (.bool(true), .init(attribute: .selected, resolvedKind: .bool, readback: .bool(true))),
            (.double(-0.0), .init(attribute: .value, resolvedKind: .double, readback: .double(-0.0))),
            (.int(9_007_199_254_740_993), .init(
                attribute: .value, resolvedKind: .int, readback: .int(9_007_199_254_740_993))),
        ]
        for (requested, witness) in cases {
            try Self.validate(.init(
                target: "slider",
                actionName: witness.attribute == .selected ? "AXSelected" : "AXSetValue",
                anchorPoint: nil,
                newValue: witness.displayString,
                valueVerification: witness), requested: requested)
        }
    }

    @Test
    func `text witness does not normalize numeric looking strings`() throws {
        let witness = ElementValueVerification(attribute: .value, resolvedKind: .string, readback: .string("58"))
        let result = ElementActionResult(
            target: "slider",
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: "58",
            valueVerification: witness)
        try Self.validate(result, requested: .string("58"))
        for requested in ["58.0", " 58", "58 "] {
            #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                try Self.validate(result, requested: .string(requested))
            }
        }
    }

    @Test
    func `malformed witness or request binding is rejected`() {
        let witness = ElementValueVerification(attribute: .value, resolvedKind: .double, readback: .double(58))
        let results: [ElementActionResult] = [
            .init(
                target: "other",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "58",
                valueVerification: witness),
            .init(
                target: "slider",
                actionName: "AXPress",
                anchorPoint: nil,
                newValue: "58",
                valueVerification: witness),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: CGPoint(x: 1, y: 2),
                newValue: "58",
                valueVerification: witness),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "59",
                valueVerification: witness),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: nil,
                valueVerification: witness),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "59",
                valueVerification: .init(
                    attribute: .value, resolvedKind: .double, readback: .double(59))),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "58",
                valueVerification: .init(
                    attribute: .value, resolvedKind: .double, readback: .string("58"))),
            .init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: "58",
                valueVerification: .init(
                    attribute: .selected, resolvedKind: .double, readback: .double(58))),
        ]
        for result in results {
            #expect(throws: PeekabooBridgeOperationReceiptError
                .receiptMismatch("set-value response request semantics"))
            {
                try Self.validate(result, requested: .int(58))
            }
        }
    }

    @Test
    func `perform action cannot carry setter verification`() {
        let request = PeekabooBridgeRequest.performAction(.init(
            target: "slider", actionName: "AXPress", snapshotId: "synthetic-snapshot"))
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
        let response = PeekabooBridgeResponse.elementActionResult(.init(
            target: "slider",
            actionName: "AXPress",
            anchorPoint: nil,
            valueVerification: .init(attribute: .value, resolvedKind: .int, readback: .int(58))))

        #expect(throws: PeekabooBridgeOperationReceiptError
            .receiptMismatch("perform-action response request semantics"))
        {
            try plan.validateBoundTypedResponse(response, outcome: nil)
        }
    }

    @Test
    func `legacy exact readback is still accepted`() throws {
        try Self.validate(
            .init(target: "slider", actionName: "AXSetValue", anchorPoint: nil, newValue: "58"),
            requested: .int(58))
    }

    @Test
    func `capability offer retains the existing element mutation floor`() {
        let capability = PeekabooBridgeClientCapability.setValueVerification
        #expect(!PeekabooBridgeClient.offeredCapabilities(for: .init(major: 1, minor: 36)).contains(capability))
        #expect(PeekabooBridgeClient.offeredCapabilities(for: .init(major: 1, minor: 37)).contains(capability))
        #expect(PeekabooBridgeClient.offeredCapabilities(for: PeekabooBridgeConstants.protocolVersion)
            .contains(capability))
        #expect(!PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            statelessClickVariants: false,
            exactWindowHeldPointerLifecycle: false).setValueVerification)
        let unsupportedOffers: [Set<String>] = [[], ["unknownFutureCapability"], ["setvalueverification"]]
        for offers in unsupportedOffers {
            #expect(!PeekabooBridgeNegotiatedSessionCapabilities.offersSetValueVerification(
                offers, negotiatedVersion: PeekabooBridgeConstants.protocolVersion))
        }
        #expect(!PeekabooBridgeNegotiatedSessionCapabilities.offersSetValueVerification(
            [capability], negotiatedVersion: .init(major: 1, minor: 36)))
        #expect(PeekabooBridgeNegotiatedSessionCapabilities.offersSetValueVerification(
            [capability], negotiatedVersion: .init(major: 1, minor: 37)))
    }

    private static func validate(_ result: ElementActionResult, requested: UIElementValue) throws {
        let request = PeekabooBridgeRequest.setValue(.init(
            target: "slider", value: requested, snapshotId: "synthetic-snapshot"))
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
        try plan.validateBoundTypedResponse(.elementActionResult(result), outcome: nil)
    }
}
