import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    static func isUnsafeFileDialogFilenameField(_ field: Element) -> Bool {
        let metadata = [
            field.attribute(Attribute<String>("AXIdentifier")) ?? "",
            field.attribute(Attribute<String>("AXRoleDescription")) ?? "",
            field.title() ?? "",
            field.attribute(Attribute<String>("AXPlaceholderValue")) ?? "",
            field.attribute(Attribute<String>("AXDescription")) ?? "",
        ]
        let normalizedMetadata = metadata.map { $0.lowercased() }
        if field.isSearchField() || normalizedMetadata.contains(where: {
            $0.contains("search") || $0.contains("filter") || $0.contains("comment") ||
                $0.contains("tagfield") || $0.contains("tagsfield")
        }) {
            return true
        }
        let unsafeWords = Set(["tag", "tags"])
        let words = metadata.flatMap { value in
            value
                .replacingOccurrences(
                    of: "([a-z0-9])([A-Z])",
                    with: "$1 $2",
                    options: .regularExpression)
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        return words.contains(where: unsafeWords.contains)
    }

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
            let enabledFields = textFields.filter { $0.isEnabled() ?? true }
            let nativeFields = enabledFields.filter {
                $0.attribute(Attribute<String>("AXIdentifier")) == "saveAsNameTextField"
            }
            let fieldsToTry: [Element] = if nativeFields.count == 1 {
                nativeFields
            } else if nativeFields.isEmpty, enabledFields.count == 1,
                      let field = enabledFields.first, !Self.isUnsafeFileDialogFilenameField(field)
            {
                [field]
            } else {
                []
            }
            guard !fieldsToTry.isEmpty else {
                self.logger.error("No safe filename field found in file dialog")
                throw DialogError.noFilenameField
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
