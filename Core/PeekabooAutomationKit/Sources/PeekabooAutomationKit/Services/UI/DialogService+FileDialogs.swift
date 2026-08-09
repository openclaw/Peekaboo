import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    public func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool = false,
        appName: String?) async throws -> DialogActionResult
    {
        self.logger.info("Handling file dialog")
        if let path {
            self.logger.debug("Path: \(path)")
        }
        if let filename {
            self.logger.debug("Filename: \(filename)")
        }
        if let actionButton {
            self.logger.debug("Action button: \(actionButton)")
        } else {
            self.logger.debug("Action button: (default/OKButton)")
        }

        let saveStartTime = Date()
        var resolution = try await self.resolveFileDialogElementResolution(appName: appName)
        var dialog = resolution.element
        var details: [String: String] = [
            "dialog_identifier": resolution.dialogIdentifier,
            "found_via": resolution.foundVia,
        ]

        await self.ensureDialogFocus(dialog: dialog, appName: appName)

        if ensureExpanded {
            try await self.ensureFileDialogExpandedIfNeeded(dialog: dialog)
            // Expanding can rebuild the AX tree; re-resolve.
            resolution = try await self.resolveFileDialogElementResolution(appName: appName)
            dialog = resolution.element
            details["dialog_identifier"] = resolution.dialogIdentifier
            details["found_via"] = resolution.foundVia
            details["ensure_expanded"] = "true"
        }

        if let filePath = path {
            let navigation = try await self.navigateToPath(
                filePath,
                in: dialog,
                ensureExpanded: ensureExpanded,
                appName: appName)
            details["path"] = filePath
            details["path_navigation_method"] = navigation

            // Navigating the path can expand/collapse the panel and rebuild the sheet tree. Re-resolve the active
            // file dialog after navigation so subsequent actions (filename + action button) target fresh AX handles.
            resolution = try await self.resolveFileDialogElementResolution(appName: appName)
            dialog = resolution.element
            details["dialog_identifier"] = resolution.dialogIdentifier
            details["found_via"] = resolution.foundVia
        }

        if let fileName = filename {
            try self.updateFilename(fileName, in: dialog)
            details["filename"] = fileName
        }

        let shouldCapturePriorDocumentPath = actionButton == nil ||
            self.isSaveLikeAction(actionButton ?? "")

        let priorDocumentPath: String? = if shouldCapturePriorDocumentPath {
            self.documentPathForApp(appName: appName)
        } else {
            nil
        }

        // The file panel can swap sheets (e.g. Go to Folder) or rebuild its button tree after typing.
        // Re-resolve the active file dialog right before clicking to avoid stale AX element handles.
        resolution = try await self.resolveFileDialogElementResolution(appName: appName)
        dialog = resolution.element
        details["dialog_identifier"] = resolution.dialogIdentifier
        details["found_via"] = resolution.foundVia

        let requestedButton = actionButton?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRequested = requestedButton.map(self.normalizedDialogButtonTitle)
        let resolvedActionButton: String = if normalizedRequested == "default" || requestedButton == nil {
            "default"
        } else {
            requestedButton ?? "default"
        }

        let clickResult = try await self.clickButton(
            in: dialog,
            buttonText: resolvedActionButton,
            allowFallbackToDefaultAction: true,
            allowGlobalFallback: true)
        details["button_clicked"] = clickResult.details["button"] ?? resolvedActionButton
        if let buttonIdentifier = clickResult.details["button_identifier"] {
            details["button_identifier"] = buttonIdentifier
        }

        let clickedTitle = clickResult.details["button"] ?? resolvedActionButton
        if self.isSaveLikeAction(clickedTitle) {
            let expectedPath = self.expectedSavedPath(path: path, filename: filename)
            let expectedBaseName = self.expectedSavedBaseName(filename: filename, expectedPath: expectedPath)

            do {
                let verification = try await self.verifySavedFile(
                    SavedFileVerificationRequest(
                        appName: appName,
                        priorDocumentPath: priorDocumentPath,
                        expectedPath: expectedPath,
                        expectedBaseName: expectedBaseName,
                        startedAt: saveStartTime,
                        timeout: 5.0))

                details["saved_path"] = verification.path
                details["saved_path_exists"] = "true"
                details["saved_path_verified"] = "true"
                details["saved_path_found_via"] = verification.foundVia

                if let expectedPath {
                    details["saved_path_matches_expected"] = String(verification.path == expectedPath)
                    if verification.path != expectedPath {
                        details["saved_path_expected"] = expectedPath
                    }
                }

                try self.enforceExpectedDirectoryIfNeeded(
                    actualSavedPath: verification.path,
                    expectedPath: expectedPath,
                    details: &details)
            } catch let error as DialogError {
                guard case .fileVerificationFailed = error else { throw error }
                let didReplace = await self.clickReplaceIfPresent(appName: appName)
                guard didReplace else { throw error }

                let retryStart = Date()
                let verification = try await self.verifySavedFile(
                    SavedFileVerificationRequest(
                        appName: appName,
                        priorDocumentPath: priorDocumentPath,
                        expectedPath: expectedPath,
                        expectedBaseName: expectedBaseName,
                        startedAt: retryStart,
                        timeout: 5.0))

                details["saved_path"] = verification.path
                details["saved_path_exists"] = "true"
                details["saved_path_verified"] = "true"
                details["saved_path_found_via"] = verification.foundVia
                details["overwrite_confirmed"] = "true"

                if let expectedPath {
                    details["saved_path_matches_expected"] = String(verification.path == expectedPath)
                    if verification.path != expectedPath {
                        details["saved_path_expected"] = expectedPath
                    }
                }

                try self.enforceExpectedDirectoryIfNeeded(
                    actualSavedPath: verification.path,
                    expectedPath: expectedPath,
                    details: &details)
            }
        }

        let result = DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: details)

        self.logger.info("\(AgentDisplayTokens.Status.success) Successfully handled file dialog")
        return result
    }
}
