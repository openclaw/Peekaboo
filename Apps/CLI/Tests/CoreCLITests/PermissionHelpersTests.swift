import PeekabooBridge
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct PermissionHelpersTests {
    @Test
    @MainActor
    func `interactive permission request marks mutation before execution and invalidates latest`() async throws {
        let snapshots = InMemorySnapshotManager()
        let explicitSnapshot = try await snapshots.createSnapshot()
        let tracker = InteractionMutationTracker()
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: true,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: PeekabooServices(snapshotManager: snapshots),
            interactionMutationTracker: tracker
        )
        var mutationWasMarkedBeforeRequest = false

        let result = try await CommanderRuntimeExecutor.runWithImplicitSnapshotInvalidation(
            using: runtime,
            required: true
        ) {
            await PermissionHelpers.performInteractivePermissionRequest(using: runtime) {
                mutationWasMarkedBeforeRequest = tracker.mutationStartedAt != nil
                return 42
            }
        }

        #expect(result == 42)
        #expect(mutationWasMarkedBeforeRequest)
        #expect(await snapshots.getMostRecentSnapshot() == nil)
        #expect(try await snapshots.listSnapshots().map(\.id) == [explicitSnapshot])
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

        let hint = PermissionHelpers.bridgeDeniedPermissionsHint(for: response)

        #expect(hint?.contains("selected Peekaboo Bridge host") == true)
        #expect(hint?.contains("--no-remote --capture-engine cg") == true)
    }

    @Test
    func `bridge hint explains remote event synthesizing denial`() {
        let response = PermissionHelpers.PermissionStatusResponse(
            source: "bridge",
            permissions: [
                PermissionHelpers.PermissionInfo(
                    name: "Screen Recording",
                    isRequired: true,
                    isGranted: true,
                    grantInstructions: "System Settings > Privacy & Security > Screen Recording"
                ),
                PermissionHelpers.PermissionInfo(
                    name: "Event Synthesizing",
                    isRequired: false,
                    isGranted: false,
                    grantInstructions: "System Settings > Privacy & Security > Accessibility"
                ),
            ]
        )

        let hint = PermissionHelpers.bridgeDeniedPermissionsHint(for: response)

        // The whole point: a bridge-sourced denial must say the grant belongs to the host app,
        // because granting the CLI or the terminal leaves the status unchanged.
        #expect(hint?.contains("Event Synthesizing") == true)
        #expect(hint?.contains("host app") == true)
        #expect(hint?.contains("--no-remote") == true)
        // Capture-only advice must not leak into a non-capture denial.
        #expect(hint?.contains("--capture-engine cg") == false)
    }

    @Test
    func `bridge hint stays quiet when every permission is granted`() {
        let response = PermissionHelpers.PermissionStatusResponse(
            source: "bridge",
            permissions: [
                PermissionHelpers.PermissionInfo(
                    name: "Screen Recording",
                    isRequired: true,
                    isGranted: true,
                    grantInstructions: "System Settings > Privacy & Security > Screen Recording"
                ),
            ]
        )

        #expect(PermissionHelpers.bridgeDeniedPermissionsHint(for: response) == nil)
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

        #expect(PermissionHelpers.bridgeDeniedPermissionsHint(for: response) == nil)
    }
}
