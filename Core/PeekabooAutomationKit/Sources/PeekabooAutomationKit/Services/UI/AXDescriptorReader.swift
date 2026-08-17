import AppKit
@preconcurrency import AXorcist
import CoreGraphics

@_spi(Testing) public enum AXAttributeReadCompletenessPolicy {
    @_spi(Testing) public static func embeddedError(in value: Any) -> AXError? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(cfValue, to: AXValue.self)
        guard AXValueGetType(axValue) == .axError else { return nil }
        var error = AXError.success
        return AXValueGetValue(axValue, .axError, &error) ? error : .failure
    }

    @_spi(Testing) public static func hasIncompleteErrorValue(in values: [Any]) -> Bool {
        values.contains { value in
            guard let error = self.embeddedError(in: value) else { return false }
            return self.isIncomplete(error: error)
        }
    }

    @_spi(Testing) public static func isIncomplete(error: AXError) -> Bool {
        switch error {
        case .success, .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
            false
        default:
            true
        }
    }

    /// Attributes that identify and place a node. Without them the element cannot be emitted or
    /// targeted at all, so a hard error on one of them really does make the node unreadable.
    @_spi(Testing) public static let nodeIdentityAttributeNames: Set<String> = [
        kAXRoleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
    ]

    /// Decides whether one attribute's embedded AX error invalidates the whole node.
    ///
    /// Applications answer inapplicable optional attributes with a generic `.failure` instead of
    /// `.attributeUnsupported`: NSTextView does it for `AXDescription`, Finder's window root does it
    /// for `AXValue`. Reading that as an unreadable node drops the element *and* abandons its subtree,
    /// which is how a document's editable text area disappears from an otherwise healthy observation.
    /// Only a node-identity attribute, or an error proving the read itself did not complete
    /// (dead element, unanswered request), may invalidate the node.
    @_spi(Testing) public static func attributeErrorInvalidatesNode(
        _ error: AXError,
        attribute: String) -> Bool
    {
        guard self.isIncomplete(error: error) else { return false }
        return error != .failure || self.nodeIdentityAttributeNames.contains(attribute)
    }

    @_spi(Testing) public static func hasNodeInvalidatingErrorValue(
        names: [String],
        values: [Any]) -> Bool
    {
        zip(names, values).contains { name, value in
            guard let error = self.embeddedError(in: value) else { return false }
            return self.attributeErrorInvalidatesNode(error, attribute: name)
        }
    }
}

/// Reads the small descriptor surface element detection needs from AX elements.
@_spi(Testing) public enum AXDescriptorReader {
    @_spi(Testing) public struct Descriptor: Equatable {
        public let frame: CGRect
        public let role: String
        public let title: String?
        public let label: String?
        public let value: String?
        public let description: String?
        public let help: String?
        public let roleDescription: String?
        public let identifier: String?
        public let isEnabled: Bool?
        public let isSelected: Bool?
        public let isFocused: Bool?
        public let placeholder: String?
    }

    @_spi(Testing) public enum ReadResult: Equatable {
        case descriptor(Descriptor)
        case absent
        case incomplete
    }

    @_spi(Testing) public enum BatchReadDisposition: Equatable {
        case values
        case fallbackRequired
        case incomplete
    }

    enum SingleAttributeReadDisposition: Equatable {
        case value
        case sparse
        case incomplete
    }

    struct SingleAttributeRead {
        let error: AXError
        let value: Any?
    }

    private struct AttributeValues {
        let position: CGPoint?
        let size: CGSize?
        let role: String?
        let title: String?
        let label: String?
        let value: String?
        let description: String?
        let help: String?
        let roleDescription: String?
        let identifier: String?
        let isEnabled: Bool?
        let isSelected: Bool?
        let isFocused: Bool?
        let placeholder: String?
    }

    private enum AttributeReadResult {
        case values(AttributeValues)
        case fallbackRequired
        case failed
    }

    private static let descriptorAttributeNames: [String] = [
        AttributeName.position,
        AttributeName.size,
        AttributeName.role,
        AttributeName.title,
        "AXLabel",
        AttributeName.value,
        AttributeName.description,
        AttributeName.help,
        AttributeName.roleDescription,
        AttributeName.identifier,
        AttributeName.enabled,
        AttributeName.selected,
        AttributeName.focused,
        AttributeName.placeholderValue,
    ]

    @_spi(Testing) public static var descriptorAttributeCount: Int {
        self.descriptorAttributeNames.count
    }

    @MainActor
    static func describe(_ element: Element) -> Descriptor? {
        guard case let .descriptor(descriptor) = self.read(element) else { return nil }
        return descriptor
    }

    @MainActor
    static func read(_ element: Element) -> ReadResult {
        let attributes: AttributeValues
        switch self.copyAttributes(for: element) {
        case let .values(values):
            attributes = values
        case .fallbackRequired:
            return self.describeWithSingleAttributeReads(element)
        case .failed:
            return .incomplete
        }

        return self.readResult(from: attributes)
    }

    @MainActor
    private static func describeWithSingleAttributeReads(_ element: Element) -> ReadResult {
        self.describeWithSingleAttributeReads { name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                element.underlyingElement,
                name as CFString,
                &value)
            return SingleAttributeRead(error: error, value: value)
        }
    }

    static func describeWithSingleAttributeReads(
        copyAttribute: (String) -> SingleAttributeRead) -> ReadResult
    {
        var valueByName: [String: Any] = [:]
        for name in self.descriptorAttributeNames {
            let read = copyAttribute(name)
            switch self.singleAttributeReadDisposition(
                error: read.error,
                value: read.value,
                attribute: name)
            {
            case .value:
                guard let value = read.value else { return .incomplete }
                valueByName[name] = value
            case .sparse:
                continue
            case .incomplete:
                return .incomplete
            }
        }
        return self.readResult(from: self.attributeValues(from: valueByName))
    }

    @MainActor
    private static func copyAttributes(for element: Element) -> AttributeReadResult {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element.underlyingElement,
            self.descriptorAttributeNames as CFArray,
            [],
            &rawValues)
        let values = rawValues as? [Any]
        switch self.batchReadDisposition(error: error, values: values) {
        case .fallbackRequired:
            return .fallbackRequired
        case .incomplete:
            return .failed
        case .values:
            break
        }
        guard let values else { return .failed }

        let valueByName = Dictionary(uniqueKeysWithValues: zip(self.descriptorAttributeNames, values))
        // Expected sparse attributes arrive as AXError-valued AXValues. Hard AX errors were rejected by
        // batchReadDisposition; the typed readers below treat only the remaining sparse entries as nil.
        return .values(self.attributeValues(from: valueByName))
    }

    private static func attributeValues(from valueByName: [String: Any]) -> AttributeValues {
        let role = self.stringValue(valueByName[AttributeName.role])
        let selected = self.boolValue(valueByName[AttributeName.selected])
            ?? self.booleanSelectionValue(role: role, rawValue: valueByName[AttributeName.value])
        return AttributeValues(
            position: self.cgPointValue(valueByName[AttributeName.position]),
            size: self.cgSizeValue(valueByName[AttributeName.size]),
            role: role,
            title: self.stringValue(valueByName[AttributeName.title]),
            label: self.stringValue(valueByName["AXLabel"]),
            value: self.displayValue(valueByName[AttributeName.value]),
            description: self.stringValue(valueByName[AttributeName.description]),
            help: self.stringValue(valueByName[AttributeName.help]),
            roleDescription: self.stringValue(valueByName[AttributeName.roleDescription]),
            identifier: self.stringValue(valueByName[AttributeName.identifier]),
            isEnabled: self.boolValue(valueByName[AttributeName.enabled]),
            isSelected: selected,
            isFocused: self.boolValue(valueByName[AttributeName.focused]),
            placeholder: self.stringValue(valueByName[AttributeName.placeholderValue]))
    }

    private static func readResult(from attributes: AttributeValues) -> ReadResult {
        let frame = CGRect(origin: attributes.position ?? .zero, size: attributes.size ?? .zero)
        guard self.isUsefulFrame(frame) else { return .absent }

        return .descriptor(Descriptor(
            frame: frame,
            role: attributes.role ?? "Unknown",
            title: attributes.title,
            label: attributes.label,
            value: attributes.value,
            description: attributes.description,
            help: attributes.help,
            roleDescription: attributes.roleDescription,
            identifier: attributes.identifier,
            isEnabled: attributes.isEnabled,
            isSelected: attributes.isSelected,
            isFocused: attributes.isFocused,
            placeholder: attributes.placeholder))
    }

    private static func booleanSelectionValue(role: String?, rawValue: Any?) -> Bool? {
        guard self.isBooleanSelectionRole(role) else { return nil }
        return self.boolValue(rawValue)
    }

    private static func isBooleanSelectionRole(_ role: String?) -> Bool {
        switch role?.lowercased() {
        case "axcheckbox", "axradiobutton", "axswitch":
            true
        default:
            false
        }
    }

    @_spi(Testing) public static func shouldFallbackToSingleAttributeReads(
        error: AXError,
        hasExpectedValueShape: Bool) -> Bool
    {
        if error == .success {
            return !hasExpectedValueShape
        }

        switch error {
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
            return true
        default:
            return false
        }
    }

    @_spi(Testing) public static func batchReadDisposition(
        error: AXError,
        values: [Any]?) -> BatchReadDisposition
    {
        let hasExpectedValueShape = values?.count == self.descriptorAttributeNames.count
        if self.shouldFallbackToSingleAttributeReads(
            error: error,
            hasExpectedValueShape: hasExpectedValueShape)
        {
            return .fallbackRequired
        }
        guard error == .success, let values else { return .incomplete }
        return AXAttributeReadCompletenessPolicy.hasNodeInvalidatingErrorValue(
            names: self.descriptorAttributeNames,
            values: values) ? .incomplete : .values
    }

    static func singleAttributeReadDisposition(
        error: AXError,
        value: Any?,
        attribute: String) -> SingleAttributeReadDisposition
    {
        if error == .success {
            guard let value else { return .incomplete }
            guard let embeddedError = AXAttributeReadCompletenessPolicy.embeddedError(in: value) else {
                return .value
            }
            return AXAttributeReadCompletenessPolicy.attributeErrorInvalidatesNode(
                embeddedError,
                attribute: attribute) ? .incomplete : .sparse
        }
        return AXAttributeReadCompletenessPolicy.attributeErrorInvalidatesNode(
            error,
            attribute: attribute) ? .incomplete : .sparse
    }

    @_spi(Testing) public static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    /// Normalizes the scalar shapes AXValue uses for user-visible control state.
    /// Descriptor strings such as titles must remain string-only, but values can legitimately be numbers or booleans.
    @_spi(Testing) public static func displayValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        if CFGetTypeID(cfValue) == CFBooleanGetTypeID() {
            return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        }
        if CFGetTypeID(cfValue) == CFNumberGetTypeID(), let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    @_spi(Testing) public static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        return (value as? NSNumber)?.boolValue
    }

    @_spi(Testing) public static func cgPointValue(_ value: Any?) -> CGPoint? {
        guard let axValue = self.axValue(value),
              AXValueGetType(axValue) == .cgPoint
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    @_spi(Testing) public static func cgSizeValue(_ value: Any?) -> CGSize? {
        guard let axValue = self.axValue(value),
              AXValueGetType(axValue) == .cgSize
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func axValue(_ value: Any?) -> AXValue? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(cfValue, to: AXValue.self)
    }

    private static func isUsefulFrame(_ frame: CGRect) -> Bool {
        frame.width > 5 && frame.height > 5
    }
}

private enum AttributeName {
    static let position = "AXPosition"
    static let size = "AXSize"
    static let role = "AXRole"
    static let title = "AXTitle"
    static let value = "AXValue"
    static let description = "AXDescription"
    static let help = "AXHelp"
    static let roleDescription = "AXRoleDescription"
    static let identifier = "AXIdentifier"
    static let enabled = "AXEnabled"
    static let selected = "AXSelected"
    static let focused = "AXFocused"
    static let placeholderValue = "AXPlaceholderValue"
}
