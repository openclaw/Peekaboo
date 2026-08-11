import Foundation

/// Canonical validation for adaptive live-capture sampling rates.
public struct CaptureCadence: Sendable, Equatable {
    public static let defaultIdleFps = 2.0
    public static let defaultActiveFps = 8.0
    public static let idleFpsRange = 0.1...5.0
    public static let activeFpsRange = 0.5...15.0

    public let idleFps: Double
    public let activeFps: Double

    public static func validated(
        idleFps: Double?,
        activeFps: Double?) throws -> CaptureCadence
    {
        let idle = idleFps ?? self.defaultIdleFps
        let active = activeFps ?? self.defaultActiveFps

        try self.validate(idle, name: "Idle", range: self.idleFpsRange)
        try self.validate(active, name: "Active", range: self.activeFpsRange)
        guard active >= idle else {
            throw CaptureCadenceValidationError.activeBelowIdle(active: active, idle: idle)
        }

        return CaptureCadence(idleFps: idle, activeFps: active)
    }

    private static func validate(
        _ value: Double,
        name: String,
        range: ClosedRange<Double>) throws
    {
        guard value.isFinite else {
            throw CaptureCadenceValidationError.nonFinite(name: name)
        }
        guard value > 0 else {
            throw CaptureCadenceValidationError.nonPositive(name: name)
        }
        guard range.contains(value) else {
            throw CaptureCadenceValidationError.outOfRange(
                name: name,
                value: value,
                minimum: range.lowerBound,
                maximum: range.upperBound)
        }
    }
}

public enum CaptureCadenceValidationError: LocalizedError, Sendable, Equatable {
    case nonFinite(name: String)
    case nonPositive(name: String)
    case outOfRange(name: String, value: Double, minimum: Double, maximum: Double)
    case activeBelowIdle(active: Double, idle: Double)

    public var errorDescription: String? {
        switch self {
        case let .nonFinite(name):
            "\(name) FPS must be a finite number."
        case let .nonPositive(name):
            "\(name) FPS must be greater than zero."
        case let .outOfRange(name, value, minimum, maximum):
            "\(name) FPS \(value) is outside the supported range \(minimum)...\(maximum)."
        case let .activeBelowIdle(active, idle):
            "Active FPS (\(active)) must be greater than or equal to idle FPS (\(idle))."
        }
    }
}
