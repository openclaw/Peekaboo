import PeekabooAutomationKit

enum DetectedElementSnapshotConverter {
    static func convert(_ detected: [DetectedElement]) -> [UIElement] {
        detected.map { element in
            UIElement(
                id: element.id,
                elementId: element.id,
                role: element.attributes["role"] ?? element.type.rawValue,
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
                parentId: nil,
                children: [],
                keyboardShortcut: element.attributes["keyboardShortcut"])
        }
    }
}
