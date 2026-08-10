import PeekabooFoundation

/// Deterministic element classification policy for AX-derived descriptors.
@_spi(Testing) public enum ElementClassifier {
    public struct AttributeInput: Sendable, Equatable {
        public let role: String
        public let title: String?
        public let description: String?
        public let help: String?
        public let roleDescription: String?
        public let identifier: String?
        public let isActionable: Bool
        public let keyboardShortcut: String?
        public let placeholder: String?

        public init(
            role: String,
            title: String? = nil,
            description: String? = nil,
            help: String? = nil,
            roleDescription: String? = nil,
            identifier: String? = nil,
            isActionable: Bool = false,
            keyboardShortcut: String? = nil,
            placeholder: String? = nil)
        {
            self.role = role
            self.title = title
            self.description = description
            self.help = help
            self.roleDescription = roleDescription
            self.identifier = identifier
            self.isActionable = isActionable
            self.keyboardShortcut = keyboardShortcut
            self.placeholder = placeholder
        }
    }

    private static let textFieldRoles: Set<String> = [
        "axtextfield",
        "axtextarea",
        "axsearchfield",
        "axsecuretextfield",
    ]
    private static let actionableRoles: Set<String> = [
        "axbutton", "axpopupbutton", "axtextfield", "axlink", "axweblink",
        "axcheckbox", "axradiobutton", "axmenuitem", "axcombobox",
        "axslider", "axtab",
    ]
    /// AXPress lookup is expensive. Keep it to container-ish roles where Chromium/Tauri can hide clickable content.
    private static let supportedActionLookupRoles: Set<String> = [
        "axgroup", "aximage", "axcell", "axrow", "axoutlineitem",
    ]
    private static let keyboardShortcutRoles: Set<String> = [
        "axbutton", "axpopupbutton", "axcheckbox", "axradiobutton",
        "axmenuitem", "axtab",
    ]
    private static let valueMetadataRoles: Set<String> = [
        "axcheckbox", "axcombobox", "axdatefield", "axincrementor", "axpopupbutton",
        "axradiobutton", "axscrollbar", "axsearchfield", "axsecuretextfield", "axslider",
        "axswitch", "axtextarea", "axtextfield",
    ]

    public static func elementType(for role: String) -> ElementType {
        let normalizedRole = role.lowercased()
        switch normalizedRole {
        case "axbutton", "axpopupbutton":
            return .button
        case _ where self.textFieldRoles.contains(normalizedRole):
            return .textField
        case "axlink", "axweblink":
            return .link
        case "aximage":
            return .image
        case "axstatictext", "axtext":
            return .other // text not in protocol
        case "axcheckbox":
            return .checkbox
        case "axradiobutton":
            return .checkbox // Use checkbox for radio buttons
        case "axcombobox":
            return .other // Not in protocol
        case "axslider":
            return .slider
        case "axmenu":
            return .menu
        case "axmenuitem":
            return .other // menuItem not in protocol
        case "axtab":
            return .other // Not in protocol
        case "axtable":
            return .other // Not in protocol
        case "axlist":
            return .other // Not in protocol
        case "axgroup":
            return .group
        case "axtoolbar":
            return .other // Not in protocol
        case "axwindow":
            return .other // Not in protocol
        default:
            return .other
        }
    }

    public static func roleIsActionable(_ role: String) -> Bool {
        self.actionableRoles.contains(role.lowercased())
    }

    public static func shouldLookupActions(for role: String) -> Bool {
        self.supportedActionLookupRoles.contains(role.lowercased())
    }

    public static func supportsKeyboardShortcut(for role: String) -> Bool {
        self.keyboardShortcutRoles.contains(role.lowercased())
    }

    public static func supportsValueMetadata(for role: String) -> Bool {
        self.valueMetadataRoles.contains(role.lowercased())
    }

    public static func attributes(from input: AttributeInput) -> [String: String] {
        var attributes: [String: String] = [:]

        attributes["role"] = input.role
        if let title = input.title {
            attributes["title"] = title
        }
        if let description = input.description {
            attributes["description"] = description
        }
        if let help = input.help {
            attributes["help"] = help
        }
        if let roleDescription = input.roleDescription {
            attributes["roleDescription"] = roleDescription
        }
        if let identifier = input.identifier {
            attributes["identifier"] = identifier
        }
        if input.isActionable {
            attributes["isActionable"] = "true"
        }
        if let shortcut = input.keyboardShortcut {
            attributes["keyboardShortcut"] = shortcut
        }
        if let placeholder = input.placeholder {
            attributes["placeholder"] = placeholder
        }

        return attributes
    }
}
