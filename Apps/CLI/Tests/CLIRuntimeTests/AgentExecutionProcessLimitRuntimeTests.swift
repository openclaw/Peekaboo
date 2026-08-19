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
        #expect(getpgid(processIdentifier) == processIdentifier)
        #expect(getsid(processIdentifier) == processIdentifier)
        close(authorization.read)
        close(readiness.write)
        close(output.write)
        defer {
            close(authorization.write)
            close(readiness.read)
            close(output.read)
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }

        let readinessBytes = try Self.readAll(readiness.read)
        #expect(readinessBytes == Data(challenge.utf8))
        try Self.expectParentProcessCreationStillWorks()
        try Self.writeAll(Data(challenge.utf8), to: authorization.write)
        close(authorization.write)

        let outputBytes = try Self.readAll(output.read)
        var waitStatus: Int32 = 0
        while Darwin.waitpid(processIdentifier, &waitStatus, 0) < 0, errno == EINTR {}
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
    func `Real gated Agent completes a provider tool provider loop through nested Bridge`() async throws {
        let bridge = try ScriptedBridgePeer(responses: [
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
            )),
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
            )),
            .ok,
            .application(ServiceApplicationInfo(
                processIdentifier: 4242,
                processStartIdentity: 9001,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "BridgeFixture",
                activationPolicy: .regular
            )),
            .applications([
                ServiceApplicationInfo(
                    processIdentifier: 4242,
                    processStartIdentity: 9001,
                    bundleIdentifier: "dev.peekaboo.fixture",
                    name: "BridgeFixture",
                    activationPolicy: .regular
                ),
            ]),
            .window(nil),
            .applications([
                ServiceApplicationInfo(
                    processIdentifier: 4242,
                    processStartIdentity: 9001,
                    bundleIdentifier: "dev.peekaboo.fixture",
                    name: "BridgeFixture",
                    activationPolicy: .regular
                ),
            ]),
        ])
        let result = try Self.runGatedAgent(bridgeSocketPath: bridge.socketPath)
        let requests = await bridge.requests
        let acceptedConnections = await bridge.acceptedConnectionCount
        let requestBodies = requests.compactMap { String(data: $0, encoding: .utf8) }
        await bridge.stop()

        #expect(
            result.waitStatus == 0,
            "Agent stdout: \(String(data: result.output, encoding: .utf8) ?? "<non-UTF8>"); stderr: \(String(data: result.standardError, encoding: .utf8) ?? "<non-UTF8>"); accepted: \(acceptedConnections); requests: \(requestBodies)"
        )
        let response = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        let payload = try #require(response["result"] as? [String: Any])
        let trace = try #require(payload["executionTrace"] as? [String: Any])
        let entries = try #require(trace["entries"] as? [[String: Any]])
        #expect(response["success"] as? Bool == true)
        #expect(
            payload["content"] as? String == "agent-provider-tool-ok",
            "Bridge requests: \(requestBodies)"
        )
        #expect(entries.map { $0["name"] as? String } == ["app"])
        #expect(
            entries.map { $0["disposition"] as? String } == ["executed/succeeded"],
            "Agent stdout: \(String(data: result.output, encoding: .utf8) ?? "<non-UTF8>")"
        )
        #expect(trace["totalCallCount"] as? Int == 1)

        try #require(requests.count == 7)
        let decodedRequests = try requests.map {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: $0)
        }
        let operations = decodedRequests.compactMap { request -> PeekabooBridgeOperation? in
            if case .handshake = request {
                return nil
            }
            return request.operation
        }
        #expect(operations.contains(.listApplications), "Bridge requests: \(requestBodies)")
    }

    private static func runGatedAgent(bridgeSocketPath: String) throws
    -> (output: Data, standardError: Data, waitStatus: Int32) {
        let binary = try TestChildProcess.peekabooBinaryURL().path
        let challenge = String(repeating: "b", count: 64)
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
            binary, "agent", "run", "List apps through nested Bridge", "--no-cache", "--max-steps", "2",
            "--model", "claude-opus-5", "--bridge-socket", bridgeSocketPath, "--json",
        ])
        defer { self.free(arguments) }
        var environment = self.cStrings([
            "PATH=/usr/bin:/bin",
            "ANTHROPIC_API_KEY=probe-key",
            "PEEKABOO_AGENT_EXECUTION_TEST_PROVIDER=permissions-v1",
            "\(AgentExecutionReleaseGate.descriptorEnvironmentKey)=\(childAuthorization)",
            "\(AgentExecutionReleaseGate.challengeEnvironmentKey)=\(challenge)",
            "\(AgentExecutionReleaseGate.lockdownDescriptorEnvironmentKey)=\(childReadiness)",
            "\(AgentExecutionReleaseGate.processCreationLimitEnvironmentKey)=0",
        ])
        defer { self.free(environment) }

        var processIdentifier: pid_t = 0
        let spawnResult = binary.withCString {
            posix_spawn(&processIdentifier, $0, &actions, &attributes, &arguments, &environment)
        }
        guard spawnResult == 0, processIdentifier > 0 else { throw POSIXError(.EIO) }
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
        while Darwin.waitpid(processIdentifier, &waitStatus, 0) < 0, errno == EINTR {}
        close(readiness.read)
        close(output.read)
        close(errors.read)
        return (outputBytes, errorBytes, waitStatus)
    }

    private static func pipePair() throws -> (read: Int32, write: Int32) {
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

    private static func readAll(_ descriptor: Int32) throws -> Data {
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

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
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

    private static func cStrings(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        values.map { strdup($0) } + [nil]
    }

    private static func free(_ values: [UnsafeMutablePointer<CChar>?]) {
        values.forEach { Darwin.free($0) }
    }
}
#endif
