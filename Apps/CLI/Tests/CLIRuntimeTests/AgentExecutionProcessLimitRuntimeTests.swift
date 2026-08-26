#if DEBUG
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
struct AgentExecutionProcessLimitRuntimeTests {
    @Test
    func `Gated CLI irreversibly denies child processes without affecting its parent`() throws {
        let binary = try TestChildProcess.peekabooBinaryURL().path
        let challenge = String(repeating: "a", count: 64)
        let authorization = try Self.pipePair()
        let readiness = try Self.pipePair()
        let output = try Self.pipePair()
        let childAuthorization: Int32 = 198
        let childReadiness: Int32 = 199

        var actions: posix_spawn_file_actions_t?
        #expect(posix_spawn_file_actions_init(&actions) == 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        #expect(posix_spawn_file_actions_adddup2(&actions, authorization.read, childAuthorization) == 0)
        #expect(posix_spawn_file_actions_adddup2(&actions, readiness.write, childReadiness) == 0)
        #expect(posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO) == 0)
        for descriptor in [
            authorization.read,
            authorization.write,
            readiness.read,
            readiness.write,
            output.read,
            output.write
        ]
            where descriptor != childAuthorization && descriptor != childReadiness && descriptor != STDOUT_FILENO {
            #expect(posix_spawn_file_actions_addclose(&actions, descriptor) == 0)
        }

        var attributes: posix_spawnattr_t?
        #expect(posix_spawnattr_init(&attributes) == 0)
        defer { posix_spawnattr_destroy(&attributes) }
        #expect(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)) == 0)

        var arguments = Self.cStrings([binary, "_agent-execution-process-limit-probe"])
        defer { Self.free(arguments) }
        var environment = Self.cStrings([
            "PATH=/usr/bin:/bin",
            "\(AgentExecutionReleaseGate.descriptorEnvironmentKey)=\(childAuthorization)",
            "\(AgentExecutionReleaseGate.challengeEnvironmentKey)=\(challenge)",
            "\(AgentExecutionReleaseGate.lockdownDescriptorEnvironmentKey)=\(childReadiness)",
            "\(AgentExecutionReleaseGate.processCreationLimitEnvironmentKey)=0",
        ])
        defer { Self.free(environment) }

        var processIdentifier: pid_t = 0
        let spawnResult = binary.withCString {
            posix_spawn(&processIdentifier, $0, &actions, &attributes, &arguments, &environment)
        }
        #expect(spawnResult == 0)
        try #require(processIdentifier > 0)
        let childProcessIdentifier = processIdentifier
        var childWasReaped = false
        #expect(getpgid(processIdentifier) == processIdentifier)
        #expect(getsid(processIdentifier) == processIdentifier)
        close(authorization.read)
        close(readiness.write)
        close(output.write)
        defer {
            close(authorization.write)
            close(readiness.read)
            close(output.read)
            if !childWasReaped {
                Self.terminateAndReap(childProcessIdentifier)
            }
        }

        let readinessBytes = try Self.readAll(readiness.read)
        #expect(readinessBytes == Data(challenge.utf8))
        try Self.expectParentProcessCreationStillWorks()
        try Self.writeAll(Data(challenge.utf8), to: authorization.write)
        close(authorization.write)

        let outputBytes = try Self.readAll(output.read)
        var waitStatus: Int32 = 0
        let waitResult = Self.waitForChild(childProcessIdentifier, status: &waitStatus)
        childWasReaped = waitResult == childProcessIdentifier
        #expect(childWasReaped)
        #expect((waitStatus & 0x7F) == 0)
        #expect(((waitStatus >> 8) & 0xFF) == 0)
        let object = try #require(JSONSerialization.jsonObject(with: outputBytes) as? [String: Bool])
        #expect(object == [
            "forkDenied": true,
            "hardLimitCannotRaise": true,
            "limitReadback": true,
            "posixSpawnDenied": true,
            "vforkDenied": true,
        ])
    }

    @Test
    func `Real gated Agent refuses receiptless custom Bridge before provider execution`() async throws {
        let bridge = try ConcurrentGatedBridgePeer()
        let binaryPath = try TestChildProcess.peekabooBinaryURL().path
        let challenge = String(repeating: "b", count: 64)
        let releaseGateEnvironment = [
            "\(AgentExecutionReleaseGate.descriptorEnvironmentKey)=198",
            "\(AgentExecutionReleaseGate.challengeEnvironmentKey)=\(challenge)",
            "\(AgentExecutionReleaseGate.lockdownDescriptorEnvironmentKey)=199",
            "\(AgentExecutionReleaseGate.processCreationLimitEnvironmentKey)=0",
        ]
        let responder = Task {
            while !Task.isCancelled {
                let request = try await bridge.nextRequest()
                try await bridge.respond(Self.response(for: request.decode()), to: request)
            }
        }
        let agent = Task.detached {
            try Self.runGatedAgent(
                binaryPath: binaryPath,
                bridgeSocketPath: bridge.socketPath,
                challenge: challenge,
                releaseGateEnvironment: releaseGateEnvironment
            )
        }
        let result: (output: Data, standardError: Data, waitStatus: Int32)
        do {
            result = try await agent.value
        } catch {
            responder.cancel()
            await bridge.stop()
            _ = try? await responder.value
            throw error
        }
        let requests = await bridge.requests
        let acceptedConnections = await bridge.acceptedConnectionCount
        let requestBodies = requests.compactMap { String(data: $0, encoding: .utf8) }
        // Agent completion closes every request socket. Stop any still-waiting responder instead of
        // trusting a request count before the count assertion below has had a chance to diagnose it.
        await bridge.stop()
        responder.cancel()
        _ = try? await responder.value

        #expect(result.waitStatus != 0)
        let response = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        let error = try #require(response["error"] as? [String: Any])
        #expect(response["success"] as? Bool == false)
        #expect(error["code"] as? String == "BRIDGE_UNAVAILABLE")
        #expect((error["message"] as? String)?.contains(bridge.socketPath) == true)
        #expect(result.standardError.isEmpty)

        let decodedRequests = try requests.map {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: $0)
        }
        let handshakeCount = decodedRequests.count { request in
            if case .handshake = request {
                true
            } else {
                false
            }
        }
        let operations = decodedRequests.compactMap { request -> PeekabooBridgeOperation? in
            if case .handshake = request {
                return nil
            }
            return request.operation
        }
        let invalidationCount = operations.count(where: { $0 == .invalidateImplicitLatestSnapshot })
        #expect(handshakeCount == 1, "Bridge requests: \(requestBodies)")
        #expect(invalidationCount == 0)
        #expect(operations.isEmpty)
        #expect(acceptedConnections == 1)
        #expect(requests.count == 1)
    }

    private static func response(for request: PeekabooBridgeRequest) -> PeekabooBridgeResponse {
        switch request {
        case .handshake:
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: .init(major: 1, minor: 28),
                supportedOperations: Array(PeekabooBridgeOperation.allCases),
                permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
                hostCapabilities: [
                    PeekabooBridgeHostCapability.hostGenerationIdentity,
                    PeekabooBridgeHostCapability.codeSignatureBuildIdentity,
                    PeekabooBridgeHostCapability.backgroundBridgeHost,
                    PeekabooBridgeHostCapability.safeBackgroundApplicationLaunchNoOp,
                    PeekabooBridgeHostCapability.processGenerationPinnedApplicationActivation,
                ]
            ))
        case .invalidateImplicitLatestSnapshot:
            .ok
        case .getFrontmostApplication:
            .application(self.fixtureApplication)
        case .listApplications:
            .applications([self.fixtureApplication])
        case .getFocusedWindow:
            .window(nil)
        default:
            .error(.init(
                code: .invalidRequest,
                message: "Unexpected gated Agent fixture request \(request.operation.rawValue)"
            ))
        }
    }

    private static var fixtureApplication: ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "BridgeFixture",
            activationPolicy: .regular
        )
    }

    private nonisolated static func runGatedAgent(
        binaryPath: String,
        bridgeSocketPath: String,
        challenge: String,
        releaseGateEnvironment: [String]
    ) throws
    -> (output: Data, standardError: Data, waitStatus: Int32) {
        let authorization = try self.pipePair()
        let readiness = try self.pipePair()
        let output = try self.pipePair()
        let errors = try self.pipePair()
        let childAuthorization: Int32 = 198
        let childReadiness: Int32 = 199

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, authorization.read, childAuthorization) == 0,
              posix_spawn_file_actions_adddup2(&actions, readiness.write, childReadiness) == 0,
              posix_spawn_file_actions_adddup2(&actions, output.write, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors.write, STDERR_FILENO) == 0
        else { throw POSIXError(.EIO) }
        for descriptor in [
            authorization.read,
            authorization.write,
            readiness.read,
            readiness.write,
            output.read,
            output.write,
            errors.read,
            errors.write
        ]
            where descriptor != childAuthorization && descriptor != childReadiness &&
            descriptor != STDOUT_FILENO && descriptor != STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else { throw POSIXError(.EIO) }
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.EIO) }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)
        ) == 0
        else { throw POSIXError(.EIO) }

        var arguments = self.cStrings([
            binaryPath, "agent", "run", "List apps through nested Bridge", "--no-cache", "--max-steps", "2",
            "--model", "claude-opus-5", "--bridge-socket", bridgeSocketPath, "--json",
        ])
        defer { self.free(arguments) }
        var environment = self.cStrings([
            "PATH=/usr/bin:/bin",
            "ANTHROPIC_API_KEY=probe-key",
            "PEEKABOO_AGENT_EXECUTION_TEST_PROVIDER=permissions-v1",
        ] + releaseGateEnvironment)
        defer { self.free(environment) }

        var processIdentifier: pid_t = 0
        let spawnResult = binaryPath.withCString {
            posix_spawn(&processIdentifier, $0, &actions, &attributes, &arguments, &environment)
        }
        guard spawnResult == 0, processIdentifier > 0 else { throw POSIXError(.EIO) }
        let childProcessIdentifier = processIdentifier
        var childWasReaped = false
        defer {
            if !childWasReaped {
                self.terminateAndReap(childProcessIdentifier)
            }
        }
        close(authorization.read)
        close(readiness.write)
        close(output.write)
        close(errors.write)
        let readinessBytes = try self.readAll(readiness.read)
        guard readinessBytes == Data(challenge.utf8) else { throw POSIXError(.EPROTO) }
        try self.writeAll(Data(challenge.utf8), to: authorization.write)
        close(authorization.write)
        let outputBytes = try self.readAll(output.read)
        let errorBytes = try self.readAll(errors.read)
        var waitStatus: Int32 = 0
        let waitResult = self.waitForChild(childProcessIdentifier, status: &waitStatus)
        guard waitResult == childProcessIdentifier else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
        }
        childWasReaped = true
        close(readiness.read)
        close(output.read)
        close(errors.read)
        return (outputBytes, errorBytes, waitStatus)
    }

    private nonisolated static func pipePair() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        return (descriptors[0], descriptors[1])
    }

    private static func expectParentProcessCreationStillWorks() throws {
        typealias ForkFunction = @convention(c) () -> pid_t
        let handle = try #require(dlopen(nil, RTLD_NOW))
        defer { dlclose(handle) }
        let symbol = try #require(dlsym(handle, "fork"))
        let forkFunction = unsafeBitCast(symbol, to: ForkFunction.self)
        let forked = forkFunction()
        if forked == 0 {
            Darwin._exit(0)
        }
        try #require(forked > 0)
        var forkStatus: Int32 = 0
        #expect(Darwin.waitpid(forked, &forkStatus, 0) == forked)
        #expect(forkStatus == 0)

        var spawned: pid_t = 0
        var arguments = Self.cStrings(["/usr/bin/true"])
        defer { Self.free(arguments) }
        #expect(posix_spawn(&spawned, "/usr/bin/true", nil, nil, &arguments, environ) == 0)
        var spawnStatus: Int32 = 0
        #expect(Darwin.waitpid(spawned, &spawnStatus, 0) == spawned)
        #expect(spawnStatus == 0)
    }

    private nonisolated static func readAll(_ descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private nonisolated static func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress?.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private nonisolated static func waitForChild(
        _ processIdentifier: pid_t,
        status: inout Int32
    ) -> pid_t {
        var result: pid_t
        repeat {
            result = Darwin.waitpid(processIdentifier, &status, 0)
        } while result < 0 && errno == EINTR
        return result
    }

    private nonisolated static func terminateAndReap(_ processIdentifier: pid_t) {
        _ = Darwin.kill(processIdentifier, SIGKILL)
        var waitStatus: Int32 = 0
        _ = self.waitForChild(processIdentifier, status: &waitStatus)
    }

    private nonisolated static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        values.map { strdup($0) } + [nil]
    }

    private nonisolated static func free(_ values: [UnsafeMutablePointer<CChar>?]) {
        values.forEach { Darwin.free($0) }
    }
}
#endif
