import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    struct SavedFileVerification {
        let path: String
        let foundVia: String
    }

    struct SavedFileVerificationRequest {
        let appName: String?
        let priorDocumentPath: String?
        let expectedPath: String?
        let expectedBaseName: String?
        let startedAt: Date
        let timeout: TimeInterval
        let retainedTarget: UIAutomationTarget.ExactWindow
    }

    struct CompletedSavedFileVerification {
        let verification: SavedFileVerification
        let overwriteConfirmed: Bool
        let target: UIAutomationTarget.ExactWindow
    }

    struct OverwriteConfirmationCandidate {
        let target: UIAutomationTarget.ExactWindow
        let dialog: Element
        let button: Element
    }

    private struct RetainedFileDialogWindowObservation {
        let window: Element
        let listedWindows: [ServiceWindowInfo]
    }

    func verifySavedFileAfterAction(
        request: SavedFileVerificationRequest,
        actionSequence: inout DesktopActionSequenceAccumulator) async throws -> CompletedSavedFileVerification
    {
        do {
            return try await CompletedSavedFileVerification(
                verification: self.verifySavedFile(request),
                overwriteConfirmed: false,
                target: request.retainedTarget)
        } catch let error as DialogError {
            guard case .fileVerificationFailed = error else { throw error }
            guard let replaceResult = try await self.clickReplaceIfPresent(
                retainedTarget: request.retainedTarget)
            else {
                throw error
            }
            let replaceTarget = try Self.coalescedOverwriteTarget(
                retained: request.retainedTarget,
                confirmation: Self.exactTarget(from: replaceResult))
            if let outcome = replaceResult.outcome {
                actionSequence.record(.outcome(outcome))
            }
            let retryRequest = SavedFileVerificationRequest(
                appName: request.appName,
                priorDocumentPath: request.priorDocumentPath,
                expectedPath: request.expectedPath,
                expectedBaseName: request.expectedBaseName,
                startedAt: Date(),
                timeout: request.timeout,
                retainedTarget: replaceTarget)
            return try await CompletedSavedFileVerification(
                verification: self.verifySavedFile(retryRequest),
                overwriteConfirmed: true,
                target: replaceTarget)
        }
    }

    func recordSavedFileVerification(
        _ completed: CompletedSavedFileVerification,
        expectedPath: String?,
        details: inout [String: String]) throws
    {
        let verification = completed.verification
        details["saved_path"] = verification.path
        details["saved_path_exists"] = "true"
        details["saved_path_verified"] = "true"
        details["saved_path_found_via"] = verification.foundVia
        if completed.overwriteConfirmed {
            details["overwrite_confirmed"] = "true"
        }
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

    func enforceExpectedDirectoryIfNeeded(
        actualSavedPath: String,
        expectedPath: String?,
        details: inout [String: String]) throws
    {
        guard let expectedPath else { return }
        let expectedDirectory = URL(fileURLWithPath: expectedPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let actualDirectory = URL(fileURLWithPath: actualSavedPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        details["saved_path_expected_directory"] = expectedDirectory
        details["saved_path_directory"] = actualDirectory
        details["saved_path_matches_expected_directory"] = String(expectedDirectory == actualDirectory)

        guard expectedDirectory == actualDirectory else {
            throw DialogError.fileSavedToUnexpectedDirectory(
                expectedDirectory: expectedDirectory,
                actualDirectory: actualDirectory,
                actualPath: actualSavedPath)
        }
    }

    func expectedSavedPath(path: String?, filename: String?) -> String? {
        guard let filename else { return nil }
        guard let path else { return nil }

        let expandedPath = (path as NSString).expandingTildeInPath
        let baseURL = URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        if baseURL.lastPathComponent == filename {
            return baseURL.path
        }

        return baseURL.appendingPathComponent(filename).path
    }

    func expectedSavedBaseName(filename: String?, expectedPath: String?) -> String? {
        if let filename {
            return URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        }
        if let expectedPath {
            return URL(fileURLWithPath: expectedPath).deletingPathExtension().lastPathComponent
        }
        return nil
    }

    func verifySavedFile(_ request: SavedFileVerificationRequest) async throws -> SavedFileVerification {
        let deadline = request.startedAt.addingTimeInterval(request.timeout)
        let fileManager = FileManager.default

        let expectedURL = request.expectedPath.map { URL(fileURLWithPath: $0) }
        let expectedDirectory = expectedURL?.deletingLastPathComponent()
        let expectedFileBaseName = expectedURL?.deletingPathExtension().lastPathComponent

        var lastDirectoryScan: Date?

        while Date() < deadline {
            if let appName = request.appName,
               let current = self.documentPathForApp(appName: appName)
            {
                let matchesName: Bool = if let expectedBaseName = request.expectedBaseName {
                    URL(fileURLWithPath: current)
                        .deletingPathExtension()
                        .lastPathComponent
                        .hasPrefix(expectedBaseName)
                } else {
                    true
                }

                if matchesName,
                   fileManager.fileExists(atPath: current),
                   self.fileWasModified(atPath: current, since: request.startedAt)
                {
                    return SavedFileVerification(path: current, foundVia: "document_path")
                }

                if matchesName,
                   let priorDocumentPath = request.priorDocumentPath,
                   current != priorDocumentPath,
                   fileManager.fileExists(atPath: current)
                {
                    return SavedFileVerification(path: current, foundVia: "document_path")
                }
            }

            if let expectedPath = request.expectedPath,
               fileManager.fileExists(atPath: expectedPath)
            {
                return SavedFileVerification(path: expectedPath, foundVia: "expected_path")
            }

            let shouldScanDirectory = lastDirectoryScan == nil ||
                Date().timeIntervalSince(lastDirectoryScan ?? Date.distantPast) > 0.5

            if shouldScanDirectory,
               let expectedDirectory,
               let expectedBaseName = expectedFileBaseName ?? request.expectedBaseName,
               let candidate = self.findRecentlyWrittenFile(
                   in: expectedDirectory,
                   fileNamePrefix: expectedBaseName,
                   startedAt: request.startedAt)
            {
                return SavedFileVerification(path: candidate, foundVia: "expected_directory_scan")
            }

            if shouldScanDirectory {
                lastDirectoryScan = Date()
            }

            try await Task.sleep(nanoseconds: 125_000_000)
        }

        if let expectedBaseName = request.expectedBaseName,
           let fallback = self.fallbackFindRecentlyWrittenFile(
               filenamePrefix: expectedBaseName,
               startedAt: request.startedAt)
        {
            return SavedFileVerification(path: fallback, foundVia: "fallback_search")
        }

        let expectedDescription: String = if let expectedPath = request.expectedPath {
            expectedPath
        } else if let expectedBaseName = request.expectedBaseName {
            "(unknown directory; name prefix: \(expectedBaseName))"
        } else {
            "(unknown path)"
        }

        throw DialogError.fileVerificationFailed(expectedPath: expectedDescription)
    }

    func clickReplaceIfPresent(
        retainedTarget: UIAutomationTarget.ExactWindow) async throws -> DialogActionResult?
    {
        let candidates = try await self.overwriteConfirmationCandidates(retainedTarget: retainedTarget)
        guard let selected = try Self.pinnedOverwriteConfirmation(
            candidates,
            retainedTarget: retainedTarget)
        else {
            return nil
        }

        let refreshedCandidates = try await self.overwriteConfirmationCandidates(
            retainedTarget: retainedTarget)
        guard let refreshed = try Self.pinnedOverwriteConfirmation(
            refreshedCandidates,
            retainedTarget: retainedTarget),
            Self.sameElement(refreshed.dialog, selected.dialog),
            Self.sameElement(refreshed.button, selected.button)
        else {
            throw self.targetUnavailable(
                "Overwrite confirmation changed before Replace dispatch.")
        }
        try Task.checkCancellation()

        let outcome = try await self.dispatchOverwriteConfirmation(refreshed.button)
        return DialogActionResult(
            success: true,
            action: .clickButton,
            details: Self.dialogTargetDetails(refreshed.target).merging([
                "button": refreshed.button.title() ?? "Replace",
            ]) { _, new in new },
            outcome: outcome,
            targetReceipt: Self.desktopActionTargetReceipt(refreshed.target),
            targetWindowIdentity: refreshed.target.identity,
            targetWindowBounds: refreshed.target.bounds,
            focusedElement: nil)
    }

    private func dispatchOverwriteConfirmation(_ button: Element) async throws -> DesktopActionOutcome {
        var sequence = DesktopActionSequenceAccumulator()
        do {
            let outcome = try await DetachedAXActionRunner.perform(
                action: AXActionNames.kAXPressAction,
                on: button.underlyingElement,
                gracePeriod: DetachedAXActionRunner.pressGracePeriod)
            sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
            try Task.checkCancellation()
            return outcome
        } catch is CancellationError {
            if let failure = sequence.cancellationFailure(
                fallbackRoute: .local,
                message: "Overwrite confirmation was cancelled after AXPress may have been dispatched.",
                hint: "Observe the exact file dialog before retrying.",
                causeDescription: "Cancellation occurred after Replace entered native AX dispatch.")
            {
                throw failure
            }
            throw CancellationError()
        } catch let failure as DesktopActionFailure {
            throw sequence.failure(
                combining: failure,
                message: failure.message,
                hint: failure.hint,
                causeDescription: failure.causeDescription)
        } catch {
            sequence.record(.mayHaveDispatched(
                route: .local,
                delivery: Self.backgroundDialogDelivery,
                unitCount: .one))
            throw DesktopActionFailure.indeterminate(
                delivery: Self.backgroundDialogDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Overwrite confirmation AXPress returned without reliable completion evidence.",
                hint: "Observe the exact file dialog before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private func overwriteConfirmationCandidates(
        retainedTarget: UIAutomationTarget.ExactWindow) async throws -> [OverwriteConfirmationCandidate]
    {
        let observation = try await self.retainedFileDialogWindowObservation(target: retainedTarget)
        let dialogs = self.freshDialogElements(in: observation.window)
        guard dialogs.readable else {
            throw self.targetUnavailable(
                "Overwrite confirmation hierarchy became unreadable before Replace dispatch.")
        }

        var candidates: [OverwriteConfirmationCandidate] = []
        for dialog in dialogs.structural {
            let owned = self.ownedOverwriteButtons(in: dialog)
            guard owned.readable else {
                throw self.targetUnavailable(
                    "Overwrite confirmation controls became unreadable before Replace dispatch.")
            }
            guard owned.buttons.count <= 1 else {
                throw self.targetUnavailable(
                    "Overwrite confirmation contains multiple eligible Replace controls.")
            }
            guard let button = owned.buttons.first else { continue }
            let target = try self.coalescedOverwriteTarget(
                for: dialog,
                retained: retainedTarget,
                listedWindows: observation.listedWindows)
            candidates.append(OverwriteConfirmationCandidate(
                target: target,
                dialog: dialog,
                button: button))
        }
        return candidates
    }

    private func retainedFileDialogWindowObservation(
        target: UIAutomationTarget.ExactWindow) async throws -> RetainedFileDialogWindowObservation
    {
        let processIdentifier = target.identity.ownerProcessIdentifier
        let application = try await self.applicationService.findApplication(
            identifier: "PID:\(processIdentifier)")
        guard application.processIdentity == target.identity.processIdentity else {
            throw self.targetUnavailable(
                "File-dialog owner changed process generation before overwrite confirmation.")
        }

        let response = try await self.applicationService.listWindows(
            for: "PID:\(processIdentifier)",
            timeout: self.targetedDialogSearchTimeout)
        let matches = response.data.windows.filter { $0.windowID == target.identity.windowID }
        guard matches.count == 1,
              let window = matches.first,
              window.mutationIdentity?.hasSameStableReceipt(as: target.identity) == true,
              window.bounds == target.bounds,
              let handle = self.windowIdentityService.findWindow(
                  byID: CGWindowID(target.identity.windowID),
                  messagingTimeout: self.targetedDialogSearchTimeout),
              handle.element.pid() == processIdentifier
        else {
            throw self.targetUnavailable(
                "File-dialog exact window receipt changed before overwrite confirmation.")
        }

        return RetainedFileDialogWindowObservation(
            window: handle.element,
            listedWindows: response.data.windows)
    }

    private func ownedOverwriteButtons(in dialog: Element) -> (buttons: [Element], readable: Bool) {
        var buttons: [Element] = []
        var visited: Set<Element> = []
        var stack = [dialog]
        var readable = true

        while let element = stack.popLast() {
            guard visited.insert(element).inserted else { continue }
            if !Self.sameElement(element, dialog),
               DialogElementClassifier.isStructuralDialog(DialogElementClassifier.evidence(for: element))
            {
                continue
            }
            if element.role() == "AXButton",
               Self.isEligiblePreparedButton(element),
               self.normalizedDialogButtonTitle(element.title() ?? "") == "replace"
            {
                buttons.append(element)
            }
            let traversal = Self.traversalChildren(of: element)
            readable = readable && traversal.readable
            stack.append(contentsOf: traversal.elements.reversed())
        }
        return (buttons, readable)
    }

    private func coalescedOverwriteTarget(
        for dialog: Element,
        retained: UIAutomationTarget.ExactWindow,
        listedWindows: [ServiceWindowInfo]) throws -> UIAutomationTarget.ExactWindow
    {
        guard dialog.pid() == retained.identity.ownerProcessIdentifier else {
            throw self.targetUnavailable(
                "Overwrite confirmation does not belong to the retained file-dialog process.")
        }
        guard let confirmationWindowID = self.windowIdentityService.getWindowID(
            from: dialog,
            messagingTimeout: self.targetedDialogSearchTimeout)
        else {
            return retained
        }

        let matches = listedWindows.filter { $0.windowID == Int(confirmationWindowID) }
        guard matches.count == 1, let window = matches.first else {
            throw self.targetUnavailable(
                "Overwrite confirmation window identity is incomplete or ambiguous.")
        }
        return try Self.coalescedOverwriteTarget(
            retained: retained,
            confirmation: UIAutomationTarget.ExactWindow(window: window))
    }

    static func pinnedOverwriteConfirmation(
        _ candidates: [OverwriteConfirmationCandidate],
        retainedTarget: UIAutomationTarget.ExactWindow) throws -> OverwriteConfirmationCandidate?
    {
        let pinned = candidates.filter {
            $0.target.identity.hasSameStableReceipt(as: retainedTarget.identity) &&
                $0.target.bounds == retainedTarget.bounds
        }
        guard pinned.count <= 1 else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Overwrite confirmation is ambiguous within the retained exact file-dialog window.",
                hint: "Observe the exact file dialog before retrying.")
        }
        return pinned.first
    }

    static func coalescedOverwriteTarget(
        retained: UIAutomationTarget.ExactWindow,
        confirmation: UIAutomationTarget.ExactWindow) throws -> UIAutomationTarget.ExactWindow
    {
        do {
            let retainedIdentity = DesktopTargetIdentity(exactWindow: retained)
            let confirmationIdentity = DesktopTargetIdentity(exactWindow: confirmation)
            guard let target = try retainedIdentity.coalescing(confirmationIdentity).exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return target
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Overwrite confirmation identifies a different exact file-dialog window.",
                hint: "Observe the exact file dialog before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private static func exactTarget(from result: DialogActionResult) throws -> UIAutomationTarget.ExactWindow {
        guard let identity = result.targetWindowIdentity,
              let bounds = result.targetWindowBounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Overwrite confirmation returned without its exact window receipt.",
                hint: "Observe the exact file dialog before retrying.")
        }
        return try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
    }

    func documentPathForApp(appName: String?) -> String? {
        guard let appName, let running = self.runningApplication(matching: appName) else { return nil }
        let appElement = AXApp(running).element

        let windows = appElement.windowsWithTimeout() ?? []
        let preferredWindows: [Element] = [
            appElement.mainWindow(),
            appElement.focusedWindow(),
        ].compactMap(\.self)

        let candidates = (preferredWindows + windows)

        func isDialogLike(_ window: Element) -> Bool {
            let subrole = window.subrole() ?? ""
            if subrole == "AXDialog" || subrole == "AXSystemDialog" || subrole == "AXAlert" {
                return true
            }

            let roleDescription = window.attribute(Attribute<String>("AXRoleDescription")) ?? ""
            if roleDescription.localizedCaseInsensitiveContains("dialog") {
                return true
            }

            let identifier = window.attribute(Attribute<String>("AXIdentifier")) ?? ""
            if identifier.contains("NSOpenPanel") || identifier.contains("NSSavePanel") {
                return true
            }

            return false
        }

        for window in candidates where !isDialogLike(window) {
            let document = window.attribute(Attribute<String>(AXAttributeNames.kAXDocumentAttribute))
            if let normalized = self.normalizeDocumentAttributeToPath(document) {
                return normalized
            }
        }

        return nil
    }

    private func fallbackFindRecentlyWrittenFile(filenamePrefix: String, startedAt: Date) -> String? {
        let fileManager = FileManager.default

        let candidates: [URL] = [
            URL(fileURLWithPath: "/private/tmp"),
            URL(fileURLWithPath: "/tmp"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
        ]
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }

        for directory in candidates {
            if let match = self.findRecentlyWrittenFile(
                in: directory,
                fileNamePrefix: filenamePrefix,
                startedAt: startedAt)
            {
                return match
            }
        }

        return nil
    }

    private func findRecentlyWrittenFile(
        in directory: URL,
        fileNamePrefix: String,
        startedAt: Date) -> String?
    {
        let fileManager = FileManager.default

        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return nil
        }

        let earliest = startedAt.addingTimeInterval(-2.0)

        let candidates: [(url: URL, modifiedAt: Date)] = urls.compactMap { url in
            guard url.lastPathComponent.hasPrefix(fileNamePrefix) else { return nil }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            guard modifiedAt >= earliest else { return nil }
            return (url: url, modifiedAt: modifiedAt)
        }

        guard let best = candidates.max(by: { $0.modifiedAt < $1.modifiedAt }) else {
            return nil
        }

        return best.url.path
    }

    private func normalizeDocumentAttributeToPath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }

        if raw.hasPrefix("file://"),
           let url = URL(string: raw),
           url.isFileURL
        {
            return url.path
        }

        return raw
    }

    private func fileWasModified(atPath path: String, since date: Date) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]),
              let modifiedAt = values.contentModificationDate
        else {
            return false
        }

        return modifiedAt >= date.addingTimeInterval(-2.0)
    }
}
