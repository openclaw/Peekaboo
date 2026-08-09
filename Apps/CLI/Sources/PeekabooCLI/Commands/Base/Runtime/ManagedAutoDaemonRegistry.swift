import Darwin
import Foundation
import PeekabooBridge

struct ManagedAutoDaemonRecord: Codable, Equatable, Sendable {
    let socketPath: String
    let processIdentifier: pid_t
    let startedAt: Date
}

enum ManagedAutoDaemonRegistry {
    private static let maximumRecordBytes: off_t = 4096

    static func makeRecord(
        status: PeekabooDaemonStatus,
        socketPath: String,
        daemonSocketPath: String = PeekabooBridgeConstants.daemonSocketPath
    ) -> ManagedAutoDaemonRecord? {
        let standardizedSocketPath = self.standardizedPath(socketPath)
        let daemonURL = URL(fileURLWithPath: self.standardizedPath(daemonSocketPath))
        let socketURL = URL(fileURLWithPath: standardizedSocketPath)
        guard self.standardizedPath(daemonSocketPath) ==
            self.standardizedPath(PeekabooBridgeConstants.daemonSocketPath),
            socketURL.deletingLastPathComponent() == daemonURL.deletingLastPathComponent(),
            DaemonControlResolver.isBuildScopedSocketName(socketURL.lastPathComponent),
            status.mode == .auto,
            let processIdentifier = status.pid,
            processIdentifier > 0,
            let startedAt = status.startedAt,
            status.bridge?.hostKind == .onDemand,
            status.bridge.map({ self.standardizedPath($0.socketPath) }) == standardizedSocketPath
        else {
            return nil
        }
        return ManagedAutoDaemonRecord(
            socketPath: standardizedSocketPath,
            processIdentifier: processIdentifier,
            startedAt: startedAt
        )
    }

    static func store(status: PeekabooDaemonStatus, socketPath: String) {
        guard let record = self.makeRecord(status: status, socketPath: socketPath),
              let data = try? JSONEncoder().encode(record)
        else {
            return
        }
        let recordURL = self.recordURL(socketPath: record.socketPath)
        do {
            try data.write(to: recordURL, options: .atomic)
            _ = chmod(recordURL.path, S_IRUSR | S_IWUSR)
        } catch {
            return
        }
    }

    static func load(socketPath: String) -> ManagedAutoDaemonRecord? {
        let recordPath = self.recordURL(socketPath: socketPath).path
        let descriptor = open(recordPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_size > 0,
              info.st_size <= self.maximumRecordBytes,
              let data = try? handle.readToEnd(),
              let record = try? JSONDecoder().decode(ManagedAutoDaemonRecord.self, from: data)
        else {
            return nil
        }
        return record
    }

    static func matches(
        _ record: ManagedAutoDaemonRecord?,
        status: PeekabooDaemonStatus,
        socketPath: String
    ) -> Bool {
        guard let record,
              let processIdentifier = status.pid,
              let startedAt = status.startedAt
        else {
            return false
        }
        return record.socketPath == self.standardizedPath(socketPath) &&
            record.processIdentifier == processIdentifier &&
            record.startedAt == startedAt
    }

    static func pruneStaleRecords(
        daemonSocketPath: String = PeekabooBridgeConstants.daemonSocketPath,
        canonicalDaemonSocketPath: String = PeekabooBridgeConstants.daemonSocketPath
    ) {
        guard self.standardizedPath(daemonSocketPath) == self.standardizedPath(canonicalDaemonSocketPath) else {
            return
        }
        let directoryURL = URL(fileURLWithPath: daemonSocketPath).deletingLastPathComponent()
        guard let recordURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let recordSuffix = ".sock.managed-auto.json"
        for recordURL in recordURLs where recordURL.lastPathComponent.hasSuffix(recordSuffix) {
            let socketName = String(recordURL.lastPathComponent.dropLast(".managed-auto.json".count))
            guard DaemonControlResolver.isBuildScopedSocketName(socketName) else { continue }

            var socketInfo = stat()
            let socketPath = directoryURL.appendingPathComponent(socketName).path
            guard let record = self.load(socketPath: socketPath),
                  record.socketPath == self.standardizedPath(socketPath),
                  record.processIdentifier > 0
            else {
                continue
            }
            guard lstat(socketPath, &socketInfo) != 0, errno == ENOENT else { continue }
            _ = unlink(recordURL.path)
        }
    }

    private static func recordURL(socketPath: String) -> URL {
        URL(fileURLWithPath: "\(self.standardizedPath(socketPath)).managed-auto.json")
    }

    private static func standardizedPath(_ path: String) -> String {
        NSString(string: path).standardizingPath
    }
}
