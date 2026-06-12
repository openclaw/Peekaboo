import Darwin
import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing

@Suite(.serialized)
struct PeekabooBridgeHostOwnershipTests {
    @Test
    func `second host cannot replace a live leased socket`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }

        let first = await Self.makeHost(socketPath: socketPath)
        let second = await Self.makeHost(socketPath: socketPath)
        try await first.startChecked()
        defer { Task { await first.stop() } }

        await #expect(throws: PeekabooBridgeHostError.self) {
            try await second.startChecked()
        }

        let handshake = try await Self.client(socketPath: socketPath).handshake(client: Self.clientIdentity())
        #expect(handshake.hostKind == .gui)
    }

    @Test
    func `host refuses to replace a live legacy listener`() async throws {
        let socketPath = Self.socketPath()
        let listener = try Self.bindSocket(path: socketPath, listen: true)
        defer {
            close(listener)
            Self.removeSocketArtifacts(socketPath)
        }

        let host = await Self.makeHost(socketPath: socketPath)
        do {
            try await host.startChecked()
            Issue.record("Expected the live listener to retain socket ownership")
            await host.stop()
        } catch let error as PeekabooBridgeHostError {
            guard case let .socketAlreadyOwned(path) = error else {
                Issue.record("Expected socketAlreadyOwned, got \(error)")
                return
            }
            #expect(path == socketPath)
            #expect(FileManager.default.fileExists(atPath: socketPath))
        }
    }

    @Test
    func `host refuses to replace a legacy socket before listen`() async throws {
        let socketPath = Self.socketPath()
        let listener = try Self.bindSocket(path: socketPath, listen: false)
        defer {
            close(listener)
            Self.removeSocketArtifacts(socketPath)
        }

        let host = await Self.makeHost(socketPath: socketPath)
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await host.startChecked()
        }

        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    func `host recognizes a live legacy listener through an equivalent path`() async throws {
        let name = "peekaboo-bridge-ownership-\(UUID().uuidString).sock"
        let boundPath = "/tmp/\(name)"
        let equivalentPath = "/private/tmp/\(name)"
        let listener = try Self.bindSocket(path: boundPath, listen: true)
        defer {
            close(listener)
            Self.removeSocketArtifacts(boundPath)
        }

        let host = await Self.makeHost(socketPath: equivalentPath)
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await host.startChecked()
        }

        #expect(FileManager.default.fileExists(atPath: boundPath))
    }

    @Test
    func `host recognizes a live relative listener after the owner changes directory`() async throws {
        let originalDirectory = FileManager.default.currentDirectoryPath
        let directory = "/tmp/peekaboo-relative-owner-\(UUID().uuidString)"
        let relativePath = "bridge.sock"
        let absolutePath = "\(directory)/\(relativePath)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        #expect(chdir(directory) == 0)
        defer {
            _ = chdir(originalDirectory)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let listener = try Self.bindSocket(path: relativePath, listen: true)
        #expect(chdir(originalDirectory) == 0)
        defer {
            close(listener)
            Self.removeSocketArtifacts(absolutePath)
        }

        let host = await Self.makeHost(socketPath: absolutePath)
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await host.startChecked()
        }

        #expect(FileManager.default.fileExists(atPath: absolutePath))
    }

    @Test
    func `host preserves a relative socket before listen after the owner changes directory`() async throws {
        let originalDirectory = FileManager.default.currentDirectoryPath
        let directory = "/tmp/peekaboo-relative-owner-\(UUID().uuidString)"
        let relativePath = "bridge.sock"
        let absolutePath = "\(directory)/\(relativePath)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        #expect(chdir(directory) == 0)
        defer {
            _ = chdir(originalDirectory)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let socket = try Self.bindSocket(path: relativePath, listen: false)
        #expect(chdir(originalDirectory) == 0)
        defer {
            close(socket)
            Self.removeSocketArtifacts(absolutePath)
        }

        let host = await Self.makeHost(socketPath: absolutePath)
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await host.startChecked()
        }

        #expect(FileManager.default.fileExists(atPath: absolutePath))
    }

    @Test
    func `host recovers a stale lease-owned socket`() async throws {
        let socketPath = Self.socketPath()
        let staleListener = try Self.bindSocket(path: socketPath, listen: false)
        try Self.recordLeaseIdentity(socketPath: socketPath)
        close(staleListener)
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        try await host.startChecked()

        let handshake = try await Self.client(socketPath: socketPath).handshake(client: Self.clientIdentity())
        #expect(handshake.hostKind == .gui)

        await host.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: "\(socketPath).lock")).isEmpty)
    }

    @Test
    func `host recovers a stale socket created before leases`() async throws {
        let socketPath = Self.socketPath()
        let staleListener = try Self.bindSocket(path: socketPath, listen: false)
        close(staleListener)
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        try await host.startChecked()

        let handshake = try await Self.client(socketPath: socketPath).handshake(client: Self.clientIdentity())
        #expect(handshake.hostKind == .gui)

        await host.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    func `host recovers after a partial self-generated lease record`() async throws {
        let socketPath = Self.socketPath()
        let staleListener = try Self.bindSocket(path: socketPath, listen: false)
        close(staleListener)
        try Data("peekaboo-bridge-lease-v1 12".utf8)
            .write(to: URL(fileURLWithPath: "\(socketPath).lock"))
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        try await host.startChecked()

        let handshake = try await Self.client(socketPath: socketPath).handshake(client: Self.clientIdentity())
        #expect(handshake.hostKind == .gui)
        let leaseContents = try String(contentsOfFile: "\(socketPath).lock", encoding: .utf8)
        #expect(!leaseContents.contains("peekaboo-bridge-lease-v1 12\n"))
        #expect(leaseContents.split(separator: "\n").count == 1)

        await host.stop()
    }

    @Test
    func `host uses the last complete lease record before a partial tail`() async throws {
        let socketPath = Self.socketPath()
        let staleListener = try Self.bindSocket(path: socketPath, listen: false)
        try Self.recordLeaseIdentity(socketPath: socketPath)
        let leaseURL = URL(fileURLWithPath: "\(socketPath).lock")
        let handle = try FileHandle(forWritingTo: leaseURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\npeekaboo-bridge-lea".utf8))
        try handle.close()
        close(staleListener)
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        try await host.startChecked()

        let handshake = try await Self.client(socketPath: socketPath).handshake(client: Self.clientIdentity())
        #expect(handshake.hostKind == .gui)

        await host.stop()
    }

    @Test
    func `host refuses to replace a non-socket path`() async throws {
        let socketPath = Self.socketPath()
        let contents = Data("owned by another subsystem".utf8)
        #expect(FileManager.default.createFile(atPath: socketPath, contents: contents))
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        do {
            try await host.startChecked()
            Issue.record("Expected the non-socket path to be preserved")
            await host.stop()
        } catch let error as PeekabooBridgeHostError {
            guard case let .socketPathIsNotSocket(path) = error else {
                Issue.record("Expected socketPathIsNotSocket, got \(error)")
                return
            }
            #expect(path == socketPath)
            #expect(try Data(contentsOf: URL(fileURLWithPath: socketPath)) == contents)
        }
    }

    @Test
    func `host refuses a symlinked lease without modifying its target`() async throws {
        let socketPath = Self.socketPath()
        let targetPath = "\(socketPath).target"
        let contents = Data("must remain intact".utf8)
        #expect(FileManager.default.createFile(atPath: targetPath, contents: contents))
        try FileManager.default.createSymbolicLink(
            atPath: "\(socketPath).lock",
            withDestinationPath: targetPath)
        defer {
            Self.removeSocketArtifacts(socketPath)
            unlink(targetPath)
        }

        let host = await Self.makeHost(socketPath: socketPath)
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await host.startChecked()
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: targetPath)) == contents)
    }

    @Test
    func `host refuses a malformed existing lease without modifying it`() async throws {
        let socketPath = Self.socketPath()
        let leasePath = "\(socketPath).lock"
        let contents = Data("owned by another subsystem".utf8)
        #expect(FileManager.default.createFile(atPath: leasePath, contents: contents))
        #expect(chmod(leasePath, S_IRUSR | S_IWUSR | S_IRGRP) == 0)
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await host.startChecked()
        }

        #expect(try Data(contentsOf: URL(fileURLWithPath: leasePath)) == contents)
        var info = stat()
        #expect(lstat(leasePath, &info) == 0)
        #expect(info.st_mode & mode_t(0o777) == S_IRUSR | S_IWUSR | S_IRGRP)
    }

    @Test
    func `host rejects an unreachable final socket path`() async {
        let socketPath = "/tmp/\(String(repeating: "x", count: 120))"
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        await #expect(throws: PeekabooBridgeHostError.self) {
            try await host.startChecked()
        }

        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    func `host supports a valid final path near the UNIX socket limit`() async throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let directoryName = "pb-\(token)\(String(repeating: "x", count: 50))"
        let directory = "/tmp/\(directoryName)"
        let socketPath = "\(directory)/s"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)

        let host = await Self.makeHost(socketPath: socketPath)
        do {
            try await host.startChecked()
            let handshake = try await Self.client(socketPath: socketPath).handshake(client: Self.clientIdentity())
            #expect(handshake.hostKind == .gui)
            await host.stop()
            try FileManager.default.removeItem(atPath: directory)
        } catch {
            await host.stop()
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
    }

    @Test
    func `host supports a relative socket filename`() async throws {
        let socketPath = "peekaboo-relative-\(UUID().uuidString).sock"
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        try await host.startChecked()

        let handshake = try await Self.client(socketPath: socketPath).handshake(client: Self.clientIdentity())
        #expect(handshake.hostKind == .gui)

        await host.stop()
    }

    @Test
    func `stopping an old host preserves a replacement socket`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath)
        try await host.startChecked()

        #expect(unlink(socketPath) == 0)
        let replacement = try Self.bindSocket(path: socketPath, listen: true)
        defer { close(replacement) }

        await host.stop()

        #expect(FileManager.default.fileExists(atPath: socketPath))
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(probe >= 0)
        defer { close(probe) }
        #expect(Self.connect(fd: probe, path: socketPath) == 0)
    }

    @Test
    func `failed socket cleanup preserves lease identity for recovery`() async throws {
        let directory = "/tmp/peekaboo-bridge-cleanup-\(UUID().uuidString)"
        let socketPath = "\(directory)/bridge.sock"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        defer {
            _ = chmod(directory, S_IRWXU)
            try? FileManager.default.removeItem(atPath: directory)
        }

        let host = await Self.makeHost(socketPath: socketPath)
        try await host.startChecked()
        let markerBefore = try Data(contentsOf: URL(fileURLWithPath: "\(socketPath).lock"))

        #expect(chmod(directory, S_IRUSR | S_IXUSR) == 0)
        await host.stop()
        #expect(chmod(directory, S_IRWXU) == 0)

        #expect(FileManager.default.fileExists(atPath: socketPath))
        let markerAfter = try Data(contentsOf: URL(fileURLWithPath: "\(socketPath).lock"))
        #expect(markerAfter == markerBefore)

        let replacement = await Self.makeHost(socketPath: socketPath)
        try await replacement.startChecked()
        await replacement.stop()
    }

    @Test
    func `host stop drains accepted connections through their deadline`() async throws {
        let socketPath = Self.socketPath()
        defer { Self.removeSocketArtifacts(socketPath) }

        let host = await Self.makeHost(socketPath: socketPath, requestTimeoutSec: 0.3)
        try await host.startChecked()

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(client >= 0)
        defer { close(client) }
        #expect(Self.connect(fd: client, path: socketPath) == 0)
        try await Task.sleep(nanoseconds: 50_000_000)

        let start = Date()
        await host.stop()

        #expect(Date().timeIntervalSince(start) >= 0.15)
    }

    private static func makeHost(
        socketPath: String,
        requestTimeoutSec: TimeInterval = 2) async -> PeekabooBridgeHost
    {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: true,
                        accessibility: true,
                        appleScript: true,
                        postEvent: true)
                })
        }
        return PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: requestTimeoutSec)
    }

    private static func client(socketPath: String) -> PeekabooBridgeClient {
        PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
    }

    private static func clientIdentity() -> PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: Host.current().name)
    }

    private static func socketPath() -> String {
        "/tmp/peekaboo-bridge-ownership-\(UUID().uuidString).sock"
    }

    private static func removeSocketArtifacts(_ socketPath: String) {
        unlink(socketPath)
        unlink("\(socketPath).lock")
    }

    private static func recordLeaseIdentity(socketPath: String) throws {
        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let marker = "peekaboo-bridge-lease-v1 \(UInt64(info.st_dev)) \(UInt64(info.st_ino))\n"
        try Data(marker.utf8).write(to: URL(fileURLWithPath: "\(socketPath).lock"))
    }

    private static func bindSocket(path: String, listen shouldListen: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            var address = try Self.socketAddress(path: path)
            let length = socklen_t(MemoryLayout.size(ofValue: address))
            let result = withUnsafePointer(to: &address) {
                Darwin.bind(fd, UnsafePointer<sockaddr>(OpaquePointer($0)), length)
            }
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if shouldListen {
                guard Darwin.listen(fd, SOMAXCONN) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func connect(fd: Int32, path: String) -> Int32 {
        guard var address = try? socketAddress(path: path) else { return -1 }
        let length = socklen_t(MemoryLayout.size(ofValue: address))
        return withUnsafePointer(to: &address) {
            Darwin.connect(fd, UnsafePointer<sockaddr>(OpaquePointer($0)), length)
        }
    }

    private static func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = path.withCString { strlcpy(&address.sun_path.0, $0, capacity) }
        guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        return address
    }
}
