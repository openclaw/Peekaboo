import Darwin
import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

@Suite("Bridge Agent live executable identity")
struct AgentExecutionExecutableIdentityTests {
    @Test(arguments: ["/bin/sleep", "/bin/sh", "/usr/bin/true", "/usr/bin/false", "/usr/bin/yes"])
    func `Capture validates the running executable slice instead of the default path slice`(
        executablePath: String) throws
    {
        try Self.withSuspendedChild(executablePath: executablePath) { pid in
            let executable = try PeekabooBridgeAgentExecutionExecutable.captureProcessForTesting(pid)
            let liveHash = try #require(PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                processIdentifier: pid,
                expectedProcessStartIdentity: executable.processStartIdentity))
            #expect(executable.path == PeekabooBridgeAgentExecutionExecutable.canonicalPath(executablePath))
            #expect(executable.codeSignatureHash == liveHash)
            #expect(PeekabooBridgeCodeSignatureIdentity.validatedCodeSignatureHash(
                unreapedChildProcessIdentifier: pid,
                expectedProcessStartIdentity: executable.processStartIdentity,
                executablePath: executable.path) == liveHash)
            #expect(try PeekabooBridgeAgentExecutionExecutable.captureChild(pid, expected: executable) == executable)
        }
    }

    @Test
    func `Selected child signature refuses a different executable path or process generation`() throws {
        try Self.withSuspendedChild(executablePath: "/bin/sleep") { pid in
            let executable = try PeekabooBridgeAgentExecutionExecutable.captureProcessForTesting(pid)
            #expect(PeekabooBridgeCodeSignatureIdentity.validatedCodeSignatureHash(
                unreapedChildProcessIdentifier: pid,
                expectedProcessStartIdentity: executable.processStartIdentity,
                executablePath: "/usr/bin/false") == nil)
            #expect(PeekabooBridgeCodeSignatureIdentity.validatedCodeSignatureHash(
                unreapedChildProcessIdentifier: pid,
                expectedProcessStartIdentity: executable.processStartIdentity &+ 1,
                executablePath: executable.path) == nil)
        }
    }

    @Test(arguments: ["path", "sha256", "codeSignatureHash"])
    func `Exact child capture refuses mismatched expected executable identity`(changedField: String) throws {
        try Self.withSuspendedChild(executablePath: "/bin/sleep") { pid in
            let executable = try PeekabooBridgeAgentExecutionExecutable.captureProcessForTesting(pid)
            let substituted = PeekabooBridgeAgentExecutionExecutable(
                processIdentifier: executable.processIdentifier,
                processStartIdentity: executable.processStartIdentity,
                path: changedField == "path" ? "/usr/bin/false" : executable.path,
                sha256: changedField == "sha256" ? String(repeating: "0", count: 64) : executable.sha256,
                codeSignatureHash: changedField == "codeSignatureHash"
                    ? String(repeating: "0", count: 40) : executable.codeSignatureHash)
            #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
                _ = try PeekabooBridgeAgentExecutionExecutable.captureChild(pid, expected: substituted)
            }
        }
    }

    @Test
    func `Peer selected signature remains bound to its audit token path and generation`() throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { sockets.forEach { close($0) } }
        let auditIdentity = try PeekabooBridgeSocketIO.peerAuditIdentity(fd: sockets[0])
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let path = try #require(PeekabooBridgeAgentExecutionExecutable.canonicalProcessPath(getpid()))
        let liveHash = try #require(PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(auditIdentity: auditIdentity))
        #expect(PeekabooBridgeCodeSignatureIdentity.validatedCodeSignatureHash(
            auditIdentity: auditIdentity,
            expectedProcessStartIdentity: generation,
            executablePath: path) == liveHash)
        #expect(PeekabooBridgeCodeSignatureIdentity.validatedCodeSignatureHash(
            auditIdentity: auditIdentity,
            expectedProcessStartIdentity: generation &+ 1,
            executablePath: path) == nil)
        #expect(PeekabooBridgeCodeSignatureIdentity.validatedCodeSignatureHash(
            auditIdentity: auditIdentity,
            expectedProcessStartIdentity: generation,
            executablePath: "/bin/sleep") == nil)

        let mismatchedAuditIdentity = PeekabooBridgePeerAuditIdentity(
            token: auditIdentity.token,
            processIdentifier: auditIdentity.processIdentifier,
            processIdentifierVersion: auditIdentity.processIdentifierVersion &+ 1,
            effectiveUserIdentifier: auditIdentity.effectiveUserIdentifier)
        #expect(PeekabooBridgeCodeSignatureIdentity.validatedCodeSignatureHash(
            auditIdentity: mismatchedAuditIdentity,
            expectedProcessStartIdentity: generation,
            executablePath: path) == nil)
    }

    private static func withSuspendedChild(
        executablePath: String,
        body: (pid_t) throws -> Void) throws
    {
        let pipes = try PeekabooBridgeAgentExecutionPipes()
        defer { pipes.closeAll() }
        let gate = try PeekabooBridgeAgentExecutionReleaseGate(excludingDescriptors: [
            pipes.stdoutRead, pipes.stdoutWrite, pipes.stderrRead, pipes.stderrWrite,
        ])
        defer { gate.closeAll() }
        let pid = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
            executablePath: executablePath,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            pipes: pipes,
            releaseGate: gate)
        defer { PeekabooBridgeAgentExecutionProcessWait.killSuspendedAndReap(pid) }
        try body(pid)
    }
}
