@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import UniformTypeIdentifiers

struct DockProcessCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let failurePrefix: String
}

struct DockContextMenuSelection {
    let element: Element
    let evidence: DesktopSelectedLeafEvidence
}

@MainActor
extension DockService {
    func launchFromDockImpl(
        target: DockGenerationBoundElement,
        appName: String) async throws -> DesktopSelectedLeafEvidence
    {
        let refreshedTarget = try self.resolveDockElement(appName: appName)
        try Self.validateDockLeafRefresh(
            expected: target,
            refreshed: refreshedTarget,
            appName: appName)
        try Self.dispatchDockLaunchPress(
            refreshedTarget.identity,
            appName: appName,
            validate: self.validateDockProcessIdentity,
            submit: {
                try refreshedTarget.element.performAction(.press)
            })

        try? await Task.sleep(nanoseconds: 200_000_000)
        return refreshedTarget.evidence
    }

    func addToDockImpl(path: String, persistent _: Bool = true) async throws {
        let sanitizedPath = try DockService.validatedDockItemPath(path)

        // Invoke defaults directly (no shell) so path content cannot break out of
        // a bash -c script. Still XML-escape the path so malformed strings cannot
        // corrupt the Dock plist fragment.
        try DockService.runProcess(
            DockService.dockDefaultsWriteCommand(forPath: sanitizedPath))
        try DockService.runProcess(DockService.restartDockCommand)
    }

    /// Reject paths that are not absolute filesystem paths (defense in depth for callers).
    ///
    /// Returns the **exact** supplied path string (no trimming) so intentional leading/trailing
    /// whitespace in rare valid filenames is preserved for `fileExists` and the Dock tile plist.
    static func validatedDockItemPath(_ path: String) throws -> String {
        guard !path.isEmpty else {
            throw PeekabooError.invalidInput("Dock path must not be empty")
        }
        // Reject whitespace-only input without rewriting non-empty paths that merely
        // begin/end with spaces (those are rare but valid HFS+/APFS names).
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PeekabooError.invalidInput("Dock path must not be empty")
        }
        guard path.hasPrefix("/") else {
            throw PeekabooError.invalidInput("Dock path must be an absolute filesystem path")
        }
        // Control characters have no valid use in file paths for Dock tiles and are a
        // common smuggling vector when values later appear in plists or logs.
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw PeekabooError.invalidInput("Dock path must not contain control characters")
        }
        return path
    }

    /// Build the Dock tile plist fragment with XML-escaped path text.
    static func dockTilePlistFragment(forPath path: String) -> String {
        let escaped = self.xmlEscape(path)
        return """
        <dict>
            <key>tile-data</key>
            <dict>
                <key>file-data</key>
                <dict>
                    <key>_CFURLString</key>
                    <string>\(escaped)</string>
                    <key>_CFURLStringType</key>
                    <integer>0</integer>
                </dict>
            </dict>
        </dict>
        """
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func dockDefaultsWriteCommand(
        forPath path: String,
        domain: String = "com.apple.dock") -> DockProcessCommand
    {
        let plistKey = self.dockPlistKey(forPath: path)
        return DockProcessCommand(
            executable: "/usr/bin/defaults",
            arguments: ["write", domain, plistKey, "-array-add", self.dockTilePlistFragment(forPath: path)],
            failurePrefix: "Failed to add item to Dock")
    }

    private static func dockPlistKey(forPath path: String) -> String {
        // App bundles are directories on disk but belong in the Dock's application array.
        // Resolve symlinks only for classification; the tile keeps the exact supplied path.
        let classificationURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try? classificationURL.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        if values?.contentType?.conforms(to: .applicationBundle) == true {
            return "persistent-apps"
        }
        return values?.isDirectory == true ? "persistent-others" : "persistent-apps"
    }

    static let restartDockCommand = DockProcessCommand(
        executable: "/usr/bin/killall",
        arguments: ["Dock"],
        failurePrefix: "Failed to restart Dock after adding item")

    static func runProcess(_ command: DockProcessCommand) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        try DockService.waitForProcessExit(process, timeoutSeconds: 15)

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw PeekabooError.operationError(message: "\(command.failurePrefix): \(errorString)")
        }
    }

    func removeFromDockImpl(appName: String) async throws {
        let element = try self.findDockElement(appName: appName)
        do {
            _ = try await ActionInputDriver().tryRightClick(element: AutomationElement(element))
            try await self.clickContextMenuItem("Remove from Dock", for: element)
        } catch {
            throw PeekabooError.operationError(
                message: "Failed to remove '\(appName)' from Dock: \(error.localizedDescription)")
        }
    }

    func rightClickDockItemImpl(
        target: DockGenerationBoundElement,
        appName: String,
        menuItem: String?) async throws -> [DesktopSelectedLeafEvidence]
    {
        let element = target.element

        guard let position = element.position(),
              let size = element.size()
        else {
            throw PeekabooError.operationError(message: "Could not determine Dock item position for '\(appName)'.")
        }

        let feedbackCenter = CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2)

        _ = await self.feedbackClient.showClickFeedback(at: feedbackCenter, type: .right)
        try Self.checkDockDispatchCancellation()

        let refreshedTarget = try self.resolveDockElement(appName: appName)
        try Self.validateDockLeafRefresh(
            expected: target,
            refreshed: refreshedTarget,
            appName: appName)
        let refreshedElement = refreshedTarget.element
        let center = try Self.refreshedDockItemCenter(
            expectedIdentity: target.identity,
            resolvedIdentity: refreshedTarget.identity,
            position: refreshedElement.position(),
            size: refreshedElement.size(),
            appName: appName)

        try Self.dispatchDockRightClick(
            target.identity,
            appName: appName,
            validate: self.validateDockProcessIdentity,
            submit: {
                try InputDriver.click(at: center, button: .right, count: 1)
            })
        usleep(50000)

        if let targetMenuItem = menuItem {
            let selectedMenuItem = try await Self.dispatchContextMenuSelection(
                targetMenuItem: targetMenuItem,
                prepare: {
                    try await self.findContextMenuItem(
                        targetMenuItem,
                        for: refreshedElement,
                        processIdentity: refreshedTarget.identity)
                },
                revalidate: { selection in
                    let refreshedSelection = try await self.findContextMenuItem(
                        targetMenuItem,
                        for: refreshedElement,
                        processIdentity: refreshedTarget.identity,
                        delayNanoseconds: 0)
                    guard selection.element == refreshedSelection.element,
                          selection.evidence.hasSameResolvedLeaf(as: refreshedSelection.evidence)
                    else {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "Dock context-menu item '\(targetMenuItem)' changed before selection.",
                            hint: "Inspect or dismiss the open Dock menu before retrying.")
                    }
                    return refreshedSelection
                },
                validateBeforeSubmit: {
                    try self.validateDockProcessIdentity(target.identity)
                },
                failureEvidence: { selection in [selection.evidence] },
                submit: { selection in
                    try selection.element.performAction(.press)
                })
            return [refreshedTarget.evidence, selectedMenuItem.evidence]
        }
        return [refreshedTarget.evidence]
    }

    static func refreshedDockItemCenter(
        expectedIdentity: ApplicationProcessIdentity,
        resolvedIdentity: ApplicationProcessIdentity,
        position: CGPoint?,
        size: CGSize?,
        appName: String) throws -> CGPoint
    {
        guard resolvedIdentity == expectedIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Dock changed process generation before dispatch",
                hint: "Resolve the current Dock generation before retrying.")
        }
        guard let position, let size else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Dock item '\(appName)' changed geometry before dispatch.",
                hint: "Resolve the current Dock item before retrying.")
        }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    static func dispatchBoundToDockGeneration(
        _ identity: ApplicationProcessIdentity,
        validate: (ApplicationProcessIdentity) throws -> Void,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        submit: () throws -> Void) throws
    {
        try validate(identity)
        try self.checkDockDispatchCancellation(checkCancellation)
        try submit()
    }

    static func dispatchDockLaunchPress(
        _ identity: ApplicationProcessIdentity,
        appName: String,
        validate: (ApplicationProcessIdentity) throws -> Void,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        submit: () throws -> Void) throws
    {
        do {
            try self.dispatchBoundToDockGeneration(
                identity,
                validate: validate,
                checkCancellation: checkCancellation,
                submit: submit)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Dock AXPress for '\(appName)' returned without reliable dispatch evidence.",
                hint: "Observe the Dock item and application before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    static func dispatchDockRightClick(
        _ identity: ApplicationProcessIdentity,
        appName: String,
        validate: (ApplicationProcessIdentity) throws -> Void,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        submit: () throws -> Void) throws
    {
        try validate(identity)
        try self.checkDockDispatchCancellation(checkCancellation)
        do {
            try submit()
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: DockContextMenuActionSemantics.rightClickDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Dock right-click for '\(appName)' returned without reliable dispatch evidence.",
                hint: "Observe the Dock item and open menu before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    @discardableResult
    static func dispatchContextMenuSelection<Selection>(
        targetMenuItem: String,
        prepare: () async throws -> Selection,
        revalidate: ((Selection) async throws -> Selection)? = nil,
        validateBeforeSubmit: () throws -> Void = {},
        failureEvidence: (Selection) -> [DesktopSelectedLeafEvidence]? = { _ in nil },
        submit: (Selection) throws -> Void) async throws -> Selection
    {
        let selection: Selection
        do {
            let prepared = try await prepare()
            selection = try await revalidate?(prepared) ?? prepared
            try Task.checkCancellation()
            try validateBeforeSubmit()
            try self.checkDockDispatchCancellation()
        } catch {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: DockContextMenuActionSemantics.rightClickDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one,
                message: "The Dock context-menu right-click was dispatched, but '\(targetMenuItem)' selection " +
                    "was not submitted.",
                hint: "Inspect or dismiss the open Dock menu before retrying the compound action.",
                causeDescription: String(describing: error))
        }

        do {
            try submit(selection)
            return selection
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: DockContextMenuActionSemantics.selectionDelivery,
                evidence: .completionUnknown,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2),
                message: "The Dock context-menu right-click was dispatched, and selecting '\(targetMenuItem)' " +
                    "may also have been dispatched.",
                hint: "Observe the Dock and menu state before retrying; replaying may repeat either action.",
                causeDescription: String(describing: error))
                .selectingLeaves(failureEvidence(selection))
        }
    }

    private func clickContextMenuItem(
        _ targetMenuItem: String,
        for dockElement: Element) async throws
    {
        guard let dockApp = self.findDockRunningApplication(),
              let startIdentity = SystemIdentityResolver.processStartIdentity(dockApp.processIdentifier)
        else {
            throw DockError.dockNotFound
        }
        let selection = try await self.findContextMenuItem(
            targetMenuItem,
            for: dockElement,
            processIdentity: .init(
                processIdentifier: dockApp.processIdentifier,
                processStartIdentity: startIdentity))
        try selection.element.performAction(.press)
    }

    private func findContextMenuItem(
        _ targetMenuItem: String,
        for dockElement: Element,
        processIdentity: ApplicationProcessIdentity,
        delayNanoseconds: UInt64 = 300_000_000) async throws -> DockContextMenuSelection
    {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let childMenus = (dockElement.children() ?? []).filter {
            $0.role() == "AXMenu" && $0.pid() == processIdentity.processIdentifier
        }
        let systemMenus = (Element.systemWide().children() ?? []).filter {
            $0.role() == "AXMenu" && $0.pid() == processIdentity.processIdentifier
        }
        let menus = Array(Set(childMenus + systemMenus))
        guard menus.count == 1, let foundMenu = menus.first else {
            if menus.count > 1 {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Multiple Dock-owned context menus are open; refusing order-dependent selection.",
                    hint: "Dismiss stale Dock menus and retry against one current context menu.")
            }
            throw DockError.menuItemNotFound(targetMenuItem)
        }

        let snapshots = (foundMenu.children() ?? []).indexed().compactMap { index, element -> DockLeafSnapshot? in
            guard element.pid() == processIdentity.processIdentifier,
                  let title = element.title()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let frame = element.frame(),
                  !frame.isEmpty
            else { return nil }
            return DockLeafSnapshot(
                element: element,
                index: index,
                title: title,
                identifier: element.identifier(),
                role: element.role() ?? "AXMenuItem",
                subrole: element.subrole(),
                frame: frame,
                url: nil)
        }
        let selection: DeterministicDesktopLeafSelector.Selection<DockLeafSnapshot>
        do {
            selection = try DeterministicDesktopLeafSelector.select(
                named: targetMenuItem,
                from: snapshots.map { snapshot in
                    DeterministicDesktopLeafSelector.Candidate(
                        value: snapshot,
                        index: snapshot.index,
                        displayName: snapshot.title,
                        matchFields: [snapshot.title],
                        stableIdentity: DeterministicDesktopLeafSelector.stableIdentity([
                            snapshot.title,
                            snapshot.identifier,
                            snapshot.role,
                            snapshot.subrole,
                            "\(snapshot.frame)",
                        ]))
                })
        } catch let error as DesktopLeafSelectionError {
            switch error {
            case .notFound, .invalidIndex:
                throw DockError.menuItemNotFound(targetMenuItem)
            case let .ambiguous(_, matches):
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Dock context-menu selector '\(targetMenuItem)' is ambiguous: " +
                        matches.joined(separator: ", "),
                    hint: "Use the exact context-menu item title.")
            }
        }
        let evidence = try Self.dockLeafEvidence(
            selection: selection,
            processIdentity: processIdentity,
            kind: .dockContextMenuItem)
        return DockContextMenuSelection(element: selection.candidate.value.element, evidence: evidence)
    }
}
