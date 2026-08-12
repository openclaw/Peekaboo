import Foundation
import PeekabooCore
import PeekabooFoundation

/// Protocol for commands that can resolve application identifiers from various inputs
protocol ApplicationResolvable {
    /// Application name, bundle ID, or 'PID:12345' format
    var app: String? { get }

    /// Process ID as a direct parameter
    var pid: Int32? { get }
}

extension ApplicationResolvable {
    /// Returns a PID when the command explicitly targets one, including the documented `--app PID:<pid>` form.
    func resolveExplicitPIDObservationTarget() throws -> Int32? {
        if let pid, self.app == nil {
            return pid
        }

        guard let appValue = self.app?.trimmingCharacters(in: .whitespacesAndNewlines),
              appValue.uppercased().hasPrefix("PID:")
        else {
            return nil
        }

        let appPidString = String(appValue.dropFirst("PID:".count))
        guard let appPid = Int32(appPidString) else {
            throw PeekabooError.invalidInput("Invalid PID format in --app: '\(appValue)'")
        }

        if let pid, pid != appPid {
            throw PeekabooError.invalidInput(
                "Conflicting PIDs: --app specifies PID \(appPid) but --pid is \(pid)"
            )
        }

        return appPid
    }

    /// Resolves the application identifier from app and/or pid parameters
    /// Supports lenient handling for redundant but non-conflicting parameters
    func resolveApplicationIdentifier() throws -> String {
        // Resolves the application identifier from app and/or pid parameters
        switch (app, pid) {
        case (nil, nil):
            throw PeekabooError.invalidInput("Either --app or --pid must be specified")

        case (let appValue?, nil):
            // Only --app provided, use as-is (supports "PID:12345" format)
            return appValue

        case (nil, let pidValue?):
            // Only --pid provided, convert to PID: format
            return "PID:\(pidValue)"

        case let (appValue?, pidValue?):
            // Both provided - need to validate they don't conflict
            return try self.validateAndResolveBothParameters(app: appValue, pid: pidValue)
        }
    }

    /// Validates when both app and pid parameters are provided
    private func validateAndResolveBothParameters(app: String, pid: Int32) throws -> String {
        // Case 1: Check if app is already in PID format
        if app.hasPrefix("PID:") {
            let appPidString = String(app.dropFirst(4))
            if let appPid = Int32(appPidString) {
                // Both specify PID - they must match
                if appPid == pid {
                    // Redundant but consistent - this is OK
                    return app
                } else {
                    throw PeekabooError.invalidInput(
                        "Conflicting PIDs: --app specifies PID \(appPid) but --pid is \(pid)"
                    )
                }
            } else {
                throw PeekabooError.invalidInput("Invalid PID format in --app: '\(app)'")
            }
        }

        throw PeekabooError.invalidInput(
            "Provide the application either with --app or --pid, not both"
        )
    }
}
