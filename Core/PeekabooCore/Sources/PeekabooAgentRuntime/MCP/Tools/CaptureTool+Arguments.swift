import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

enum CaptureToolArgumentResolver {
    static func source(from rawValue: String?) throws -> CaptureSessionResult.Source {
        let normalized = self.normalized(rawValue) ?? "live"
        guard let source = CaptureSessionResult.Source(rawValue: normalized) else {
            throw PeekabooError.invalidInput("Unsupported capture source '\(rawValue ?? "")'. Use live or video.")
        }
        return source
    }

    static func mode(
        from rawValue: String?,
        hasRegion: Bool,
        hasWindowTarget: Bool) throws -> CaptureMode
    {
        if let normalized = self.normalized(rawValue) {
            if normalized == "region" {
                return .area
            }
            guard let mode = CaptureMode(rawValue: normalized) else {
                throw PeekabooError.invalidInput(
                    "Unsupported capture mode '\(rawValue ?? "")'. Use screen, window, frontmost, or area.")
            }
            return mode
        }
        if hasRegion {
            return .area
        }
        if hasWindowTarget {
            return .window
        }
        return .frontmost
    }

    static func applicationIdentifier(app: String?, pid: Int?) -> String {
        if let app = app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            return app
        }
        if let pid {
            return "PID:\(pid)"
        }
        return "frontmost"
    }

    static func region(from rawValue: String?) throws -> CGRect {
        guard let rawValue else {
            throw PeekabooError.invalidInput("region is required when mode=area")
        }

        let parts = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            throw PeekabooError.invalidInput("region must be x,y,width,height")
        }

        let values = try parts.map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let value = Double(trimmed), value.isFinite else {
                throw PeekabooError.invalidInput("region must contain numeric x,y,width,height values")
            }
            return value
        }

        guard values[2] > 0, values[3] > 0 else {
            throw PeekabooError.invalidInput("region width and height must be greater than zero")
        }

        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    static func diffStrategy(from rawValue: String?) throws -> CaptureOptions.DiffStrategy {
        let normalized = self.normalized(rawValue) ?? "fast"
        guard let strategy = CaptureOptions.DiffStrategy(rawValue: normalized) else {
            throw PeekabooError.invalidInput("Unsupported diff_strategy '\(rawValue ?? "")'. Use fast or quality.")
        }
        return strategy
    }

    static func captureFocus(from rawValue: String?) throws -> CaptureFocus {
        let normalized = self.normalized(rawValue) ?? "background"
        guard let focus = CaptureFocus(rawValue: normalized) else {
            throw PeekabooError.invalidInput(
                "Unsupported capture_focus '\(rawValue ?? "")'. Use auto, background, or foreground.")
        }
        return focus
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
