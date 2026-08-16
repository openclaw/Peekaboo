// Space (Virtual Desktop) Management Utilities
//
// This file provides utilities for managing macOS Spaces (virtual desktops) using
// private CoreGraphics APIs. These APIs enable advanced window management features
// that are not available through public frameworks.
//
// ## \(AgentDisplayTokens.Status.warning) Important Warning
//
// This implementation relies on private CGS (CoreGraphics Services) APIs that:
// - Are undocumented and unsupported by Apple
// - May change or break between macOS versions
// - Could cause crashes if used incorrectly
// - May require special entitlements in the future
//
// ## Key Features
//
// 1. **Space Information**: List all Spaces and their properties
// 2. **Space Navigation**: Switch between Spaces programmatically
// 3. **Window Movement**: Move windows between Spaces
// 4. **Space Detection**: Find which Space contains a window
//
// ## Requirements (macOS 15 Sequoia+)
//
// - Screen Recording permission (for CGSCopySpacesForWindows)
// - Accessibility permission (for window manipulation)
// - Must be called from main thread
// - NSApplication must be initialized
//
// ## Usage Examples
//
// ```swift
// let service = SpaceManagementService()
//
// // List all Spaces
// let spaces = service.getAllSpaces()
// for space in spaces {
//     print("Space \(space.id): \(space.type) - Active: \(space.isActive)")
// }
//
// // Switch to a Space
// try await service.switchToSpace(spaceNumber: 2)
//
// // Move window to current Space
// try service.moveWindowToCurrentSpace(windowID: 1234)
// ```
//
// ## References
//
// - Based on reverse-engineered CGS APIs
// - Similar implementations: yabai, Amethyst, Rectangle
// - No official documentation available

import AppKit
@preconcurrency import CoreFoundation
import Foundation
import PeekabooFoundation

// MARK: - Space Management Service

@MainActor
public final class SpaceManagementService {
    private var _connection: CGSConnectionID?
    private let feedbackClient: any AutomationFeedbackClient

    private var connection: CGSConnectionID {
        if self._connection == nil {
            // We're guaranteed to be on main thread due to @MainActor

            // Initialize NSApplication if needed
            _ = NSApplication.shared

            self._connection = _CGSDefaultConnection()

            // Verify we got a valid connection
            if self._connection == 0 {
                print("WARNING: Failed to get CGS connection")
            }
        }
        return self._connection!
    }

    public init(feedbackClient: any AutomationFeedbackClient = NoopAutomationFeedbackClient()) {
        self.feedbackClient = feedbackClient
        // Defer connection initialization until first use
        Task { @MainActor in
            self.feedbackClient.connect()
        }
    }

    // MARK: - Space Information

    /// Get information about all Spaces
    public func getAllSpaces() -> [SpaceInfo] {
        // Check if we have a valid connection
        guard self.connection != 0 else {
            print("ERROR: Invalid CGS connection")
            return []
        }

        guard let spacesRef = CGSCopySpaces(connection, kCGSAllSpacesMask) else {
            print("ERROR: CGSCopySpaces returned nil")
            return []
        }

        // Try to interpret the result as an array
        let spacesArray = spacesRef as NSArray
        let activeSpace = CGSGetActiveSpace(connection)

        var spaces: [SpaceInfo] = []

        // Handle both array of IDs and array of dictionaries
        for element in spacesArray {
            var spaceID: CGSSpaceID?

            if let id = element as? Int {
                // Direct space ID
                spaceID = CGSSpaceID(id)
            } else if let dict = element as? [String: Any] {
                // Dictionary with space info - try different keys
                if let id = dict["ManagedSpaceID"] as? Int {
                    spaceID = CGSSpaceID(id)
                } else if let id = dict["id64"] as? Int {
                    spaceID = CGSSpaceID(id)
                } else if let id = dict["id"] as? Int {
                    spaceID = CGSSpaceID(id)
                }
            }

            guard let validSpaceID = spaceID else { continue }

            let spaceType = CGSSpaceGetType(connection, validSpaceID)
            let type: SpaceInfo.SpaceType = switch spaceType {
            case kCGSSpaceUser: .user
            case kCGSSpaceFullscreen: .fullscreen
            case kCGSSpaceSystem: .system
            case kCGSSpaceTiled: .tiled
            default: .unknown
            }

            // Get additional space information
            let spaceName = CGSSpaceCopyName(connection, validSpaceID) as String?
            let ownerPIDsArray = CGSSpaceCopyOwners(connection, validSpaceID) as? [Int] ?? []

            spaces.append(SpaceInfo(
                id: validSpaceID,
                type: type,
                isActive: validSpaceID == activeSpace,
                displayID: nil,
                name: spaceName,
                ownerPIDs: ownerPIDsArray))
        }

        return spaces
    }

    /// Get information about all Spaces organized by display
    public func getAllSpacesByDisplay() -> [CGDirectDisplayID: [SpaceInfo]] {
        guard self.connection != 0 else {
            print("ERROR: Invalid CGS connection")
            return [:]
        }

        let managedSpacesRef = CGSCopyManagedDisplaySpaces(connection)
        let managedSpacesArray = managedSpacesRef as NSArray
        let activeSpace = CGSGetActiveSpace(connection)

        return buildSpacesByDisplay(
            managedSpaces: managedSpacesArray,
            activeSpace: activeSpace)
    }

    /// Get the current active Space
    public func getCurrentSpace() -> SpaceInfo? {
        // Check if we have a valid connection
        guard self.connection != 0 else {
            print("ERROR: Invalid CGS connection")
            return nil
        }

        let activeSpaceID = CGSGetActiveSpace(connection)
        guard activeSpaceID != 0 else {
            // Failed to get active Space
            return nil
        }

        let spaceType = CGSSpaceGetType(connection, activeSpaceID)
        let type: SpaceInfo.SpaceType = switch spaceType {
        case kCGSSpaceUser: .user
        case kCGSSpaceFullscreen: .fullscreen
        case kCGSSpaceSystem: .system
        case kCGSSpaceTiled: .tiled
        default: .unknown
        }

        // Get additional space information
        let spaceName = CGSSpaceCopyName(connection, activeSpaceID) as String?
        let ownerPIDsArray = CGSSpaceCopyOwners(connection, activeSpaceID) as? [Int] ?? []
        let displayID: CGDirectDisplayID? = nil // Simplified for now

        return SpaceInfo(
            id: activeSpaceID,
            type: type,
            isActive: true,
            displayID: displayID,
            name: spaceName,
            ownerPIDs: ownerPIDsArray)
    }

    /// Get Spaces that contain a specific window
    public func getSpacesForWindow(windowID: CGWindowID) -> [SpaceInfo] {
        // Check if we have a valid connection
        guard self.connection != 0 else {
            print("ERROR: Invalid CGS connection")
            return []
        }

        let windowArray = [windowID] as CFArray

        guard let spacesRef = CGSCopySpacesForWindows(connection, kCGSAllSpacesMask, windowArray) else {
            // Failed to get Spaces for window
            return []
        }

        // Try to interpret the result as an array
        let spacesArray = spacesRef as NSArray
        let activeSpace = CGSGetActiveSpace(connection)

        var spaces: [SpaceInfo] = []

        // Handle both array of IDs and array of dictionaries
        for element in spacesArray {
            var spaceID: CGSSpaceID?

            if let id = element as? Int {
                // Direct space ID
                spaceID = CGSSpaceID(id)
            } else if let dict = element as? [String: Any] {
                // Dictionary with space info - try different keys
                if let id = dict["ManagedSpaceID"] as? Int {
                    spaceID = CGSSpaceID(id)
                } else if let id = dict["id64"] as? Int {
                    spaceID = CGSSpaceID(id)
                } else if let id = dict["id"] as? Int {
                    spaceID = CGSSpaceID(id)
                }
            }

            guard let validSpaceID = spaceID else { continue }

            let spaceType = CGSSpaceGetType(connection, validSpaceID)
            let type: SpaceInfo.SpaceType = switch spaceType {
            case kCGSSpaceUser: .user
            case kCGSSpaceFullscreen: .fullscreen
            case kCGSSpaceSystem: .system
            case kCGSSpaceTiled: .tiled
            default: .unknown
            }

            // Get additional space information
            let spaceName = CGSSpaceCopyName(connection, validSpaceID) as String?
            let ownerPIDsArray = CGSSpaceCopyOwners(connection, validSpaceID) as? [Int] ?? []

            spaces.append(SpaceInfo(
                id: validSpaceID,
                type: type,
                isActive: validSpaceID == activeSpace,
                displayID: nil,
                name: spaceName,
                ownerPIDs: ownerPIDsArray))
        }

        return spaces
    }

    // MARK: - Space Switching

    private static let switchDelivery = DesktopActionOutcome.Delivery(
        mechanism: .nativeFramework,
        mode: .foreground)

    /// Switch to a specific Space and return the canonical native dispatch outcome.
    public func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void> {
        if CGSGetActiveSpace(self.connection) == spaceID {
            return DesktopActionResult(outcome: .confirmedNoChange())
        }

        try Task.checkCancellation()
        CGSManagedDisplaySetCurrentSpace(self.connection, kCGSPackagesMainDisplayIdentifier, spaceID)

        do {
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: Self.switchDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Space switch was dispatched, but post-dispatch settling failed.",
                hint: "Observe the active Space before retrying; replaying may switch away from the intended desktop.",
                causeDescription: error.localizedDescription)
        }

        return DesktopActionResult(
            outcome: .dispatchedUnverified(
                delivery: Self.switchDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one))
    }

    /// Switch to a specific Space
    public func switchToSpace(_ spaceID: CGSSpaceID) async throws {
        _ = try await self.switchToSpaceResult(spaceID)
    }

    /// Switch to the Space containing a specific window
    public func switchToWindowSpace(windowID: CGWindowID) async throws {
        // Switch to the Space containing a specific window
        let spaces = self.getSpacesForWindow(windowID: windowID)

        guard let targetSpace = spaces.first else {
            throw SpaceError.windowNotInAnySpace(windowID)
        }

        // If already on the correct Space, no need to switch
        if targetSpace.isActive {
            // Window is already on active Space
            return
        }

        try await self.switchToSpace(targetSpace.id)
    }

    /// Switch to the Space containing one generation-pinned exact window.
    public func switchToWindowSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        let connection = self.connection
        return try await SpaceWindowMutationDispatcher.switchToWindowSpace(
            windowID: windowID,
            expectedIdentity: expectedIdentity,
            backend: .init(
                destinationExists: { destination in
                    self.getAllSpaces().contains { $0.id == destination }
                },
                validateIdentity: SystemIdentityResolver.validateWindowMutationIdentity,
                spaceIDsForWindow: {
                    self.getSpacesForWindow(windowID: windowID).map(\.id)
                },
                activeSpaceID: { CGSGetActiveSpace(connection) },
                setCurrentSpace: { destination in
                    CGSManagedDisplaySetCurrentSpace(
                        connection,
                        kCGSPackagesMainDisplayIdentifier,
                        destination)
                },
                settle: {
                    try await Task.sleep(nanoseconds: 300_000_000)
                }))
    }

    // MARK: - Window Information

    /// Get the window level (z-order) for a window
    public func getWindowLevel(windowID: CGWindowID) -> Int32? {
        // Check if we have a valid connection
        guard self.connection != 0 else {
            print("ERROR: Invalid CGS connection")
            return nil
        }

        // Get the window level
        var level: CGWindowLevel = 0
        let error = CGSGetWindowLevel(connection, windowID, &level)

        // Check for error
        if error != .success {
            return nil
        }

        return level
    }

    // MARK: - Window Movement

    /// Move a window to a specific Space
    public func moveWindowToSpace(windowID: CGWindowID, spaceID: CGSSpaceID) throws {
        // Move a window to a specific Space
        let windowArray = [windowID] as CFArray
        let spaceArray = [spaceID] as CFArray

        // First, get current Spaces for the window
        let currentSpaces = self.getSpacesForWindow(windowID: windowID)

        // Remove from current Spaces
        if !currentSpaces.isEmpty {
            let currentSpaceIDs = currentSpaces.map(\.id) as CFArray
            CGSRemoveWindowsFromSpaces(self.connection, windowArray, currentSpaceIDs)
        }

        // Add to target Space
        CGSAddWindowsToSpaces(self.connection, windowArray, spaceArray)

        // Moved window to Space
    }

    /// Move one generation-pinned exact window to a specific Space.
    ///
    /// The destination is established and verified before prior memberships are removed, then the
    /// final exact membership is verified before this method reports a confirmed change.
    public func moveWindowToSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        spaceID: CGSSpaceID) throws -> UIAutomationActionResult<Void>
    {
        let connection = self.connection
        let windowArray = [windowID] as CFArray
        let targetSpaceArray = [spaceID] as CFArray

        return try SpaceWindowMutationDispatcher.moveWindow(
            windowID: windowID,
            expectedIdentity: expectedIdentity,
            targetSpaceID: spaceID,
            backend: .init(
                destinationExists: { destination in
                    self.getAllSpaces().contains { $0.id == destination }
                },
                validateIdentity: SystemIdentityResolver.validateWindowMutationIdentity,
                spaceIDsForWindow: {
                    self.getSpacesForWindow(windowID: windowID).map(\.id)
                },
                removeWindows: { sourceSpaceIDs in
                    CGSRemoveWindowsFromSpaces(connection, windowArray, sourceSpaceIDs as CFArray)
                },
                addWindow: { _ in
                    CGSAddWindowsToSpaces(connection, windowArray, targetSpaceArray)
                }))
    }

    /// Move a window to the current Space
    public func moveWindowToCurrentSpace(windowID: CGWindowID) throws {
        // Move a window to the current Space
        guard let currentSpace = getCurrentSpace() else {
            throw SpaceError.failedToGetCurrentSpace
        }

        try self.moveWindowToSpace(windowID: windowID, spaceID: currentSpace.id)
    }

    /// Move one generation-pinned exact window to the current Space.
    public func moveWindowToCurrentSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity) throws -> UIAutomationActionResult<Void>
    {
        guard let currentSpace = getCurrentSpace() else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Could not resolve the current Space before moving the window.",
                hint: "Refresh the Space inventory before retrying.")
        }

        return try self.moveWindowToSpaceResult(
            windowID: windowID,
            expectedIdentity: expectedIdentity,
            spaceID: currentSpace.id)
    }
}
