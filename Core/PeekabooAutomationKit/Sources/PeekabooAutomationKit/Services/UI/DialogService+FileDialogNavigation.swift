import AppKit
import AXorcist
import Foundation

@MainActor
extension DialogService {
    func navigateToPath(
        _ filePath: String,
        in dialog: Element,
        ensureExpanded: Bool,
        appName: String?) async throws -> String
    {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        let targetURL = URL(fileURLWithPath: expandedPath)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory)

        let directoryPath: String = if exists, !isDirectory.boolValue {
            targetURL.deletingLastPathComponent().path
        } else if !targetURL.pathExtension.isEmpty {
            targetURL.deletingLastPathComponent().path
        } else {
            expandedPath
        }

        return try await self.navigateToDirectory(
            directoryPath: directoryPath,
            in: dialog,
            ensureExpanded: ensureExpanded,
            appName: appName)
    }

    func ensureDialogFocus(dialog: Element, appName: String?) async {
        guard let appName, let running = self.runningApplication(matching: appName) else {
            self.clickDialogCenterIfPossible(dialog)
            return
        }

        if NSWorkspace.shared.frontmostApplication?.processIdentifier != running.processIdentifier {
            _ = running.activate(options: [.activateAllWindows])
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        self.clickDialogCenterIfPossible(dialog)
    }

    func ensureFileDialogExpandedIfNeeded(dialog: Element) async throws {
        let identifierAttribute = Attribute<String>("AXIdentifier")

        func findDisclosureCandidate(in element: Element) -> Element? {
            firstUniqueDepthFirst(
                from: element,
                matching: { current in
                    if current.role() == "AXDisclosureTriangle" {
                        return true
                    }

                    let identifier = current.attribute(identifierAttribute) ?? ""
                    if identifier.localizedCaseInsensitiveContains("DISCLOSURE_TRIANGLE") ||
                        identifier.localizedCaseInsensitiveContains("DISCLOSURE") ||
                        identifier.localizedCaseInsensitiveContains("ShowDetails") ||
                        identifier.localizedCaseInsensitiveContains("HideDetails")
                    {
                        return true
                    }

                    let title = (current.title() ?? "").lowercased()
                    if title.contains("show details") || title.contains("hide details") {
                        return true
                    }

                    let description = (current.attribute(Attribute<String>("AXDescription")) ?? "").lowercased()
                    return description.contains("show details") || description.contains("hide details")
                },
                children: { self.sheetElements(for: $0) + ($0.children() ?? []) })
        }

        guard let disclosure = findDisclosureCandidate(in: dialog) else { return }

        // Only click if it appears to be collapsed, or if we can't infer state (we'll still try once).
        let title = (disclosure.title() ?? "").lowercased()
        let description = (disclosure.attribute(Attribute<String>("AXDescription")) ?? "").lowercased()
        let shouldClick = title.contains("show details") ||
            description.contains("show details") ||
            (title.isEmpty && description.isEmpty)
        guard shouldClick else { return }

        try self.pressOrClick(disclosure)
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func navigateToDirectory(
        directoryPath: String,
        in dialog: Element,
        ensureExpanded: Bool,
        appName: String?) async throws -> String
    {
        let identifierAttribute = Attribute<String>("AXIdentifier")
        let pathFieldIdentifier = "PathTextField"

        func findPathField(in element: Element) -> Element? {
            self.collectTextFields(from: element).first(where: { field in
                field.attribute(identifierAttribute) == pathFieldIdentifier
            })
        }

        var pathField = findPathField(in: dialog)

        if ensureExpanded {
            try await self.ensureFileDialogExpandedIfNeeded(dialog: dialog)
            pathField = findPathField(in: dialog)
        }

        await self.ensureDialogFocus(dialog: dialog, appName: appName)

        let requestedDirectory = URL(fileURLWithPath: directoryPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        var autoExpandedForNavigation = false
        if pathField == nil, !ensureExpanded {
            // When NSSavePanel/NSSOpenPanel is collapsed, Cmd+Shift+G (Go to Folder) is often ignored and the
            // PathTextField isn't in the AX tree. Best effort: expand once before falling back to Go to Folder.
            try? await self.ensureFileDialogExpandedIfNeeded(dialog: dialog)
            autoExpandedForNavigation = true
            pathField = findPathField(in: dialog)
        }

        guard let pathField else {
            try await self.navigateViaGoToFolder(directoryPath: requestedDirectory, dialog: dialog, appName: appName)
            return autoExpandedForNavigation ? "go_to_folder+auto_expand" : "go_to_folder"
        }

        var method = "path_textfield"

        self.focusTextField(pathField)
        if pathField.isAttributeSettable(named: AXAttributeNames.kAXValueAttribute),
           pathField.setValue(requestedDirectory, forAttribute: AXAttributeNames.kAXValueAttribute)
        {
            // Some NSSavePanel implementations don't update AXValue immediately; commit via Return below.
            method = "path_textfield_axvalue"
        } else {
            try? InputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.05)
            try await Task.sleep(nanoseconds: 75_000_000)
            try self.typeTextValue(requestedDirectory, delay: 5000)
            method = "path_textfield_typed"
        }
        try InputDriver.tapKey(.return)
        try await Task.sleep(nanoseconds: 250_000_000)

        let rawValue = pathField.value() as? String
        if let rawValue, !rawValue.isEmpty {
            let actualDirectory = URL(fileURLWithPath: rawValue)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            if actualDirectory != requestedDirectory {
                self.logger.debug("PathTextField mismatch; Go to Folder.")
                self.logger.debug("requested: \(requestedDirectory), actual: \(actualDirectory)")
                try await self.navigateViaGoToFolder(
                    directoryPath: requestedDirectory,
                    dialog: dialog,
                    appName: appName)
                method += "+fallback_go_to_folder"
            }
        } else {
            self.logger.debug("PathTextField did not expose an AXValue; falling back to Go to Folder")
            try await self.navigateViaGoToFolder(
                directoryPath: requestedDirectory,
                dialog: dialog,
                appName: appName)
            method += "+fallback_go_to_folder"
        }

        return method
    }

    private func clickDialogCenterIfPossible(_ dialog: Element) {
        guard let position = dialog.position(),
              let size = dialog.size(),
              size.width > 0,
              size.height > 0
        else {
            return
        }

        let point = CGPoint(x: position.x + size.width / 2.0, y: position.y + size.height / 2.0)
        try? InputDriver.click(at: point)
    }

    private func navigateViaGoToFolder(directoryPath: String, dialog: Element, appName: String?) async throws {
        await self.ensureDialogFocus(dialog: dialog, appName: appName)
        // Cmd+Shift+G is unreliable when the panel is collapsed; try to expand first.
        try? await self.ensureFileDialogExpandedIfNeeded(dialog: dialog)
        self.logger.debug("Navigating via Go to Folder (Cmd+Shift+G): \(directoryPath)")

        try await self.performGoToFolderKeyboardNavigation(directoryPath: directoryPath) {
            // Best effort: re-assert focus before typing into the Go-to sheet.
            await self.ensureDialogFocus(dialog: dialog, appName: appName)
        }
        try await Task.sleep(nanoseconds: 450_000_000)
    }

    func performGoToFolderKeyboardNavigation(
        directoryPath: String,
        reassertFocus: () async -> Void) async throws
    {
        try self.syntheticInputDriver.hotkey(keys: ["cmd", "shift", "g"], holdDuration: 0.05)
        try await Task.sleep(nanoseconds: 250_000_000)
        await reassertFocus()
        try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.05)
        try await Task.sleep(nanoseconds: 75_000_000)
        try self.syntheticInputDriver.type(directoryPath, delayPerCharacter: 0.005)
        try self.syntheticInputDriver.tapKey(.return, modifiers: [])
    }
}
