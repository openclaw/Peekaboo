import Commander
import Darwin
import Foundation
import PeekabooBridge

extension BridgeCommand {
    /// Private coordinator surface for one Bridge-owned background Agent execution.
    ///
    /// This is intentionally a plain command rather than a `RuntimeBackedCommand`: selecting a
    /// normal command runtime here could recursively launch or route through another Bridge host.
    @MainActor
    struct AgentExecutionTraceSubcommand: ParsableCommand {
        static let commandDescription = CommandDescription(
            commandName: "_agent-execution-trace",
            abstract: "Run one coordinator-owned, signed background Agent execution"
        )

        static let coordinationReceiptBasename = "agent-execution-coordination.json"
        static let acknowledgementBasename = "agent-execution-ack.json"
        static let maximumTaskBytes = PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes
        static let maximumStepsRange = 1...100
        static let startTimeoutMillisecondsRange = 1...120_000
        static let runTimeoutMillisecondsRange = 1...7_200_000
        static let transportGraceSeconds: TimeInterval = 10

        @Option(name: .long, help: "Natural-language task for the background Agent")
        var task = ""

        @Option(name: .long, help: "Canonical existing owner-private run root")
        var runRoot = ""

        var bridgeSocket = ""

        @Option(
            name: .customLong("trusted-host-team-id"),
            help: "Trusted signing Team ID for the selected Bridge host; repeat to allow more than one"
        )
        var trustedHostTeamIDs: [String] = []

        @Option(name: .long, help: "Maximum Agent turns (1-100, default 40)")
        var maxSteps = 40

        @Option(name: .long, help: "Seconds to wait for coordinator acknowledgement (default 30)")
        var startTimeoutSeconds: TimeInterval = 30

        @Option(name: .long, help: "Seconds to wait for Agent termination (default 900)")
        var runTimeoutSeconds: TimeInterval = 900

        mutating func run() async throws {
            // Complete every caller-controlled validation before opening the selected socket.
            let invocation = try self.validatedInvocation()
            let client = PeekabooBridgeClient(
                socketPath: invocation.bridgeSocketPath,
                requestTimeoutSec: invocation.startTimeoutSeconds,
                trustedHostTeamIDs: invocation.trustedHostTeamIDs
            )
            let handshake = try await client.handshake(
                client: BridgeDiagnostics.currentClientIdentity(),
                overallTimeoutSec: invocation.startTimeoutSeconds
            )
            let bundle = try await client.agentExecutionTraceReceiptBundle(
                invocation.request,
                timeoutSeconds: invocation.startTimeoutSeconds + invocation.runTimeoutSeconds +
                    Self.transportGraceSeconds
            )
            guard let operationAttestation = handshake.operationAttestation else {
                throw ValidationError("Bridge did not retain the authenticated receipt trust anchor")
            }
            try bundle.validate(trustAnchor: .listenerAttestation(operationAttestation))
            var bytes = try bundle.canonicalEncodedData()
            bytes.append(0x0A)
            FileHandle.standardOutput.write(bytes)
        }

        func validatedInvocation() throws -> ValidatedInvocation {
            let request = try self.validatedRequest()
            let bridgeSocketPath = try Self.validatedAbsolutePath(
                self.bridgeSocket,
                option: "--bridge-socket",
                mustExist: true
            )
            let trustedHostTeamIDs = try BridgeReceiptVerifier.trustedHostTeamIDs(
                for: bridgeSocketPath,
                explicitValues: self.trustedHostTeamIDs
            )
            return ValidatedInvocation(
                request: request,
                bridgeSocketPath: bridgeSocketPath,
                trustedHostTeamIDs: trustedHostTeamIDs,
                startTimeoutSeconds: self.startTimeoutSeconds,
                runTimeoutSeconds: self.runTimeoutSeconds
            )
        }

        func validatedRequest() throws -> PeekabooBridgeAgentExecutionTraceRequest {
            guard !self.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  self.task.utf8.count <= Self.maximumTaskBytes,
                  !self.task.utf8.contains(0),
                  self.task.first != "-"
            else {
                throw ValidationError(
                    "--task must be nonempty, NUL-free, at most \(Self.maximumTaskBytes / 1024) KiB, " +
                        "and must not begin with '-'"
                )
            }
            guard Self.maximumStepsRange.contains(self.maxSteps) else {
                throw ValidationError("--max-steps must be between 1 and 100")
            }
            let startTimeoutMilliseconds = try Self.validatedMilliseconds(
                self.startTimeoutSeconds,
                option: "--start-timeout-seconds",
                range: Self.startTimeoutMillisecondsRange
            )
            let runTimeoutMilliseconds = try Self.validatedMilliseconds(
                self.runTimeoutSeconds,
                option: "--run-timeout-seconds",
                range: Self.runTimeoutMillisecondsRange
            )
            let runRootPath = try Self.validatedRunRoot(self.runRoot)
            let runRootURL = URL(fileURLWithPath: runRootPath, isDirectory: true)
            let coordinationReceiptPath = runRootURL
                .appendingPathComponent(Self.coordinationReceiptBasename, isDirectory: false).path
            let acknowledgementPath = runRootURL
                .appendingPathComponent(Self.acknowledgementBasename, isDirectory: false).path
            guard Self.pathIsAbsent(coordinationReceiptPath),
                  Self.pathIsAbsent(acknowledgementPath)
            else {
                throw ValidationError(
                    "--run-root must not already contain Agent execution coordination files"
                )
            }

            return PeekabooBridgeAgentExecutionTraceRequest(
                task: self.task,
                maxSteps: self.maxSteps,
                runRootPath: runRootPath,
                coordinationReceiptPath: coordinationReceiptPath,
                acknowledgementPath: acknowledgementPath,
                startTimeoutMilliseconds: startTimeoutMilliseconds,
                runTimeoutMilliseconds: runTimeoutMilliseconds
            )
        }

        private static func validatedMilliseconds(
            _ seconds: TimeInterval,
            option: String,
            range: ClosedRange<Int>
        ) throws -> Int {
            guard seconds.isFinite, seconds > 0,
                  seconds <= TimeInterval(range.upperBound) / 1000
            else {
                throw ValidationError(
                    "\(option) must be greater than zero and at most \(range.upperBound / 1000)"
                )
            }
            let milliseconds = Int((seconds * 1000).rounded(.up))
            guard range.contains(milliseconds) else {
                throw ValidationError(
                    "\(option) must be at least \(Double(range.lowerBound) / 1000) seconds"
                )
            }
            return milliseconds
        }

        private static func validatedRunRoot(_ rawPath: String) throws -> String {
            let runRootPath = try self.validatedAbsolutePath(
                rawPath,
                option: "--run-root",
                mustExist: true
            )
            var info = stat()
            guard lstat(runRootPath, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid(),
                  (info.st_mode & 0o777) == 0o700
            else {
                throw ValidationError("--run-root must be an existing owner-owned mode-0700 directory")
            }
            return runRootPath
        }

        private static func validatedAbsolutePath(
            _ rawPath: String,
            option: String,
            mustExist: Bool
        ) throws -> String {
            guard !rawPath.isEmpty,
                  !rawPath.utf8.contains(0)
            else {
                throw ValidationError("\(option) must be a nonempty, NUL-free absolute path")
            }
            let expandedPath = (rawPath as NSString).expandingTildeInPath
            guard expandedPath.first == "/" else {
                throw ValidationError("\(option) must be an absolute path")
            }
            let pathComponents = (expandedPath as NSString).pathComponents
            guard !pathComponents.contains("."), !pathComponents.contains("..") else {
                throw ValidationError("\(option) must be canonical and contain no '.' or '..' components")
            }
            if mustExist {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                guard expandedPath.withCString({ realpath($0, &buffer) }) != nil else {
                    throw ValidationError("\(option) must be a canonical existing path")
                }
                let isCanonical = expandedPath.withCString { expectedPath in
                    buffer.withUnsafeBufferPointer { resolvedPath in
                        strcmp(resolvedPath.baseAddress, expectedPath) == 0
                    }
                }
                guard isCanonical else {
                    throw ValidationError("\(option) must be a canonical existing path")
                }
            }
            return expandedPath
        }

        private static func pathIsAbsent(_ path: String) -> Bool {
            var info = stat()
            if lstat(path, &info) == 0 {
                return false
            }
            return errno == ENOENT
        }
    }
}

extension BridgeCommand.AgentExecutionTraceSubcommand {
    struct ValidatedInvocation {
        let request: PeekabooBridgeAgentExecutionTraceRequest
        let bridgeSocketPath: String
        let trustedHostTeamIDs: Set<String>
        let startTimeoutSeconds: TimeInterval
        let runTimeoutSeconds: TimeInterval
    }
}

@MainActor
extension BridgeCommand.AgentExecutionTraceSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.task = try values.requireOption("task", as: String.self)
        self.runRoot = try values.requireOption("runRoot", as: String.self)
        self.bridgeSocket = try values.requireOption("bridge-socket", as: String.self)
        self.trustedHostTeamIDs = values.optionValues("trustedHostTeamIDs")
        self.maxSteps = try values.decodeOption("maxSteps", as: Int.self) ?? self.maxSteps
        self.startTimeoutSeconds = try values.decodeOption("startTimeoutSeconds", as: TimeInterval.self) ??
            self.startTimeoutSeconds
        self.runTimeoutSeconds = try values.decodeOption("runTimeoutSeconds", as: TimeInterval.self) ??
            self.runTimeoutSeconds
    }
}
