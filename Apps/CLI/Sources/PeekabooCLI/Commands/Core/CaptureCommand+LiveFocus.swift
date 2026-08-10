import PeekabooCore

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

extension CaptureLiveCommand: CaptureFocusReceiptCommand {}
extension CaptureActionCommand: CaptureFocusReceiptCommand {}

@MainActor
extension CaptureLiveCommand {
    mutating func focusIfNeeded(appIdentifier: String) async throws {
        switch captureFocus {
        case .background: return
        case .auto:
            let windowTitle = self.windowTitle
            let services = self.services
            let options = FocusOptions(
                autoFocus: true,
                focusTimeout: nil,
                focusRetryCount: nil,
                spaceSwitch: false,
                bringToCurrentSpace: false
            )
            try await self.withCaptureFocusDispatchReceipt {
                try await ensureFocused(
                    applicationName: appIdentifier,
                    windowTitle: windowTitle,
                    options: options,
                    services: services
                )
            }
        case .foreground:
            let windowTitle = self.windowTitle
            let services = self.services
            let options = FocusOptions(
                autoFocus: true,
                focusTimeout: nil,
                focusRetryCount: nil,
                spaceSwitch: true,
                bringToCurrentSpace: true
            )
            try await self.withCaptureFocusDispatchReceipt {
                try await ensureFocused(
                    applicationName: appIdentifier,
                    windowTitle: windowTitle,
                    options: options,
                    services: services
                )
            }
        }
    }
}
