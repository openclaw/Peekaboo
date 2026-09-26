import Commander
import Foundation
import PeekabooCore

typealias LiveCaptureMode = PeekabooCore.CaptureMode
typealias LiveCaptureFocus = PeekabooCore.CaptureFocus
typealias LiveCaptureSessionResult = PeekabooCore.CaptureSessionResult

enum CaptureCommandOptionParser {
    @MainActor
    static func enginePreference(
        cliValue: String?,
        configuredValue: String?,
        kind: CaptureScope.Kind,
        gateOwner: CaptureTransactionGateOwner,
        supportsEngineScope: Bool
    ) throws -> CaptureEnginePreference? {
        let value = ObservationCommandSupport.resolvedCaptureEngineValue(
            cliValue: cliValue,
            configuredValue: configuredValue
        )
        if value == nil, gateOwner == .service || !supportsEngineScope {
            return nil
        }
        try ObservationCommandSupport.validateCaptureEngineValue(value)
        guard supportsEngineScope else {
            throw ValidationError("The selected capture service cannot honor a capture-engine override.")
        }
        let preference = ObservationCommandSupport.captureEnginePreference(cliValue: value, configuredValue: nil)
        // Only caller-owned capture uses the local auto-region optimization. A remote host owns its backend policy.
        if gateOwner == .caller, kind == .region, preference == .auto {
            return .legacy
        }
        return preference
    }

    static func diffStrategy(_ value: String?) throws -> CaptureOptions.DiffStrategy {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "fast"
        guard let strategy = CaptureOptions.DiffStrategy(rawValue: normalized) else {
            throw ValidationError("Unsupported diff strategy '\(value ?? "")'. Use fast or quality.")
        }
        return strategy
    }
}

@MainActor
struct CaptureCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "capture",
                abstract: "Capture live screens/windows or ingest a video and extract frames",
                subcommands: [
                    CaptureLiveCommand.self,
                    CaptureActionCommand.self,
                    CaptureVideoCommand.self,
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}
