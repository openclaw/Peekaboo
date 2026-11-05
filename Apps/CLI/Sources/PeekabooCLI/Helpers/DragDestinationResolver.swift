import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
struct DragDestinationResolver {
    let services: any PeekabooServiceProviding

    func destinationPoint(forApplicationNamed appName: String) async throws -> CGPoint {
        if appName.lowercased() == "trash" {
            return try await self.findTrashPoint()
        }

        let appInfo = try await self.resolveApplication(appName)
        let appIdentifier = "PID:\(appInfo.processIdentifier)"
        if let point = try? await self.centerOfBestWindow(for: appIdentifier) {
            return point
        }
        if let point = try await self.centerOfBestWindow(target: .application(appIdentifier)) {
            return point
        }

        throw PeekabooError.windowNotFound(criteria: "No visible destination window for \(appInfo.name)")
    }

    private func resolveApplication(_ identifier: String) async throws -> ServiceApplicationInfo {
        do {
            return try await self.services.applications.findApplication(identifier: identifier)
        } catch {
            if identifier.lowercased() == "frontmost" {
                throw PeekabooError.appNotFound(identifier)
            }
            throw error
        }
    }

    private func findTrashPoint() async throws -> CGPoint {
        let trash = try await self.services.dock.findDockItem(name: "Trash")
        guard let position = trash.position, let size = trash.size else {
            throw PeekabooError.elementNotFound("Trash position unavailable in Dock")
        }

        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private func centerOfBestWindow(for appIdentifier: String) async throws -> CGPoint? {
        let windowList = try await self.services.applications.listWindows(for: appIdentifier, timeout: nil)
        return self.centerOfBestWindow(in: windowList.data.windows)
    }

    private func centerOfBestWindow(target: WindowTarget) async throws -> CGPoint? {
        let windows = try await self.services.windows.listWindows(target: target)
        return self.centerOfBestWindow(in: windows)
    }

    private func centerOfBestWindow(in windows: [ServiceWindowInfo]) -> CGPoint? {
        guard let window = windows.first(where: { $0.isMainWindow && $0.isOnScreen })
            ?? windows.first(where: \.isOnScreen)
            ?? windows.first
        else {
            return nil
        }
        return CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    }
}
