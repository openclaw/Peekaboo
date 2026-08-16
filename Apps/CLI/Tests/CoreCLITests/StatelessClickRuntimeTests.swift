import Commander
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

struct StatelessClickRuntimeTests {
    @Test
    func `Middle and triple clicks separate protocol payload and background capability requirements`() throws {
        for flag in ["middle", "triple"] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: ["on": ["B1"]],
                    flags: [flag]
                ),
                commandType: ClickCommand.self
            )
            #expect(options.requiresStatelessClickVariants)
            #expect(options.requiresBackgroundStatelessClickVariants)
            #expect(options.requiresPostEventPermission)
        }

        let operations: [PeekabooBridgeOperation] = [.targetedClick, .exactWindowTargetedClick]
        let permissions = PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
        let previous = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 29),
            supportedOperations: operations,
            permissions: permissions,
            hostCapabilities: [PeekabooBridgeHostCapability.statelessClickVariants]
        )
        let missingCapability = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.statelessClickVariantVersion,
            supportedOperations: operations,
            permissions: permissions
        )
        let capable = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.statelessClickVariantVersion,
            supportedOperations: operations,
            permissions: permissions,
            hostCapabilities: [PeekabooBridgeHostCapability.statelessClickVariants]
        )
        var options = CommandRuntimeOptions()
        options.requiresStatelessClickVariants = true
        options.requiresBackgroundStatelessClickVariants = true

        #expect(!CommandRuntime.supportsRemoteRequirements(for: previous, options: options))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: missingCapability, options: options))
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: options))

        var foregroundOptions = CommandRuntimeOptions()
        foregroundOptions.requiresStatelessClickVariants = true
        #expect(!CommandRuntime.supportsRemoteRequirements(for: previous, options: foregroundOptions))
        #expect(CommandRuntime.supportsRemoteRequirements(for: missingCapability, options: foregroundOptions))
        #expect(CommandRuntime.supportsRemoteRequirements(for: capable, options: foregroundOptions))
    }

    @Test
    func `Held pointer support requires complete enabled protocol 1 30 capability`() {
        let operations: [PeekabooBridgeOperation] = [
            .createExactWindowHeldPointerOwner,
            .beginExactWindowHeldPointer,
            .releaseExactWindowHeldPointer,
            .revokeExactWindowHeldPointer,
            .disconnectExactWindowHeldPointerOwner,
        ]
        let capability = [PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle]
        let previous = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 29),
            supportedOperations: operations,
            hostCapabilities: capability
        )
        let missingCapability = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion,
            supportedOperations: operations
        )
        let missingOperation = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion,
            supportedOperations: Array(operations.dropLast()),
            hostCapabilities: capability
        )
        let disabledOperation = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion,
            supportedOperations: operations,
            enabledOperations: Array(operations.dropLast()),
            hostCapabilities: capability
        )
        let capable = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.exactWindowHeldPointerLifecycleVersion,
            supportedOperations: operations,
            enabledOperations: operations,
            hostCapabilities: capability
        )

        #expect(!BridgeCapabilityPolicy.supportsExactWindowHeldPointerLifecycle(for: previous))
        #expect(!BridgeCapabilityPolicy.supportsExactWindowHeldPointerLifecycle(for: missingCapability))
        #expect(!BridgeCapabilityPolicy.supportsExactWindowHeldPointerLifecycle(for: missingOperation))
        #expect(!BridgeCapabilityPolicy.supportsExactWindowHeldPointerLifecycle(for: disabledOperation))
        #expect(BridgeCapabilityPolicy.supportsExactWindowHeldPointerLifecycle(for: capable))
    }
}
