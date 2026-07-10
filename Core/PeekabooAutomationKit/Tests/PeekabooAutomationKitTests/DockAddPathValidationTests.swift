import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DockAddPathValidationTests {
    @Test
    func `rejects empty and relative paths`() {
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("")
        }
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("Applications/Calculator.app")
        }
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("  ")
        }
    }

    @Test
    func `rejects control characters`() {
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("/tmp/evil\n.app")
        }
        #expect(throws: PeekabooError.self) {
            try DockService.validatedDockItemPath("/tmp/evil\u{0000}.app")
        }
    }

    @Test
    func `preserves exact leading and trailing whitespace on absolute paths`() throws {
        let withTrailing = "/tmp/App Name .app"
        let withLeading = "/tmp/ leading.app"
        #expect(try DockService.validatedDockItemPath(withTrailing) == withTrailing)
        #expect(try DockService.validatedDockItemPath(withLeading) == withLeading)

        let fragment = DockService.dockTilePlistFragment(forPath: withTrailing)
        #expect(fragment.contains("<string>/tmp/App Name .app</string>"))
    }

    @Test
    func `accepts absolute paths and XML-escapes special characters`() throws {
        let path = try DockService.validatedDockItemPath("/Applications/Foo & Bar <Test>.app")
        #expect(path == "/Applications/Foo & Bar <Test>.app")

        let fragment = DockService.dockTilePlistFragment(forPath: path)
        #expect(fragment.contains("<string>/Applications/Foo &amp; Bar &lt;Test&gt;.app</string>"))
        #expect(!fragment.contains("<string>/Applications/Foo & Bar <Test>.app</string>"))
    }

    @Test
    func `shell metacharacter path stays a single non-shell argument payload`() throws {
        let payload = #"/tmp/x'; touch /tmp/pwned; echo '"#
        let path = try DockService.validatedDockItemPath(payload)
        let command = DockService.dockDefaultsWriteCommand(forPath: path)

        #expect(command.executable == "/usr/bin/defaults")
        #expect(command.arguments == [
            "write",
            "com.apple.dock",
            "persistent-apps",
            "-array-add",
            DockService.dockTilePlistFragment(forPath: path),
        ])
        #expect(command.executable != "/bin/bash")
        #expect(!command.arguments.contains("-c"))
        #expect(DockService.restartDockCommand == DockProcessCommand(
            executable: "/usr/bin/killall",
            arguments: ["Dock"],
            failurePrefix: "Failed to restart Dock after adding item"))
    }

    @Test
    func `real defaults write treats shell metacharacters as literal path data`() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-dock-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let markerPath = temporaryDirectory.appendingPathComponent("shell-command-ran").path
        let payload = "\(temporaryDirectory.path)/Probe '; touch \(markerPath); echo ' & <tag>.app"
        let domain = temporaryDirectory.appendingPathComponent("dock-domain").path
        let command = DockService.dockDefaultsWriteCommand(
            forPath: payload,
            domain: domain)

        try DockService.runProcess(command)

        #expect(!fileManager.fileExists(atPath: markerPath))
        let plistURL = URL(fileURLWithPath: domain + ".plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        let root = try #require(plist as? [String: Any])
        let persistentApps = try #require(root["persistent-apps"] as? [[String: Any]])
        let tile = try #require(persistentApps.first)
        let tileData = try #require(tile["tile-data"] as? [String: Any])
        let fileData = try #require(tileData["file-data"] as? [String: Any])
        #expect(fileData["_CFURLString"] as? String == payload)
    }

    @Test
    func `application bundles use the Dock applications array`() {
        let path = "/System/Applications/Calculator.app"
        #expect(FileManager.default.fileExists(atPath: path))

        let command = DockService.dockDefaultsWriteCommand(forPath: path)

        #expect(command.arguments[2] == "persistent-apps")
    }

    @Test
    func `ordinary directories use the Dock folders array`() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-dock-folder-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let command = DockService.dockDefaultsWriteCommand(forPath: directory.path)

        #expect(command.arguments[2] == "persistent-others")
    }

    @Test
    func `symlinks to application bundles keep their path and use the applications array`() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-dock-symlink-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let symlink = temporaryDirectory.appendingPathComponent("Calculator Link.app")
        try fileManager.createSymbolicLink(
            at: symlink,
            withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))

        let command = DockService.dockDefaultsWriteCommand(forPath: symlink.path)

        #expect(command.arguments[2] == "persistent-apps")
        #expect(command.arguments[4].contains("<string>\(symlink.path)</string>"))
    }

    @Test
    func `real defaults write places an application bundle in persistent apps`() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("peekaboo-dock-app-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let calculatorPath = "/System/Applications/Calculator.app"
        let domain = temporaryDirectory.appendingPathComponent("dock-domain").path
        let command = DockService.dockDefaultsWriteCommand(forPath: calculatorPath, domain: domain)

        try DockService.runProcess(command)

        let plistURL = URL(fileURLWithPath: domain + ".plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        let root = try #require(plist as? [String: Any])
        let persistentApps = try #require(root["persistent-apps"] as? [[String: Any]])
        #expect(root["persistent-others"] == nil)
        #expect(persistentApps.count == 1)

        let tileData = try #require(persistentApps[0]["tile-data"] as? [String: Any])
        let fileData = try #require(tileData["file-data"] as? [String: Any])
        #expect(fileData["_CFURLString"] as? String == calculatorPath)
    }
}
