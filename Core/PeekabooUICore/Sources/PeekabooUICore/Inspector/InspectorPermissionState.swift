import Observation

@MainActor
@Observable
final class InspectorPermissionState {
    private(set) var status: InspectorView.PermissionStatus = .checking

    private let checkProvider: () -> Bool
    private let promptProvider: () -> Bool

    init(check: @escaping () -> Bool, prompt: @escaping () -> Bool) {
        self.checkProvider = check
        self.promptProvider = prompt
    }

    /// Synchronously checks one provider, stores its status, and reports whether it changed.
    @discardableResult
    func checkPermissions(prompt: Bool = false) -> Bool {
        let accessEnabled = prompt ? self.promptProvider() : self.checkProvider()
        let newStatus: InspectorView.PermissionStatus = accessEnabled ? .granted : .denied
        guard self.status != newStatus else { return false }
        self.status = newStatus
        return true
    }
}
