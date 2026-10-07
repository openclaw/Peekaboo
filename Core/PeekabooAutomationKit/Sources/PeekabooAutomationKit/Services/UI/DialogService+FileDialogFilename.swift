import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    func updateFilename(
        _ fileName: String,
        in dialog: Element,
        execution: FileExecution? = nil) async throws -> DesktopActionOutcome?
    {
        var sequence = DesktopActionSequenceAccumulator()
        do {
            self.logger.debug("Setting filename in dialog")
            let textFields = try await self.fileDialogControls(in: dialog, execution: execution, role: "AXTextField")
            guard !textFields.isEmpty else {
                self.logger.error("No text fields found in file dialog")
                throw DialogError.noTextFields
            }

            let expectedBaseName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent.lowercased()
            let identifierAttribute = Attribute<String>("AXIdentifier")

            func fieldScore(_ field: Element) -> Int {
                let title = (field.title() ?? "").lowercased()
                let placeholder = (field.attribute(Attribute<String>("AXPlaceholderValue")) ?? "").lowercased()
                let description = (field.attribute(Attribute<String>("AXDescription")) ?? "").lowercased()
                let identifier = (field.attribute(identifierAttribute) ?? "").lowercased()
                let combined = "\(title) \(placeholder) \(description) \(identifier)"

                if combined.contains("tags") {
                    return 100
                }
                if combined.contains("save") ||
                    combined.contains("file name") ||
                    combined.contains("filename") ||
                    combined.contains("name")
                {
                    return 0
                }

                let value = (field.value() as? String) ?? ""
                if !value.isEmpty {
                    return 10
                }
                return 50
            }

            let fieldsToTry: [Element] = if let saveAsField = textFields.first(where: { field in
                field.attribute(identifierAttribute) == "saveAsNameTextField"
            }) {
                [saveAsField]
            } else {
                textFields
                    .filter { $0.isEnabled() ?? true }
                    .compactMap { field -> (field: Element, score: Int, position: CGPoint)? in
                        guard let position = field.position() else { return nil }
                        return (field: field, score: fieldScore(field), position: position)
                    }
                    .sorted(by: { lhs, rhs in
                        if lhs.score != rhs.score {
                            return lhs.score < rhs.score
                        }
                        if lhs.position.y != rhs.position.y {
                            return lhs.position.y < rhs.position.y
                        }
                        return lhs.position.x < rhs.position.x
                    })
                    .map(\.field)
            }

            for (index, field) in fieldsToTry.indexed() {
                try self.requireFileExecutionFocus(execution)
                try sequence.record(.outcome(self.focusTextField(field)))
                if let outcome = try self.setFileDialogValue(fileName, field: field) {
                    sequence.record(.outcome(outcome))
                    // Commit below by sending a small delay; some panels apply filename changes lazily.
                } else {
                    try self.requireFileExecutionFocus(execution, field: field)
                    try sequence.record(.outcome(self.fileDialogGlobalInput(operation: "select the filename field") {
                        try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.05)
                    }))
                    try await Task.sleep(for: .milliseconds(75))
                    try self.requireFileExecutionFocus(execution, field: field)
                    try sequence.record(.outcome(self.typeTextValue(fileName, delay: 5000)))
                }
                try await Task.sleep(for: .milliseconds(150))

                if let updatedValue = field.value() as? String {
                    let actualBaseName = URL(fileURLWithPath: updatedValue)
                        .deletingPathExtension()
                        .lastPathComponent
                        .lowercased()
                    if actualBaseName == expectedBaseName || actualBaseName.hasPrefix(expectedBaseName) {
                        self.logger.debug("Filename set using text field index \(index)")
                        return sequence.successResolution().outcome
                    }
                }

                // Many NSSavePanel implementations (including TextEdit) do not reliably expose the live text field
                // contents via AXValue. If we successfully focused a plausible field and typed the name, treat the
                // attempt as best-effort and continue the flow; the subsequent save verification will catch failures.
                if index == 0 {
                    self.logger.debug(
                        "Typed filename into first candidate text field; proceeding without AXValue confirmation")
                    return sequence.successResolution().outcome
                }
            }

            self.logger.debug(
                """
                Typed filename into \(fieldsToTry.count) candidate text fields; proceeding without AXValue \
                confirmation
                """)
            return sequence.successResolution().outcome
        } catch {
            throw Self.preservingFileDialogFailure(error, after: sequence, target: nil)
        }
    }
}
