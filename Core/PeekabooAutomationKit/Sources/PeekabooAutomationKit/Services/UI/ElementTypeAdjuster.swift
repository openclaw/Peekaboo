import PeekabooFoundation

@_spi(Testing) public struct ElementTypeAdjustmentInput: Sendable, Equatable {
    public let role: String
    public let roleDescription: String?
    public let title: String?
    public let label: String?
    public let placeholder: String?
    public let isEditable: Bool

    public init(
        role: String,
        roleDescription: String?,
        title: String?,
        label: String?,
        placeholder: String?,
        isEditable: Bool)
    {
        self.role = role
        self.roleDescription = roleDescription
        self.title = title
        self.label = label
        self.placeholder = placeholder
        self.isEditable = isEditable
    }
}

/// Applies Peekaboo's text-field recovery heuristics to AX-derived element types.
@_spi(Testing) public enum ElementTypeAdjuster {
    private static let textFieldKeywords = ["email", "password", "username", "phone", "code"]

    public static func resolve(
        baseType: ElementType,
        input: ElementTypeAdjustmentInput,
        hasTextFieldDescendant: Bool)
        -> ElementType
    {
        let resolved = self.roleResolvedType(baseType: baseType, input: input)
        guard self.canRecoverTextField(baseType: resolved, input: input) else {
            return resolved
        }

        if self.hasTextFieldHint(input) || hasTextFieldDescendant {
            return .textField
        }

        return resolved
    }

    /// SwiftUI and web accessibility bridges can collapse an input into a static-text proxy while
    /// retaining text-entry metadata. Preserve an explicitly assigned identifier, but unwrap the
    /// conventional group proxy prefix when the proxy itself is promoted to the hidden control.
    public static func resolveIdentifier(
        _ identifier: String?,
        baseType: ElementType,
        resolvedType: ElementType) -> String?
    {
        guard baseType != .textField,
              resolvedType == .textField,
              let identifier,
              identifier.hasPrefix("group-"),
              identifier.count > "group-".count
        else {
            return identifier
        }
        return String(identifier.dropFirst("group-".count))
    }

    public static func shouldScanForTextFieldDescendant(
        baseType: ElementType,
        input: ElementTypeAdjustmentInput)
        -> Bool
    {
        self.roleResolvedType(baseType: baseType, input: input) == .group && !self.hasTextFieldHint(input)
    }

    private static func roleResolvedType(baseType: ElementType, input: ElementTypeAdjustmentInput) -> ElementType {
        ElementRoleResolver.resolveType(
            baseType: baseType,
            info: ElementRoleInfo(
                role: input.role,
                roleDescription: input.roleDescription,
                isEditable: input.isEditable))
    }

    private static func hasTextFieldHint(_ input: ElementTypeAdjustmentInput) -> Bool {
        if input.placeholder?.isEmpty == false {
            return true
        }

        let loweredTitle = input.title?.lowercased()
        let loweredLabel = input.label?.lowercased()
        return loweredTitle.map { title in self.textFieldKeywords.contains(where: { title.contains($0) }) } ?? false ||
            loweredLabel.map { label in self.textFieldKeywords.contains(where: { label.contains($0) }) } ?? false
    }

    private static func canRecoverTextField(baseType: ElementType, input: ElementTypeAdjustmentInput) -> Bool {
        if baseType == .group {
            return true
        }

        // A placeholder on AXStaticText is not ordinary rendered text; it is the strongest portable signal
        // left by frameworks that flatten an editable child into its accessibility wrapper.
        return baseType == .other &&
            input.role.caseInsensitiveCompare("AXStaticText") == .orderedSame &&
            input.placeholder?.isEmpty == false
    }
}
