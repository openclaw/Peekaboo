import Darwin
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import Tachikoma
import Testing
@testable import PeekabooCLI

struct CommandRuntimeInjectionTests {
    @Test
    @MainActor
    func `uses the injected service provider`() {
        let services = RecordingPeekabooServices()
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )
        #expect(services.ensureVisualizerConnectionCallCount == 1)
        #expect(runtime.services is RecordingPeekabooServices)
    }

    @Test
    @MainActor
    func `installs MCP/tool defaults when constructed`() {
        let services = RecordingPeekabooServices()
        _ = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )

        let context = MCPToolContext.shared
        #expect(ObjectIdentifier(context.snapshots as AnyObject) ==
            ObjectIdentifier(services.snapshots as AnyObject))

        let tools = ToolRegistry.allTools()
        #expect(!tools.isEmpty)
    }

    @Test
    @MainActor
    func `learn resolves tools from its injected service provider`() {
        let injectedServices = RecordingPeekabooServices()
        let fallbackServices = RecordingPeekabooServices()
        var fallbackRequests = 0
        ToolRegistry.configureDefaultServices {
            fallbackRequests += 1
            return fallbackServices
        }

        let tools = LearnCommand.toolDefinitions(using: injectedServices)

        #expect(!tools.isEmpty)
        #expect(fallbackRequests == 0)
    }

    @Test
    @MainActor
    func `aligns Tachikoma profile directory with Peekaboo`() {
        let previousProfile = TachikomaConfiguration.profileDirectoryName
        defer { TachikomaConfiguration.profileDirectoryName = previousProfile }

        TachikomaConfiguration.profileDirectoryName = ".tachikoma"
        let services = RecordingPeekabooServices()
        _ = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: services
        )

        #expect(TachikomaConfiguration.profileDirectoryPath == PeekabooCore.ConfigurationManager.baseDir)
    }

    @Test
    func `targeted hotkey support requires enabled bridge operation`() {
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedHotkey],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [
                PeekabooBridgeOperation.targetedHotkey.rawValue: [.postEvent],
            ]
        )

        let enabled = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedHotkey],
            enabledOperations: [.captureScreen, .targetedHotkey]
        )

        #expect(!CommandRuntime.supportsTargetedHotkeys(for: supported))
        #expect(CommandRuntime.supportsTargetedHotkeys(for: enabled))

        let availability = CommandRuntime.targetedHotkeyAvailability(for: supported)
        #expect(availability.unavailableReason?.contains("Event Synthesizing") == true)
        #expect(availability.missingPermissions == [.postEvent])
    }

    @Test
    func `targeted hotkey availability does not require accessibility`() {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.targetedHotkey],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: false,
                postEvent: true
            ),
            enabledOperations: [.targetedHotkey],
            permissionTags: [
                PeekabooBridgeOperation.targetedHotkey.rawValue: [.postEvent],
            ]
        )

        #expect(CommandRuntime.supportsTargetedHotkeys(for: handshake))
        let availability = CommandRuntime.targetedHotkeyAvailability(for: handshake)
        #expect(availability.isEnabled)
        #expect(availability.unavailableReason == nil)
        #expect(availability.missingPermissions.isEmpty)
    }

    @Test
    func `targeted type support requires protocol 1_8 and enabled bridge operation`() {
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 8),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedTypeActions],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [
                PeekabooBridgeOperation.targetedTypeActions.rawValue: [.postEvent],
            ]
        )

        let enabled = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 8),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedTypeActions],
            enabledOperations: [.captureScreen, .targetedTypeActions]
        )

        let oldProtocol = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedTypeActions],
            enabledOperations: [.captureScreen, .targetedTypeActions]
        )

        #expect(!CommandRuntime.supportsTargetedTypeActions(for: supported))
        #expect(CommandRuntime.supportsTargetedTypeActions(for: enabled))
        #expect(!CommandRuntime.supportsTargetedTypeActions(for: oldProtocol))

        let availability = CommandRuntime.targetedTypeAvailability(for: supported)
        #expect(availability.unavailableReason?.contains("Event Synthesizing") == true)
        #expect(availability.missingPermissions == [.postEvent])
    }

    @Test
    func `targeted click support requires enabled bridge operation`() {
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [
                PeekabooBridgeOperation.targetedClick.rawValue: [.postEvent],
            ]
        )

        let enabled = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            enabledOperations: [.captureScreen, .targetedClick]
        )

        #expect(!CommandRuntime.supportsTargetedClicks(for: supported))
        #expect(CommandRuntime.supportsTargetedClicks(for: enabled))

        let availability = CommandRuntime.targetedClickAvailability(for: supported)
        #expect(availability.unavailableReason?.contains("Event Synthesizing") == true)
        #expect(availability.missingPermissions == [.postEvent])
    }

    @Test
    func `exact window click support requires protocol 1_17 capability`() {
        let oldHost = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 16),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.targetedClick],
            enabledOperations: [.targetedClick]
        )
        let currentHost = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 17),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.targetedClick, .exactWindowTargetedClick],
            enabledOperations: [.targetedClick, .exactWindowTargetedClick]
        )

        #expect(!BridgeCapabilityPolicy.supportsExactWindowTargetedClicks(for: oldHost))
        #expect(BridgeCapabilityPolicy.supportsExactWindowTargetedClicks(for: currentHost))
    }

    @Test
    func `request-aware targeted click capability reports its Accessibility requirement`() {
        let accessibilityOnly = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: false
            ),
            enabledOperations: [.captureScreen, .targetedClick],
            permissionTags: [PeekabooBridgeOperation.targetedClick.rawValue: []]
        )
        let unavailable = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 9),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .targetedClick],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: false,
                postEvent: false
            ),
            enabledOperations: [.captureScreen],
            permissionTags: [PeekabooBridgeOperation.targetedClick.rawValue: []]
        )

        let accessibilityAvailability = CommandRuntime.targetedClickAvailability(for: accessibilityOnly)
        #expect(accessibilityAvailability.isEnabled)
        #expect(accessibilityAvailability.missingPermissions.isEmpty)

        let unavailableAvailability = CommandRuntime.targetedClickAvailability(for: unavailable)
        #expect(!unavailableAvailability.isEnabled)
        #expect(unavailableAvailability.missingPermissions == [.accessibility])
        #expect(unavailableAvailability.unavailableReason?.contains("Accessibility") == true)
    }

    @Test
    func `post event permission request support requires advertised protocol operation`() {
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 2),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .requestPostEventPermission]
        )
        let older = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .requestPostEventPermission]
        )
        let hidden = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 2),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        #expect(CommandRuntime.supportsPostEventPermissionRequest(for: supported))
        #expect(!CommandRuntime.supportsPostEventPermissionRequest(for: older))
        #expect(!CommandRuntime.supportsPostEventPermissionRequest(for: hidden))
    }

    @Test
    func `desktop observation support requires advertised protocol operation`() {
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 5),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .desktopObservation]
        )
        let older = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 4),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .desktopObservation]
        )
        let hidden = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 5),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let disabled = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 5),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .desktopObservation],
            enabledOperations: [.captureScreen]
        )

        #expect(CommandRuntime.supportsDesktopObservation(for: supported))
        #expect(!CommandRuntime.supportsDesktopObservation(for: older))
        #expect(!CommandRuntime.supportsDesktopObservation(for: hidden))
        #expect(!CommandRuntime.supportsDesktopObservation(for: disabled))
    }

    @Test
    func `inspect UI support requires advertised protocol operation`() {
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )
        let older = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )
        let hidden = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )

        #expect(CommandRuntime.supportsInspectAccessibilityTree(for: supported))
        #expect(!CommandRuntime.supportsInspectAccessibilityTree(for: older))
        #expect(!CommandRuntime.supportsInspectAccessibilityTree(for: hidden))
    }

    @Test
    func `remote requirements reject inspect UI when required capability is unavailable`() {
        var options = CommandRuntimeOptions()
        options.requiresInspectAccessibilityTree = true
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 7),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )
        let unsupported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 6),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .inspectAccessibilityTree]
        )

        #expect(CommandRuntime.supportsRemoteRequirements(for: supported, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: unsupported, options: options))
    }

    @Test
    func `remote requirements reject browser MCP when required capability is unavailable`() {
        var options = CommandRuntimeOptions()
        options.requiresBrowserMCP = true
        let supported = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.browserConnectionReceiptVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect, .browserExecute],
            hostCapabilities: [PeekabooBridgeHostCapability.browserConnectionReceipts]
        )
        let older = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 3),
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect, .browserExecute]
        )
        let missingExecute = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.browserConnectionReceiptVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect],
            hostCapabilities: [PeekabooBridgeHostCapability.browserConnectionReceipts]
        )
        let gui = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.browserConnectionReceiptVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect, .browserExecute],
            hostCapabilities: [PeekabooBridgeHostCapability.browserConnectionReceipts]
        )
        let missingReceiptCapability = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.browserConnectionReceiptVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen, .browserStatus, .browserConnect, .browserDisconnect, .browserExecute]
        )

        #expect(CommandRuntime.supportsBrowserMCP(for: supported))
        #expect(!CommandRuntime.supportsBrowserMCP(for: older))
        #expect(!CommandRuntime.supportsBrowserMCP(for: missingExecute))
        #expect(!CommandRuntime.supportsBrowserMCP(for: gui))
        #expect(!CommandRuntime.supportsBrowserMCP(for: missingReceiptCapability))
        #expect(CommandRuntime.supportsRemoteRequirements(for: supported, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: older, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: missingExecute, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: gui, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: missingReceiptCapability, options: options))
    }

    @Test
    func `environment bridge socket disables daemon auto start`() {
        let options = CommandRuntimeOptions()
        let environment = ["PEEKABOO_BRIDGE_SOCKET": "/tmp/explicit.sock"]

        #expect(CommandRuntime.explicitBridgeSocket(options: options, environment: environment) == "/tmp/explicit.sock")
        #expect(!CommandRuntime.shouldAutoStartDaemon(options: options, environment: environment))
    }

    @Test
    func `cli bridge socket takes precedence over environment bridge socket`() {
        var options = CommandRuntimeOptions()
        options.bridgeSocketPath = "/tmp/cli.sock"
        let environment = ["PEEKABOO_BRIDGE_SOCKET": "/tmp/env.sock"]

        #expect(CommandRuntime.explicitBridgeSocket(options: options, environment: environment) == "/tmp/cli.sock")
        #expect(!CommandRuntime.shouldAutoStartDaemon(options: options, environment: environment))
    }

    @Test
    func `daemon socket environment configures auto start target without becoming explicit bridge socket`() {
        let options = CommandRuntimeOptions()
        let environment = ["PEEKABOO_DAEMON_SOCKET": "/tmp/daemon.sock"]

        #expect(CommandRuntime.explicitBridgeSocket(options: options, environment: environment) == nil)
        #expect(CommandRuntime.daemonSocketPath(environment: environment) == "/tmp/daemon.sock")
        #expect(CommandRuntime.shouldAutoStartDaemon(options: options, environment: environment))
    }

    @Test
    func `daemon defaults to its dedicated socket`() {
        #expect(CommandRuntime.daemonSocketPath(environment: [:]) == PeekabooBridgeConstants.daemonSocketPath)
        #expect(CommandRuntime.daemonSocketPath(environment: [:]) != PeekabooBridgeConstants.peekabooSocketPath)
        #expect(DaemonLaunchPolicy.shouldMigrateLegacyDaemon(
            targetSocketPath: PeekabooBridgeConstants.daemonSocketPath
        ))
        #expect(!DaemonLaunchPolicy.shouldMigrateLegacyDaemon(targetSocketPath: "/tmp/custom-daemon.sock"))
    }

    @Test
    func `rejected default daemon uses a stable build-scoped auto-start socket`() {
        let firstSocketPath = DaemonLaunchPolicy.autoStartSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            defaultSocketWasOccupiedAndRejected: true,
            runtimeBuildIdentity: "build-a"
        )
        let repeatedSocketPath = DaemonLaunchPolicy.autoStartSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            defaultSocketWasOccupiedAndRejected: true,
            runtimeBuildIdentity: "build-a"
        )
        let nextBuildSocketPath = DaemonLaunchPolicy.autoStartSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            defaultSocketWasOccupiedAndRejected: true,
            runtimeBuildIdentity: "build-b"
        )

        #expect(URL(fileURLWithPath: firstSocketPath).deletingLastPathComponent() ==
            URL(fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath).deletingLastPathComponent())
        #expect(firstSocketPath == repeatedSocketPath)
        #expect(firstSocketPath != nextBuildSocketPath)
        #expect(URL(fileURLWithPath: firstSocketPath).lastPathComponent.hasPrefix("daemon-"))
    }

    @Test
    func `runtime build identity is independent of the loaded universal slice`() {
        let executableURL = URL(fileURLWithPath: "/tmp/peekaboo-universal")
        let nativeIdentity = DaemonLaunchPolicy.runtimeBuildIdentity(executableURL: executableURL) { _ in
            ["bbbbbbbb", "aaaaaaaa"]
        }
        let translatedIdentity = DaemonLaunchPolicy.runtimeBuildIdentity(executableURL: executableURL) { _ in
            ["aaaaaaaa", "bbbbbbbb"]
        }

        #expect(nativeIdentity == translatedIdentity)
        #expect(nativeIdentity.hasSuffix("aaaaaaaa,bbbbbbbb"))
    }

    @Test
    func `runtime build identity reads UUIDs from every universal slice`() {
        func littleEndian(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian, Array.init)
        }

        func bigEndian(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian, Array.init)
        }

        func thinMachO(uuid: [UInt8]) -> Data {
            var data = Data(littleEndian(0xFEED_FACF))
            for _ in 0..<3 {
                data.append(contentsOf: littleEndian(0))
            }
            data.append(contentsOf: littleEndian(1))
            data.append(contentsOf: littleEndian(24))
            data.append(contentsOf: littleEndian(0))
            data.append(contentsOf: littleEndian(0))
            data.append(contentsOf: littleEndian(0x1B))
            data.append(contentsOf: littleEndian(24))
            data.append(contentsOf: uuid)
            return data
        }

        let firstUUID = Array(UInt8(0)...UInt8(15))
        let secondUUID = Array(UInt8(16)...UInt8(31))
        let firstSlice = thinMachO(uuid: firstUUID)
        let secondSlice = thinMachO(uuid: secondUUID)
        let firstOffset = UInt32(48)
        let secondOffset = firstOffset + UInt32(firstSlice.count)

        var universal = Data([0xCA, 0xFE, 0xBA, 0xBE])
        universal.append(contentsOf: bigEndian(2))
        for (offset, size) in [
            (firstOffset, UInt32(firstSlice.count)),
            (secondOffset, UInt32(secondSlice.count)),
        ] {
            universal.append(contentsOf: bigEndian(0))
            universal.append(contentsOf: bigEndian(0))
            universal.append(contentsOf: bigEndian(offset))
            universal.append(contentsOf: bigEndian(size))
            universal.append(contentsOf: bigEndian(0))
        }
        universal.append(firstSlice)
        universal.append(secondSlice)

        #expect(Set(DaemonLaunchPolicy.machoUUIDs(in: universal)) == [
            "000102030405060708090a0b0c0d0e0f",
            "101112131415161718191a1b1c1d1e1f",
        ])
    }

    @Test
    func `auto-start keeps unoccupied and custom daemon sockets`() {
        #expect(DaemonLaunchPolicy.autoStartSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            defaultSocketWasOccupiedAndRejected: false,
            runtimeBuildIdentity: "build-a"
        ) == PeekabooBridgeConstants.daemonSocketPath)
        #expect(DaemonLaunchPolicy.autoStartSocketPath(
            daemonSocketPath: "/tmp/custom-daemon.sock",
            defaultSocketWasOccupiedAndRejected: true,
            runtimeBuildIdentity: "build-a"
        ) == "/tmp/custom-daemon.sock")
    }

    @Test
    func `implicit runtime candidates preserve the default app fallback only`() throws {
        let buildScopedPath = DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
        )
        #expect(DaemonLaunchPolicy.implicitRuntimeCandidateRole(
            socketPath: PeekabooBridgeConstants.daemonSocketPath,
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            buildScopedDaemonSocketPath: buildScopedPath
        ) == .reusableDaemon)
        #expect(try DaemonLaunchPolicy.implicitRuntimeCandidateRole(
            socketPath: #require(buildScopedPath),
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            buildScopedDaemonSocketPath: buildScopedPath
        ) == .reusableDaemon)
        #expect(DaemonLaunchPolicy.implicitRuntimeCandidateRole(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath
        ) == .defaultAppFallback)
        #expect(DaemonLaunchPolicy.implicitRuntimeCandidateRole(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            daemonSocketPath: "/tmp/custom-daemon.sock"
        ) == nil)
    }

    @Test
    func `default app fallback accepts GUI hosts and legacy daemons`() {
        let guiHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let daemonHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let embeddedHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .inProcess,
            build: nil,
            supportedOperations: [.captureScreen]
        )
        let daemonStatus = PeekabooDaemonStatus(running: true, mode: .auto)

        #expect(DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .defaultAppFallback,
            handshake: guiHandshake,
            daemonStatus: nil
        ))
        #expect(DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .defaultAppFallback,
            handshake: daemonHandshake,
            daemonStatus: daemonStatus
        ))
        #expect(!DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .defaultAppFallback,
            handshake: embeddedHandshake,
            daemonStatus: nil
        ))
        #expect(!DaemonLaunchPolicy.isSelectableImplicitRuntimeCandidate(
            role: .reusableDaemon,
            handshake: guiHandshake,
            daemonStatus: nil
        ))
    }

    @Test
    func `bridge diagnostics select only runtime-routed sockets`() {
        let options = CommandRuntimeOptions()
        let environment = ["PEEKABOO_DAEMON_SOCKET": "/tmp/custom-daemon.sock"]

        #expect(BridgeDiagnostics.runtimeCandidateSocketPaths(
            runtimeOptions: options,
            environment: environment
        ) == ["/tmp/custom-daemon.sock"])

        let diagnosticPaths = BridgeDiagnostics.diagnosticSocketPaths(
            runtimeOptions: options,
            environment: environment
        )
        #expect(diagnosticPaths.first == "/tmp/custom-daemon.sock")
        #expect(diagnosticPaths.contains(PeekabooBridgeConstants.peekabooSocketPath))
        #expect(diagnosticPaths.contains(PeekabooBridgeConstants.claudeSocketPath))
    }

    @Test
    func `default bridge diagnostics include build-scoped and legacy runtime fallbacks`() throws {
        let runtimePaths = BridgeDiagnostics.runtimeCandidateSocketPaths(
            runtimeOptions: CommandRuntimeOptions(),
            environment: [:]
        )
        let buildScopedPath = DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
        )

        #expect(try runtimePaths == [
            #require(buildScopedPath),
            PeekabooBridgeConstants.daemonSocketPath,
            PeekabooBridgeConstants.peekabooSocketPath,
        ])
        #expect(try DaemonControlResolver.defaultSocketPaths() == [
            PeekabooBridgeConstants.daemonSocketPath,
            #require(buildScopedPath),
        ])
    }

    @Test
    func `bridge diagnostics preserve runtime ordering for validated historical daemons`() throws {
        let historicalPath = "/tmp/peekaboo/daemon-bbbbbbbbbbbbbbbb.sock"
        let options = CommandRuntimeOptions()
        let runtimePaths = BridgeDiagnostics.runtimeCandidateSocketPaths(
            runtimeOptions: options,
            environment: [:],
            historicalBuildScopedDaemonSocketPaths: [historicalPath]
        )
        let diagnosticPaths = BridgeDiagnostics.diagnosticSocketPaths(
            runtimeOptions: options,
            environment: [:],
            historicalBuildScopedDaemonSocketPaths: [historicalPath]
        )
        let buildScopedPath = try #require(DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
        ))

        #expect(runtimePaths == [
            buildScopedPath,
            PeekabooBridgeConstants.daemonSocketPath,
            historicalPath,
            PeekabooBridgeConstants.peekabooSocketPath,
        ])
        #expect(Array(diagnosticPaths.prefix(runtimePaths.count)) == runtimePaths)
    }

    @Test
    func `bridge diagnostics use GUI-first runtime ordering for host inventory`() throws {
        let historicalPath = "/tmp/peekaboo/daemon-bbbbbbbbbbbbbbbb.sock"
        var options = CommandRuntimeOptions()
        options.requiresHostApplicationInventory = true
        let runtimePaths = BridgeDiagnostics.runtimeCandidateSocketPaths(
            runtimeOptions: options,
            environment: [:],
            historicalBuildScopedDaemonSocketPaths: [historicalPath]
        )
        let buildScopedPath = try #require(DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
        ))

        #expect(runtimePaths == [
            PeekabooBridgeConstants.peekabooSocketPath,
            buildScopedPath,
            PeekabooBridgeConstants.daemonSocketPath,
            historicalPath,
        ])
    }

    @Test
    func `explicit bridge diagnostics probe only the explicit runtime socket`() {
        var options = CommandRuntimeOptions()
        options.bridgeSocketPath = "/tmp/explicit.sock"

        #expect(BridgeDiagnostics.diagnosticSocketPaths(
            runtimeOptions: options,
            environment: ["PEEKABOO_DAEMON_SOCKET": "/tmp/ignored.sock"]
        ) == ["/tmp/explicit.sock"])
    }
}

extension CommandRuntimeInjectionTests {
    @Test
    func `on demand daemon arguments use auto mode and idle timeout`() {
        let args = CommandRuntime.onDemandDaemonArguments(socketPath: "/tmp/daemon.sock", idleTimeoutSeconds: 12.5)

        #expect(args.contains("auto"))
        #expect(args.contains("/tmp/daemon.sock"))
        #expect(args.contains("--idle-timeout"))
        #expect(args.contains("12.500s"))
    }

    @Test
    func `manual daemon migration preserves mode without idle timeout`() {
        let args = DaemonLaunchPolicy.daemonArguments(
            socketPath: "/tmp/daemon.sock",
            mode: .manual,
            pollIntervalMs: 375,
            idleTimeoutSeconds: 12.5
        )

        #expect(args.contains("manual"))
        #expect(args.contains("--poll-interval"))
        #expect(args.contains("375ms"))
        #expect(!args.contains("--idle-timeout"))
    }

    @Test
    func `automatic daemon migration preserves live settings`() {
        let status = PeekabooDaemonStatus(
            running: true,
            mode: .auto,
            windowTracker: PeekabooDaemonWindowTrackerStatus(
                trackedWindows: 1,
                lastEventAt: nil,
                lastPollAt: nil,
                axObserverCount: 1,
                cgPollIntervalMs: 425
            ),
            activity: PeekabooDaemonActivityStatus(
                activeRequests: 0,
                lastActivityAt: nil,
                idleTimeoutSeconds: 47.5,
                idleExitAt: nil
            ),
            supportsConditionalStop: true
        )

        let args = DaemonLaunchPolicy.migratedDaemonArguments(
            socketPath: "/tmp/daemon.sock",
            status: status,
            fallbackIdleTimeoutSeconds: 300
        )

        #expect(args?.contains("auto") == true)
        #expect(args?.contains("425ms") == true)
        #expect(args?.contains("47.500s") == true)
    }

    @Test
    func `daemon startup waits for a draining lease`() async throws {
        let socketPath = "/tmp/peekaboo-daemon-wait-\(UUID().uuidString).sock"
        let leasePath = "\(socketPath).lock"
        let leaseFD = open(
            leasePath,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        #expect(leaseFD >= 0)
        defer {
            if leaseFD >= 0 {
                flock(leaseFD, LOCK_UN)
                close(leaseFD)
            }
            unlink(leasePath)
        }
        #expect(flock(leaseFD, LOCK_EX | LOCK_NB) == 0)

        let waitTask = Task {
            try await DaemonLaunchPolicy.waitForDaemonSocketAvailability(
                socketPath: socketPath,
                client: DaemonControlClient(socketPath: socketPath),
                timeout: 1
            )
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(flock(leaseFD, LOCK_UN) == 0)

        #expect(try await waitTask.value == .available)
    }

    @Test
    @MainActor
    func `on-demand daemon startup propagates launcher cancellation`() async {
        let socketPath = "/tmp/peekaboo-daemon-cancel-wrapper-\(UUID().uuidString).sock"
        defer {
            unlink(socketPath)
            unlink("\(socketPath).lock")
        }
        var launchCalls = 0

        await #expect(throws: CancellationError.self) {
            _ = try await DaemonLaunchPolicy.startOnDemandDaemon(
                socketPath: socketPath,
                environment: [:],
                launch: { _, _, _ in
                    launchCalls += 1
                    throw CancellationError()
                }
            )
        }

        #expect(launchCalls == 1)
    }

    @Test
    @MainActor
    func `migration launch rejects uncooperative success before legacy stop`() async throws {
        var resumeLaunch: CheckedContinuation<Void, Never>?
        var rolledBackResult: Bool?
        let task = Task { @MainActor in
            try await DaemonLaunchPolicy.performMigrationLaunch(
                launch: {
                    await withCheckedContinuation { continuation in
                        resumeLaunch = continuation
                    }
                    return true
                },
                rollback: { result in
                    rolledBackResult = result
                }
            )
        }
        while resumeLaunch == nil {
            await Task.yield()
        }
        task.cancel()
        resumeLaunch?.resume()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(rolledBackResult == true)
    }

    @Test
    @MainActor
    func `replacement rollback retries after active work drains`() async throws {
        let socketPath = "/tmp/peekaboo-daemon-rollback-\(UUID().uuidString).sock"
        defer {
            unlink(socketPath)
            unlink("\(socketPath).lock")
        }
        let daemon = PeekabooDaemon(configuration: .init(
            mode: .manual,
            bridgeSocketPath: socketPath,
            allowlistedTeams: [],
            windowTrackingEnabled: false,
            hostKind: .onDemand
        ))
        try await daemon.startChecked()
        #expect(await daemon.admitActivity(operation: .captureScreen))

        let status = await daemon.daemonStatus()
        let rollbackTask = Task {
            await DaemonLaunchPolicy.stopReplacement(
                client: DaemonControlClient(socketPath: socketPath),
                replacement: .init(status: status, processID: getpid())
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await daemon.recordActivityEnd(operation: .captureScreen)

        #expect(await rollbackTask.value)
        await daemon.waitUntilStopped()
    }

    @Test
    @MainActor
    func `canceled migration rolls back its replacement in an uncanceled task`() async throws {
        let socketPath = "/tmp/peekaboo-daemon-canceled-rollback-\(UUID().uuidString).sock"
        defer {
            unlink(socketPath)
            unlink("\(socketPath).lock")
        }
        let daemon = PeekabooDaemon(configuration: .init(
            mode: .manual,
            bridgeSocketPath: socketPath,
            allowlistedTeams: [],
            windowTrackingEnabled: false,
            hostKind: .onDemand
        ))
        try await daemon.startChecked()
        #expect(await daemon.admitActivity(operation: .captureScreen))

        let status = await daemon.daemonStatus()
        let rollbackTask = Task { @MainActor in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await DaemonLaunchPolicy.stopReplacementAfterCancellation(
                client: DaemonControlClient(socketPath: socketPath),
                replacement: .init(status: status, processID: getpid())
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await daemon.recordActivityEnd(operation: .captureScreen)

        #expect(await rollbackTask.value)
        await daemon.waitUntilStopped()
    }

    @Test
    func `daemon idle timeout environment falls back to default for invalid values`() {
        #expect(CommandRuntime.daemonIdleTimeoutSeconds(environment: [:]) ==
            CommandRuntime.defaultDaemonIdleTimeoutSeconds)
        #expect(CommandRuntime.daemonIdleTimeoutSeconds(environment: [
            "PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS": "0",
        ]) == CommandRuntime.defaultDaemonIdleTimeoutSeconds)
        #expect(CommandRuntime.daemonIdleTimeoutSeconds(environment: [
            "PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS": "42.5",
        ]) == 42.5)
    }

    @Test
    func `daemon log helper creates missing file and appends`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-daemon-log-\(UUID().uuidString)")
        let logURL = directory.appendingPathComponent("daemon.log")

        let firstHandle = try #require(DaemonPaths.openFileForAppend(at: logURL))
        try firstHandle.write(contentsOf: Data("first\n".utf8))
        try firstHandle.close()

        let secondHandle = try #require(DaemonPaths.openFileForAppend(at: logURL))
        try secondHandle.write(contentsOf: Data("second\n".utf8))
        try secondHandle.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        #expect(contents == "first\nsecond\n")
    }
}

extension CommandRuntimeInjectionTests {
    @Test
    func `composite type delivery support requires protocol and raw capability`() {
        let operations: [PeekabooBridgeOperation] = [
            .targetedTypeActions,
            .exactWindowTargetedTypeActions,
            .exactWindowPixelFocusType,
        ]
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.compositeTypeDeliveryVersion,
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.compositeTypeDelivery,
            ]
        )
        let receiptless = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.compositeTypeDeliveryVersion,
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: [PeekabooBridgeHostCapability.compositeTypeDelivery]
        )
        let missingCapability = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.compositeTypeDeliveryVersion,
            supportedOperations: operations,
            enabledOperations: operations
        )
        let previous = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 35),
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: [PeekabooBridgeHostCapability.compositeTypeDelivery]
        )

        #expect(BridgeCapabilityPolicy.supportsCompositeTypeDelivery(for: current))
        #expect(!BridgeCapabilityPolicy.supportsCompositeTypeDelivery(for: receiptless))
        #expect(!BridgeCapabilityPolicy.supportsCompositeTypeDelivery(for: missingCapability))
        #expect(!BridgeCapabilityPolicy.supportsCompositeTypeDelivery(for: previous))
    }
}

@MainActor
final class RecordingPeekabooServices: PeekabooServiceProviding {
    private let base = PeekabooServices()
    private(set) var ensureVisualizerConnectionCallCount = 0

    func ensureVisualizerConnection() {
        self.ensureVisualizerConnectionCallCount += 1
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
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

    var files: any FileServiceProtocol {
        self.base.files
    }

    var clipboard: any ClipboardServiceProtocol {
        self.base.clipboard
    }

    var configuration: PeekabooCore.ConfigurationManager {
        self.base.configuration
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var audioInput: AudioInputService {
        self.base.audioInput
    }

    var screens: any ScreenServiceProtocol {
        self.base.screens
    }

    var browser: any BrowserMCPClientProviding {
        self.base.browser
    }

    var agent: (any AgentServiceProtocol)? {
        self.base.agent
    }
}
