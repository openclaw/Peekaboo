import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

enum DialogMetadataReader {
    typealias AttributeCopy = @Sendable (AXUIElement, String) -> (error: AXError, value: CFTypeRef?)

    @MainActor
    static func read(
        _ element: Element,
        owner: ApplicationProcessIdentity,
        budget: DialogOperationDeadline,
        copyAttribute: @escaping AttributeCopy = Self.copyAttribute) async throws -> DialogElements
    {
        let identity = DialogAXReadIdentity(element: element.underlyingElement)
        let reader = Reader(budget: budget, copyAttribute: copyAttribute)
        return try await DialogAXReadRunner.run(owner: owner, budget: budget) {
            try reader.metadata(for: identity)
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error, value)
    }

    private struct Reader: Sendable {
        let budget: DialogOperationDeadline
        let copyAttribute: AttributeCopy

        /// Preserve AXorcist's default child collection for legacy button/field metadata. Static text
        /// deliberately uses structural children only; neither path changes dialog candidate discovery.
        private static let alternativeChildAttributes = [
            "AXVisibleChildren", "AXWebAreaChildren", "AXApplicationNavigation", "AXApplicationElements",
            "AXBodyArea", "AXSplitGroupContents", "AXLayoutAreaChildren", "AXGroupChildren", "AXContents",
            "AXChildrenInNavigationOrder", "AXSelectedChildren", "AXRows", "AXColumns", "AXTabs",
        ]

        func metadata(for dialog: DialogAXReadIdentity) throws -> DialogElements {
            let info = try DialogInfo(
                title: self.string(kAXTitleAttribute, on: dialog) ?? "Untitled Dialog",
                role: self.string(kAXRoleAttribute, on: dialog) ?? "Unknown",
                subrole: self.string(kAXSubroleAttribute, on: dialog),
                isFileDialog: self.isFileDialog(dialog),
                bounds: self.bounds(dialog))
            return try DialogElements(
                dialogInfo: info,
                buttons: self.buttons(dialog),
                textFields: self.textFields(dialog),
                staticTexts: self.staticTexts(dialog),
                otherElements: self.otherElements(dialog))
        }

        private func value(_ name: String, on element: DialogAXReadIdentity) throws -> CFTypeRef? {
            try self.budget.check()
            let result = self.copyAttribute(element.element, name)
            try self.budget.check()
            // Metadata is optional output, unlike hierarchy evidence establishing unique membership.
            // Preserve its missing/error defaults; deadline and cancellation always remain fatal.
            return result.error == .success ? result.value : nil
        }

        private func string(_ name: String, on element: DialogAXReadIdentity) throws -> String? {
            guard let value = try self.value(name, on: element) else { return nil }
            if CFGetTypeID(value) == CFStringGetTypeID() {
                return value as? String
            }
            if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
                return unsafeDowncast(value, to: NSAttributedString.self).string
            }
            return nil
        }

        private func bool(_ name: String, on element: DialogAXReadIdentity) throws -> Bool? {
            try self.value(name, on: element) as? Bool
        }

        private func bounds(_ element: DialogAXReadIdentity) throws -> CGRect {
            guard let position = try self.value(kAXPositionAttribute, on: element),
                  CFGetTypeID(position) == AXValueGetTypeID()
            else { return .zero }
            let positionValue = unsafeDowncast(position, to: AXValue.self)
            var point = CGPoint.zero
            guard AXValueGetType(positionValue) == .cgPoint,
                  AXValueGetValue(positionValue, .cgPoint, &point),
                  let size = try self.value(kAXSizeAttribute, on: element),
                  CFGetTypeID(size) == AXValueGetTypeID()
            else { return .zero }
            let sizeValue = unsafeDowncast(size, to: AXValue.self)
            var dimensions = CGSize.zero
            guard AXValueGetType(sizeValue) == .cgSize,
                  AXValueGetValue(sizeValue, .cgSize, &dimensions)
            else { return .zero }
            return CGRect(origin: point, size: dimensions)
        }

        private func elements(_ name: String, on element: DialogAXReadIdentity) throws -> [DialogAXReadIdentity] {
            guard let value = try self.value(name, on: element),
                  CFGetTypeID(value) == CFArrayGetTypeID(),
                  let values = value as? [AnyObject],
                  values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
            else { return [] }
            return values.map { DialogAXReadIdentity(element: unsafeDowncast($0, to: AXUIElement.self)) }
        }

        private func children(of element: DialogAXReadIdentity, strict: Bool) throws -> [DialogAXReadIdentity] {
            var result: [DialogAXReadIdentity] = []
            var visited: Set<DialogAXReadIdentity> = []
            func append(_ children: [DialogAXReadIdentity]) {
                // This is AXorcist's existing per-parent collection limit, not a new traversal bound.
                for child in children {
                    guard result.count < 50000 else { return }
                    if visited.insert(child).inserted {
                        result.append(child)
                    }
                }
            }
            try append(self.elements(kAXChildrenAttribute, on: element))
            if !strict {
                for name in Self.alternativeChildAttributes {
                    try append(self.elements(name, on: element))
                }
            }
            if try self.string(kAXRoleAttribute, on: element) == "AXApplication" {
                try append(self.elements(kAXWindowsAttribute, on: element))
            }
            if try self.string(kAXRoleAttribute, on: element) == "AXApplication",
               let focused = try self.value(kAXFocusedUIElementAttribute, on: element),
               CFGetTypeID(focused) == AXUIElementGetTypeID()
            {
                append([DialogAXReadIdentity(element: unsafeDowncast(focused, to: AXUIElement.self))])
            }
            return result
        }

        private func collect(
            from dialog: DialogAXReadIdentity,
            roles: Set<String>,
            structuralTextOnly: Bool = false) throws -> [DialogAXReadIdentity]
        {
            var result: [DialogAXReadIdentity] = []
            var visited: Set<DialogAXReadIdentity> = []
            var stack = [dialog]
            while let element = stack.popLast() {
                try self.budget.check()
                guard visited.insert(element).inserted else { continue }
                if let role = try self.string(kAXRoleAttribute, on: element), roles.contains(role) {
                    result.append(element)
                }
                if structuralTextOnly, element != dialog {
                    let role = try self.string(kAXRoleAttribute, on: element)
                    if role == "AXApplication" || role == "AXWindow" {
                        continue
                    }
                }
                try stack.append(contentsOf: self.children(of: element, strict: structuralTextOnly).reversed())
            }
            return result
        }

        private func isFileDialog(_ dialog: DialogAXReadIdentity) throws -> Bool {
            let evidence = try DialogElementEvidence(
                role: self.string(kAXRoleAttribute, on: dialog) ?? "",
                subrole: self.string(kAXSubroleAttribute, on: dialog) ?? "",
                roleDescription: self.string(kAXRoleDescriptionAttribute, on: dialog) ?? "",
                identifier: self.string(kAXIdentifierAttribute, on: dialog) ?? "",
                title: self.string(kAXTitleAttribute, on: dialog) ?? "",
                isModal: self.bool(kAXModalAttribute, on: dialog))
            if DialogElementClassifier.isFileDialog(evidence) {
                return true
            }

            let buttons = try self.collect(from: dialog, roles: ["AXButton"])
            let titles = try Set(buttons.compactMap { try self.string(kAXTitleAttribute, on: $0)?.lowercased() })
            let identifiers = try Set(buttons.compactMap { try self.string(kAXIdentifierAttribute, on: $0) })
            let hasCancel = titles.contains("cancel") || identifiers.contains("CancelButton")
            let hasPrimary = ["save", "open", "choose", "replace", "export", "import"].contains {
                titles.contains($0)
            } || identifiers.contains("OKButton")
            return hasCancel && hasPrimary
        }

        private func buttons(_ dialog: DialogAXReadIdentity) throws -> [DialogButton] {
            try self.collect(from: dialog, roles: ["AXButton"]).compactMap { button in
                guard let title = try self.string(kAXTitleAttribute, on: button) else { return nil }
                return try DialogButton(
                    title: title,
                    isEnabled: self.bool(kAXEnabledAttribute, on: button) ?? true,
                    isDefault: self.bool("AXDefault", on: button) ?? false)
            }
        }

        private func textFields(_ dialog: DialogAXReadIdentity) throws -> [DialogTextField] {
            try self.collect(from: dialog, roles: ["AXTextField", "AXTextArea"]).enumerated().map { index, field in
                try DialogTextField(
                    title: self.string(kAXTitleAttribute, on: field),
                    value: self.string(kAXValueAttribute, on: field),
                    placeholder: self.string("AXPlaceholderValue", on: field),
                    index: index,
                    isEnabled: self.bool(kAXEnabledAttribute, on: field) ?? true)
            }
        }

        private func staticTexts(_ dialog: DialogAXReadIdentity) throws -> [String] {
            try self.collect(from: dialog, roles: ["AXStaticText"], structuralTextOnly: true).compactMap { element in
                try [kAXValueAttribute, kAXTitleAttribute, "AXLabel", kAXDescriptionAttribute]
                    .compactMap { try self.string($0, on: element) }
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        }

        private func otherElements(_ dialog: DialogAXReadIdentity) throws -> [DialogElement] {
            let excluded: Set = ["AXButton", "AXTextField", "AXTextArea", "AXStaticText"]
            let children = try self.children(of: dialog, strict: false).filter {
                try !excluded.contains(self.string(kAXRoleAttribute, on: $0) ?? "")
            }
            return try children.compactMap { element in
                guard let role = try self.string(kAXRoleAttribute, on: element) else { return nil }
                return try DialogElement(
                    role: role,
                    title: self.string(kAXTitleAttribute, on: element),
                    value: self.string(kAXValueAttribute, on: element))
            }
        }
    }
}
