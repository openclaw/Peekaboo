import CoreGraphics
import Foundation
import PeekabooFoundation

extension InMemorySnapshotManager {
    func applyDetectionResult(_ result: ElementDetectionResult, to snapshotData: inout UIAutomationSnapshot) {
        if (snapshotData.screenshotPath ?? "").isEmpty, !result.screenshotPath.isEmpty {
            snapshotData.screenshotPath = result.screenshotPath
        }
        snapshotData.lastUpdateTime = Date()
        snapshotData.captureCoordinateContext = result.metadata.captureCoordinateContext ?? snapshotData
            .captureCoordinateContext

        if let context = result.metadata.windowContext {
            self.applyWindowContext(context, to: &snapshotData)
        } else {
            snapshotData.focusedElement = nil
            self.applyLegacyWarnings(result.metadata.warnings, to: &snapshotData)
        }

        var uiMap: [String: UIElement] = [:]
        uiMap.reserveCapacity(result.elements.all.count)
        for element in result.elements.all {
            let uiElement = UIElement(
                id: element.id,
                elementId: "element_\(uiMap.count)",
                role: element.attributes["role"] ?? self.convertElementTypeToRole(element.type),
                title: element.attributes["title"],
                label: element.label,
                value: element.value,
                description: element.attributes["description"],
                help: element.attributes["help"],
                roleDescription: element.attributes["roleDescription"],
                identifier: element.attributes["identifier"],
                confidence: element.attributes["confidence"].flatMap(Double.init),
                frame: element.bounds,
                isActionable: element.isActionable,
                isEnabled: element.knownIsEnabled,
                isSelected: element.isSelected,
                isValueSettable: element.isValueSettable,
                keyboardShortcut: element.attributes["keyboardShortcut"])
            uiMap[element.id] = uiElement
        }
        snapshotData.uiMap = uiMap
    }

    private func applyWindowContext(_ context: WindowContext, to snapshotData: inout UIAutomationSnapshot) {
        snapshotData.applicationName = context.applicationName ?? snapshotData.applicationName
        snapshotData.applicationBundleId = context.applicationBundleId ?? snapshotData.applicationBundleId
        snapshotData.applicationProcessId = context.applicationProcessId ?? snapshotData.applicationProcessId
        snapshotData.windowTitle = context.windowTitle ?? snapshotData.windowTitle
        snapshotData.windowBounds = context.windowBounds ?? snapshotData.windowBounds
        snapshotData.windowMutationIdentity = context.windowMutationIdentity ?? snapshotData.windowMutationIdentity
        snapshotData.focusedElement = context.focusedElement
        if let windowID = context.windowID {
            snapshotData.windowID = CGWindowID(windowID)
        }
    }

    private func applyLegacyWarnings(_ warnings: [String], to snapshotData: inout UIAutomationSnapshot) {
        for warning in warnings {
            if warning.hasPrefix("APP:") || warning.hasPrefix("app:") {
                snapshotData.applicationName = String(warning.dropFirst(4))
            } else if warning.hasPrefix("WINDOW:") || warning.hasPrefix("window:") {
                snapshotData.windowTitle = String(warning.dropFirst(7))
            } else if warning.hasPrefix("BOUNDS:"),
                      let boundsData = String(warning.dropFirst(7)).data(using: .utf8),
                      let bounds = try? JSONDecoder().decode(CGRect.self, from: boundsData)
            {
                snapshotData.windowBounds = bounds
            } else if warning.hasPrefix("WINDOW_ID:"),
                      let windowID = CGWindowID(String(warning.dropFirst(10)))
            {
                snapshotData.windowID = windowID
            } else if warning.hasPrefix("AX_IDENTIFIER:") {
                snapshotData.windowAXIdentifier = String(warning.dropFirst(14))
            }
        }
    }

    func detectionResult(
        from snapshotData: UIAutomationSnapshot,
        snapshotId: String) -> ElementDetectionResult?
    {
        guard let screenshotPath = snapshotData.annotatedPath ?? snapshotData.screenshotPath,
              !screenshotPath.isEmpty
        else {
            return nil
        }

        var allElements: [DetectedElement] = []
        allElements.reserveCapacity(snapshotData.uiMap.count)

        for uiElement in snapshotData.uiMap.values {
            var attributes: [String: String] = [:]
            if let identifier = uiElement.identifier {
                attributes["identifier"] = identifier
            }
            if let shortcut = uiElement.keyboardShortcut {
                attributes["keyboardShortcut"] = shortcut
            }
            attributes["role"] = uiElement.role
            if let title = uiElement.title {
                attributes["title"] = title
            }
            if let description = uiElement.description {
                attributes["description"] = description
            }
            if let help = uiElement.help {
                attributes["help"] = help
            }
            if let roleDescription = uiElement.roleDescription {
                attributes["roleDescription"] = roleDescription
            }
            if let confidence = uiElement.confidence {
                attributes["confidence"] = String(format: "%.2f", confidence)
            }
            attributes["isActionable"] = String(uiElement.isActionable)
            attributes["axEnabledKnown"] = String(uiElement.isEnabled != nil)
            if let isValueSettable = uiElement.isValueSettable {
                attributes["isValueSettable"] = String(isValueSettable)
            }
            let detectedElement = DetectedElement(
                id: uiElement.id,
                type: self.convertRoleToElementType(uiElement.role),
                label: uiElement.label ?? uiElement.title,
                value: uiElement.value,
                bounds: uiElement.frame,
                isEnabled: uiElement.isEnabled ?? uiElement.isActionable,
                isSelected: uiElement.isSelected,
                attributes: attributes)
            allElements.append(detectedElement)
        }

        let elements = self.organizeElementsByType(allElements)
        let metadata = DetectionMetadata(
            detectionTime: Date().timeIntervalSince(snapshotData.lastUpdateTime),
            elementCount: snapshotData.uiMap.count,
            method: "memory-cache",
            warnings: self.buildWarnings(from: snapshotData),
            windowContext: self.windowContext(from: snapshotData),
            isDialog: false,
            truncationInfo: nil,
            captureCoordinateContext: snapshotData.captureCoordinateContext)

        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: screenshotPath,
            elements: elements,
            metadata: metadata)
    }

    private func convertElementTypeToRole(_ type: ElementType) -> String {
        switch type {
        case .button: "AXButton"
        case .textField: "AXTextField"
        case .link: "AXLink"
        case .image: "AXImage"
        case .group: "AXGroup"
        case .slider: "AXSlider"
        case .checkbox: "AXCheckBox"
        case .menu: "AXMenu"
        case .staticText: "AXStaticText"
        case .radioButton: "AXRadioButton"
        case .menuItem: "AXMenuItem"
        case .window: "AXWindow"
        case .dialog: "AXDialog"
        case .other: "AXUnknown"
        }
    }

    private func convertRoleToElementType(_ role: String) -> ElementType {
        switch role {
        case "AXButton": .button
        case "AXTextField", "AXTextArea": .textField
        case "AXLink": .link
        case "AXImage": .image
        case "AXGroup": .group
        case "AXSlider": .slider
        case "AXCheckBox": .checkbox
        case "AXMenu": .menu
        case "AXMenuItem": .menuItem
        case "AXStaticText": .staticText
        case "AXRadioButton": .radioButton
        case "AXWindow": .window
        case "AXDialog": .dialog
        default: .other
        }
    }

    private func organizeElementsByType(_ elements: [DetectedElement]) -> DetectedElements {
        var buttons: [DetectedElement] = []
        var textFields: [DetectedElement] = []
        var links: [DetectedElement] = []
        var images: [DetectedElement] = []
        var groups: [DetectedElement] = []
        var sliders: [DetectedElement] = []
        var checkboxes: [DetectedElement] = []
        var menus: [DetectedElement] = []
        var other: [DetectedElement] = []

        for element in elements {
            switch element.type {
            case .button: buttons.append(element)
            case .textField: textFields.append(element)
            case .link: links.append(element)
            case .image: images.append(element)
            case .group: groups.append(element)
            case .slider: sliders.append(element)
            case .checkbox: checkboxes.append(element)
            case .menu, .menuItem: menus.append(element)
            case .other, .staticText, .radioButton, .window, .dialog: other.append(element)
            }
        }

        return DetectedElements(
            buttons: buttons,
            textFields: textFields,
            links: links,
            images: images,
            groups: groups,
            sliders: sliders,
            checkboxes: checkboxes,
            menus: menus,
            other: other)
    }

    private func buildWarnings(from snapshotData: UIAutomationSnapshot) -> [String] {
        var warnings: [String] = []
        if let appName = snapshotData.applicationName {
            warnings.append("APP:\(appName)")
        }
        if let windowTitle = snapshotData.windowTitle {
            warnings.append("WINDOW:\(windowTitle)")
        }
        if let windowBounds = snapshotData.windowBounds,
           let boundsData = try? JSONEncoder().encode(windowBounds),
           let boundsString = String(data: boundsData, encoding: .utf8)
        {
            warnings.append("BOUNDS:\(boundsString)")
        }
        if let windowID = snapshotData.windowID {
            warnings.append("WINDOW_ID:\(windowID)")
        }
        if let axIdentifier = snapshotData.windowAXIdentifier {
            warnings.append("AX_IDENTIFIER:\(axIdentifier)")
        }
        return warnings
    }

    private func windowContext(from snapshotData: UIAutomationSnapshot) -> WindowContext? {
        guard snapshotData.applicationName != nil ||
            snapshotData.applicationBundleId != nil ||
            snapshotData.applicationProcessId != nil ||
            snapshotData.windowTitle != nil ||
            snapshotData.windowID != nil ||
            snapshotData.windowBounds != nil ||
            snapshotData.windowMutationIdentity != nil
            || snapshotData.focusedElement != nil
        else {
            return nil
        }

        return WindowContext(
            applicationName: snapshotData.applicationName,
            applicationBundleId: snapshotData.applicationBundleId,
            applicationProcessId: snapshotData.applicationProcessId,
            windowTitle: snapshotData.windowTitle,
            windowID: snapshotData.windowID.map(Int.init),
            windowBounds: snapshotData.windowBounds,
            windowMutationIdentity: snapshotData.windowMutationIdentity,
            focusedElement: snapshotData.focusedElement)
    }
}
