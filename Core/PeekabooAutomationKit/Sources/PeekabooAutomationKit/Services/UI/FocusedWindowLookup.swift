import Foundation
import PeekabooFoundation

@MainActor
struct FocusedWindowLookup {
    var frontmostApplication: () async throws -> ServiceApplicationInfo
    var listWindows: (String) async throws -> [ServiceWindowInfo]
    var windowByID: (Int) async throws -> [ServiceWindowInfo]
    var focusedWindowID: (pid_t) async throws -> Int?
    var processStartIdentity: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity

    func capture() async throws -> ServiceWindowInfo? {
        let application = try await self.frontmostApplication()
        let pid = application.processIdentifier
        guard let startIdentity = self.processStartIdentity(pid) else { return nil }
        let windows = try await self.listWindows("PID:\(pid)")
        guard let focusedID = try await self.focusedWindowID(pid) else { return nil }

        let focusedWindow: ServiceWindowInfo?
        if let listedWindow = windows.first(where: { $0.windowID == focusedID }) {
            focusedWindow = listedWindow
        } else {
            do {
                focusedWindow = try await self.windowByID(focusedID).first {
                    $0.windowID == focusedID && $0.mutationIdentity?.ownerProcessIdentifier == pid
                }
            } catch PeekabooError.windowNotFound {
                return nil
            }
        }
        guard self.processStartIdentity(pid) == startIdentity else { return nil }
        return focusedWindow
    }
}
