import Darwin
import Foundation
import PeekabooBridge
import PeekabooCore
import Testing
@testable import PeekabooAutomationKit

/// Owns only a newly created directory, never a borrowed store or an ambient runtime root.
struct CLIDesktopFixture {
    let root: URL
    let watermarkStore: DesktopMutationWatermarkStore
    let laneCoordinator: DesktopOperationLaneCoordinator

    init() throws {
        // Keep UNIX socket paths below sockaddr_un's limit, including on Darwin's long temporary paths.
        var template = Array("/tmp/pb-cli-XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let root = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        self.root = root
        self.watermarkStore = DesktopMutationWatermarkStore(directoryURL: root)
        self.laneCoordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
    }

    /// Call only after all operations borrowing the store/coordinator have completed.
    func removeDirectory() {
        do {
            try FileManager.default.removeItem(at: self.root)
        } catch {
            Issue.record("Could not remove CLI fixture directory: \(error)")
        }
    }
}

@MainActor
final class CLIBridgeHostFixture {
    let desktop: CLIDesktopFixture
    private var hosts: [PeekabooBridgeHost] = []

    private init() throws {
        self.desktop = try CLIDesktopFixture()
    }

    static func withHosts<T>(_ body: @MainActor (CLIBridgeHostFixture) async throws -> T) async throws -> T {
        let fixture = try CLIBridgeHostFixture()
        do {
            let result = try await body(fixture)
            await fixture.stopAndRemoveDirectory()
            return result
        } catch {
            await fixture.stopAndRemoveDirectory()
            throw error
        }
    }

    func start(_ host: PeekabooBridgeHost) async throws {
        // Retain before startup so partial startup and later sibling failures also drain the host.
        self.hosts.append(host)
        try await host.startChecked()
    }

    private func stopAndRemoveDirectory() async {
        for host in self.hosts.reversed() {
            await host.stop()
            await host.waitUntilFullyStopped()
        }
        self.hosts.removeAll()
        self.desktop.removeDirectory()
    }
}
