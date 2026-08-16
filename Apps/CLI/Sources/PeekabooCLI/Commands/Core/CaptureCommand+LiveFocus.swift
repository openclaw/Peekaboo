import CoreGraphics
import PeekabooCore
import PeekabooFoundation

@MainActor
protocol CaptureFocusReceiptCommand {
    var captureMutationDispatched: Bool { get set }
    func withCaptureFocusMutation(_ operation: () async throws -> Void) async rethrows
}

extension CaptureFocusReceiptCommand {
    mutating func withCaptureFocusDispatchReceipt(_ operation: () async throws -> Void) async rethrows {
        self.captureMutationDispatched = true
        try await self.withCaptureFocusMutation(operation)
    }
}

@MainActor
protocol CaptureFocusTargetCommand: CaptureFocusReceiptCommand, InjectedRuntimeBackedCommand {
    var captureFocus: LiveCaptureFocus { get }
    var windowTitle: String? { get }
}

extension CaptureLiveCommand: CaptureFocusTargetCommand {}
extension CaptureActionCommand: CaptureFocusTargetCommand {}

extension CaptureFocusTargetCommand {
    mutating func focusIfNeeded(
        appIdentifier: String,
        windowID: CGWindowID?,
        windowMutationIdentity: WindowMutationIdentity?,
        focusResultProvider: FocusResultProvider? = nil
    ) async throws {
        let options: FocusOptions
        switch self.captureFocus {
        case .background:
            return
        case .auto:
            options = FocusOptions(
                autoFocus: true,
                focusTimeout: nil,
                focusRetryCount: nil,
                spaceSwitch: false,
                bringToCurrentSpace: false
            )
        case .foreground:
            options = FocusOptions(
                autoFocus: true,
                focusTimeout: nil,
                focusRetryCount: nil,
                spaceSwitch: true,
                bringToCurrentSpace: true
            )
        }

        let services = self.services
        let windowTitle = windowID == nil ? self.windowTitle : nil
        let preparedSelection = try preparedCaptureFocusSelection(
            windowID: windowID,
            identity: windowMutationIdentity
        )
        var actionResult: UIAutomationActionResult<Void>?
        try await self.withCaptureFocusDispatchReceipt {
            actionResult = try await ensureFocused(
                windowID: windowID,
                applicationName: appIdentifier,
                windowTitle: windowTitle,
                options: options,
                services: services,
                focusResultProvider: focusResultProvider,
                preparedSelection: preparedSelection
            )
        }
        guard let actionResult else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Capture focus completed without a canonical action result.",
                hint: "Observe the target before retrying and update the runtime host."
            )
        }
        _ = try validatedSuccessfulActionResult(
            actionResult,
            operation: "Capture focus",
            requiresTarget: windowID != nil
        )
    }
}

private func preparedCaptureFocusSelection(
    windowID: CGWindowID?,
    identity: WindowMutationIdentity?
) throws -> PreparedFocusSelection? {
    guard let windowID else {
        guard identity == nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Capture focus received a window identity without a window ID."
            )
        }
        return nil
    }
    guard let identity,
          identity.windowID == Int(windowID),
          let bounds = identity.capturedBounds
    else {
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Capture focus requires the exact process generation, window ID, and captured bounds.",
            hint: "Resolve the capture scope again before retrying focus."
        )
    }
    let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
    return PreparedFocusSelection(
        target: .windowId(identity.windowID),
        identity: identity,
        targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow)
    )
}
