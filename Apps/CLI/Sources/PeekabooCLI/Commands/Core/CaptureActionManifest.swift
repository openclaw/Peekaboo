import CryptoKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

struct CaptureActionManifestReceipt: Codable {
    let path: String
    let sha256: String

    init(path: String, sha256: String) {
        precondition(Self.isValid(path: path, sha256: sha256))
        self.path = path
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case sha256
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let sha256 = try container.decode(String.self, forKey: .sha256)
        guard Self.isValid(path: path, sha256: sha256) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sha256,
                in: container,
                debugDescription: "Capture action manifest receipt is invalid"
            )
        }
        self.path = path
        self.sha256 = sha256
    }

    private static func isValid(path: String, sha256: String) -> Bool {
        path.hasPrefix("/") && !path.hasSuffix("/") && sha256.utf8.count == 64 && sha256.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}

struct CaptureActionManifest: Codable {
    enum ContainmentScope: String, Codable {
        case processGroup = "process_group"
    }

    let schemaVersion: Int
    let runID: String
    let timeline: Timeline
    let request: Request
    let action: Action
    let capture: Capture
    let artifacts: [Artifact]
    let result: ResultSemantics

    init(
        schemaVersion: Int,
        runID: String,
        timeline: Timeline,
        request: Request,
        action: Action,
        capture: Capture,
        artifacts: [Artifact],
        result: ResultSemantics
    ) {
        precondition(schemaVersion == 1 && !runID.isEmpty)
        precondition(Self.artifactsAreCanonical(artifacts))
        precondition(Self.semanticFailure(
            timeline: timeline,
            request: request,
            action: action,
            capture: capture,
            result: result
        ) == nil)
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.timeline = timeline
        self.request = request
        self.action = action
        self.capture = capture
        self.artifacts = artifacts
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case timeline
        case request
        case action
        case capture
        case artifacts
        case result
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let runID = try container.decode(String.self, forKey: .runID)
        let timeline = try container.decode(Timeline.self, forKey: .timeline)
        let request = try container.decode(Request.self, forKey: .request)
        let action = try container.decode(Action.self, forKey: .action)
        let capture = try container.decode(Capture.self, forKey: .capture)
        let artifacts = try container.decode([Artifact].self, forKey: .artifacts)
        let result = try container.decode(ResultSemantics.self, forKey: .result)
        if schemaVersion != 1 || runID.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Capture action manifest identity is invalid"
            )
        }
        guard Self.artifactsAreCanonical(artifacts) else {
            throw DecodingError.dataCorruptedError(
                forKey: .artifacts,
                in: container,
                debugDescription: "Capture action manifest artifact inventory is invalid"
            )
        }
        if let failure = Self.semanticFailure(
            timeline: timeline,
            request: request,
            action: action,
            capture: capture,
            result: result
        ) {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: failure
            )
        }
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.timeline = timeline
        self.request = request
        self.action = action
        self.capture = capture
        self.artifacts = artifacts
        self.result = result
    }

    private static func semanticFailure(
        timeline: Timeline,
        request: Request,
        action: Action,
        capture: Capture,
        result: ResultSemantics
    ) -> String? {
        guard request.preRollMs >= 0, request.postRollMs >= 0 else {
            return "Capture action manifest roll timing is invalid"
        }
        let (postRollBoundaryMs, postRollOverflow) = timeline.actionCompletedMs.addingReportingOverflow(
            request.postRollMs
        )
        guard !postRollOverflow else {
            return "Capture action manifest roll timing overflowed"
        }
        let expectedFocusRoute: DesktopActionOutcome.Route = capture.executionRoute == .remote ? .bridge : .local
        if let focusOutcome = result.focusOutcome?.outcome,
           focusOutcome.route != expectedFocusRoute {
            return "Capture action focus route contradicts the selected capture host"
        }
        let routeIsCanonical = switch capture.executionRoute {
        case .local: capture.remoteSocketPath == nil
        case .remote: capture.remoteSocketPath?.isEmpty == false
        }
        let expectedSuccess = !action.timedOut && action.exitCode == 0 &&
            action.processGroupCleaned && result.validation.ok
        guard request.commandArgumentCount > 0,
              request.actionTimeoutSeconds.isFinite,
              request.actionTimeoutSeconds >= 0,
              request.captureDurationLimitSeconds.isFinite,
              request.captureDurationLimitSeconds > 0,
              timeline.captureStartedAtUnixMs > 0,
              timeline.actionStartedMs >= 0,
              timeline.actionCompletedMs >= timeline.actionStartedMs,
              timeline.samplingCompletedMs >= 0,
              timeline.captureCompletedMs >= timeline.samplingCompletedMs,
              action.processGroupCleaned,
              routeIsCanonical,
              !capture.hostDescription.isEmpty,
              result.childOutcome.outcome == CaptureActionOutcomeSemantics.completedChildOutcome,
              result.success == expectedSuccess,
              !result.success || timeline.samplingCompletedMs >= postRollBoundaryMs,
              request.captureFocus != .background || result.focusOutcome == nil
        else {
            return "Capture action manifest fields contradict the retained action evidence"
        }
        return nil
    }

    private static func artifactsAreCanonical(_ artifacts: [Artifact]) -> Bool {
        !artifacts.isEmpty &&
            Set(artifacts.map(\.path)).count == artifacts.count &&
            artifacts.contains(where: { $0.role == .frame }) &&
            artifacts.contains(where: { $0.role == .contactSheet }) &&
            artifacts.contains(where: { $0.role == .metadata })
    }

    struct Timeline: Codable {
        let captureStartedAtUnixMs: Int64
        let actionStartedMs: Int
        let actionCompletedMs: Int
        let samplingCompletedMs: Int
        let captureCompletedMs: Int
    }

    struct Request: Codable {
        let commandSHA256: String
        let commandArgumentCount: Int
        let preRollMs: Int
        let postRollMs: Int
        let actionTimeoutSeconds: TimeInterval
        let captureDurationLimitSeconds: TimeInterval
        let captureFocus: CaptureFocus
        let requestedCaptureEngine: CaptureEnginePreference
    }

    struct Stream: Codable {
        let sha256: String
        let byteCount: Int
        let truncated: Bool
    }

    struct Action: Codable {
        let containmentScope: ContainmentScope
        let processIdentifier: pid_t
        let processStartIdentity: UInt64
        let processStartIdentityDecimal: String
        let exitCode: Int32
        let timedOut: Bool
        let processGroupCleaned: Bool
        let durationMs: Int
        let stdout: Stream
        let stderr: Stream

        init(
            containmentScope: ContainmentScope,
            processIdentifier: pid_t,
            processStartIdentity: UInt64,
            processStartIdentityDecimal: String,
            exitCode: Int32,
            timedOut: Bool,
            processGroupCleaned: Bool,
            durationMs: Int,
            stdout: Stream,
            stderr: Stream
        ) {
            precondition(processStartIdentityDecimal == String(processStartIdentity))
            self.containmentScope = containmentScope
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.processStartIdentityDecimal = processStartIdentityDecimal
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.processGroupCleaned = processGroupCleaned
            self.durationMs = durationMs
            self.stdout = stdout
            self.stderr = stderr
        }

        private enum CodingKeys: String, CodingKey {
            case containmentScope
            case processIdentifier
            case processStartIdentity
            case processStartIdentityDecimal
            case exitCode
            case timedOut
            case processGroupCleaned
            case durationMs
            case stdout
            case stderr
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let processIdentifier = try container.decode(pid_t.self, forKey: .processIdentifier)
            let processStartIdentity = try container.decode(UInt64.self, forKey: .processStartIdentity)
            let processStartIdentityDecimal = try container.decode(
                String.self,
                forKey: .processStartIdentityDecimal
            )
            guard processIdentifier > 0,
                  processStartIdentity > 0,
                  processStartIdentityDecimal == String(processStartIdentity)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .processStartIdentity,
                    in: container,
                    debugDescription: "Capture action process provenance is incomplete"
                )
            }
            self.containmentScope = try container.decode(ContainmentScope.self, forKey: .containmentScope)
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.processStartIdentityDecimal = processStartIdentityDecimal
            self.exitCode = try container.decode(Int32.self, forKey: .exitCode)
            self.timedOut = try container.decode(Bool.self, forKey: .timedOut)
            self.processGroupCleaned = try container.decode(Bool.self, forKey: .processGroupCleaned)
            self.durationMs = try container.decode(Int.self, forKey: .durationMs)
            self.stdout = try container.decode(Stream.self, forKey: .stdout)
            self.stderr = try container.decode(Stream.self, forKey: .stderr)
        }
    }

    struct Capture: Codable {
        let scope: CaptureScope
        let executionRoute: PeekabooServiceExecutionHost
        let hostDescription: String
        let remoteSocketPath: String?
        let hostIdentity: AuthenticatedHostIdentity
        let observedCaptureEngines: [String]
    }

    struct AuthenticatedHostIdentity: Codable, Equatable {
        let processIdentifier: pid_t
        let processStartIdentity: UInt64
        let processStartIdentityDecimal: String
        let signingIdentifier: String
        let teamIdentifier: String
        let bundleShortVersion: String?
        let bundleVersion: String?
        let codeSignatureHash: String
        let sourceCommit: String

        init(validating identity: PeekabooBridgeAuthenticatedHostIdentity) throws {
            guard identity.processIdentifier > 0,
                  identity.processStartIdentity > 0,
                  !identity.signingIdentifier.isEmpty,
                  PeekabooBridgeConstants.trustedReleaseTeamIDs.contains(identity.teamIdentifier),
                  Self.isLowerHex(identity.codeSignatureHash, count: 40),
                  Self.isLowerHex(identity.sourceCommit, count: 40)
            else {
                throw CaptureActionHostProvenanceError(
                    message: "Capture action requires a source-stamped, signed host identity"
                )
            }
            self.processIdentifier = identity.processIdentifier
            self.processStartIdentity = identity.processStartIdentity
            self.processStartIdentityDecimal = String(identity.processStartIdentity)
            self.signingIdentifier = identity.signingIdentifier
            self.teamIdentifier = identity.teamIdentifier
            self.bundleShortVersion = identity.bundleShortVersion
            self.bundleVersion = identity.bundleVersion
            self.codeSignatureHash = identity.codeSignatureHash
            self.sourceCommit = identity.sourceCommit
        }

        private enum CodingKeys: String, CodingKey {
            case processIdentifier
            case processStartIdentity
            case processStartIdentityDecimal
            case signingIdentifier
            case teamIdentifier
            case bundleShortVersion
            case bundleVersion
            case codeSignatureHash
            case sourceCommit
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let processIdentifier = try container.decode(pid_t.self, forKey: .processIdentifier)
            let processStartIdentity = try container.decode(UInt64.self, forKey: .processStartIdentity)
            let processStartIdentityDecimal = try container.decode(
                String.self,
                forKey: .processStartIdentityDecimal
            )
            let codeSignatureHash = try container.decode(String.self, forKey: .codeSignatureHash)
            let sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
            let signingIdentifier = try container.decode(String.self, forKey: .signingIdentifier)
            let teamIdentifier = try container.decode(String.self, forKey: .teamIdentifier)
            guard processIdentifier > 0,
                  processStartIdentity > 0,
                  processStartIdentityDecimal == String(processStartIdentity),
                  !signingIdentifier.isEmpty,
                  PeekabooBridgeConstants.trustedReleaseTeamIDs.contains(teamIdentifier),
                  Self.isLowerHex(codeSignatureHash, count: 40),
                  Self.isLowerHex(sourceCommit, count: 40)
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .codeSignatureHash,
                    in: container,
                    debugDescription: "Capture action host provenance is incomplete"
                )
            }
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.processStartIdentityDecimal = processStartIdentityDecimal
            self.signingIdentifier = signingIdentifier
            self.teamIdentifier = teamIdentifier
            self.bundleShortVersion = try container.decodeIfPresent(String.self, forKey: .bundleShortVersion)
            self.bundleVersion = try container.decodeIfPresent(String.self, forKey: .bundleVersion)
            self.codeSignatureHash = codeSignatureHash
            self.sourceCommit = sourceCommit
        }

        private static func isLowerHex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                    (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
        }
    }

    struct Artifact: Codable {
        enum Role: String, Codable {
            case frame
            case contactSheet = "contact_sheet"
            case metadata
            case video
        }

        let role: Role
        let path: String
        let byteCount: Int
        let sha256: String
    }

    struct ResultSemantics: Codable {
        let commandSucceeded: Bool
        let validation: CaptureActionArtifactValidation
        let focusOutcome: DesktopActionOutcome.Projection?
        let childOutcome: DesktopActionOutcome.Projection
        let outcome: DesktopActionOutcome.Projection?

        var success: Bool {
            self.commandSucceeded
        }

        var effect: DesktopActionOutcome.Effect {
            self.outcome?.effect ?? .unverifiable
        }

        var mutationDispatched: Bool {
            self.outcome?.mutationDispatched ?? self.childOutcome.mutationDispatched
        }

        var retrySafe: Bool {
            self.outcome?.retrySafe ?? false
        }

        init(
            commandSucceeded: Bool,
            validation: CaptureActionArtifactValidation,
            focusOutcome: DesktopActionOutcome?,
            childOutcome: DesktopActionOutcome,
            outcome: DesktopActionOutcome?
        ) {
            precondition(CaptureActionOutcomeSemantics.isCanonicalAggregate(
                outcome,
                focusOutcome: focusOutcome,
                childOutcome: childOutcome
            ))
            precondition(validation.isCanonical)
            self.commandSucceeded = commandSucceeded
            self.validation = validation
            self.focusOutcome = focusOutcome?.projection
            self.childOutcome = childOutcome.projection
            self.outcome = outcome?.projection
        }

        private enum CodingKeys: String, CodingKey {
            case success
            case effect
            case mutationDispatched
            case retrySafe
            case validation
            case focusOutcome
            case childOutcome
            case outcome
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let commandSucceeded = try container.decode(Bool.self, forKey: .success)
            let validation = try container.decode(CaptureActionArtifactValidation.self, forKey: .validation)
            let focusOutcome = try container.decodeIfPresent(
                DesktopActionOutcome.Projection.self,
                forKey: .focusOutcome
            )
            let childOutcome = try container.decode(
                DesktopActionOutcome.Projection.self,
                forKey: .childOutcome
            )
            let outcome = try container.decodeIfPresent(DesktopActionOutcome.Projection.self, forKey: .outcome)
            self.commandSucceeded = commandSucceeded
            self.validation = validation
            self.focusOutcome = focusOutcome
            self.childOutcome = childOutcome
            self.outcome = outcome
            guard validation.isCanonical,
                  CaptureActionOutcomeSemantics.isCanonicalAggregate(
                      outcome?.outcome,
                      focusOutcome: focusOutcome?.outcome,
                      childOutcome: childOutcome.outcome
                  ),
                  try container.decode(DesktopActionOutcome.Effect.self, forKey: .effect) == self.effect,
                  try container.decode(Bool.self, forKey: .mutationDispatched) == self.mutationDispatched,
                  try container.decode(Bool.self, forKey: .retrySafe) == self.retrySafe
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .outcome,
                    in: container,
                    debugDescription: "Capture action result fields contradict the canonical outcome"
                )
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.success, forKey: .success)
            try container.encode(self.effect, forKey: .effect)
            try container.encode(self.mutationDispatched, forKey: .mutationDispatched)
            try container.encode(self.retrySafe, forKey: .retrySafe)
            try container.encode(self.validation, forKey: .validation)
            try container.encodeIfPresent(self.focusOutcome, forKey: .focusOutcome)
            try container.encode(self.childOutcome, forKey: .childOutcome)
            try container.encodeIfPresent(self.outcome, forKey: .outcome)
        }
    }
}

enum CaptureActionManifestWriter {
    static let fileName = "action.json"

    private struct PublishedFileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct HashedFile {
        let sha256: String
        let byteCount: Int
    }

    private struct RetainedFile {
        let data: Data?
        let hashed: HashedFile
    }

    static func makeArtifacts(
        capture: CaptureSessionResult,
        outputRoot: URL,
        metadataSHA256: String
    ) throws -> [CaptureActionManifest.Artifact] {
        var artifacts = try capture.frames.map { frame in
            try self.artifact(
                role: .frame,
                path: frame.path,
                expectedSHA256: frame.sha256,
                outputRoot: outputRoot
            )
        }
        try artifacts.append(self.artifact(
            role: .contactSheet,
            path: capture.contactSheet.path,
            expectedSHA256: capture.contactSheet.sha256,
            outputRoot: outputRoot
        ))
        try artifacts.append(self.artifact(
            role: .metadata,
            path: capture.metadataFile,
            expectedSHA256: metadataSHA256,
            outputRoot: outputRoot
        ))
        if let videoOut = capture.videoOut {
            guard let videoCustody = capture.videoArtifactCustody,
                  URL(fileURLWithPath: videoOut).standardizedFileURL.path == videoCustody.path
            else {
                throw CaptureActionManifestError(
                    message: "Capture action video lacks matching writer-authored custody: \(videoOut)"
                )
            }
            try artifacts.append(self.artifact(
                role: .video,
                path: videoOut,
                expectedSHA256: videoCustody.sha256,
                expectedCustody: videoCustody,
                outputRoot: outputRoot
            ))
        }
        return artifacts
    }

    static func write(
        _ manifest: CaptureActionManifest,
        outputRoot: URL,
        beforePostPublicationValidation: () throws -> Void = {}
    ) throws -> CaptureActionManifestReceipt {
        try Task.checkCancellation()
        try self.validateArtifacts(manifest.artifacts, outputRoot: outputRoot)
        try Task.checkCancellation()
        let encoder = self.encoder()
        let data = try encoder.encode(manifest)
        let url = outputRoot.appendingPathComponent(self.fileName, isDirectory: false)
        let temporaryURL = outputRoot.appendingPathComponent(
            ".\(self.fileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        var publishedIdentity: PublishedFileIdentity?
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try Task.checkCancellation()
            publishedIdentity = try self.fileIdentity(at: temporaryURL)
            try Task.checkCancellation()
            let publishResult = temporaryURL.withUnsafeFileSystemRepresentation { sourcePath in
                url.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return Int32(-1) }
                    return renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        destinationPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard publishResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if error is CancellationError {
                throw error
            }
            throw CaptureActionManifestError(
                message: "Could not publish capture action manifest at \(url.path): \(error.localizedDescription)"
            )
        }

        do {
            try beforePostPublicationValidation()
            try Task.checkCancellation()
            guard let publishedIdentity else {
                throw CaptureActionManifestError(message: "Capture action manifest publication identity is missing")
            }
            let retainedFile = try self.retainedFile(
                at: url,
                maximumBytes: data.count,
                expectedIdentity: publishedIdentity,
                retainData: true
            )
            guard let retained = retainedFile.data,
                  retained == data,
                  let decoded = try? JSONDecoder().decode(CaptureActionManifest.self, from: retained),
                  try encoder.encode(decoded) == retained
            else {
                throw CaptureActionManifestError(message: "Capture action manifest failed canonical readback")
            }
            try self.validateArtifacts(manifest.artifacts, outputRoot: outputRoot)
            try Task.checkCancellation()
            return CaptureActionManifestReceipt(path: url.path, sha256: self.sha256(retained))
        } catch {
            let removed = self.quarantinePublishedManifest(
                at: url,
                identity: publishedIdentity
            )
            if error is CancellationError, removed {
                throw error
            }
            let cleanup = removed
                ? "published manifest quarantined"
                : "published manifest cleanup could not be verified"
            throw CaptureActionManifestError(message: "\(error.localizedDescription); \(cleanup)")
        }
    }

    static func commandSHA256(_ command: [String]) throws -> String {
        try self.sha256(self.encoder().encode(command))
    }

    static func stream(_ value: String, truncated: Bool) -> CaptureActionManifest.Stream {
        let data = Data(value.utf8)
        return CaptureActionManifest.Stream(
            sha256: self.sha256(data),
            byteCount: data.count,
            truncated: truncated
        )
    }

    static func validateArtifacts(
        _ artifacts: [CaptureActionManifest.Artifact],
        outputRoot: URL
    ) throws {
        for artifact in artifacts {
            try Task.checkCancellation()
            let url = self.url(for: artifact.path, outputRoot: outputRoot)
            let roleLimit = self.maximumBytes(for: artifact.role)
            guard artifact.byteCount > 0, artifact.byteCount <= roleLimit else {
                throw CaptureActionManifestError(
                    message: "Capture action artifact size is outside its role limit: \(artifact.path)"
                )
            }
            let observed = try self.fileDigestAndSize(at: url, maximumBytes: artifact.byteCount)
            guard observed.byteCount == artifact.byteCount,
                  observed.sha256 == artifact.sha256
            else {
                throw CaptureActionManifestError(
                    message: "Capture action artifact changed before manifest publication: \(artifact.path)"
                )
            }
        }
    }

    private static func artifact(
        role: CaptureActionManifest.Artifact.Role,
        path: String,
        expectedSHA256: String?,
        expectedCustody: CaptureVideoArtifactCustody? = nil,
        outputRoot: URL
    ) throws -> CaptureActionManifest.Artifact {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let expectedIdentity: PublishedFileIdentity? = try expectedCustody.map { custody in
            guard let device = dev_t(exactly: custody.device),
                  let inode = ino_t(exactly: custody.inode)
            else {
                throw CaptureActionManifestError(message: "Capture action video custody identity is invalid: \(path)")
            }
            return PublishedFileIdentity(device: device, inode: inode)
        }
        let observed = try self.retainedFile(
            at: url,
            maximumBytes: self.maximumBytes(for: role),
            expectedIdentity: expectedIdentity,
            retainData: false
        ).hashed
        guard observed.byteCount > 0 else {
            throw CaptureActionManifestError(message: "Capture action artifact is empty: \(path)")
        }
        if let expectedCustody, observed.byteCount != expectedCustody.byteCount {
            throw CaptureActionManifestError(message: "Capture action video custody size changed: \(path)")
        }
        if let expectedSHA256, observed.sha256 != expectedSHA256 {
            throw CaptureActionManifestError(message: "Capture action artifact digest changed: \(path)")
        }
        return CaptureActionManifest.Artifact(
            role: role,
            path: self.manifestPath(for: url, outputRoot: outputRoot),
            byteCount: observed.byteCount,
            sha256: observed.sha256
        )
    }

    private static func manifestPath(for url: URL, outputRoot: URL) -> String {
        let root = outputRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    private static func url(for path: String, outputRoot: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return outputRoot.appendingPathComponent(path).standardizedFileURL
    }

    private static func fileIdentity(at url: URL) throws -> PublishedFileIdentity {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return PublishedFileIdentity(device: information.st_dev, inode: information.st_ino)
    }

    private static func quarantinePublishedManifest(
        at url: URL,
        identity: PublishedFileIdentity?
    ) -> Bool {
        guard let identity else { return false }
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).failed",
            isDirectory: false
        )
        let quarantineResult = url.withUnsafeFileSystemRepresentation { sourcePath in
            quarantineURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if quarantineResult != 0 {
            return errno == ENOENT
        }
        guard (try? self.fileIdentity(at: quarantineURL)) == identity else {
            _ = quarantineURL.withUnsafeFileSystemRepresentation { sourcePath in
                url.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return Int32(-1) }
                    return renameatx_np(
                        AT_FDCWD,
                        sourcePath,
                        AT_FDCWD,
                        destinationPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            return false
        }
        return true
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func fileDigestAndSize(at url: URL, maximumBytes: Int) throws -> HashedFile {
        try self.retainedFile(
            at: url,
            maximumBytes: maximumBytes,
            expectedIdentity: nil,
            retainData: false
        ).hashed
    }

    private static func retainedFile(
        at url: URL,
        maximumBytes: Int,
        expectedIdentity: PublishedFileIdentity?,
        retainData: Bool
    ) throws -> RetainedFile {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              before.st_size <= off_t(maximumBytes)
        else {
            throw CaptureActionManifestError(
                message: "Capture action artifact is not a bounded regular file: \(url.path)"
            )
        }
        let openedIdentity = PublishedFileIdentity(device: before.st_dev, inode: before.st_ino)
        guard expectedIdentity == nil || expectedIdentity == openedIdentity else {
            throw CaptureActionManifestError(message: "Capture action artifact identity changed: \(url.path)")
        }
        var hasher = SHA256()
        var byteCount = 0
        var data = Data()
        if retainData {
            data.reserveCapacity(Int(before.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let chunk = Data(buffer.prefix(count))
                hasher.update(data: chunk)
                if retainData {
                    data.append(chunk)
                }
                let (updatedCount, overflow) = byteCount.addingReportingOverflow(count)
                guard !overflow, updatedCount <= maximumBytes else {
                    throw CaptureActionManifestError(message: "Capture action artifact is too large: \(url.path)")
                }
                byteCount = updatedCount
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var after = stat()
        var pathAfter = stat()
        let pathResult = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &pathAfter)
        }
        guard fstat(descriptor, &after) == 0,
              pathResult == 0,
              after.st_mode & S_IFMT == S_IFREG,
              pathAfter.st_mode & S_IFMT == S_IFREG,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == pathAfter.st_dev,
              after.st_ino == pathAfter.st_ino,
              byteCount == Int(after.st_size)
        else {
            throw CaptureActionManifestError(
                message: "Capture action artifact changed while it was being hashed: \(url.path)"
            )
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return RetainedFile(
            data: retainData ? data : nil,
            hashed: HashedFile(sha256: digest, byteCount: byteCount)
        )
    }

    private static func maximumBytes(for role: CaptureActionManifest.Artifact.Role) -> Int {
        switch role {
        case .frame, .contactSheet:
            256 * 1024 * 1024
        case .metadata:
            16 * 1024 * 1024
        case .video:
            4 * 1024 * 1024 * 1024
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CaptureActionManifestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        self.message
    }
}

struct CaptureActionHostProvenanceError: LocalizedError {
    let message: String

    var errorDescription: String? {
        self.message
    }
}
