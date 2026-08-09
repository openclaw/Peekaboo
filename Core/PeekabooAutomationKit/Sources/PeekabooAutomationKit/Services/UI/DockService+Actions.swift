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

@MainActor
extension DockService {
    func launchFromDockImpl(appName: String) async throws {
        let dockElement = try findDockElement(appName: appName)

        do {
            try dockElement.performAction(.press)
        } catch {
            throw PeekabooError.operationError(message: "Failed to launch '\(appName)' from Dock.")
        }

        try await Task.sleep(nanoseconds: 200_000_000)
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

    func rightClickDockItemImpl(appName: String, menuItem: String?) async throws {
        let element = try findDockElement(appName: appName)

        guard let position = element.position(),
              let size = element.size()
        else {
            throw PeekabooError.operationError(message: "Could not determine Dock item position for '\(appName)'.")
        }

        let center = CGPoint(
            x: position.x + size.width / 2,
            y: position.y + size.height / 2)

        _ = await self.feedbackClient.showClickFeedback(at: center, type: .right)

        try InputDriver.click(at: center, button: .right, count: 1)
        usleep(50000)

        if let targetMenuItem = menuItem {
            try await self.clickContextMenuItem(targetMenuItem, for: element)
        }
    }

    private func clickContextMenuItem(
        _ targetMenuItem: String,
        for dockElement: Element) async throws
    {
        try await Task.sleep(nanoseconds: 300_000_000)

        let menu: Element?
        if let childMenu = dockElement.children()?.first(where: { $0.role() == "AXMenu" }) {
            menu = childMenu
        } else {
            let systemWide = Element.systemWide()
            menu = systemWide.children()?.first(where: { $0.role() == "AXMenu" })
        }

        guard let foundMenu = menu else {
            throw DockError.menuItemNotFound(targetMenuItem)
        }

        let menuItems = foundMenu.children() ?? []
        guard let targetItem = menuItems.first(where: { item in
            item.title() == targetMenuItem ||
                item.title()?.contains(targetMenuItem) == true
        }) else {
            throw DockError.menuItemNotFound(targetMenuItem)
        }

        try targetItem.performAction(.press)
    }
}
