import Commander
import Darwin
import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct ScreenCaptureKitOwnerRuntimeTests {
    @Test
    func `busy caller-local modern refuses before service construction`() async {
        let owner = Self.ownerReceipt()
        var options = Self.captureOptions(engine: "modern")
        options.preferRemote = false
        options.remoteIsolationRequested = true
        var claimCalls = 0
        var inspectCalls = 0
        var localFactoryCalls = 0
        let started = ContinuousClock.now

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: .init(
                    makeLocalServices: { _ in
                        localFactoryCalls += 1
                        return PeekabooServices()
                    },
                    claimScreenCaptureKitOwner: {
                        claimCalls += 1
                        throw ScreenCaptureKitOwnerLease.LeaseError.ownedByAnotherProcess(
                            path: "/tmp/fixture-owner.lock",
                            receipt: owner
                        )
                    },
                    inspectScreenCaptureKitOwner: {
                        inspectCalls += 1
                        return owner
                    }
                )
            )
        }

        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(error?.code == .CAPTURE_FAILED)
        #expect(error?.envelopeEffect == .refused)
        #expect(error?.envelopeRetrySafe == true)
        #expect(error?.envelopeMutationDispatched == false)
        #expect(error?.localizedDescription.contains("PID 4242, generation 9001") == true)
        #expect(claimCalls == 0)
        #expect(inspectCalls == 1)
        #expect(localFactoryCalls == 0)
    }

    @Test
    func `free caller-local modern claims once and constructs one service graph`() async throws {
        let owner = Self.ownerReceipt()
        var options = Self.captureOptions(engine: "modern")
        options.preferRemote = false
        options.remoteIsolationRequested = true
        var claimCalls = 0
        var inspectCalls = 0
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: {
                    claimCalls += 1
                    return owner
                },
                inspectScreenCaptureKitOwner: {
                    inspectCalls += 1
                    return nil
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(claimCalls == 1)
        #expect(inspectCalls == 1)
        #expect(localFactoryCalls == 1)
    }

    @Test
    func `caller-local AX-only see skips ScreenCaptureKit ownership and old-host discovery`() async throws {
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: [:],
                flags: ["tree", "noScreenshot"]
            ),
            commandType: SeeCommand.self
        )
        options.preferRemote = false
        options.remoteIsolationRequested = true
        var claimCalls = 0
        var inspectOwnerCalls = 0
        var inspectSafetyCalls = 0
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: {
                    claimCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitOwner: {
                    inspectOwnerCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    inspectSafetyCalls += 1
                    return RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
                        socketPath: "/tmp/old-host.sock",
                        processIdentifier: 3131,
                        processStartIdentity: 4141
                    )
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(!options.requiresDesktopObservation)
        #expect(!options.requiresScreenCapturePermission)
        #expect(!options.requiresSilentCapture)
        #expect(claimCalls == 0)
        #expect(inspectOwnerCalls == 0)
        #expect(inspectSafetyCalls == 0)
        #expect(localFactoryCalls == 1)
    }

    @Test
    func `caller-local explicit snapshot scroll skips capture ownership and old-host discovery`() async throws {
        let snapshots = InMemorySnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        let localServices = PeekabooServices(snapshotManager: snapshots)
        var options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["elem_3"], "snapshot": [snapshotID]],
                flags: ["no-remote"]
            ),
            commandType: ScrollCommand.self
        )
        options.preferRemote = false
        options.remoteIsolationRequested = true
        var claimCalls = 0
        var inspectOwnerCalls = 0
        var inspectSafetyCalls = 0
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return localServices
                },
                claimScreenCaptureKitOwner: {
                    claimCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitOwner: {
                    inspectOwnerCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    inspectSafetyCalls += 1
                    return RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
                        socketPath: "/tmp/old-host.sock",
                        processIdentifier: 3131,
                        processStartIdentity: 4141
                    )
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(!options.requiresSilentCapture)
        #expect(claimCalls == 0)
        #expect(inspectOwnerCalls == 0)
        #expect(inspectSafetyCalls == 0)
        #expect(localFactoryCalls == 1)
    }

    @Test(arguments: ["modern", "auto"])
    func `implicit remote SCK-capable engine with an unmatched owner refuses without factory or auto-start`(
        engine: String
    ) async {
        let owner = Self.ownerReceipt()
        let missingSocket = "/tmp/peekaboo-unmatched-owner-\(UUID().uuidString).sock"
        let options = Self.captureOptions(engine: engine)
        var claimCalls = 0
        var inspectCalls = 0
        var localFactoryCalls = 0

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: ["PEEKABOO_DAEMON_SOCKET": missingSocket],
                configurationInput: nil,
                dependencies: .init(
                    makeLocalServices: { _ in
                        localFactoryCalls += 1
                        return PeekabooServices()
                    },
                    claimScreenCaptureKitOwner: {
                        claimCalls += 1
                        return owner
                    },
                    inspectScreenCaptureKitOwner: {
                        inspectCalls += 1
                        return owner
                    }
                )
            )
        }

        #expect(error?.code == .CAPTURE_FAILED)
        #expect(error?.localizedDescription.contains("no compatible Bridge host") == true)
        #expect(error?.hint?.contains("Bridge socket served by exactly PID 4242, generation 9001") == true)
        #expect(claimCalls == 0)
        #expect(inspectCalls == 1)
        #expect(localFactoryCalls == 0)
        #expect(!FileManager.default.fileExists(atPath: missingSocket))
    }

    @Test(arguments: ["auto", "classic"])
    func `explicit transported capture refuses an owner-unaware host before capture or local fallback`(
        engine: String
    ) async throws {
        let explicitSocket = "/tmp/peekaboo-owner-unaware-\(UUID().uuidString).sock"
        let oldHost = try await Self.startHost(
            socketPath: explicitSocket,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            codeSignatureHash: "old-build",
            ownerAware: false
        )
        defer { Task { await oldHost.stop() } }
        var options = Self.captureOptions(engine: engine)
        options.bridgeSocketPath = explicitSocket
        options.autoStartDaemon = false
        var inspectCalls = 0
        var recordedBlockers: [RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost] = []
        var localFactoryCalls = 0

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: .init(
                    makeLocalServices: { _ in
                        localFactoryCalls += 1
                        return PeekabooServices()
                    },
                    claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                    inspectScreenCaptureKitOwner: {
                        inspectCalls += 1
                        return nil
                    },
                    inspectScreenCaptureKitSafety: { _, _, _, _ in
                        RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
                            socketPath: explicitSocket,
                            processIdentifier: 3131,
                            processStartIdentity: 4141,
                            buildIdentity: "4.0.0 (4000099)"
                        )
                    },
                    recordScreenCaptureKitSafetyBlocker: { blocker in
                        recordedBlockers.append(blocker)
                    }
                )
            )
        }

        #expect(error?.code == .CAPTURE_FAILED)
        #expect(error?.envelopeEffect == .refused)
        #expect(error?.envelopeRetrySafe == true)
        #expect(error?.envelopeMutationDispatched == false)
        #expect(error?.localizedDescription.contains("PID 3131, generation 4141") == true)
        #expect(error?.localizedDescription.contains("build 4.0.0 (4000099)") == true)
        #expect(error?.localizedDescription.contains(explicitSocket) == true)
        #expect(error?.localizedDescription.contains("Selected socket: \(explicitSocket)") == true)
        #expect(error?.hint?.contains("revalidate and stop exactly PID 3131, generation 4141") == true)
        #expect(error?.hint?.contains("never use the socket path alone") == true)
        #expect(inspectCalls == 0)
        #expect(recordedBlockers == [RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
            socketPath: explicitSocket,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            buildIdentity: "4.0.0 (4000099)"
        )])
        #expect(localFactoryCalls == 0)
        await oldHost.stop()
    }

    @Test
    func `automatic capture routes to an owner-aware host around an auxiliary legacy SCK blocker`() async throws {
        let selectedSocket = "/tmp/peekaboo-auto-classic-first-\(UUID().uuidString).sock"
        let ownerAwareHost = try await Self.startHost(
            socketPath: selectedSocket,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            codeSignatureHash: "current-build"
        )
        defer { Task { await ownerAwareHost.stop() } }

        var options = Self.captureOptions(engine: "auto")
        options.bridgeSocketPath = selectedSocket
        options.autoStartDaemon = false
        let auxiliaryBlocker = RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
            socketPath: PeekabooBridgeConstants.claudeSocketPath,
            processIdentifier: 5151,
            processStartIdentity: 6161,
            buildIdentity: "legacy-build"
        )
        var recordedBlockers: [RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost] = []
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                inspectScreenCaptureKitOwner: { nil },
                inspectScreenCaptureKitSafety: { _, _, _, _ in auxiliaryBlocker },
                recordScreenCaptureKitSafetyBlocker: { recordedBlockers.append($0) }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == selectedSocket)
        #expect(resolution.captureEngineSafetyOverride == .legacy)
        #expect(recordedBlockers == [auxiliaryBlocker])
        #expect(localFactoryCalls == 0)
        await ownerAwareHost.stop()
    }

    @Test
    func `explicit modern capture still refuses an auxiliary legacy SCK blocker`() async throws {
        let selectedSocket = "/tmp/peekaboo-modern-auxiliary-blocker-\(UUID().uuidString).sock"
        let ownerAwareHost = try await Self.startHost(
            socketPath: selectedSocket,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            codeSignatureHash: "current-build"
        )
        defer { Task { await ownerAwareHost.stop() } }

        var options = Self.captureOptions(engine: "modern")
        options.bridgeSocketPath = selectedSocket
        options.autoStartDaemon = false
        let auxiliaryBlocker = RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
            socketPath: PeekabooBridgeConstants.claudeSocketPath,
            processIdentifier: 5151,
            processStartIdentity: 6161,
            buildIdentity: "legacy-build"
        )
        var recordedBlockers: [RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost] = []
        var localFactoryCalls = 0

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: .init(
                    makeLocalServices: { _ in
                        localFactoryCalls += 1
                        return PeekabooServices()
                    },
                    claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                    inspectScreenCaptureKitOwner: { nil },
                    inspectScreenCaptureKitSafety: { _, _, _, _ in auxiliaryBlocker },
                    recordScreenCaptureKitSafetyBlocker: { recordedBlockers.append($0) }
                )
            )
        }

        #expect(error?.code == .CAPTURE_FAILED)
        #expect(error?.localizedDescription.contains("legacy-build") == true)
        #expect(recordedBlockers == [auxiliaryBlocker])
        #expect(localFactoryCalls == 0)
        await ownerAwareHost.stop()
    }

    @Test
    func `known legacy owner diagnostics distinguish selected and owner sockets`() {
        let ownerSocket = "/tmp/legacy-owner.sock"
        let selectedSocket = "/tmp/selected-current.sock"
        let error = RuntimeHostResolver.ownerCapabilityRefusal(
            host: .init(
                socketPath: ownerSocket,
                processIdentifier: 3131,
                processStartIdentity: 4141,
                buildIdentity: "4.0.0 (4000099)"
            ),
            selectedSocket: selectedSocket
        )

        #expect(error.code == .CAPTURE_FAILED)
        #expect(error.envelopeMutationDispatched == false)
        #expect(error.localizedDescription.contains("PID 3131, generation 4141") == true)
        #expect(error.localizedDescription.contains("build 4.0.0 (4000099)") == true)
        #expect(error.localizedDescription.contains("owner socket \(ownerSocket)") == true)
        #expect(error.localizedDescription.contains("Selected socket: \(selectedSocket)") == true)
        #expect(error.hint?.contains("stop exactly PID 3131, generation 4141") == true)
        #expect(error.hint?.contains("never use the socket path alone") == true)
        #expect(error.hint?.contains("peekaboo see --capture-engine classic") == true)
        #expect(error.hint?.contains("retry with its --snapshot") == true)
        #expect(error.hint?.contains("explicitly choose --capture-engine classic") == false)
    }

    @Test
    func `unknown legacy owner diagnostics refuse unsafe stop guidance and redact hostile build`() {
        let ownerSocket = "/tmp/legacy-unknown.sock"
        let selectedSocket = "/tmp/selected-current.sock"
        let hostileBuild = "4.0.0\n/private/user/$TOKEN"
        let error = RuntimeHostResolver.ownerCapabilityRefusal(
            host: .init(
                socketPath: ownerSocket,
                processIdentifier: nil,
                processStartIdentity: nil,
                buildIdentity: hostileBuild
            ),
            selectedSocket: selectedSocket
        )

        #expect(error.localizedDescription.contains("exact PID and process-start identity are unavailable") == true)
        #expect(error.localizedDescription.contains("owner socket \(ownerSocket)") == true)
        #expect(error.localizedDescription.contains("Selected socket: \(selectedSocket)") == true)
        #expect(!error.localizedDescription.contains(hostileBuild))
        #expect(!error.localizedDescription.contains("/private/user"))
        #expect(error.hint?.contains("Do not stop any process") == true)
        #expect(error.hint?.contains("stop exactly") == false)
    }

    @Test
    func `PID-only legacy owner remains ambiguous and non-actionable`() {
        let error = RuntimeHostResolver.ownerCapabilityRefusal(
            host: .init(
                socketPath: "/tmp/legacy-partial.sock",
                processIdentifier: 3131,
                processStartIdentity: nil,
                buildIdentity: "4.0.0"
            ),
            selectedSocket: nil
        )

        #expect(error.localizedDescription.contains("PID 3131, build 4.0.0") == true)
        #expect(error.localizedDescription.contains("exact process-start identity is unavailable") == true)
        #expect(error.localizedDescription.contains("Selected socket: automatic resolution") == true)
        #expect(error.hint?.contains("Do not stop any process") == true)
    }

    @Test
    func `deferred legacy owner record retains build and safe socket diagnostics`() {
        let host = ScreenCaptureKitOwnerLease.UncoordinatedHost(
            socketPath: "/tmp/deferred-owner.sock",
            processIdentifier: 3131,
            processStartIdentity: 4141,
            buildIdentity: "4.0.0 (4000099)"
        )
        let error = RuntimeHostResolver.ownerRefusal(
            error: ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedHosts([host]),
            callerLocal: true,
            selectedSocket: "/tmp/selected-current.sock"
        )

        #expect(error.localizedDescription.contains("PID 3131, generation 4141") == true)
        #expect(error.localizedDescription.contains("build 4.0.0 (4000099)") == true)
        #expect(error.localizedDescription.contains("owner socket /tmp/deferred-owner.sock") == true)
        #expect(error.localizedDescription.contains("Selected socket: /tmp/selected-current.sock") == true)
    }

    @Test
    func `classic false-permission host remains executable after request-aware selection`() async throws {
        let socketPath = "/tmp/peekaboo-classic-deferral-\(UUID().uuidString).sock"
        let host = try await Self.startHost(
            socketPath: socketPath,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            codeSignatureHash: "classic-build",
            screenRecording: false,
            serviceOverride: OwnerPolicyFixtureServices(
                ownerAware: true,
                observation: ClassicDispatchSentinelObservationService()
            )
        )
        defer { Task { await host.stop() } }
        var permissionRejections: [String] = []

        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: socketPath,
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let resolved = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [candidate],
            identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: "boo.peekaboo.test.client",
                teamIdentifier: nil,
                processIdentifier: getpid()
            ),
            options: Self.captureOptions(engine: "classic"),
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections
        )
        let resolution = try #require(resolved)

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await resolution.services.desktopObservation.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                capture: DesktopCaptureOptions(engine: .legacy),
                detection: DesktopDetectionOptions(mode: .none)
            ))
        }

        #expect(error?.standardizedErrorCode == .captureFailed)
        #expect(error?.message.contains("classic request reached the remote observation service") == true)
        #expect(permissionRejections.isEmpty)
        await host.stop()
    }

    @Test
    func `dynamic remote projection evaluates each request engine from raw host capabilities`() async throws {
        let socketPath = "/tmp/peekaboo-dynamic-classic-deferral-\(UUID().uuidString).sock"
        let host = try await Self.startHost(
            socketPath: socketPath,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            codeSignatureHash: "dynamic-build",
            screenRecording: false,
            serviceOverride: OwnerPolicyFixtureServices(
                ownerAware: true,
                observation: ClassicDispatchSentinelObservationService()
            )
        )
        defer { Task { await host.stop() } }
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )
        var options = CommandRuntimeOptions()
        options.captureEnginePreference = "auto"
        options.usesPerToolSnapshotInvalidation = true
        options.requiresScreenCaptureKitOwnerCapability = true
        options.requiresSilentCapture = true
        var permissionRejections: [String] = []
        let resolved = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [.init(
                socketPath: socketPath,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            )],
            identity: identity,
            options: options,
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections
        )
        let resolution = try #require(resolved)

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await resolution.services.desktopObservation.observe(DesktopObservationRequest(
                target: .screen(index: 0),
                capture: DesktopCaptureOptions(engine: .legacy),
                detection: DesktopDetectionOptions(mode: .none)
            ))
        }

        #expect(error?.standardizedErrorCode == .captureFailed)
        #expect(error?.message.contains("classic request reached the remote observation service") == true)
        #expect(permissionRejections.isEmpty)
        await host.stop()
    }

    @Test
    func `explicit remote modern refuses a nonowner socket without rerouting or local fallback`() async throws {
        let explicitSocket = "/tmp/peekaboo-explicit-nonowner-\(UUID().uuidString).sock"
        let nonownerHost = try await Self.startHost(
            socketPath: explicitSocket,
            processIdentifier: 1111,
            processStartIdentity: 2222,
            codeSignatureHash: "other-build"
        )
        defer { Task { await nonownerHost.stop() } }
        var options = Self.captureOptions(engine: "modern")
        options.bridgeSocketPath = explicitSocket
        options.autoStartDaemon = false
        var claimCalls = 0
        var inspectCalls = 0
        var localFactoryCalls = 0

        let error = await #expect(throws: PreDispatchActionError.self) {
            _ = try await RuntimeHostResolver.resolveServices(
                options: options,
                environment: [:],
                configurationInput: nil,
                dependencies: .init(
                    makeLocalServices: { _ in
                        localFactoryCalls += 1
                        return PeekabooServices()
                    },
                    claimScreenCaptureKitOwner: {
                        claimCalls += 1
                        return Self.ownerReceipt()
                    },
                    inspectScreenCaptureKitOwner: {
                        inspectCalls += 1
                        return Self.ownerReceipt()
                    }
                )
            )
        }

        #expect(error?.code == .CAPTURE_FAILED)
        #expect(error?.envelopeEffect == .refused)
        #expect(error?.envelopeRetrySafe == true)
        #expect(error?.envelopeMutationDispatched == false)
        #expect(error?.localizedDescription.contains(explicitSocket) == true)
        #expect(error?.hint?.contains("Change or remove --bridge-socket") == true)
        #expect(claimCalls == 0)
        #expect(inspectCalls == 1)
        #expect(localFactoryCalls == 0)
        await nonownerHost.stop()
    }

    @Test
    func `explicit remote modern accepts the exact owner socket without rerouting`() async throws {
        let explicitSocket = "/tmp/peekaboo-explicit-owner-\(UUID().uuidString).sock"
        let ownerHost = try await Self.startHost(
            socketPath: explicitSocket,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build"
        )
        defer { Task { await ownerHost.stop() } }
        var options = Self.captureOptions(engine: "modern")
        options.bridgeSocketPath = explicitSocket
        options.autoStartDaemon = false
        var inspectCalls = 0
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                inspectScreenCaptureKitOwner: {
                    inspectCalls += 1
                    return Self.ownerReceipt()
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == explicitSocket)
        #expect(inspectCalls == 1)
        #expect(localFactoryCalls == 0)
        await ownerHost.stop()
    }

    @Test(arguments: ["auto", "classic"])
    func `local-default dynamic tools follow an explicit owner Bridge`(startupEngine: String) async throws {
        let ownerSocket = "/tmp/peekaboo-dynamic-owner-\(UUID().uuidString).sock"
        let ownerHost = try await Self.startHost(
            socketPath: ownerSocket,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build"
        )
        defer { Task { await ownerHost.stop() } }
        var options = CommandRuntimeOptions()
        options.captureEnginePreference = startupEngine
        options.preferRemote = false
        options.bridgeSocketPath = ownerSocket
        options.usesPerToolSnapshotInvalidation = true
        options.requiresScreenCaptureKitOwnerCapability = true
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                inspectScreenCaptureKitOwner: { Self.ownerReceipt() }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == ownerSocket)
        #expect(localFactoryCalls == 0)
        await ownerHost.stop()
    }

    @Test
    func `stateful dynamic tools follow an implicit owner outside the build-scoped daemon`() async throws {
        let ownerSocket = "/tmp/peekaboo-dynamic-implicit-owner-\(UUID().uuidString).sock"
        let ownerHost = try await Self.startHost(
            socketPath: ownerSocket,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build"
        )
        defer { Task { await ownerHost.stop() } }
        var options = CommandRuntimeOptions()
        options.preferRemote = true
        options.usesPerToolSnapshotInvalidation = true
        options.requiresScreenCaptureKitOwnerCapability = true
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: { Self.ownerReceipt() },
                inspectScreenCaptureKitOwner: { Self.ownerReceipt() },
                remoteCandidatePlan: { _, _ in
                    RuntimeHostResolver.RemoteCandidatePlan(
                        explicitSocket: nil,
                        daemonSocketPath: "/tmp/peekaboo-dynamic-daemon.sock",
                        runtimeBuildIdentity: "current-build",
                        buildScopedDaemonSocketPath: "/tmp/peekaboo-dynamic-current-build.sock",
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: [.init(
                            socketPath: ownerSocket,
                            requireReusableDaemon: false,
                            requiredHostKind: nil,
                            requiresValidatedHistoricalDaemon: false
                        )]
                    )
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == ownerSocket)
        #expect(localFactoryCalls == 0)
        await ownerHost.stop()
    }
}

extension ScreenCaptureKitOwnerRuntimeTests {
    @Test(arguments: ["caller-auto", "implicit-auto", "caller-classic", "implicit-classic"])
    func `dynamic tools remain local and defer old-host safety until an SCK leaf`(
        scenario: String
    ) async throws {
        let callerLocal = scenario.hasPrefix("caller-")
        let startupEngine = scenario.hasSuffix("-classic") ? "classic" : "auto"
        var options = CommandRuntimeOptions()
        options.captureEnginePreference = startupEngine
        options.preferRemote = !callerLocal
        options.remoteIsolationRequested = callerLocal
        options.usesPerToolSnapshotInvalidation = true
        options.requiresScreenCaptureKitOwnerCapability = true
        options.requiresSilentCapture = true
        var claimCalls = 0
        var inspectOwnerCalls = 0
        var inspectSafetyCalls = 0
        var recordedBlockers: [RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost] = []
        var localFactoryCalls = 0

        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: {
                    claimCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitOwner: {
                    inspectOwnerCalls += 1
                    return nil
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    inspectSafetyCalls += 1
                    return RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
                        socketPath: "/tmp/old-host.sock",
                        processIdentifier: 3131,
                        processStartIdentity: 4141
                    )
                },
                recordScreenCaptureKitSafetyBlocker: { blocker in
                    recordedBlockers.append(blocker)
                }
            )
        )

        #expect(resolution.selectedRemoteSocketPath == nil)
        #expect(claimCalls == 0)
        #expect(inspectOwnerCalls == 0)
        #expect(inspectSafetyCalls == 1)
        #expect(recordedBlockers == [RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
            socketPath: "/tmp/old-host.sock",
            processIdentifier: 3131,
            processStartIdentity: 4141
        )])
        #expect(resolution.toolCapturePreflightRefusal?.message.contains("/tmp/old-host.sock") == true)
        #expect(resolution.toolCapturePreflightRefusal?.message.contains("No capture was dispatched") == true)
        #expect(localFactoryCalls == 1)
    }

    @Test(arguments: ["modern", "classic", "auto"])
    func `remote capture engines never preclaim in the caller`(engine: String) async throws {
        let missingSocket = "/tmp/peekaboo-owner-runtime-\(UUID().uuidString).sock"
        var options = Self.captureOptions(engine: engine)
        options.bridgeSocketPath = missingSocket
        options.autoStartDaemon = false
        var claimCalls = 0
        var inspectCalls = 0
        var localFactoryCalls = 0

        _ = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: {
                    claimCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitOwner: {
                    inspectCalls += 1
                    return nil
                }
            )
        )

        #expect(claimCalls == 0)
        #expect(inspectCalls == (engine == "classic" ? 0 : 1))
        #expect(localFactoryCalls == 1)
    }

    @Test
    func `owner matching requires exact generation capability and signed build when known`() {
        let owner = Self.ownerReceipt()
        let matching = Self.handshake(processIdentifier: 4242, processStartIdentity: 9001)
        let wrongGeneration = Self.handshake(processIdentifier: 4242, processStartIdentity: 9002)
        let noCapability = Self.handshake(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            hostCapabilities: []
        )
        let noBuildCapability = Self.handshake(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            hostCapabilities: [PeekabooBridgeHostCapability.hostGenerationIdentity]
        )
        let wrongBuild = Self.handshake(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "different"
        )

        #expect(RuntimeHostResolver.screenCaptureKitHostMatchesOwner(handshake: matching, owner: owner))
        #expect(!RuntimeHostResolver.screenCaptureKitHostMatchesOwner(
            handshake: wrongGeneration,
            owner: owner
        ))
        #expect(!RuntimeHostResolver.screenCaptureKitHostMatchesOwner(handshake: noCapability, owner: owner))
        #expect(!RuntimeHostResolver.screenCaptureKitHostMatchesOwner(
            handshake: noBuildCapability,
            owner: owner
        ))
        #expect(!RuntimeHostResolver.screenCaptureKitHostMatchesOwner(handshake: wrongBuild, owner: owner))
    }

    @Test
    func `remote auto and modern prefer an existing owner while classic remains isolated`() {
        for engine in ["auto", "modern"] {
            #expect(RuntimeHostResolver.shouldPreferScreenCaptureKitOwnerHost(
                options: Self.captureOptions(engine: engine),
                environment: [:]
            ))
        }
        #expect(!RuntimeHostResolver.shouldPreferScreenCaptureKitOwnerHost(
            options: Self.captureOptions(engine: "classic"),
            environment: [:]
        ))
    }

    @Test
    func `owner candidate expansion preserves runtime order and adds known GUI hosts once`() {
        let runtime = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/runtime.sock",
            requireReusableDaemon: true,
            requiredHostKind: .onDemand,
            requiresValidatedHistoricalDaemon: false
        )

        let candidates = RuntimeHostResolver.screenCaptureKitOwnerCandidates(from: [runtime])

        #expect(candidates.first?.socketPath == "/tmp/runtime.sock")
        #expect(candidates.map(\.socketPath).contains(PeekabooBridgeConstants.peekabooSocketPath))
        #expect(candidates.map(\.socketPath).contains(PeekabooBridgeConstants.claudeSocketPath))
        #expect(candidates.map(\.socketPath).contains(PeekabooBridgeConstants.clawdbotSocketPath))
        #expect(Set(candidates.map { NSString(string: $0.socketPath).standardizingPath }).count == candidates.count)
    }

    @Test
    func `external host diagnostics attribute only one exact main application`() {
        let exactClaude = RuntimeHostResolver.ScreenCaptureKitExternalApplication(
            bundleIdentifier: "com.anthropic.claudefordesktop",
            bundleName: "Claude",
            localizedName: "Claude",
            processIdentifier: 3131,
            isTerminated: false,
            buildIdentity: "4.0.0 (4000099)"
        )
        let helper = RuntimeHostResolver.ScreenCaptureKitExternalApplication(
            bundleIdentifier: "com.anthropic.claudefordesktop.helper",
            bundleName: "Claude Helper",
            localizedName: "Claude Helper",
            processIdentifier: 3232,
            isTerminated: false,
            buildIdentity: "4.0.0 (4000099)"
        )
        let similarlyNamed = RuntimeHostResolver.ScreenCaptureKitExternalApplication(
            bundleIdentifier: "com.example.claude.integration",
            bundleName: "Claude Integration",
            localizedName: "Claude Integration",
            processIdentifier: 3333,
            isTerminated: false,
            buildIdentity: "fixture"
        )
        let generation: (pid_t) -> UInt64? = { processIdentifier in
            processIdentifier == 3131 ? 4141 : 5151
        }

        let exact = RuntimeHostResolver.knownExternalHostPresence(
            socketPath: PeekabooBridgeConstants.claudeSocketPath,
            applications: [exactClaude, helper],
            processStartIdentity: generation
        )
        #expect(exact == .present(
            processIdentifier: 3131,
            processStartIdentity: 4141,
            buildIdentity: "4.0.0 (4000099)"
        ))

        for ambiguousApplications in [[helper], [similarlyNamed], [exactClaude, exactClaude]] {
            let ambiguous = RuntimeHostResolver.knownExternalHostPresence(
                socketPath: PeekabooBridgeConstants.claudeSocketPath,
                applications: ambiguousApplications,
                processStartIdentity: generation
            )
            #expect(ambiguous == .present(
                processIdentifier: nil,
                processStartIdentity: nil,
                buildIdentity: nil
            ))
        }

        let absent = RuntimeHostResolver.knownExternalHostPresence(
            socketPath: PeekabooBridgeConstants.claudeSocketPath,
            applications: [],
            processStartIdentity: generation
        )
        #expect(absent == .absent)
    }

    @Test
    func `old-host safety skips only definitive socket and process absence`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/fixture.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )

        for code in [POSIXErrorCode.ENOENT, .ECONNREFUSED, .ENAMETOOLONG] {
            let result = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
                candidates: [candidate],
                identity: identity,
                handshake: { _, _ in throw POSIXError(code) },
                externalHostPresence: { _ in .absent }
            )
            #expect(result == nil)
        }

        let timeout = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: { _, _ in throw POSIXError(.ETIMEDOUT) },
            externalHostPresence: { _ in .absent }
        )
        #expect(timeout == RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
            socketPath: candidate.socketPath,
            processIdentifier: nil,
            processStartIdentity: nil
        ))

        let unauthorized = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: { _, _ in
                throw PeekabooBridgeErrorEnvelope(code: .unauthorizedClient, message: "fixture")
            },
            externalHostPresence: { _ in .absent }
        )
        #expect(unauthorized == timeout)

        let liveExternalProcess = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: { _, _ in throw POSIXError(.ENOENT) },
            externalHostPresence: { _ in
                .present(processIdentifier: nil, processStartIdentity: nil, buildIdentity: nil)
            }
        )
        #expect(liveExternalProcess == timeout)

        let explicitUnknownSocket = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: { _, _ in throw POSIXError(.ECONNREFUSED) },
            externalHostPresence: { _ in .absent }
        )
        #expect(explicitUnknownSocket == nil)

        let auxiliary = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/auxiliary.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let validExplicitWithAbsentAuxiliary = try await RuntimeHostResolver
            .firstScreenCaptureKitOwnerUnawareHost(
                candidates: [candidate, auxiliary],
                identity: identity,
                handshake: { candidateUnderTest, _ in
                    guard candidateUnderTest.socketPath == candidate.socketPath else {
                        throw POSIXError(.ENOENT)
                    }
                    return Self.handshake(
                        processIdentifier: 4242,
                        processStartIdentity: 9001
                    )
                },
                externalHostPresence: { _ in .absent }
            )
        #expect(validExplicitWithAbsentAuxiliary == nil)

        await #expect(throws: CancellationError.self) {
            _ = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
                candidates: [candidate],
                identity: identity,
                handshake: { _, _ in throw CancellationError() },
                externalHostPresence: { _ in
                    .present(processIdentifier: nil, processStartIdentity: nil, buildIdentity: nil)
                }
            )
        }

        let uncooperativeHandshake = Task { @MainActor in
            try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
                candidates: [candidate],
                identity: identity,
                handshake: { _, _ in
                    try? await Task.sleep(for: .milliseconds(20))
                    return Self.handshake(
                        processIdentifier: 3131,
                        processStartIdentity: 4141,
                        hostCapabilities: []
                    )
                },
                externalHostPresence: { _ in
                    .present(processIdentifier: nil, processStartIdentity: nil, buildIdentity: nil)
                }
            )
        }
        try await Task.sleep(for: .milliseconds(1))
        uncooperativeHandshake.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await uncooperativeHandshake.value
        }
    }

    @Test
    func `old-host safety retains handshake and exact external owner diagnostics`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/fixture-owner.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )

        let handshakeOwner = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: { _, _ in
                Self.handshake(
                    processIdentifier: 3131,
                    processStartIdentity: 4141,
                    hostCapabilities: [],
                    build: "4.0.0 (4000099)"
                )
            },
            externalHostPresence: { _ in .absent }
        )
        #expect(handshakeOwner == .init(
            socketPath: candidate.socketPath,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            buildIdentity: "4.0.0 (4000099)"
        ))

        let unreachableOwner = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: { _, _ in throw POSIXError(.ETIMEDOUT) },
            externalHostPresence: { _ in
                .present(
                    processIdentifier: 5151,
                    processStartIdentity: 6161,
                    buildIdentity: "3.9.2 (3920)"
                )
            }
        )
        #expect(unreachableOwner == .init(
            socketPath: candidate.socketPath,
            processIdentifier: 5151,
            processStartIdentity: 6161,
            buildIdentity: "3.9.2 (3920)"
        ))
    }

    @Test
    func `legacy handshake enriches only a matching external PID`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/fixture-owner.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )
        let partialHandshake: RuntimeHostResolver.ScreenCaptureKitHandshake = { _, _ in
            Self.handshake(
                processIdentifier: 3131,
                processStartIdentity: nil,
                hostCapabilities: [],
                build: nil
            )
        }

        let matching = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: partialHandshake,
            externalHostPresence: { _ in
                .present(
                    processIdentifier: 3131,
                    processStartIdentity: 4141,
                    buildIdentity: "4.0.0"
                )
            }
        )
        #expect(matching == .init(
            socketPath: candidate.socketPath,
            processIdentifier: 3131,
            processStartIdentity: 4141,
            buildIdentity: "4.0.0"
        ))

        let mismatched = try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
            candidates: [candidate],
            identity: identity,
            handshake: partialHandshake,
            externalHostPresence: { _ in
                .present(
                    processIdentifier: 9191,
                    processStartIdentity: 9292,
                    buildIdentity: "unrelated-build"
                )
            }
        )
        #expect(mismatched == .init(
            socketPath: candidate.socketPath,
            processIdentifier: 3131,
            processStartIdentity: nil,
            buildIdentity: nil
        ))
    }

    @Test
    func `remote candidate cancellation never falls through to another host`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/cancelled-owner.sock",
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )
        let task = Task { @MainActor in
            var permissionRejections: [String] = []
            return try await RuntimeHostResolver.resolveRemoteServices(
                candidates: [candidate],
                identity: identity,
                options: Self.captureOptions(engine: "auto"),
                snapshotInvalidationRemoteSocketPaths: [],
                permissionRejections: &permissionRejections,
                handshake: { _, _ in
                    try? await Task.sleep(for: .milliseconds(20))
                    return Self.handshake(
                        processIdentifier: 4242,
                        processStartIdentity: 9001
                    )
                }
            )
        }

        try await Task.sleep(for: .milliseconds(1))
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `empty remote candidate resolution rechecks cancellation before fallback`() async throws {
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "boo.peekaboo.test.client",
            teamIdentifier: nil,
            processIdentifier: getpid()
        )
        var resumeResolution: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            await withCheckedContinuation { continuation in
                resumeResolution = continuation
            }
            var permissionRejections: [String] = []
            return try await RuntimeHostResolver.resolveRemoteServices(
                candidates: [],
                identity: identity,
                options: Self.captureOptions(engine: "auto"),
                snapshotInvalidationRemoteSocketPaths: [],
                permissionRejections: &permissionRejections
            )
        }
        while resumeResolution == nil {
            await Task.yield()
        }
        task.cancel()
        resumeResolution?.resume()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `remote resolution prefers the exact live owner over an earlier capable host`() async throws {
        let firstSocket = "/tmp/peekaboo-nonowner-\(UUID().uuidString).sock"
        let ownerSocket = "/tmp/peekaboo-owner-\(UUID().uuidString).sock"
        let firstHost = try await Self.startHost(
            socketPath: firstSocket,
            processIdentifier: 1111,
            processStartIdentity: 2222,
            codeSignatureHash: "other-build"
        )
        let ownerHost = try await Self.startHost(
            socketPath: ownerSocket,
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build"
        )
        defer {
            Task {
                await firstHost.stop()
                await ownerHost.stop()
            }
        }
        var permissionRejections: [String] = []

        let resolution = try await RuntimeHostResolver.resolveRemoteServices(
            candidates: [
                .init(
                    socketPath: firstSocket,
                    requireReusableDaemon: false,
                    requiredHostKind: nil,
                    requiresValidatedHistoricalDaemon: false
                ),
                .init(
                    socketPath: ownerSocket,
                    requireReusableDaemon: false,
                    requiredHostKind: nil,
                    requiresValidatedHistoricalDaemon: false
                ),
            ],
            identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: "boo.peekaboo.test.client",
                teamIdentifier: nil,
                processIdentifier: getpid()
            ),
            options: Self.captureOptions(engine: "modern"),
            requiredOwner: Self.ownerReceipt(),
            snapshotInvalidationRemoteSocketPaths: [],
            permissionRejections: &permissionRejections
        )

        #expect(resolution?.selectedRemoteSocketPath == ownerSocket)
        #expect(permissionRejections.isEmpty)
        await firstHost.stop()
        await ownerHost.stop()
    }

    private static func captureOptions(engine: String) -> CommandRuntimeOptions {
        var options = CommandRuntimeOptions()
        options.captureEnginePreference = engine
        options.transportsCaptureEnginePreference = true
        options.requiresCaptureEnginePreferenceHost = true
        options.requiresCaptureEnginePreferenceCapability = engine != "auto"
        options.requiresScreenCaptureKitOwnerCapability = true
        options.requiresDesktopObservation = true
        options.requiresScreenCapturePermission = true
        return options
    }

    static func ownerReceipt() -> ScreenCaptureKitOwnerLease.OwnerReceipt {
        ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "owner-build"
        )
    }

    private static func handshake(
        processIdentifier: pid_t,
        processStartIdentity: UInt64?,
        hostCapabilities: [String] = [
            PeekabooBridgeHostCapability.hostGenerationIdentity,
            PeekabooBridgeHostCapability.codeSignatureBuildIdentity,
            PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership,
        ],
        codeSignatureHash: String = "owner-build",
        build: String? = nil
    ) -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion,
            hostKind: .onDemand,
            build: build,
            supportedOperations: [.captureScreen, .desktopObservation],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                appleScript: false,
                postEvent: true
            ),
            enabledOperations: [.captureScreen, .desktopObservation],
            hostIdentity: PeekabooBridgeHostIdentity(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                bundleIdentifier: "boo.peekaboo.test",
                bundleShortVersion: nil,
                bundleVersion: nil,
                codeSignatureHash: codeSignatureHash
            ),
            hostCapabilities: hostCapabilities
        )
    }

    static func startHost(
        socketPath: String,
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        codeSignatureHash: String,
        ownerAware: Bool = true,
        screenRecording: Bool = true,
        maximumProtocolVersion: PeekabooBridgeProtocolVersion =
            PeekabooBridgeConstants.exactForcedDialogDismissExecutionVersion,
        usesCurrentHostIdentity: Bool = false,
        serviceOverride: (any PeekabooBridgeServiceProviding)? = nil,
        permissionEvaluationObserver: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> PeekabooBridgeHost {
        let services: any PeekabooBridgeServiceProviding = if let serviceOverride {
            serviceOverride
        } else if ownerAware {
            PeekabooServices()
        } else {
            OwnerPolicyFixtureServices(ownerAware: false)
        }
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: ClosedRange(uncheckedBounds: (
                lower: PeekabooBridgeConstants.supportedProtocolRange.lowerBound,
                upper: maximumProtocolVersion
            )),
            allowedOperations: [
                .permissionsStatus,
                .captureScreen,
                .desktopObservation,
                .invalidateImplicitLatestSnapshot,
                .launchApplicationWithOptions,
                .findApplication,
                .activateApplication,
                .targetedHotkey,
                .targetedTypeActions,
                .targetedClick,
                .ownsSnapshot,
                .targetedDialogListElements,
                .prepareDialogAction,
                .exactDialogClickButton,
                .exactDialogDismiss,
            ],
            hostIdentity: usesCurrentHostIdentity
                ? .current()
                : PeekabooBridgeHostIdentity(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: "boo.peekaboo.test.host",
                    bundleShortVersion: nil,
                    bundleVersion: nil,
                    codeSignatureHash: codeSignatureHash
                ),
            permissionStatusEvaluator: { _ in
                permissionEvaluationObserver()
                return PermissionsStatus(
                    screenRecording: screenRecording,
                    accessibility: true,
                    appleScript: false,
                    postEvent: true
                )
            }
        )
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2
        )
        try await host.startChecked()
        return host
    }
}

@MainActor
private final class OwnerPolicyFixtureServices: PeekabooBridgeServiceProviding {
    private let base = PeekabooServices()
    private let ownerAware: Bool
    private let observation: (any DesktopObservationServiceProtocol)?

    init(
        ownerAware: Bool,
        observation: (any DesktopObservationServiceProtocol)? = nil
    ) {
        self.ownerAware = ownerAware
        self.observation = observation
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.observation ?? self.base.desktopObservation
    }

    var supportsDesktopObservationCaptureEngine: Bool {
        true
    }

    var supportsScreenCaptureKitProcessOwnership: Bool {
        self.ownerAware
    }

    func browserStatus(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        try await self.base.browserStatus(channel: channel)
    }

    func browserConnect(channel: String?) async throws -> PeekabooBridgeBrowserStatus {
        try await self.base.browserConnect(channel: channel)
    }

    func browserDisconnect() async throws {
        try await self.base.browserDisconnect()
    }

    func browserExecute(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
    -> PeekabooBridgeBrowserToolResponse {
        try await self.base.browserExecute(request)
    }
}

@MainActor
private final class ClassicDispatchSentinelObservationService: DesktopObservationServiceProtocol {
    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        throw OperationError.captureFailed(reason: "classic request reached the remote observation service")
    }
}
