import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct InstalledApplicationCatalogTests {
    @Test
    func `scanner discovers nested bundles and classifies declared presentation`() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Self.makeApplication(
            root: root,
            relativePath: "Editors/Regular.app",
            bundleIdentifier: "com.example.regular",
            name: "Regular")
        try Self.makeApplication(
            root: root,
            relativePath: "Menu.app",
            bundleIdentifier: "com.example.menu",
            name: "Menu",
            uiElement: true)
        try Self.makeApplication(
            root: root,
            relativePath: "Daemon.app",
            bundleIdentifier: "com.example.daemon",
            name: "Daemon",
            backgroundOnly: true)
        try Self.makeApplication(
            root: root,
            relativePath: "Outer.app",
            bundleIdentifier: "com.example.outer",
            name: "Outer")
        try Self.makeApplication(
            root: root,
            relativePath: "Outer.app/Contents/Helpers/Inner.app",
            bundleIdentifier: "com.example.inner",
            name: "Inner")

        let output = try InstalledApplicationCatalogScanner(
            roots: [.init(url: root, priority: 0, label: "fixture")]).scan()

        #expect(output.summary.status == .success)
        #expect(output.data.applications.map(\.name) == ["Daemon", "Menu", "Outer", "Regular"])
        #expect(output.data.applications.map(\.declaredPresentation) == [
            .backgroundOnly,
            .uiElement,
            .regular,
            .regular,
        ])
        #expect(!output.data.applications.contains { $0.bundleIdentifier == "com.example.inner" })
    }

    @Test
    func `scanner deduplicates by root precedence with deterministic warning`() throws {
        let preferred = try Self.temporaryDirectory()
        let fallback = try Self.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: preferred)
            try? FileManager.default.removeItem(at: fallback)
        }
        let preferredApp = try Self.makeApplication(
            root: preferred,
            relativePath: "Preferred.app",
            bundleIdentifier: "com.example.duplicate",
            name: "Preferred")
        let fallbackApp = try Self.makeApplication(
            root: fallback,
            relativePath: "Fallback.app",
            bundleIdentifier: "COM.EXAMPLE.DUPLICATE",
            name: "Fallback")

        let output = try InstalledApplicationCatalogScanner(roots: [
            .init(url: fallback, priority: 10, label: "fallback"),
            .init(url: preferred, priority: 0, label: "preferred"),
        ]).scan()

        #expect(output.summary.status == .partial)
        #expect(output.data.applications == [
            ServiceInstalledApplicationInfo(
                name: "Preferred",
                bundleIdentifier: "com.example.duplicate",
                launchPath: preferredApp.path,
                declaredPresentation: .regular),
        ])
        #expect(output.metadata.warnings == [
            "Duplicate installed application bundle ID COM.EXAMPLE.DUPLICATE at " +
                "\(preferredApp.path) and \(fallbackApp.path); selected \(preferredApp.path)",
        ])
    }

    @Test
    func `scanner bounds traversal and reports partial truth`() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("a", isDirectory: true),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("b", isDirectory: true),
            withIntermediateDirectories: true)

        let output = try InstalledApplicationCatalogScanner(
            roots: [.init(url: root, priority: 0, label: "fixture")],
            maximumVisitedEntries: 1).scan()

        #expect(output.summary.status == .partial)
        #expect(output.metadata.warnings == ["Installed application catalog stopped after 1 filesystem entries"])
    }

    @Test
    func `empty-root deadline is still reported as partial`() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let output = try InstalledApplicationCatalogScanner(
            roots: [.init(url: root, priority: 0, label: "fixture")],
            timeout: .zero).scan()

        #expect(output.summary.status == .partial)
        #expect(output.metadata.warnings == ["Installed application catalog exceeded its 0.0s deadline"])
    }

    @Test
    func `reconciler never turns live processes into installed-only rows`() {
        let catalog = [
            Self.installed("Bundle match", id: "com.example.live", path: "/Applications/Live.app"),
            Self.installed("Available", id: "com.example.available", path: "/Applications/Available.app"),
        ]
        let running = [
            ServiceApplicationInfo(
                processIdentifier: 41,
                bundleIdentifier: "COM.EXAMPLE.LIVE",
                name: "Hidden Live",
                bundlePath: "/different/Live.app",
                isHidden: true,
                activationPolicy: .prohibited),
        ]

        #expect(InstalledApplicationReconciler.installedButNotRunning(
            catalog: catalog,
            running: running) == [catalog[1]])
    }

    @Test
    func `identity-poor running inventory suppresses every absence claim`() {
        let catalog = [
            Self.installed("Possible Match", id: "com.example.possible", path: "/Applications/Possible.app"),
            Self.installed("Other", id: "com.example.other", path: "/Applications/Other.app"),
        ]
        let running = [ServiceApplicationInfo(
            processIdentifier: 41,
            processStartIdentity: 7,
            bundleIdentifier: nil,
            name: "Possible Match",
            bundlePath: "/Applications/Possible.app",
            isHiddenKnown: false)]

        #expect(InstalledApplicationReconciler.hasIdentityPoorRunningApplications(running))
        #expect(InstalledApplicationReconciler.installedButNotRunning(
            catalog: catalog,
            running: running).isEmpty)
    }

    @Test
    func `catalog coalesces concurrent scans and caches only complete output`() async throws {
        let counter = CatalogScanCounter()
        let catalog = InstalledApplicationCatalog(scanHandler: {
            try await Task.sleep(for: .milliseconds(20))
            return await counter.output()
        })

        async let first = catalog.listApplications()
        async let second = catalog.listApplications()
        let (firstOutput, secondOutput) = try await (first, second)
        let cachedOutput = try await catalog.listApplications()

        #expect(firstOutput.data.applications == secondOutput.data.applications)
        #expect(cachedOutput.data.applications == firstOutput.data.applications)
        #expect(await counter.count == 1)
    }

    @Test
    func `hard timeout quarantines a blocked scan without coupling later callers`() async throws {
        let blocker = CatalogBlockingScan()
        let catalog = InstalledApplicationCatalog(
            hardTimeout: .milliseconds(20),
            scanHandler: { await blocker.output() })

        await #expect(throws: (any Error).self) {
            _ = try await catalog.listApplications()
        }
        let secondStartedAt = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await catalog.listApplications()
        }
        #expect(secondStartedAt.duration(to: .now) < .milliseconds(10))
        #expect(await blocker.count == 1)

        await blocker.releaseFirstScan()
        var recovered: UnifiedToolOutput<ServiceInstalledApplicationListData>?
        for _ in 0..<20 where recovered == nil {
            do {
                recovered = try await catalog.listApplications()
            } catch {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(recovered?.data.applications.map(\.name) == ["Fixture"])
        #expect(await blocker.count == 2)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-installed-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private static func makeApplication(
        root: URL,
        relativePath: String,
        bundleIdentifier: String,
        name: String,
        uiElement: Bool = false,
        backgroundOnly: Bool = false) throws -> URL
    {
        let application = root.appendingPathComponent(relativePath, isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleDisplayName": name,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        if uiElement {
            info["LSUIElement"] = true
        }
        if backgroundOnly {
            info["LSBackgroundOnly"] = true
        }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return application
    }

    private static func installed(_ name: String, id: String, path: String) -> ServiceInstalledApplicationInfo {
        ServiceInstalledApplicationInfo(
            name: name,
            bundleIdentifier: id,
            launchPath: path,
            declaredPresentation: .regular)
    }
}

private actor CatalogScanCounter {
    private(set) var count = 0

    func output() -> UnifiedToolOutput<ServiceInstalledApplicationListData> {
        self.count += 1
        return UnifiedToolOutput(
            data: ServiceInstalledApplicationListData(applications: [
                ServiceInstalledApplicationInfo(
                    name: "Fixture",
                    bundleIdentifier: "com.example.fixture",
                    launchPath: "/Applications/Fixture.app",
                    declaredPresentation: .regular),
            ]),
            summary: .init(brief: "Fixture", status: .success),
            metadata: .init(duration: 0))
    }
}

private actor CatalogBlockingScan {
    private(set) var count = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func output() async -> UnifiedToolOutput<ServiceInstalledApplicationListData> {
        self.count += 1
        if self.count == 1 {
            await withCheckedContinuation { continuation in
                self.firstContinuation = continuation
            }
        }
        return UnifiedToolOutput(
            data: ServiceInstalledApplicationListData(applications: [
                ServiceInstalledApplicationInfo(
                    name: "Fixture",
                    bundleIdentifier: "com.example.fixture",
                    launchPath: "/Applications/Fixture.app",
                    declaredPresentation: .regular),
            ]),
            summary: .init(brief: "Fixture", status: .success),
            metadata: .init(duration: 0))
    }

    func releaseFirstScan() {
        self.firstContinuation?.resume()
        self.firstContinuation = nil
    }
}
