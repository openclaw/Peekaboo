import Commander
import Foundation
import PeekabooAutomation
import PeekabooBridge
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooCLI

extension CommanderBinderTests {
    @Test(arguments: BridgeTestFixtures.scrollHandshakeCases)
    func `Scroll host selection preserves the shared handshake contract`(
        fixture: BridgeTestFixtures.ScrollHandshakeCase
    ) {
        var element = CommandRuntimeOptions()
        element.requiresTargetedScroll = true
        var coordinate = element
        coordinate.requiresBackgroundCoordinateScroll = true

        #expect(CommandRuntime.supportsRemoteRequirements(for: fixture.handshake, options: element) ==
            fixture.requestPinnedScroll)
        #expect(CommandRuntime.supportsRemoteRequirements(for: fixture.handshake, options: coordinate) ==
            fixture.coordinateScroll)
    }

    @Test
    func `Coordinate scroll binds and requires its negotiated capability without changing element scroll`() throws {
        let coordinate = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["direction": ["down"], "at": ["20,30"]], flags: []),
            commandType: ScrollCommand.self
        )
        let element = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["direction": ["down"], "on": ["S1"]], flags: []),
            commandType: ScrollCommand.self
        )
        #expect(coordinate.requiresBackgroundCoordinateScroll && coordinate.requiresTargetedScroll)
        #expect(!element.requiresBackgroundCoordinateScroll && element.requiresTargetedScroll)

        for (minor, hasCapability) in [(42, true), (43, false), (43, true)] {
            var capabilities = [PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt]
            if hasCapability {
                capabilities.append(PeekabooBridgeHostCapability.backgroundCoordinateScroll)
            }
            let handshake = BridgeTestFixtures.handshake(
                negotiatedVersion: .init(major: 1, minor: minor),
                supportedOperations: [.captureScreen, .scroll, .targetedScroll, .invalidateImplicitLatestSnapshot],
                permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true),
                hostCapabilities: capabilities
            ).withProducerBoundSnapshotFixture()
            #expect(CommandRuntime.supportsRemoteRequirements(for: handshake, options: coordinate) ==
                (minor == 43 && hasCapability))
            #expect(CommandRuntime.supportsRemoteRequirements(for: handshake, options: element))
        }
    }

    @Test
    func `Background press requires process-generation-pinned Bridge hotkeys`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["a"], options: ["pid": ["42"]], flags: []),
            commandType: PressCommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["a"], options: [:], flags: ["foreground"]),
            commandType: PressCommand.self
        )
        let operations: [PeekabooBridgeOperation] = [
            .targetedHotkey,
            .invalidateImplicitLatestSnapshot,
        ]
        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 18),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations
        )
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationPinnedHotkeyVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            enabledOperations: operations
        )

        #expect(background.requiresProcessGenerationPinnedHotkeys)
        #expect(!foreground.requiresProcessGenerationPinnedHotkeys)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: background))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: background))
        #expect(CommandRuntime.supportsRemoteRequirements(for: legacy, options: foreground))
    }

    @Test
    func `Process-targeted input requires Bridge protocol 1_22 receipts`() throws {
        let type = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["hello"], options: ["app": ["TextEdit"]], flags: []),
            commandType: TypeCommand.self
        )
        let click = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: ["on": ["B1"]], flags: []),
            commandType: ClickCommand.self
        )
        let exactClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"], "windowId": ["42"], "app": ["TextEdit"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let paste = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["hello"], options: ["app": ["TextEdit"]], flags: []),
            commandType: PasteCommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: ["hello"], options: [:], flags: ["foreground"]),
            commandType: TypeCommand.self
        )
        let operations: [PeekabooBridgeOperation] = [
            .targetedHotkey,
            .targetedTypeActions,
            .targetedClick,
            .exactWindowTargetedClick,
            .invalidateImplicitLatestSnapshot,
        ]
        let legacy = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 21),
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: operations
        )
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.processGenerationPinnedInteractionVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: operations
        )
        let policyCapable = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: operations,
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery,
            ]
        )

        #expect(type.requiresProcessGenerationPinnedTypeActions)
        #expect(click.requiresProcessGenerationPinnedClicks)
        #expect(click.requiresTargetedClickAccessibilityValueDelivery)
        #expect(!exactClick.requiresProcessGenerationPinnedClicks)
        #expect(exactClick.requiresTargetedClickAccessibilityValueDelivery)
        #expect(paste.requiresProcessGenerationPinnedTypeActions)
        #expect(paste.requiresProcessGenerationPinnedHotkeys)
        #expect(!foreground.requiresProcessGenerationPinnedTypeActions)
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: type))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: click))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: paste))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: type))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: current, options: click))
        #expect(CommandRuntime.supportsRemoteRequirements(for: current, options: paste))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: legacy, options: exactClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: policyCapable, options: click))
        #expect(CommandRuntime.supportsRemoteRequirements(for: policyCapable, options: exactClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: legacy, options: foreground))
    }

    @Test
    func `Click delivery selects the permission required by its actual path`() throws {
        let coordinate = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let coordinateDouble = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: ["double"]
            ),
            commandType: ClickCommand.self
        )
        let coordinateRight = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: ["right"]
            ),
            commandType: ClickCommand.self
        )
        let unconsentedLongPress = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["longPress"]
            ),
            commandType: ClickCommand.self
        )
        let longPress = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["longPress", "foreground"]
            ),
            commandType: ClickCommand.self
        )
        let doubleClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["double"]
            ),
            commandType: ClickCommand.self
        )
        let singleClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: []
            ),
            commandType: ClickCommand.self
        )
        let rightClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["right"]
            ),
            commandType: ClickCommand.self
        )
        let conflictingVariants = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["double", "right"]
            ),
            commandType: ClickCommand.self
        )
        let foregroundCoordinate = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["at": ["10,20"]],
                flags: ["foreground"]
            ),
            commandType: ClickCommand.self
        )
        let foregroundDoubleClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["on": ["B1"]],
                flags: ["double", "foreground"]
            ),
            commandType: ClickCommand.self
        )

        #expect(!coordinate.requiresPostEventPermission)
        #expect(coordinateDouble.requiresPostEventPermission)
        #expect(coordinateRight.requiresPostEventPermission)
        #expect(!unconsentedLongPress.requiresPostEventPermission)
        #expect(!unconsentedLongPress.requiresLongPressClick)
        #expect(unconsentedLongPress.requiresAccessibilityPermission)
        #expect(longPress.requiresPostEventPermission)
        #expect(longPress.requiresLongPressClick)
        #expect(!longPress.requiresAccessibilityPermission)
        #expect(doubleClick.requiresPostEventPermission)
        #expect(!singleClick.requiresPostEventPermission)
        #expect(!rightClick.requiresPostEventPermission)
        #expect(conflictingVariants.requiresPostEventPermission)
        #expect(foregroundCoordinate.requiresPostEventPermission)
        #expect(foregroundDoubleClick.requiresPostEventPermission)
        #expect(coordinate.requiresAccessibilityPermission)
        #expect(singleClick.requiresAccessibilityPermission)
        #expect(!foregroundCoordinate.requiresAccessibilityPermission)

        let accessibilityOnly = Self.clickPermissionHandshake(postEvent: false)
        let fullyPermitted = Self.clickPermissionHandshake(postEvent: true)

        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: singleClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: rightClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: coordinate))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: doubleClick))
        #expect(!CommandRuntime.supportsRemoteRequirements(for: accessibilityOnly, options: foregroundCoordinate))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: coordinate))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: doubleClick))
        #expect(CommandRuntime.supportsRemoteRequirements(for: fullyPermitted, options: foregroundCoordinate))
    }

    private static func clickPermissionHandshake(postEvent: Bool) -> PeekabooBridgeHandshakeResponse {
        let operations: [PeekabooBridgeOperation] = [
            .captureScreen,
            .invalidateImplicitLatestSnapshot,
            .targetedClick,
        ]
        return BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.targetedClickAccessibilityValueDeliveryVersion,
            hostKind: .onDemand,
            build: nil,
            supportedOperations: operations,
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                postEvent: postEvent
            ),
            enabledOperations: operations,
            permissionTags: [PeekabooBridgeOperation.targetedClick.rawValue: []],
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.targetedClickAccessibilityValueDelivery,
            ]
        )
    }
}
