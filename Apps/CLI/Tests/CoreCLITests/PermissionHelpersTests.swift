import PeekabooBridge
import Testing
@testable import PeekabooCLI

struct PermissionHelpersTests {
    @Test
    func `permission bridge follows the runtime daemon socket`() {
        let paths = PermissionHelpers.remotePermissionSocketPaths(
            explicitSocket: nil,
            environment: ["PEEKABOO_DAEMON_SOCKET": "/tmp/custom-daemon.sock"]
        )

        #expect(paths == ["/tmp/custom-daemon.sock"])
    }

    @Test
    func `permission bridge includes the default legacy runtime fallback`() {
        let paths = PermissionHelpers.remotePermissionSocketPaths(
            explicitSocket: nil,
            environment: [:]
        )

        #expect(paths == [
            PeekabooBridgeConstants.daemonSocketPath,
            PeekabooBridgeConstants.peekabooSocketPath,
        ])
    }

    @Test
    func `permission bridge explicit socket overrides the daemon`() {
        let paths = PermissionHelpers.remotePermissionSocketPaths(
            explicitSocket: "/tmp/explicit.sock",
            environment: ["PEEKABOO_DAEMON_SOCKET": "/tmp/custom-daemon.sock"]
        )

        #expect(paths == ["/tmp/explicit.sock"])
    }

    @Test
    func `bridge hint explains remote screen recording denial`() {
        let response = PermissionHelpers.PermissionStatusResponse(
            source: "bridge",
            permissions: [
                PermissionHelpers.PermissionInfo(
                    name: "Screen Recording",
                    isRequired: true,
                    isGranted: false,
                    grantInstructions: "System Settings > Privacy & Security > Screen Recording"
                ),
                PermissionHelpers.PermissionInfo(
                    name: "Accessibility",
                    isRequired: true,
                    isGranted: true,
                    grantInstructions: "System Settings > Privacy & Security > Accessibility"
                ),
            ]
        )

        let hint = PermissionHelpers.bridgeScreenRecordingHint(for: response)

        #expect(hint?.contains("selected Peekaboo Bridge host") == true)
        #expect(hint?.contains("--no-remote --capture-engine cg") == true)
    }

    @Test
    func `bridge hint stays quiet for local screen recording denial`() {
        let response = PermissionHelpers.PermissionStatusResponse(
            source: "local",
            permissions: [
                PermissionHelpers.PermissionInfo(
                    name: "Screen Recording",
                    isRequired: true,
                    isGranted: false,
                    grantInstructions: "System Settings > Privacy & Security > Screen Recording"
                ),
            ]
        )

        #expect(PermissionHelpers.bridgeScreenRecordingHint(for: response) == nil)
    }
}
