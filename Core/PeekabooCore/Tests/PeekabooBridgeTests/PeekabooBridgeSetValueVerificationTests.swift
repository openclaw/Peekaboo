import Foundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

struct PeekabooBridgeSetValueVerificationTests {
    @Test
    func `legacy projection rejects forged presentation and typed coercion bypass`() {
        let cases: [(UIElementValue, ElementValueVerification)] = [
            (.string("58"), .init(
                attribute: .value,
                resolvedKind: .double,
                readback: .double(57.99999999999999),
                legacyPresentation: "58")),
            (.string("false"), .init(
                attribute: .value, resolvedKind: .double, readback: .double(0), legacyPresentation: "false")),
            (.bool(false), .init(
                attribute: .value, resolvedKind: .double, readback: .double(0), legacyPresentation: "true")),
        ]
        for (requested, witness) in cases {
            let request = PeekabooBridgeRequest.setValue(.init(
                target: "slider", value: requested, snapshotId: "synthetic-snapshot"))
            let response = PeekabooBridgeResponse.elementActionResult(.init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: witness.displayString,
                valueVerification: witness))
            for offered in [false, true] {
                #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                    try response.projectingSetValueVerification(offered: offered, request: request)
                }
            }
        }
    }

    @Test
    func `native NSNumber integral presentation retains the old literal rejection`() throws {
        let raw = NSNumber(value: 58.0)
        let legacy = try #require(NativeElementValuePresentation.describe(raw))
        #expect(legacy == "58")
        let witness = ElementValueVerification(
            attribute: .value, resolvedKind: .double, readback: .double(58), legacyPresentation: legacy)
        let response = PeekabooBridgeResponse.elementActionResult(.init(
            target: "slider",
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: witness.displayString,
            valueVerification: witness))
        let request = PeekabooBridgeRequest.setValue(.init(
            target: "slider", value: .string("58.0"), snapshotId: "synthetic-snapshot"))
        let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
        let legacyResponse = try response.projectingSetValueVerification(offered: false, request: request)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try plan.validateBoundTypedResponse(legacyResponse, outcome: nil)
        }
        try plan.validateBoundTypedResponse(
            response.projectingSetValueVerification(offered: true, request: request), outcome: nil)
    }

    @Test
    func `raw Swift scalar legacy spellings preserve exact acceptance`() throws {
        let cases: [(Any, UIElementValue, String, Bool)] = [
            (58.0, .string("58.0"), "58.0", true),
            (Float(58), .string("58.0"), "58.0", true),
            (-0.0, .string("-0.0"), "-0.0", true),
            (Float(-0.0), .string("-0.0"), "-0.0", true),
            (Float(0.1), .double(Double(Float(0.1))), "0.1", false),
            (0, .int(0), "0", true),
        ]
        for (raw, requested, legacy, accepted) in cases {
            let readback = try #require(ElementValueReadback(nativeValue: raw))
            #expect(NativeElementValuePresentation.describe(raw) == legacy)
            let witness = ElementValueVerification(
                attribute: .value, resolvedKind: readback.kind, readback: readback, legacyPresentation: legacy)
            let request = PeekabooBridgeRequest.setValue(.init(
                target: "slider", value: requested, snapshotId: "synthetic-snapshot"))
            let response = PeekabooBridgeResponse.elementActionResult(.init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: witness.displayString,
                valueVerification: witness))
            let projected = try response.projectingSetValueVerification(offered: false, request: request)
            guard case let .elementActionResult(result) = projected else {
                Issue.record("Expected an element result")
                continue
            }
            #expect(result.newValue == legacy)
            #expect(result.valueVerification == nil)
            let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)
            if accepted {
                try plan.validateBoundTypedResponse(projected, outcome: nil)
            } else {
                #expect(throws: PeekabooBridgeOperationReceiptError.self) {
                    try plan.validateBoundTypedResponse(projected, outcome: nil)
                }
            }
        }
    }

    @Test
    func `legacy NS number boolean binding survives witness projection`() throws {
        for requested in [false, true] {
            let rawObservation = NSNumber(value: requested ? 1.0 : 0.0)
            let legacyPresentation = try #require(NativeElementValuePresentation.describe(rawObservation))
            #expect(legacyPresentation == String(requested))
            let witness = try ElementValueVerification(
                attribute: .value,
                resolvedKind: .double,
                readback: #require(ElementValueReadback(nativeValue: rawObservation)),
                legacyPresentation: legacyPresentation)
            let response = PeekabooBridgeResponse.elementActionResult(.init(
                target: "slider",
                actionName: "AXSetValue",
                anchorPoint: nil,
                newValue: witness.displayString,
                valueVerification: witness))
            let request = PeekabooBridgeRequest.setValue(.init(
                target: "slider", value: .bool(requested), snapshotId: "synthetic-snapshot"))
            let projected = try response.projectingSetValueVerification(offered: false, request: request)
            let plan = PeekabooBridgeOperationResultSemantics.requestPlan(for: request, vocabulary: .current)

            try plan.validateBoundTypedResponse(projected, outcome: nil)
        }
    }

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
