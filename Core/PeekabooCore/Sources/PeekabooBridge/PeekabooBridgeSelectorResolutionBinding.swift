import CoreGraphics
import Foundation
import PeekabooAutomationKit

/// Shared request-to-resolution-proof validation used by live signing and offline receipt verification.
enum PeekabooBridgeSelectorResolutionBinding {
    static func applicationMismatch(
        identifier: String,
        application: ServiceApplicationInfo,
        expectedWindowIdentity: WindowMutationIdentity? = nil,
        proofs: [SelectorResolutionProof]?,
        requireProof: Bool) -> String?
    {
        guard let proofs, !proofs.isEmpty else {
            return requireProof ? "missing application selector proof" : nil
        }
        guard proofs.count <= 2,
              proofs.first?.scope == .application,
              proofs.dropFirst().allSatisfy({ $0.scope == .window }),
              proofs.count(where: { $0.scope == .application }) == 1,
              proofs.count(where: { $0.scope == .window }) <= 1,
              let applicationProof = proofs.first
        else {
            return "application selector proof order"
        }
        let candidate = ApplicationIdentifierMatcher.Candidate(application)
        if let mismatch = applicationProof.applicationMismatch(
            identifier: identifier,
            selectedCandidate: candidate,
            processIdentity: application.processIdentity,
            windowIdentity: expectedWindowIdentity)
        {
            return "application \(mismatch)"
        }
        return nil
    }

    static func windowMismatch(
        selection: WindowSelection,
        application: ServiceApplicationInfo,
        window: ServiceWindowInfo,
        proofs: [SelectorResolutionProof]?,
        requireProof: Bool) -> String?
    {
        guard let proofs else { return requireProof ? "missing window selector proof" : nil }
        guard let windowProof = proofs.first(where: { $0.scope == .window }) else {
            return requireProof ? "missing window selector proof" : nil
        }
        if let mismatch = windowProof.windowMismatch(
            selection: selection,
            selectedWindow: window,
            processIdentity: application.processIdentity)
        {
            return "window \(mismatch)"
        }
        return nil
    }

    static func captureMismatch(
        request: PeekabooBridgeRequest,
        result: CaptureResult,
        requireProof: Bool) -> String?
    {
        guard case let .captureWindow(payload) = request,
              payload.windowId == nil
        else {
            return nil
        }
        guard let application = result.metadata.applicationInfo else {
            return requireProof ? "missing application selector proof" : nil
        }
        guard let window = result.metadata.windowInfo else {
            return requireProof ? "missing window selector proof" : nil
        }
        let identifier = ApplicationIdentifierMatcher.normalized(payload.appIdentifier)
        if let mismatch = self.applicationMismatch(
            identifier: identifier,
            application: application,
            expectedWindowIdentity: window.mutationIdentity,
            proofs: result.metadata.selectorResolutionProofs,
            requireProof: requireProof)
        {
            return mismatch
        }
        let selection = payload.windowIndex.map(WindowSelection.index) ?? .automatic
        return self.windowMismatch(
            selection: selection,
            application: application,
            window: window,
            proofs: result.metadata.selectorResolutionProofs,
            requireProof: requireProof)
    }

    static func observationMismatch(
        request: DesktopObservationRequest,
        result: DesktopObservationResult,
        requireProof: Bool) -> String?
    {
        guard let app = result.target.app else {
            guard requireProof else { return nil }
            return switch request.target {
            case .app: "missing application selector proof"
            case .pid: "PID selector process"
            case .allScreens, .area, .frontmost, .menubar, .menubarPopover, .screen, .windowID: nil
            }
        }
        let application = ServiceApplicationInfo(
            processIdentifier: app.processIdentifier,
            processStartIdentity: app.processStartIdentity,
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            bundlePath: app.bundlePath,
            executablePath: app.executablePath,
            activationPolicy: app.activationPolicy,
            selectorResolutionProofs: app.selectorResolutionProofs)
        let windowIdentity = result.target.detectionContext?.windowMutationIdentity ??
            result.capture.metadata.windowInfo?.mutationIdentity
        let requiresWindowProof = requireProof && request.target.exactWindowID == nil
        let windowSelection: WindowSelection?
        switch request.target {
        case let .app(identifier, selection):
            if let mismatch = self.applicationMismatch(
                identifier: identifier,
                application: application,
                expectedWindowIdentity: windowIdentity,
                proofs: result.target.selectorResolutionProofs,
                requireProof: requireProof)
            {
                return mismatch
            }
            windowSelection = selection
        case let .pid(processIdentifier, selection):
            guard application.processIdentifier == processIdentifier else {
                return "PID selector process"
            }
            if requireProof {
                let proofs = result.target.selectorResolutionProofs ?? []
                if requiresWindowProof {
                    guard proofs.count == 1,
                          proofs.first?.scope == .window
                    else {
                        return "PID window selector proof order"
                    }
                } else {
                    guard proofs.count <= 1,
                          proofs.allSatisfy({ $0.scope == .window })
                    else {
                        return "PID window selector proof order"
                    }
                }
            }
            windowSelection = selection
        case .allScreens, .area, .frontmost, .menubar, .menubarPopover, .screen, .windowID:
            return nil
        }
        guard let window = result.target.window,
              let windowIdentity
        else {
            return nil
        }
        let selection = windowSelection ?? .automatic
        let serviceWindow = ServiceWindowInfo(
            windowID: window.windowID,
            title: window.title,
            bounds: window.bounds,
            index: window.index,
            mutationIdentity: windowIdentity)
        return self.windowMismatch(
            selection: selection,
            application: application,
            window: serviceWindow,
            proofs: result.target.selectorResolutionProofs,
            requireProof: requiresWindowProof)
    }

    static func dialogMismatch(
        selector: DialogTargetSelector,
        evidence: ResolvedDialogTargetEvidence,
        requireProof: Bool) -> String?
    {
        let application = ServiceApplicationInfo(
            processIdentifier: evidence.target.identity.ownerProcessIdentifier,
            processStartIdentity: evidence.target.identity.ownerProcessStartIdentity,
            bundleIdentifier: evidence.applicationBundleIdentifier,
            name: evidence.applicationName,
            bundlePath: evidence.applicationBundlePath,
            executablePath: evidence.applicationExecutablePath,
            activationPolicy: evidence.applicationActivationPolicy)
        if let identifier = selector.applicationIdentifier,
           let mismatch = self.applicationMismatch(
               identifier: identifier,
               application: application,
               expectedWindowIdentity: evidence.target.identity,
               proofs: evidence.selectorResolutionProofs,
               requireProof: requireProof)
        {
            return mismatch
        }
        let selection: WindowSelection = if let windowID = selector.windowID {
            .id(CGWindowID(windowID))
        } else if let windowTitle = selector.windowTitle {
            .title(windowTitle)
        } else if let windowIndex = selector.windowIndex {
            .index(windowIndex)
        } else {
            .automatic
        }
        let window = ServiceWindowInfo(
            windowID: evidence.target.identity.windowID,
            title: evidence.windowTitle,
            bounds: evidence.target.bounds,
            index: evidence.windowIndex,
            mutationIdentity: evidence.target.identity)
        return self.windowMismatch(
            selection: selection,
            application: application,
            window: window,
            proofs: evidence.selectorResolutionProofs,
            requireProof: requireProof)
    }
}
