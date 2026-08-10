import Foundation
import PeekabooCore

@MainActor
protocol OutputFormattable {
    var jsonOutput: Bool { get }
    var outputLogger: Logger { get }
}

extension OutputFormattable {
    func output(_ data: some Codable, effect: ActionEffect? = nil, humanReadable: () -> Void) {
        if jsonOutput {
            outputSuccessCodable(
                data: data,
                effect: effect ?? (self as? any ActionOutputFormattable)?.defaultEffect,
                logger: self.outputLogger
            )
        } else {
            humanReadable()
        }
    }
}

@MainActor
func requireScreenRecordingPermission(services: any PeekabooServiceProviding) async throws {
    let hasPermission = await Task { @MainActor in
        await services.screenCapture.hasScreenRecordingPermission()
    }.value

    guard hasPermission else {
        throw CaptureError.screenRecordingPermissionDenied
    }
}

@MainActor
func requireAccessibilityPermission(services: any PeekabooServiceProviding) throws {
    if !services.permissions.checkAccessibilityPermission() {
        throw CaptureError.accessibilityPermissionDenied
    }
}
