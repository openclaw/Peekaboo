import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

extension UtilityTests.BuildStalenessCheckerTests {
    @Test(arguments: ["/", "//", "/./", "/../", "/missing/../"])
    func `Root is checked exactly once`(path: String) {
        let fileManager = MissingGitFileManager(maximumChecks: 1)

        #expect(findGitConfigPath(
            startingAt: URL(fileURLWithPath: path, isDirectory: true),
            fileManager: fileManager
        ) == nil)
        #expect(fileManager.checkedPaths == ["/.git"])
    }

    @Test(arguments: ["/", "/peekaboo-missing/./child/.."])
    func `Bridged URLs cannot traverse above root`(path: String) {
        let directory = NSURL(fileURLWithPath: path, isDirectory: true) as URL
        let fileManager = MissingGitFileManager(maximumChecks: directory.standardizedFileURL.pathComponents.count)

        #expect(findGitConfigPath(startingAt: directory, fileManager: fileManager) == nil)
        #expect(fileManager.checkedPaths.last == "/.git")
        #expect(fileManager.checkedPaths.count == directory.standardizedFileURL.pathComponents.count)
    }

    @Test
    func `Missing metadata visits only canonical ancestors`() {
        let fileManager = MissingGitFileManager(maximumChecks: 4)

        #expect(findGitConfigPath(
            startingAt: URL(fileURLWithPath: "/peekaboo-missing/one/./unused/../two/", isDirectory: true),
            fileManager: fileManager
        ) == nil)
        #expect(fileManager.checkedPaths == [
            "/peekaboo-missing/one/two/.git",
            "/peekaboo-missing/one/.git",
            "/peekaboo-missing/.git",
            "/.git"
        ])
    }

    @Test(arguments: ["", ".", "..", "missing/child", "missing/../child"])
    func `Empty and relative starting paths have finite ancestor searches`(path: String) {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let fileManager = MissingGitFileManager(maximumChecks: directory.standardizedFileURL.pathComponents.count)

        #expect(findGitConfigPath(startingAt: directory, fileManager: fileManager) == nil)
        #expect(fileManager.checkedPaths.count == directory.standardizedFileURL.pathComponents.count)
        #expect(fileManager.checkedPaths.last == "/.git")
        #expect(Set(fileManager.checkedPaths).count == fileManager.checkedPaths.count)
    }

    @Test
    func `Nearest git directory wins even from nonexistent descendants`() throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        #expect(findGitConfigPath(startingAt: directory) == directory.appendingPathComponent(".git/config").path)
        #expect(findGitConfigPath(startingAt: nested.appendingPathComponent("missing/child"))
            == nested.appendingPathComponent(".git/config").path)
    }

    @Test(arguments: [false, true])
    func `Gitdir files resolve relative and absolute directories`(absolute: Bool) throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout", isDirectory: true)
        let metadata = directory.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let gitdir = absolute ? metadata.path : "../metadata"
        try "gitdir: \(gitdir)\n".write(to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "[peekaboo]\ncheck-build-staleness = true\n".write(
            to: metadata.appendingPathComponent("config"),
            atomically: true,
            encoding: .utf8
        )

        #expect(findGitConfigPath(startingAt: checkout.appendingPathComponent("missing"))
            == metadata.appendingPathComponent("config").path)
        #expect(isBuildStalenessCheckEnabled(environment: [:], currentDirectory: checkout.path))
    }

    @Test
    func `Malformed gitdir files allow ancestor lookup`() throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try "not a gitdir file\n".write(to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        #expect(findGitConfigPath(startingAt: checkout) == directory.appendingPathComponent(".git/config").path)
    }

    @Test(.enabled(if: geteuid() != 0, "POSIX permissions do not deny root access"))
    func `Inaccessible metadata allows ancestor lookup`() throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked", isDirectory: true)
        let child = blocked.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: blocked.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }

        #expect(!FileManager.default.fileExists(atPath: blocked.appendingPathComponent(".git").path))
        #expect(findGitConfigPath(startingAt: child) == directory.appendingPathComponent(".git/config").path)
    }

    @Test(.enabled(if: geteuid() != 0, "POSIX permissions do not deny root access"))
    func `Unreadable gitdir files allow ancestor lookup`() throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let dotGit = checkout.appendingPathComponent(".git")
        try "gitdir: ../metadata\n".write(to: dotGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dotGit.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotGit.path) }

        #expect(throws: (any Error).self) { try String(contentsOf: dotGit, encoding: .utf8) }
        #expect(findGitConfigPath(startingAt: checkout) == directory.appendingPathComponent(".git/config").path)
    }

    @Test(arguments: ["1", " TRUE ", "yes", "0", "false", "no", "other"])
    func `Nonempty environment override takes precedence over config`(override: String) throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let enabled = ["1", " TRUE ", "yes"].contains(override)
        let config = directory.appendingPathComponent("config")
        try "[peekaboo]\ncheck-build-staleness = \(!enabled)\n".write(to: config, atomically: true, encoding: .utf8)

        #expect(isBuildStalenessCheckEnabled(
            environment: ["PEEKABOO_CHECK_BUILD_STALENESS": override],
            currentDirectory: "/",
            gitConfigPaths: [config.path]
        ) == enabled)
    }

    @Test(arguments: ["", " \n "])
    func `Blank environment override preserves config opt in`(override: String) throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try "[peekaboo]\ncheck-build-staleness = true\n".write(to: config, atomically: true, encoding: .utf8)

        #expect(isBuildStalenessCheckEnabled(
            environment: ["PEEKABOO_CHECK_BUILD_STALENESS": override],
            gitConfigPaths: [config.path]
        ))
        #expect(!isBuildStalenessCheckEnabled(
            environment: ["PEEKABOO_CHECK_BUILD_STALENESS": override],
            gitConfigPaths: []
        ))
        #expect(!isBuildStalenessCheckEnabled(environment: [:], gitConfigPaths: []))
    }

    @Test
    func `Discovered repository config overrides home and XDG settings`() throws {
        let directory = try self.makeStalenessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let xdg = directory.appendingPathComponent("xdg", isDirectory: true)
        let checkout = directory.appendingPathComponent("checkout", isDirectory: true)
        for path in [home, xdg.appendingPathComponent("git"), checkout] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try "[peekaboo]\ncheck-build-staleness = false\n".write(
            to: xdg.appendingPathComponent("git/config"), atomically: true, encoding: .utf8
        )
        try "[peekaboo]\ncheck-build-staleness = true\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8
        )
        let environment = ["HOME": home.path, "XDG_CONFIG_HOME": xdg.path]
        #expect(isBuildStalenessCheckEnabled(environment: environment, currentDirectory: checkout.path))

        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try "[peekaboo]\ncheck-build-staleness = false\n".write(
            to: checkout.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8
        )
        #expect(!isBuildStalenessCheckEnabled(environment: environment, currentDirectory: checkout.path))
    }

    private func makeStalenessDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Each instance belongs to one synchronous test; no real filesystem metadata is consulted.
private final nonisolated class MissingGitFileManager: FileManager, @unchecked Sendable {
    private(set) var checkedPaths: [String] = []
    private let maximumChecks: Int

    init(maximumChecks: Int) {
        self.maximumChecks = maximumChecks
        super.init()
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        self.checkedPaths.append(path)
        // Return a sentinel repository on overrun so a regression fails instead of hanging the test runner.
        isDirectory?.pointee = true
        return self.checkedPaths.count > self.maximumChecks
    }
}
