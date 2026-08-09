//
//  ServiceProtocols.swift
//  PeekabooProtocols
//

public enum LogLevel: Int, Sendable, Codable, Comparable {
    case trace = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case critical = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
