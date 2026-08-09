//
//  ObservableProtocols.swift
//  PeekabooProtocols
//

import Foundation
import PeekabooFoundation

// MARK: - Observable Service Protocols

/// Protocol for observable permissions service
public protocol ObservablePermissionsServiceProtocol: AnyObject {
    var screenRecordingStatus: PermissionState { get }
    var accessibilityStatus: PermissionState { get }
    var appleScriptStatus: PermissionState { get }
    var hasAllPermissions: Bool { get }

    func checkPermissions()
    func requestPermissions() async
}

public enum PermissionState: String, Sendable {
    case notDetermined
    case denied
    case authorized
}

// MARK: - Focus Options Protocol

public protocol FocusOptionsProtocol {
    var raiseWindow: Bool { get }
    var activateApp: Bool { get }
    var waitForWindow: Bool { get }
    var timeout: TimeInterval { get }
}
