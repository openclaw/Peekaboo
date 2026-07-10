import Foundation

/// Protocol defining file system operations for snapshot management.
public protocol FileServiceProtocol: Sendable {
    /// Clean all snapshot data.
    /// - Parameter dryRun: If true, only preview what would be deleted without actually deleting.
    /// - Returns: Result containing information about cleaned snapshots.
    func cleanAllSnapshots(dryRun: Bool) async throws -> SnapshotCleanResult

    /// Clean snapshots older than specified hours.
    /// - Parameters:
    ///   - hours: Remove snapshots older than this many hours.
    ///   - dryRun: If true, only preview what would be deleted without actually deleting.
    /// - Returns: Result containing information about cleaned snapshots.
    func cleanOldSnapshots(hours: Int, dryRun: Bool) async throws -> SnapshotCleanResult

    /// Clean a specific snapshot by ID.
    /// - Parameters:
    ///   - snapshotId: The snapshot ID to remove.
    ///   - dryRun: If true, only preview what would be deleted without actually deleting.
    /// - Returns: Result containing information about the cleaned snapshot.
    func cleanSpecificSnapshot(snapshotId: String, dryRun: Bool) async throws -> SnapshotCleanResult

    /// Get the snapshot cache directory path.
    /// - Returns: URL to the snapshot cache directory.
    func getSnapshotCacheDirectory() -> URL

    /// Calculate the total size of a directory and its contents.
    /// - Parameter directory: The directory to calculate size for.
    /// - Returns: Total size in bytes.
    func calculateDirectorySize(_ directory: URL) async throws -> Int64

    /// List all snapshots with their metadata.
    /// - Returns: Array of snapshot information.
    func listSnapshots() async throws -> [FileSnapshotInfo]
}

/// Result of cleaning operations.
public struct SnapshotCleanResult: Sendable, Codable {
    /// Number of snapshots removed.
    public let snapshotsRemoved: Int

    /// Total bytes freed.
    public let bytesFreed: Int64

    /// Details about each cleaned snapshot.
    public let snapshotDetails: [SnapshotDetail]

    /// Whether this was a dry run.
    public let dryRun: Bool

    /// Execution time in seconds.
    public var executionTime: TimeInterval?

    public init(
        snapshotsRemoved: Int,
        bytesFreed: Int64,
        snapshotDetails: [SnapshotDetail],
        dryRun: Bool,
        executionTime: TimeInterval? = nil)
    {
        self.snapshotsRemoved = snapshotsRemoved
        self.bytesFreed = bytesFreed
        self.snapshotDetails = snapshotDetails
        self.dryRun = dryRun
        self.executionTime = executionTime
    }
}

/// Details about a specific snapshot.
public struct SnapshotDetail: Sendable, Codable {
    /// Snapshot identifier.
    public let snapshotId: String

    /// Full path to the snapshot directory.
    public let path: String

    /// Size of the snapshot in bytes.
    public let size: Int64

    /// Creation date of the snapshot.
    public let creationDate: Date?

    /// Last modification date.
    public let modificationDate: Date?

    public init(
        snapshotId: String,
        path: String,
        size: Int64,
        creationDate: Date? = nil,
        modificationDate: Date? = nil)
    {
        self.snapshotId = snapshotId
        self.path = path
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

/// Information about a snapshot from file system perspective.
public struct FileSnapshotInfo: Sendable, Codable {
    /// Snapshot identifier.
    public let snapshotId: String

    /// Path to the snapshot directory.
    public let path: URL

    /// Size in bytes.
    public let size: Int64

    /// Creation date.
    public let creationDate: Date

    /// Last modification date.
    public let modificationDate: Date

    /// Files contained in the snapshot.
    public let files: [String]

    public init(
        snapshotId: String,
        path: URL,
        size: Int64,
        creationDate: Date,
        modificationDate: Date,
        files: [String])
    {
        self.snapshotId = snapshotId
        self.path = path
        self.size = size
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.files = files
    }
}

/// Errors that can occur during file operations.
public enum FileServiceError: LocalizedError, Sendable {
    case invalidSnapshotID
    case snapshotNotFound(String)
    case directoryNotFound(URL)
    case insufficientPermissions(URL)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshotID:
            "Invalid snapshot ID: expected one folder name"
        case let .snapshotNotFound(snapshotId):
            "Snapshot '\(snapshotId)' not found"
        case let .directoryNotFound(url):
            "Directory not found: \(url.path)"
        case let .insufficientPermissions(url):
            "Insufficient permissions to access: \(url.path)"
        case let .fileSystemError(message):
            "File system error: \(message)"
        }
    }
}
