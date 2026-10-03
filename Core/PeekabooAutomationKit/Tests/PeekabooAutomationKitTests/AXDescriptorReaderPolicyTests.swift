import ApplicationServices
import Foundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

struct AXDescriptorReaderPolicyTests {
    @Test
    func `Date value representations use the same UTC timestamp`() throws {
        let date = Date(timeIntervalSince1970: 1_791_033_456.125)
        let cfDate = try #require(CFDateCreate(nil, date.timeIntervalSinceReferenceDate))
        let values: [Any] = [date, date as NSDate, cfDate]

        for value in values {
            #expect(AXDescriptorReader.displayValue(value) == "2026-10-03T13:17:36.125Z")
            #expect(AXDescriptorReader.stringValue(value) == nil)
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func `Nonfinite date values remain unavailable`(seconds: Double) {
        #expect(AXDescriptorReader.displayValue(Date(timeIntervalSinceReferenceDate: seconds)) == nil)
    }

    @Test
    func `Date control state survives descriptor mapping without coercing its title`() {
        let date = Date(timeIntervalSince1970: 1_791_033_456.125)
        var reads = Self.requiredDescriptorReads(role: "AXGroup", identifier: "active-view")
        reads["AXValue"] = AXDescriptorReader.SingleAttributeRead(error: .success, value: date as NSDate)
        reads["AXTitle"] = AXDescriptorReader.SingleAttributeRead(error: .success, value: date as NSDate)
        let result = AXDescriptorReader.describeWithSingleAttributeReads { name in
            reads[name] ?? AXDescriptorReader.SingleAttributeRead(error: .noValue, value: nil)
        }

        guard case let .descriptor(descriptor) = result else {
            Issue.record("Expected a date-valued descriptor, got \(result)")
            return
        }
        #expect(descriptor.value == "2026-10-03T13:17:36.125Z")
        #expect(descriptor.title == nil)
        #expect(descriptor.identifier == "active-view")
        #expect(descriptor.frame == CGRect(x: 10, y: 20, width: 100, height: 40))
    }

    @Test
    func `Batch capability and shape errors retain single-read fallback`() {
        let capabilityErrors: [AXError] = [
            .attributeUnsupported,
            .parameterizedAttributeUnsupported,
            .notImplemented,
        ]

        for error in capabilityErrors {
            #expect(AXDescriptorReader.shouldFallbackToSingleAttributeReads(
                error: error,
                hasExpectedValueShape: false))
        }
        #expect(AXDescriptorReader.shouldFallbackToSingleAttributeReads(
            error: .success,
            hasExpectedValueShape: false))
        #expect(!AXDescriptorReader.shouldFallbackToSingleAttributeReads(
            error: .success,
            hasExpectedValueShape: true))
    }

    @Test
    func `Transient and invalid batch failures do not issue a second blocking read`() {
        let failures: [AXError] = [
            .cannotComplete,
            .invalidUIElement,
            .invalidUIElementObserver,
            .noValue,
            .failure,
        ]

        for error in failures {
            #expect(!AXDescriptorReader.shouldFallbackToSingleAttributeReads(
                error: error,
                hasExpectedValueShape: false))
        }
    }

    @Test
    func `Embedded cannot-complete error is incomplete while sparse attributes remain safe`() throws {
        var cannotComplete = AXError.cannotComplete
        let failedValue = try #require(AXValueCreate(.axError, &cannotComplete))
        var unsupported = AXError.attributeUnsupported
        let sparseValue = try #require(AXValueCreate(.axError, &unsupported))

        #expect(AXAttributeReadCompletenessPolicy.embeddedError(in: failedValue) == .cannotComplete)
        #expect(AXAttributeReadCompletenessPolicy.hasIncompleteErrorValue(in: [failedValue]))
        #expect(!AXAttributeReadCompletenessPolicy.hasIncompleteErrorValue(in: [sparseValue]))
        #expect(AXDescriptorReader.singleAttributeReadDisposition(
            error: .success,
            value: failedValue,
            attribute: kAXDescriptionAttribute) == .incomplete)
        #expect(AXDescriptorReader.singleAttributeReadDisposition(
            error: .success,
            value: sparseValue,
            attribute: kAXDescriptionAttribute) == .sparse)

        var failedValues = [Any](
            repeating: NSNull(),
            count: AXDescriptorReader.descriptorAttributeCount)
        failedValues[0] = failedValue
        var sparseValues = [Any](
            repeating: NSNull(),
            count: AXDescriptorReader.descriptorAttributeCount)
        sparseValues[0] = sparseValue

        #expect(AXDescriptorReader.batchReadDisposition(
            error: .success,
            values: failedValues) == .incomplete)
        #expect(AXDescriptorReader.batchReadDisposition(
            error: .success,
            values: sparseValues) == .values)
    }

    @Test
    func `Cannot-complete is incomplete while malformed success retains compatibility fallback`() {
        #expect(AXDescriptorReader.batchReadDisposition(
            error: .cannotComplete,
            values: nil) == .incomplete)
        #expect(AXDescriptorReader.batchReadDisposition(
            error: .success,
            values: []) == .fallbackRequired)
    }

    @Test
    func `Single-read fallback propagates hard optional attribute failure`() {
        let required = Self.requiredDescriptorReads()

        let result = AXDescriptorReader.describeWithSingleAttributeReads { name in
            if name == "AXTitle" {
                return AXDescriptorReader.SingleAttributeRead(error: .cannotComplete, value: nil)
            }
            return required[name] ?? AXDescriptorReader.SingleAttributeRead(
                error: .attributeUnsupported,
                value: nil)
        }

        #expect(result == .incomplete)
    }

    @Test
    func `Single-read fallback permits genuine sparse attributes`() {
        let required = Self.requiredDescriptorReads()

        let result = AXDescriptorReader.describeWithSingleAttributeReads { name in
            required[name] ?? AXDescriptorReader.SingleAttributeRead(error: .noValue, value: nil)
        }

        guard case let .descriptor(descriptor) = result else {
            Issue.record("Expected a complete sparse descriptor, got \(result)")
            return
        }
        #expect(descriptor.role == "AXButton")
        #expect(descriptor.frame == CGRect(x: 10, y: 20, width: 100, height: 40))
        #expect(descriptor.title == nil)
    }

    @Test
    func `Current AX reader retains a production semantic witness frame`() {
        let required = Self.requiredDescriptorReads(
            size: CGSize(width: 8, height: 8),
            role: "AXStaticText",
            identifier: "single-click-count",
            value: "2")

        let result = AXDescriptorReader.describeWithSingleAttributeReads { name in
            required[name] ?? AXDescriptorReader.SingleAttributeRead(error: .noValue, value: nil)
        }

        guard case let .descriptor(descriptor) = result else {
            Issue.record("Expected the current AX reader to retain the semantic witness")
            return
        }
        #expect(descriptor.frame.size == CGSize(width: 8, height: 8))
        #expect(descriptor.role == "AXStaticText")
        #expect(descriptor.identifier == "single-click-count")
        #expect(descriptor.value == "2")
    }

    @Test
    func `Single-read fallback treats successful nil value as malformed`() {
        let required = Self.requiredDescriptorReads()

        let result = AXDescriptorReader.describeWithSingleAttributeReads { name in
            if name == "AXTitle" {
                return AXDescriptorReader.SingleAttributeRead(error: .success, value: nil)
            }
            return required[name] ?? AXDescriptorReader.SingleAttributeRead(
                error: .attributeUnsupported,
                value: nil)
        }

        #expect(result == .incomplete)
    }

    @Test
    func `Single-read fallback classifies hard and sparse AX errors separately`() {
        for error in [AXError.cannotComplete, .invalidUIElement, .apiDisabled] {
            #expect(AXDescriptorReader.singleAttributeReadDisposition(
                error: error,
                value: nil,
                attribute: kAXDescriptionAttribute) == .incomplete)
        }
        for error in [AXError.noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented] {
            #expect(AXDescriptorReader.singleAttributeReadDisposition(
                error: error,
                value: nil,
                attribute: kAXDescriptionAttribute) == .sparse)
        }
    }

    /// A declined optional attribute must not cost the caller the whole element; a declined
    /// identity attribute must, because the element can no longer be placed or targeted.
    @Test
    func `A declined attribute is sparse unless the node depends on it`() {
        #expect(AXDescriptorReader.singleAttributeReadDisposition(
            error: .failure,
            value: nil,
            attribute: kAXDescriptionAttribute) == .sparse)
        for attribute in AXAttributeReadCompletenessPolicy.nodeIdentityAttributeNames {
            #expect(AXDescriptorReader.singleAttributeReadDisposition(
                error: .failure,
                value: nil,
                attribute: attribute) == .incomplete)
        }
    }

    @Test
    func `A declined descriptive attribute keeps the batch usable`() throws {
        var declined = AXError.failure
        let declinedValue = try #require(AXValueCreate(.axError, &declined))
        var values = [Any](
            repeating: NSNull(),
            count: AXDescriptorReader.descriptorAttributeCount)
        // The identity attributes lead the descriptor batch, so the last slot is descriptive.
        values[values.count - 1] = declinedValue

        #expect(AXDescriptorReader.batchReadDisposition(
            error: .success,
            values: values) == .values)
    }

    private static func requiredDescriptorReads(
        size: CGSize = CGSize(width: 100, height: 40),
        role: String = "AXButton",
        identifier: String? = nil,
        value: String? = nil) -> [String: AXDescriptorReader.SingleAttributeRead]
    {
        var point = CGPoint(x: 10, y: 20)
        var size = size
        var reads = [
            "AXPosition": AXDescriptorReader.SingleAttributeRead(
                error: .success,
                value: AXValueCreate(.cgPoint, &point)),
            "AXSize": AXDescriptorReader.SingleAttributeRead(
                error: .success,
                value: AXValueCreate(.cgSize, &size)),
            "AXRole": AXDescriptorReader.SingleAttributeRead(error: .success, value: role),
        ]
        if let identifier {
            reads["AXIdentifier"] = AXDescriptorReader.SingleAttributeRead(
                error: .success,
                value: identifier)
        }
        if let value {
            reads["AXValue"] = AXDescriptorReader.SingleAttributeRead(error: .success, value: value)
        }
        return reads
    }
}
