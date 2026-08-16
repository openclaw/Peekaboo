import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

struct RemoteSpaceReadUnsupportedError: LocalizedError, ResultEnvelopeError {
    let operation: String

    nonisolated var errorDescription: String? {
        "Cannot \(self.operation) because the selected execution host is remote and remote Space support is " +
            "not implemented. No caller-local Space inventory was read."
    }

    nonisolated var envelopeCode: ErrorCode? {
        .BRIDGE_UNAVAILABLE
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeHint: String? {
        "Re-run with --no-remote to select the caller-local host."
    }
}

enum SpaceCommandHostOwnership {
    static func requireLocalRead(
        services: any PeekabooServiceProviding,
        operation: String
    ) throws {
        guard services.executionHost == .local else {
            throw RemoteSpaceReadUnsupportedError(operation: operation)
        }
    }

    static func requireLocalMutation(
        services: any PeekabooServiceProviding,
        operation: String
    ) throws {
        guard services.executionHost == .local else {
            throw PreDispatchActionError(
                message: "Cannot \(operation) because the selected execution host is remote and remote Space " +
                    "support is not implemented. No caller-local Space inventory or mutation was attempted.",
                code: .BRIDGE_UNAVAILABLE,
                hint: "Re-run with --no-remote to select the caller-local host.",
                reason: .operationUnsupported
            )
        }
    }
}

protocol SpaceCommandSpaceService: Sendable {
    func getAllSpaces() async -> [SpaceInfo]
    func getSpacesForWindow(windowID: CGWindowID) async -> [SpaceInfo]
    func moveWindowToCurrentSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void>
    func moveWindowToSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        spaceID: CGSSpaceID
    ) async throws -> UIAutomationActionResult<Void>
    func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void>
}

enum SpaceCommandEnvironment {
    @TaskLocal
    private static var override: (any SpaceCommandSpaceService)?

    static var service: any SpaceCommandSpaceService {
        self.override ?? LiveSpaceService.shared
    }

    static func withSpaceService<T>(
        _ service: any SpaceCommandSpaceService,
        perform operation: () async throws -> T
    ) async rethrows -> T {
        try await self.$override.withValue(service) {
            try await operation()
        }
    }

    private final class LiveSpaceService: SpaceCommandSpaceService {
        static let shared = LiveSpaceService()
        @MainActor private static let actor = SpaceManagementActor()

        private init() {}

        func getAllSpaces() async -> [SpaceInfo] {
            await MainActor.run {
                Self.actor.getAllSpaces()
            }
        }

        func getSpacesForWindow(windowID: CGWindowID) async -> [SpaceInfo] {
            await MainActor.run {
                Self.actor.getSpacesForWindow(windowID: windowID)
            }
        }

        func moveWindowToCurrentSpaceResult(
            windowID: CGWindowID,
            expectedIdentity: WindowMutationIdentity
        ) async throws -> UIAutomationActionResult<Void> {
            try await MainActor.run {
                try Self.actor.moveWindowToCurrentSpaceResult(
                    windowID: windowID,
                    expectedIdentity: expectedIdentity
                )
            }
        }

        func moveWindowToSpaceResult(
            windowID: CGWindowID,
            expectedIdentity: WindowMutationIdentity,
            spaceID: CGSSpaceID
        ) async throws -> UIAutomationActionResult<Void> {
            try await MainActor.run {
                try Self.actor.moveWindowToSpaceResult(
                    windowID: windowID,
                    expectedIdentity: expectedIdentity,
                    spaceID: spaceID
                )
            }
        }

        func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void> {
            try await Self.actor.switchToSpaceResult(spaceID)
        }
    }

    @MainActor
    private final class SpaceManagementActor {
        private let inner = SpaceManagementService(feedbackClient: VisualizerAutomationFeedbackClient())

        func getAllSpaces() -> [SpaceInfo] {
            self.inner.getAllSpaces()
        }

        func getSpacesForWindow(windowID: CGWindowID) -> [SpaceInfo] {
            self.inner.getSpacesForWindow(windowID: windowID)
        }

        func moveWindowToCurrentSpaceResult(
            windowID: CGWindowID,
            expectedIdentity: WindowMutationIdentity
        ) throws -> UIAutomationActionResult<Void> {
            try self.inner.moveWindowToCurrentSpaceResult(
                windowID: windowID,
                expectedIdentity: expectedIdentity
            )
        }

        func moveWindowToSpaceResult(
            windowID: CGWindowID,
            expectedIdentity: WindowMutationIdentity,
            spaceID: CGSSpaceID
        ) throws -> UIAutomationActionResult<Void> {
            try self.inner.moveWindowToSpaceResult(
                windowID: windowID,
                expectedIdentity: expectedIdentity,
                spaceID: spaceID
            )
        }

        func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void> {
            try await self.inner.switchToSpaceResult(spaceID)
        }
    }
}

/// Manage macOS Spaces (virtual desktops)
@MainActor
struct SpaceCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "space",
        abstract: "Manage macOS Spaces (virtual desktops)",
        discussion: """
        SYNOPSIS:
          peekaboo space SUBCOMMAND [OPTIONS]

        DESCRIPTION:
          Provides Space (virtual desktop) management capabilities including
          listing Spaces, switching between them, and moving windows.

        EXAMPLES:
          # List all Spaces
          peekaboo space list

          # Switch to Space 2
          peekaboo space switch --to 2 --foreground

          # Move window to Space 3
          peekaboo space move-window --app Safari --to 3

          # Move window to current Space
          peekaboo space move-window --app Terminal --to-current

          # Move a window and intentionally follow it to Space 3
          peekaboo space move-window --app Safari --to 3 --follow --foreground

        SUBCOMMANDS:
          list          List all Spaces and their windows
          switch        Switch to a different Space
          move-window   Move a window to a different Space

        NOTE:
          Space management uses private macOS APIs that may change between
          macOS versions. Some features may not work on all systems.
        """,
        subcommands: [
            ListSubcommand.self,
            SwitchSubcommand.self,
            MoveWindowSubcommand.self,
        ],
        showHelpOnEmptyInvocation: true
    )
}

// MARK: - Response Types

struct SpaceListData: Codable {
    let spaces: [SpaceData]
}

struct SpaceData: Codable {
    let id: UInt64
    let type: String
    let is_active: Bool
    let display_id: CGDirectDisplayID?
}

struct SpaceActionResult: Codable {
    let action: String
    let success: Bool
    let space_id: UInt64
    let space_number: Int
}

struct WindowSpaceActionResult: Codable {
    let action: String
    let success: Bool
    let window_id: CGWindowID
    let window_title: String
    let space_id: UInt64?
    let space_number: Int?
    let moved_to_current: Bool?
    let followed: Bool?
}
