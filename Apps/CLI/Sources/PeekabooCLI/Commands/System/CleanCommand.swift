import Commander
import Foundation
import PeekabooCore

/// Clean up snapshot cache and temporary files
@available(macOS 14.0, *)
@MainActor
struct CleanCommand: OutputFormattable, RuntimeOptionsConfigurable {
    static let commandDescription = CommandDescription(
        commandName: "clean",
        abstract: "Clean up snapshot cache and temporary files",
        discussion: """

            EXAMPLES:
              peekaboo clean --all-snapshots      # Remove all snapshot data
              peekaboo clean --older-than 24      # Remove snapshots older than 24 hours
              peekaboo clean --snapshot 12345     # Remove specific snapshot
              peekaboo clean --dry-run            # Preview what would be deleted

            SNAPSHOT CACHE:
              Snapshots are stored in ~/.peekaboo/snapshots/<snapshot-id>/
              Each snapshot contains:
              - snapshot.json: UI element mapping and metadata

              --snapshot only checks the on-disk cache. If the ID exists only in the
              daemon's memory backend, the command reports not_found and removes nothing.
        """,

        showHelpOnEmptyInvocation: true
    )

    @Flag(help: "Remove all snapshot data")
    var allSnapshots = false

    @Option(help: "Remove snapshots older than specified hours (default: 24)")
    var olderThan: Int?

    @Option(help: "Remove specific snapshot by ID")
    var snapshot: String?

    @Flag(help: "Show what would be deleted without actually deleting")
    var dryRun = false
    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    var outputLogger: Logger {
        self.logger
    }

    private var configuration: CommandRuntime.Configuration {
        if let runtime {
            return runtime.configuration
        }
        // During bare parsing in unit tests no runtime is injected; fall back
        // to the parsed runtime options so flags like --json are visible.
        return self.runtimeOptions.makeConfiguration()
    }

    var jsonOutput: Bool {
        self.configuration.jsonOutput
    }

    var effectiveOlderThan: Int? {
        if let olderThan {
            return olderThan
        }
        if self.dryRun, !self.allSnapshots, self.snapshot == nil {
            return 24
        }
        return nil
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()

        do {
            // Validate options
            let effectiveOlderThan = self.effectiveOlderThan
            let optionCount = [allSnapshots, effectiveOlderThan != nil, self.snapshot != nil].count { $0 }
            guard optionCount == 1 else {
                throw ValidationError("Specify exactly one of: --all-snapshots, --older-than, or --snapshot")
            }

            // Perform cleanup based on option using the FileService
            let result: SnapshotCleanResult
            let requestedSnapshotId = self.snapshot

            if self.allSnapshots {
                result = try await self.services.files.cleanAllSnapshots(dryRun: self.dryRun)
            } else if let hours = effectiveOlderThan {
                result = try await self.services.files.cleanOldSnapshots(hours: hours, dryRun: self.dryRun)
            } else if let snapshotId = snapshot {
                result = try await self.services.files.cleanSpecificSnapshot(
                    snapshotId: snapshotId,
                    dryRun: self.dryRun
                )
            } else {
                throw ValidationError("No cleanup option specified")
            }

            // Calculate execution time
            let executionTime = Date().timeIntervalSince(startTime)

            // Output results
            if self.jsonOutput {
                let outputData = CleanResultPayload(
                    result: result,
                    executionTime: executionTime,
                    requestedSnapshotId: requestedSnapshotId
                )
                outputSuccessCodable(data: outputData, logger: self.outputLogger)
            } else {
                self.printResults(
                    result,
                    executionTime: executionTime,
                    requestedSnapshotId: requestedSnapshotId
                )
            }

        } catch let error as ValidationError {
            if self.jsonOutput {
                outputError(message: error.localizedDescription, code: .VALIDATION_ERROR, logger: self.outputLogger)
            } else {
                var stderrStream = FileHandleTextOutputStream(FileHandle.standardError)
                print("Error: \(error.localizedDescription)", to: &stderrStream)
            }
            throw ExitCode.failure
        } catch let error as FileServiceError {
            handleFileServiceError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
            throw ExitCode(1)
        } catch {
            if self.jsonOutput {
                outputError(message: error.localizedDescription, code: .INTERNAL_SWIFT_ERROR, logger: self.outputLogger)
            } else {
                var localStandardErrorStream = FileHandleTextOutputStream(FileHandle.standardError)
                print("Error: \(error.localizedDescription)", to: &localStandardErrorStream)
            }
            throw ExitCode.failure
        }
    }

    private func printResults(
        _ result: SnapshotCleanResult,
        executionTime: TimeInterval,
        requestedSnapshotId: String?
    ) {
        if result.dryRun {
            print("🔍 Dry run mode - no files will be deleted")
            print("")
        }

        if result.snapshotsRemoved == 0 {
            if let requestedSnapshotId {
                print("✅ Snapshot '\(requestedSnapshotId)' was not found on disk; no disk snapshots were removed")
                print("ℹ️  Daemon-memory snapshots are not pruned by this command.")
            } else {
                print("✅ No snapshots to clean")
            }
        } else {
            let action = result.dryRun ? "Would remove" : "Removed"
            print("🗑️  \(action) \(result.snapshotsRemoved) snapshot\(result.snapshotsRemoved == 1 ? "" : "s")")
            print("💾 Space \(result.dryRun ? "to be freed" : "freed"): \(self.formatBytes(result.bytesFreed))")

            if result.snapshotDetails.count <= 5 {
                print("\nSnapshots:")
                for detail in result.snapshotDetails {
                    print("  - \(detail.snapshotId) (\(self.formatBytes(detail.size)))")
                }
            }
        }

        print("\n⏱️  Completed in \(String(format: "%.2f", executionTime))s")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private struct CleanResultPayload: Codable {
        let snapshotsRemoved: Int
        let bytesFreed: Int64
        let snapshotDetails: [SnapshotDetail]
        let dryRun: Bool
        let executionTime: TimeInterval?
        let not_found: Bool?

        init(result: SnapshotCleanResult, executionTime: TimeInterval, requestedSnapshotId: String?) {
            self.snapshotsRemoved = result.snapshotsRemoved
            self.bytesFreed = result.bytesFreed
            self.snapshotDetails = result.snapshotDetails
            self.dryRun = result.dryRun
            self.executionTime = executionTime
            self.not_found = requestedSnapshotId != nil && result.snapshotsRemoved == 0 ? true : nil
        }
    }
}

// MARK: - Error Handling

private func handleFileServiceError(_ error: FileServiceError, jsonOutput: Bool, logger: Logger) {
    let errorCode: ErrorCode = switch error {
    case .snapshotNotFound:
        .SNAPSHOT_NOT_FOUND
    case .directoryNotFound:
        .FILE_IO_ERROR
    case .insufficientPermissions:
        .PERMISSION_DENIED
    case .fileSystemError:
        .FILE_IO_ERROR
    }

    if jsonOutput {
        outputError(message: error.localizedDescription, code: errorCode, logger: logger)
    } else {
        var localStandardErrorStream = FileHandleTextOutputStream(FileHandle.standardError)
        print("❌ \(error.localizedDescription)", to: &localStandardErrorStream)
    }
}

extension CleanCommand: AsyncRuntimeCommand {}

@MainActor
extension CleanCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.allSnapshots = values.flag("allSnapshots")
        self.dryRun = values.flag("dryRun")
        self.olderThan = try values.decodeOption("olderThan", as: Int.self)
        self.snapshot = values.singleOption("snapshot")
    }
}
