import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
protocol CaptureWindowSelectorProviding {
    var app: String? { get }
    var pid: Int32? { get }
    var windowTitle: String? { get }
    var windowIndex: Int? { get }
}

extension CaptureWindowSelectorProviding {
    func validatedCaptureWindowSelector(allowMissingTarget: Bool = false) throws -> InteractionTargetSelector {
        try validatedMutationSelector(
            InteractionTargetSelector(
                applicationIdentifier: self.app,
                processIdentifier: self.pid.map(Int.init),
                windowTitle: self.windowTitle,
                windowIndex: self.windowIndex
            ),
            allowMissingTarget: allowMissingTarget,
            missingTargetMessage: "Window capture requires --app or --pid",
            multipleWindowSelectorsMessage: "Provide only one of --window-title or --window-index"
        )
    }
}

extension CaptureLiveCommand: CaptureWindowSelectorProviding {}
extension CaptureActionCommand: CaptureWindowSelectorProviding {}

@MainActor
func resolveExactCaptureWindowReference(
    selector: InteractionTargetSelector,
    applicationIdentifier: String,
    services: any PeekabooServiceProviding,
    operation: String
) async throws -> (windowID: UInt32, windowIndex: Int, identity: WindowMutationIdentity) {
    let windows = try await WindowServiceBridge.listWindows(
        windows: services.windows,
        target: .application(applicationIdentifier)
    )
    let renderable = ObservationTargetResolver.captureCandidates(from: windows)
    let selectedWindow: ServiceWindowInfo
    do {
        selectedWindow = try ExactWindowSelectorResolver.select(
            from: renderable,
            selector: selector,
            operation: operation
        )
    } catch {
        throw ValidationError(error.localizedDescription)
    }
    guard let windowID = UInt32(exactly: selectedWindow.windowID) else {
        throw ValidationError(
            "\(operation) selected window ID \(selectedWindow.windowID) is outside the CoreGraphics range"
        )
    }
    guard let identity = selectedWindow.mutationIdentity,
          identity.windowID == selectedWindow.windowID,
          identity.capturedBounds == selectedWindow.bounds
    else {
        throw ValidationError(
            "\(operation) selected a window without an exact process-generation and bounds receipt"
        )
    }
    return (windowID: windowID, windowIndex: selectedWindow.index, identity: identity)
}

@MainActor
extension CaptureLiveCommand {
    func resolveScope() async throws -> CaptureScope {
        let mode = try self.resolveMode()
        let selector = try self.validatedCaptureWindowSelector(allowMissingTarget: true)
        switch mode {
        case .screen:
            let displayInfo = try await self.displayInfo(for: self.screenIndex)
            return CaptureScope(
                kind: .screen,
                screenIndex: displayInfo?.index,
                displayUUID: displayInfo?.uuid,
                windowId: nil,
                applicationIdentifier: nil,
                windowIndex: nil,
                region: nil
            )
        case .frontmost:
            return CaptureScope(
                kind: .frontmost,
                screenIndex: nil,
                displayUUID: nil,
                windowId: nil,
                applicationIdentifier: nil,
                windowIndex: nil,
                region: nil
            )
        case .window:
            guard selector.hasOwnerInput else {
                throw ValidationError("Window capture requires --app or --pid")
            }
            let identifier = try self.resolveApplicationIdentifier()
            let windowReference = try await resolveExactCaptureWindowReference(
                selector: selector,
                applicationIdentifier: identifier,
                services: self.services,
                operation: "Capture live"
            )
            return CaptureScope(
                kind: .window,
                screenIndex: nil,
                displayUUID: nil,
                windowId: windowReference.windowID,
                windowMutationIdentity: windowReference.identity,
                applicationIdentifier: identifier,
                windowIndex: windowReference.windowIndex,
                region: nil
            )
        case .area:
            let rect = try self.parseRegion()
            return CaptureScope(kind: .region, region: rect)
        case .multi:
            throw ValidationError("capture live does not support multi-mode captures")
        }
    }

    /// Exposed internally for tests.
    func resolveMode() throws -> LiveCaptureMode {
        if let explicit = self.mode {
            let normalized = explicit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "region" {
                return .area
            }
            guard let mode = LiveCaptureMode(rawValue: normalized) else {
                throw ValidationError(
                    "Unsupported capture live mode '\(explicit)'. Use screen, window, frontmost, or area."
                )
            }
            return mode
        }
        if self.region != nil {
            return .area
        }
        if self.app != nil || self.pid != nil || self.windowTitle != nil || self.windowIndex != nil {
            return .window
        }
        return .frontmost
    }

    func parseRegion() throws -> CGRect {
        guard let region = self.region?.trimmingCharacters(in: .whitespacesAndNewlines),
              !region.isEmpty
        else {
            throw PeekabooError.invalidInput("Region must be provided when --mode area is set")
        }
        let parts = region
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3])
        else {
            throw PeekabooError.invalidInput("Region must be x,y,width,height")
        }
        guard width > 0, height > 0 else {
            throw PeekabooError.invalidInput("Region width and height must be greater than zero")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func displayInfo(for index: Int?) async throws -> (index: Int, uuid: String)? {
        guard let index else { return nil }
        let screens = self.services.screens.listScreens()
        guard let match = screens.first(where: { $0.index == index }) else {
            throw PeekabooError.invalidInput("Screen index \(index) not found")
        }
        return (index, "\(match.displayID)")
    }
}
