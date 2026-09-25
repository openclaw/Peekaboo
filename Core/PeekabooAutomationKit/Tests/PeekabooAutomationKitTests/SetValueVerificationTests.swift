import AXorcist
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct SetValueVerificationTests {
    @MainActor
    @Test
    func `decimal integer strings preserve all digits and ordinary exponent forms`() throws {
        let cases: [(String, Int)] = [
            ("9007199254740993.0", 9_007_199_254_740_993),
            ("9007199254740993e0", 9_007_199_254_740_993),
            ("\(Int.max).0", Int.max),
            ("\(Int.min).0", Int.min),
            ("001.0", 1), ("10e-1", 1), (".0", 0), ("1.", 1), ("1.e3", 1000), ("-1e+3", -1000),
            ("1." + String(repeating: "0", count: 80), 1),
            ("1" + String(repeating: "0", count: 80) + "e-80", 1),
            ("0e99999999999999999999999999", 0),
            ("-0.0e-99999999999999999999999", 0),
        ]
        for (text, expected) in cases {
            let element = ActionInputMockAutomationElement(value: 3, isValueSettable: true)
            let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string(text))
            #expect(element.setValues == [.int(expected)])
            #expect(result.valueVerification?.readback == .int(expected))
        }
    }

    @MainActor
    @Test(arguments: [
        "1.0000000000000001", "1e-400", "9007199254740993.5",
        "1.0000000000000000000000000000000000000000000000000000001",
        "1e9999999999999999999999", "1e-9999999999999999999999",
        "9223372036854775808.0", "-9223372036854775809.0", "0x1p2", "0x1.8p1",
        "", "+", "-", ".", "+.", "1e", "1e+", "e1", "1e1e1", "1..0", "   ",
    ])
    func `inexact out of range and hexadecimal integer strings fail before dispatch`(text: String) {
        let element = ActionInputMockAutomationElement(value: 3, isValueSettable: true)
        #expect(throws: ActionInputError.self) {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: .string(text))
        }
        #expect(element.setValues.isEmpty)
    }

    @MainActor
    @Test(arguments: ["1.0000000000000001", "1e-400", "0x1p2"])
    func `integer string restrictions never apply to literal text controls`(text: String) throws {
        let element = ActionInputMockAutomationElement(role: "AXTextField", value: "before", isValueSettable: true)
        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string(text))
        #expect(element.setValues == [.string(text)])
        #expect(result.valueVerification?.readback == .string(text))
    }

    @MainActor
    @Test
    func `legacy presentation is captured from the same raw native observation`() throws {
        let cases: [(Any, UIElementValue, String)] = [
            (58.0, .double(58), "58.0"),
            (Float(58), .double(58), "58.0"),
            (NSNumber(value: 58.0), .double(58), "58"),
            (NSNumber(value: Float(58)), .double(58), "58"),
            (0, .int(0), "0"),
            (1, .int(1), "1"),
            (NSNumber(value: 0), .bool(false), "false"),
            (NSNumber(value: 1), .bool(true), "true"),
            (NSNumber(value: 0.0), .bool(false), "false"),
            (NSNumber(value: 1.0), .bool(true), "true"),
            (-0.0, .double(0), "-0.0"),
            (Float(-0.0), .double(0), "-0.0"),
            (NSNumber(value: -0.0), .bool(false), "false"),
            (Float(0.1), .double(Double(Float(0.1))), "0.1"),
            (NSNumber(value: Float(0.1)), .double(Double(Float(0.1))), "0.10000000149011612"),
        ]
        for (raw, requested, expectedPresentation) in cases {
            let element = ActionInputMockAutomationElement(role: "AXSlider", value: raw, isValueSettable: true)
            let result = try ActionInputDriver().trySetValueForTesting(element: element, value: requested)
            let witness = try #require(result.valueVerification)
            #expect(witness.legacyPresentation == expectedPresentation)
            #expect(witness.readback == ElementValueReadback(nativeValue: raw))
            #expect(witness.matches(requested: requested, newValue: witness.displayString, actionName: "AXSetValue"))
            #expect(element.setValues.isEmpty)
        }
    }

    @MainActor
    @Test
    func `post dispatch legacy presentation describes the readback not the request`() throws {
        let observed = 57.99999999999999
        let element = ActionInputMockAutomationElement(
            role: "AXSlider", value: 47.0, isValueSettable: true, valueSetterReadbackOverride: .double(observed))
        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("58"))
        let witness = try #require(result.valueVerification)
        #expect(witness.legacyPresentation == String(observed))
        #expect(witness.legacyPresentation != "58")
        #expect(witness.displayString == String(observed))
    }

    @Test
    func `legacy rendering validation accepts only exact finite native spellings`() {
        let invalid: [(ElementValueReadback, String)] = [
            (.double(57.99999999999999), "58"),
            (.double(57.99999999999999), "58.0"),
            (.double(Double(Float(0.1))), "0.100000001"),
            (.double(.infinity), "inf"),
            (.int(58), "58.0"),
            (.bool(true), "1"),
            (.string("58"), "58.0"),
        ]
        for (readback, presentation) in invalid {
            #expect(!NativeElementValuePresentation.accepts(presentation, for: readback))
        }
        #expect(NativeElementValuePresentation.accepts("-0.0", for: .double(0)))
        #expect(NativeElementValuePresentation.accepts("false", for: .double(0)))
        #expect(NativeElementValuePresentation.accepts("true", for: .int(1)))
        #expect(NativeElementValuePresentation.accepts("0.1", for: .double(Double(Float(0.1)))))
    }

    @MainActor
    @Test(arguments: [UIElementValue.string("58"), .int(58), .double(58)])
    func `rounded slider readback is witnessed and repeated requests do not dispatch`(
        requested: UIElementValue) throws
    {
        let observed = 57.99999999999999
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            value: 47.0,
            isValueSettable: true,
            valueSetterReadbackOverride: .double(observed))
        let driver = ActionInputDriver()

        let changed = try driver.trySetValueForTesting(element: element, value: requested)
        let verification = try #require(changed.valueVerification)

        #expect(element.setValues == [.double(58)])
        #expect(changed.outcome.state == .confirmedChange)
        #expect(changed.outcome.evidence == .verifiedChange)
        #expect(verification.attribute == .value)
        #expect(verification.resolvedKind == .double)
        #expect(verification.readback == .double(observed))
        #expect(verification.displayString == String(observed))
        #expect(verification.matches(
            requested: requested,
            newValue: String(observed),
            actionName: changed.actionName))

        let unchanged = try driver.trySetValueForTesting(element: element, value: requested)

        #expect(element.setValues == [.double(58)])
        #expect(unchanged.outcome.state == .confirmedNoChange)
        #expect(unchanged.outcome.dispatchState == .none)
        #expect(unchanged.valueVerification == verification)
    }

    @MainActor
    @Test(arguments: ["AXTextField", "AXSlider"])
    func `actual numeric-looking string readback remains literal`(role: String) {
        let element = ActionInputMockAutomationElement(
            role: role,
            value: "47",
            isValueSettable: true,
            valueSetterReadbackOverride: .string("57.99999999999999"))

        self.expectUnverifiedMutation(element: element, requested: .string("58"))

        #expect(element.setValues == [.string("58")])
    }

    @MainActor
    @Test
    func `numeric request on a text field retains a string witness`() throws {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXTextFieldRole,
            value: "47",
            isValueSettable: true)

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .int(58))
        let verification = try #require(result.valueVerification)

        #expect(element.setValues == [.string("58")])
        #expect(verification.resolvedKind == .string)
        #expect(verification.readback == .string("58"))
        #expect(verification.matches(requested: .int(58), newValue: "58", actionName: result.actionName))
        #expect(!verification.matches(requested: .string("058"), newValue: "58", actionName: result.actionName))
    }

    @MainActor
    @Test
    func `integer coercion preserves precision above the floating point exact range`() throws {
        let expected = 9_007_199_254_740_993
        let element = ActionInputMockAutomationElement(value: expected - 2, isValueSettable: true)
        let requested = UIElementValue.string("000\(expected)")

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: requested)
        let verification = try #require(result.valueVerification)

        #expect(element.setValues == [.int(expected)])
        #expect(verification.resolvedKind == .int)
        #expect(verification.readback == .int(expected))
        #expect(verification.matches(
            requested: requested,
            newValue: String(expected),
            actionName: result.actionName))
        #expect(!verification.matches(
            requested: .int(expected + 1),
            newValue: String(expected),
            actionName: result.actionName))
    }

    @MainActor
    @Test(arguments: [UIElementValue.int(9_007_199_254_740_994), .double(9_007_199_254_740_992)])
    func `integer verification rejects adjacent and floating point readback`(readback: UIElementValue) {
        let expected = 9_007_199_254_740_993
        let element = ActionInputMockAutomationElement(
            value: expected - 2,
            isValueSettable: true,
            valueSetterReadbackOverride: readback)

        self.expectUnverifiedMutation(element: element, requested: .int(expected))

        #expect(element.setValues == [.int(expected)])
    }

    @MainActor
    @Test(arguments: [UIElementValue.string(" 001.0 "), .double(1), .bool(true)])
    func `integer coercion retains existing accepted request forms`(requested: UIElementValue) throws {
        let element = ActionInputMockAutomationElement(value: 0, isValueSettable: true)

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: requested)
        let verification = try #require(result.valueVerification)

        #expect(element.setValues == [.int(1)])
        #expect(verification.resolvedKind == .int)
        #expect(verification.readback == .int(1))
        #expect(verification.matches(requested: requested, newValue: "1", actionName: result.actionName))
    }

    @MainActor
    @Test(arguments: [UIElementValue.string(" on "), .string("YES"), .int(1), .double(1), .bool(true)])
    func `boolean value witnesses preserve explicit coercion and idempotence`(requested: UIElementValue) throws {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXCheckBoxRole,
            value: false,
            isValueSettable: true)
        let driver = ActionInputDriver()

        let changed = try driver.trySetValueForTesting(element: element, value: requested)
        let verification = try #require(changed.valueVerification)
        let unchanged = try driver.trySetValueForTesting(element: element, value: requested)

        #expect(element.setValues == [.bool(true)])
        #expect(verification.attribute == .value)
        #expect(verification.resolvedKind == .bool)
        #expect(verification.readback == .bool(true))
        #expect(verification.matches(requested: requested, newValue: "true", actionName: changed.actionName))
        #expect(unchanged.outcome.state == .confirmedNoChange)
        #expect(unchanged.outcome.dispatchState == .none)
        #expect(unchanged.valueVerification == verification)
    }

    @MainActor
    @Test
    func `selected-only setter attests selected boolean readback`() throws {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXRowRole,
            isSelectedSettable: true,
            selectedValue: false)
        let driver = ActionInputDriver()

        let changed = try driver.trySetValueForTesting(element: element, value: .string("on"))
        let verification = try #require(changed.valueVerification)
        let unchanged = try driver.trySetValueForTesting(element: element, value: .bool(true))

        #expect(element.setValues.isEmpty)
        #expect(element.setSelectedValues == [true])
        #expect(changed.outcome.state == .confirmedChange)
        #expect(verification.attribute == .selected)
        #expect(verification.resolvedKind == .bool)
        #expect(verification.readback == .bool(true))
        #expect(verification.matches(requested: .string("on"), newValue: "true", actionName: "AXSelected"))
        #expect(!verification.matches(requested: .bool(true), newValue: "true", actionName: "AXSetValue"))
        #expect(unchanged.outcome.state == .confirmedNoChange)
        #expect(unchanged.outcome.dispatchState == .none)
        #expect(unchanged.valueVerification == verification)
    }

    @MainActor
    @Test
    func `CFBoolean and integer NSNumber produce distinct resolved kinds and readback tags`() throws {
        let booleanElement = ActionInputMockAutomationElement(value: NSNumber(value: false), isValueSettable: true)
        let integerElement = ActionInputMockAutomationElement(value: NSNumber(value: 0), isValueSettable: true)
        let driver = ActionInputDriver()

        let booleanResult = try driver.trySetValueForTesting(element: booleanElement, value: .int(1))
        let integerResult = try driver.trySetValueForTesting(element: integerElement, value: .int(1))

        #expect(booleanElement.setValues == [.bool(true)])
        #expect(booleanResult.valueVerification?.resolvedKind == .bool)
        #expect(booleanResult.valueVerification?.readback == .bool(true))
        #expect(integerElement.setValues == [.int(1)])
        #expect(integerResult.valueVerification?.resolvedKind == .int)
        #expect(integerResult.valueVerification?.readback == .int(1))
    }

    @MainActor
    @Test
    func `integer Boolean readback preserves exact zero and one`() throws {
        let integerElement = ActionInputMockAutomationElement(
            value: 0,
            isValueSettable: true,
            valueSetterReadbackOverride: .bool(true))
        let driver = ActionInputDriver()

        let integerResult = try driver.trySetValueForTesting(element: integerElement, value: .int(1))
        let integerVerification = try #require(integerResult.valueVerification)

        #expect(integerVerification.resolvedKind == .int)
        #expect(integerVerification.readback == .bool(true))
        #expect(integerVerification.matches(requested: .int(1), newValue: "true", actionName: "AXSetValue"))
    }

    @MainActor
    @Test(arguments: [0.5, -0.5, 1.5, Double.leastNonzeroMagnitude, Double(1).nextUp])
    func `fractional numeric Boolean readback is retry unsafe after dispatch`(readback: Double) {
        let requested = readback >= 1
        let element = ActionInputMockAutomationElement(
            role: "AXCheckBox",
            value: !requested,
            isValueSettable: true,
            valueSetterReadbackOverride: .double(readback))

        self.expectUnverifiedMutation(element: element, requested: .bool(requested))
        #expect(element.setValues == [.bool(requested)])
    }

    @MainActor
    @Test(arguments: [0.5, -0.5, 1.5])
    func `fractional Boolean prestate is not an idempotent match`(readback: Double) throws {
        let requested = readback >= 1
        let element = ActionInputMockAutomationElement(
            role: "AXCheckBox", value: NSNumber(value: readback), isValueSettable: true)
        let driver = ActionInputDriver()
        let changed = try driver.trySetValueForTesting(element: element, value: .bool(requested))
        #expect(changed.outcome.state == .confirmedChange)
        #expect(element.setValues == [.bool(requested)])
        let repeated = try driver.trySetValueForTesting(element: element, value: .bool(requested))
        #expect(repeated.outcome.state == .confirmedNoChange)
        #expect(element.setValues == [.bool(requested)])
    }

    @MainActor
    @Test(arguments: [false, true])
    func `exact numeric Boolean prestate remains idempotent`(requested: Bool) throws {
        for raw in [NSNumber(value: requested ? 1 : 0), NSNumber(value: requested ? 1.0 : 0.0)] {
            let element = ActionInputMockAutomationElement(role: "AXCheckBox", value: raw, isValueSettable: true)
            let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .bool(requested))
            #expect(result.outcome.state == .confirmedNoChange)
            #expect(element.setValues.isEmpty)
        }
    }

    @MainActor
    @Test(arguments: [UIElementValue.string("2"), .int(2), .double(1.01)])
    func `boolean coercion rejects non-boolean requests without dispatch`(requested: UIElementValue) {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXCheckBoxRole,
            value: false,
            isValueSettable: true)

        #expect(throws: ActionInputError.self) {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: requested)
        }
        #expect(element.setValues.isEmpty)
    }

    @MainActor
    @Test(arguments: [UIElementValue.double(.nan), .double(.infinity), .double(-.infinity), .string("nan")])
    func `nonfinite numeric requests are rejected before dispatch`(requested: UIElementValue) {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            value: 47.0,
            isValueSettable: true)

        #expect(throws: ActionInputError.self) {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: requested)
        }
        #expect(element.setValues.isEmpty)
    }

    @MainActor
    @Test(arguments: [
        UIElementValue.double(58.000001), .double(.nan), .double(.infinity), .double(-.infinity), .string("58"),
    ])
    func `unverifiable numeric readback remains retry unsafe after dispatch`(readback: UIElementValue) {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            value: 47.0,
            isValueSettable: true,
            valueSetterReadbackOverride: readback)

        self.expectUnverifiedMutation(element: element, requested: .int(58))

        #expect(element.setValues == [.double(58)])
    }

    @MainActor
    @Test
    func `unreadable post-dispatch value cannot yield a witness`() {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            isValueSettable: true,
            valueSetterDoesNotChange: true)

        self.expectUnverifiedMutation(element: element, requested: .int(58))

        #expect(element.setValues == [.double(58)])
    }

    @MainActor
    @Test
    func `verified readback does not upgrade an unknown pre-state outcome`() throws {
        let element = ActionInputMockAutomationElement(role: AXRoleNames.kAXTextFieldRole, isValueSettable: true)

        let result = try ActionInputDriver().trySetValueForTesting(element: element, value: .string("58"))

        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.retrySafety == .unsafe)
        #expect(result.valueVerification?.readback == .string("58"))
    }

    @Test
    func `witness validation binds actual display attribute action and resolved kind`() {
        let numeric = ElementValueVerification(
            attribute: .value,
            resolvedKind: .double,
            readback: .double(57.99999999999999))
        let text = ElementValueVerification(
            attribute: .value,
            resolvedKind: .string,
            readback: .string("57.99999999999999"))
        let malformedSelected = ElementValueVerification(
            attribute: .selected,
            resolvedKind: .double,
            readback: .bool(true))

        #expect(!numeric.matches(requested: .int(58), newValue: "58", actionName: "AXSetValue"))
        #expect(!numeric.matches(requested: .int(58), newValue: nil, actionName: "AXSetValue"))
        #expect(!numeric.matches(requested: .int(58), newValue: numeric.displayString, actionName: nil))
        #expect(!numeric.matches(requested: .int(58), newValue: numeric.displayString, actionName: "AXSelected"))
        #expect(!text.matches(requested: .string("58"), newValue: text.displayString, actionName: "AXSetValue"))
        #expect(text.matches(
            requested: .string("57.99999999999999"),
            newValue: text.displayString,
            actionName: "AXSetValue"))
        #expect(!malformedSelected.matches(requested: .bool(true), newValue: "true", actionName: "AXSelected"))
    }

    @Test
    func `floating point witness retains the native absolute and relative tolerances`() {
        let nearZero = ElementValueVerification(attribute: .value, resolvedKind: .double, readback: .double(1e-10))
        let inside = ElementValueVerification(attribute: .value, resolvedKind: .double, readback: .double(58 + 5e-8))
        let outside = ElementValueVerification(attribute: .value, resolvedKind: .double, readback: .double(58 + 1e-7))

        #expect(nearZero.matches(requested: .double(0), newValue: nearZero.displayString, actionName: "AXSetValue"))
        #expect(inside.matches(requested: .int(58), newValue: inside.displayString, actionName: "AXSetValue"))
        #expect(!outside.matches(requested: .int(58), newValue: outside.displayString, actionName: "AXSetValue"))
    }

    @Test(arguments: [
        ElementValueReadback.string("-0.0"), .bool(true), .int(9_007_199_254_740_993),
        .double(58), .double(57.99999999999999), .double(0), .double(-0.0),
    ])
    func `typed readback and witness preserve their tag through canonical JSON roundtrips`(
        readback: ElementValueReadback) throws
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(readback)
        let decoded = try JSONDecoder().decode(ElementValueReadback.self, from: data)

        #expect(decoded == readback)
        #expect(decoded.kind == readback.kind)
        #expect(try encoder.encode(decoded) == data)

        let witness = ElementValueVerification(attribute: .value, resolvedKind: readback.kind, readback: readback)
        let witnessData = try encoder.encode(witness)
        let decodedWitness = try JSONDecoder().decode(ElementValueVerification.self, from: witnessData)

        #expect(decodedWitness == witness)
        #expect(try encoder.encode(decodedWitness) == witnessData)
    }

    @Test
    func `integral doubles remain tagged doubles and numeric zero is canonical`() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let integralData = Data(#"{"kind":"double","value":58}"#.utf8)
        let integral = try JSONDecoder().decode(ElementValueReadback.self, from: integralData)

        #expect(integral == .double(58))
        #expect(integral.kind == .double)
        #expect(try encoder.encode(integral) == integralData)
        #expect(try encoder.encode(ElementValueReadback.double(-0.0)) == encoder.encode(ElementValueReadback.double(0)))
        #expect(ElementValueReadback.double(-0.0).displayString == "0")
        #expect(ElementValueReadback.double(0).displayString == "0")
        #expect(ElementValueReadback.string("-0.0").displayString == "-0.0")
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func `nonfinite typed readback is rejected even with permissive JSON strategies`(value: Double) {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN")
        let readback = ElementValueReadback.double(value)
        let witness = ElementValueVerification(attribute: .value, resolvedKind: .double, readback: readback)

        #expect(throws: EncodingError.self) { try encoder.encode(readback) }
        #expect(throws: EncodingError.self) { try encoder.encode(witness) }
        #expect(!witness.matches(requested: .double(value), newValue: witness.displayString, actionName: "AXSetValue"))
    }

    @Test(arguments: ["NaN", "Infinity", "-Infinity"])
    func `nonfinite decoded readback cannot enter the typed contract`(value: String) {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN")
        let data = Data("{\"kind\":\"double\",\"value\":\"\(value)\"}".utf8)

        #expect(throws: DecodingError.self) { try decoder.decode(ElementValueReadback.self, from: data) }
    }

    @Test
    func `element results omit absent witnesses and preserve present witnesses`() throws {
        let legacy = ElementActionResult(target: "slider", actionName: "AXSetValue", anchorPoint: nil, newValue: "58")
        let encoder = JSONEncoder()
        let legacyData = try encoder.encode(legacy)
        let legacyJSON = try #require(String(bytes: legacyData, encoding: .utf8))

        #expect(!legacyJSON.contains("valueVerification"))
        #expect(try JSONDecoder().decode(ElementActionResult.self, from: legacyData) == legacy)

        let witness = ElementValueVerification(attribute: .value, resolvedKind: .double, readback: .double(58))
        let witnessed = ElementActionResult(
            target: "slider",
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: witness.displayString,
            valueVerification: witness)
        let witnessedData = try encoder.encode(witnessed)

        #expect(try JSONDecoder().decode(ElementActionResult.self, from: witnessedData) == witnessed)
    }

    @MainActor
    @Test
    func `unsigned native integers outside Int range cannot become wrapped witnesses`() {
        let rawValue = NSNumber(value: UInt64.max)
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXSliderRole,
            value: rawValue,
            isValueSettable: true)

        #expect(ElementValueReadback(nativeValue: rawValue) == nil)
        #expect(ElementValueReadback(nativeValue: NSNumber(value: UInt64(Int.max))) == .int(Int.max))
        #expect(throws: ActionInputError.self) {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: .int(58))
        }
        #expect(element.setValues.isEmpty)
    }

    @MainActor
    private func expectUnverifiedMutation(
        element: ActionInputMockAutomationElement,
        requested: UIElementValue)
    {
        do {
            _ = try ActionInputDriver().trySetValueForTesting(element: element, value: requested)
            Issue.record("Expected the accepted setter to fail readback verification")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.projection.requiresFreshObservation)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
