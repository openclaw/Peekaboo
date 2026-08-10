import CoreGraphics
import Foundation
import PeekabooAutomationKit

private enum DesktopReadLaneResolution {
    case lane(scope: DesktopOperationScope, access: DesktopOperationAccess, validatesIdentity: Bool)
    case exactIdentityUnavailable
}

extension PeekabooBridgeServer {
    func validatedDesktopReadOperationLane(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess))
        -> (scope: DesktopOperationScope, access: DesktopOperationAccess)
    {
        switch self.desktopReadLaneResolution(for: request, proposed: proposed) {
        case let .lane(scope, access, validatesIdentity):
            if validatesIdentity, !self.desktopReadScopeIsCurrent(scope) {
                return (.global, .write)
            }
            return (scope, access)
        case .exactIdentityUnavailable:
            return (.global, .write)
        }
    }

    func withValidatedDesktopReadOperationLane<T: Sendable>(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess),
        operation: () async throws -> T) async throws -> T
    {
        try await self.withValidatedDesktopReadOperationLane(
            for: request,
            proposed: proposed)
        { _ in
            try await operation()
        }
    }

    private func withValidatedDesktopReadOperationLane<T: Sendable>(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess),
        operation: (DesktopOperationScope) async throws -> T) async throws -> T
    {
        let resolution = self.desktopReadLaneResolution(for: request, proposed: proposed)
        guard case let .lane(scope, access, validatesIdentity) = resolution else {
            throw Self.exactDesktopReadTargetChangedError()
        }
        return try await self.desktopOperationLaneCoordinator.run(scope: scope, access: access) {
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            if validatesIdentity, !self.desktopReadScopeIsCurrent(scope) {
                throw Self.exactDesktopReadTargetChangedError()
            }
            let result = try await operation(scope)
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            if validatesIdentity, !self.desktopReadScopeIsCurrent(scope) {
                throw Self.exactDesktopReadTargetChangedError()
            }
            return result
        }
    }

    private func desktopReadLaneResolution(
        for request: PeekabooBridgeRequest,
        proposed: (scope: DesktopOperationScope, access: DesktopOperationAccess)) -> DesktopReadLaneResolution
    {
        if let exactScope = self.exactDesktopReadScope(for: request) {
            return .lane(scope: exactScope, access: .read, validatesIdentity: true)
        }
        if self.requiresExactDesktopReadIdentity(request) {
            return .exactIdentityUnavailable
        }
        return .lane(scope: proposed.scope, access: proposed.access, validatesIdentity: false)
    }

    private func exactDesktopReadScope(for request: PeekabooBridgeRequest) -> DesktopOperationScope? {
        if let identity = request.exactWindowReadIdentity {
            return .window(identity)
        }

        switch request {
        case let .captureWindow(payload):
            if let rawWindowID = payload.windowId,
               let windowID = CGWindowID(exactly: rawWindowID)
            {
                return self.currentExactWindowReadScope(windowID: windowID)
            }
            guard let processIdentifier = Self.explicitProcessIdentifier(payload.appIdentifier) else {
                return nil
            }
            return self.currentExactProcessReadScope(processIdentifier: processIdentifier)
        case let .desktopObservation(observation):
            switch observation.target {
            case let .windowID(windowID):
                return self.currentExactWindowReadScope(windowID: windowID)
            case let .pid(processIdentifier, selection):
                if case let .id(windowID)? = selection {
                    guard case let .window(identity)? = self.currentExactWindowReadScope(windowID: windowID),
                          identity.ownerProcessIdentifier == processIdentifier
                    else {
                        return nil
                    }
                    return .window(identity)
                }
                return self.currentExactProcessReadScope(processIdentifier: processIdentifier)
            case let .app(_, selection):
                guard case let .id(windowID)? = selection else { return nil }
                return self.currentExactWindowReadScope(windowID: windowID)
            case .allScreens, .area, .frontmost, .menubar, .menubarPopover, .screen:
                return nil
            }
        default:
            return nil
        }
    }

    private func requiresExactDesktopReadIdentity(_ request: PeekabooBridgeRequest) -> Bool {
        if request.exactWindowReadIdentity != nil {
            return true
        }
        switch request {
        case let .captureWindow(payload):
            return payload.windowId != nil || Self.explicitProcessIdentifier(payload.appIdentifier) != nil
        case let .desktopObservation(observation):
            return switch observation.target {
            case .pid, .windowID:
                true
            case let .app(_, selection):
                if case .id? = selection {
                    true
                } else {
                    false
                }
            case .allScreens, .area, .frontmost, .menubar, .menubarPopover, .screen:
                false
            }
        default:
            return false
        }
    }

    private func currentExactProcessReadScope(processIdentifier: pid_t) -> DesktopOperationScope? {
        guard processIdentifier > 0,
              let processStartIdentity = self.processStartIdentityProvider(processIdentifier),
              self.processStartIdentityProvider(processIdentifier) == processStartIdentity
        else {
            return nil
        }
        return .process(ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity))
    }

    private func currentExactWindowReadScope(windowID: CGWindowID) -> DesktopOperationScope? {
        guard windowID != kCGNullWindowID,
              let ownerProcessIdentifier = self.windowOwnerProcessIdentifierProvider(windowID),
              ownerProcessIdentifier > 0,
              let bounds = self.windowBoundsProvider(windowID),
              let processStartIdentity = self.processStartIdentityProvider(ownerProcessIdentifier),
              self.windowOwnerProcessIdentifierProvider(windowID) == ownerProcessIdentifier,
              self.windowBoundsProvider(windowID) == bounds,
              self.processStartIdentityProvider(ownerProcessIdentifier) == processStartIdentity
        else {
            return nil
        }
        return .window(WindowMutationIdentity(
            windowID: Int(windowID),
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds))
    }

    private func desktopReadScopeIsCurrent(_ scope: DesktopOperationScope) -> Bool {
        switch scope {
        case .global:
            return true
        case let .process(identity):
            return self.processStartIdentityProvider(identity.processIdentifier) == identity.processStartIdentity
        case let .window(identity):
            guard let windowID = CGWindowID(exactly: identity.windowID),
                  let capturedBounds = identity.capturedBounds
            else {
                return false
            }
            return self.windowOwnerProcessIdentifierProvider(windowID) == identity.ownerProcessIdentifier &&
                self.windowBoundsProvider(windowID) == capturedBounds &&
                self.processStartIdentityProvider(identity.ownerProcessIdentifier) ==
                identity.ownerProcessStartIdentity
        }
    }

    private static func explicitProcessIdentifier(_ identifier: String) -> pid_t? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("PID:"),
              let processIdentifier = pid_t(trimmed.dropFirst("PID:".count)),
              processIdentifier > 0
        else {
            return nil
        }
        return processIdentifier
    }

    private static func exactDesktopReadTargetChangedError() -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "The exact desktop read target changed owner, process generation, or bounds before completion")
    }
}
