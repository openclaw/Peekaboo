import Foundation
import Observation
import os.log
import PeekabooCore

/// Manages and monitors system permission states for Peekaboo.
///
/// `Permissions` provides a centralized interface for checking and monitoring the system
/// permissions required by Peekaboo, including Screen Recording and Accessibility.
/// It uses the ObservablePermissionsService from PeekabooCore under the hood.
@Observable
@MainActor
final class Permissions {
    private let permissionsService: any ObservablePermissionsServiceProtocol
    private let logger = Logger(subsystem: "com.peekaboo.peekaboo", category: "Permissions")

    var screenRecordingStatus: ObservablePermissionsService.PermissionState {
        self.permissionsService.screenRecordingStatus
    }

    var accessibilityStatus: ObservablePermissionsService.PermissionState {
        self.permissionsService.accessibilityStatus
    }

    var postEventStatus: ObservablePermissionsService.PermissionState {
        self.permissionsService.postEventStatus
    }

    var hasAllPermissions: Bool {
        self.permissionsService.hasAllPermissions
    }

    private var monitorTimer: Timer?
    private var isChecking = false
    private var pendingForcedCheck = false
    private var registrations = 0
    private var lastCheck: Date?
    private var lastOptionalCheck: Date?
    private let minimumCheckInterval: TimeInterval = 0.5
    private let optionalCheckInterval: TimeInterval = 10.0

    private var includeOptionalPermissions = false

    init(permissionsService: (any ObservablePermissionsServiceProtocol)? = nil) {
        self.permissionsService = permissionsService ?? ObservablePermissionsService()
    }

    func check() async {
        await self.check(force: false)
    }

    func refresh() async {
        await self.check(force: true)
    }

    func setIncludeOptionalPermissions(_ enabled: Bool) {
        if self.includeOptionalPermissions == enabled {
            return
        }
        self.includeOptionalPermissions = enabled
        self.lastOptionalCheck = nil
    }

    func requestScreenRecording() async {
        await self.permissionsService.requestScreenRecording()
    }

    func requestAccessibility() async {
        await self.permissionsService.requestAccessibility()
    }

    func requestPostEvent() async {
        await self.permissionsService.requestPostEvent()
    }

    func registerMonitoring() {
        self.registrations += 1
        if self.registrations == 1 {
            self.startMonitoringTimer()
        }
    }

    func unregisterMonitoring() {
        guard self.registrations > 0 else { return }
        self.registrations -= 1
        if self.registrations == 0 {
            self.stopMonitoringTimer()
        }
    }

    private func startMonitoringTimer() {
        // Passive on purpose: force would unlock the ScreenCaptureKit probe, which can present
        // the system Screen Recording prompt just from opening a window that shows the checklist.
        // Only explicit user actions (Refresh, Grant) force a probe.
        Task { @MainActor in
            await self.check(force: false)
        }

        self.monitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.check(force: false)
            }
        }
    }

    private func stopMonitoringTimer() {
        self.monitorTimer?.invalidate()
        self.monitorTimer = nil
        self.lastCheck = nil
        self.lastOptionalCheck = nil
    }

    private func check(force: Bool) async {
        if self.isChecking {
            // checkPermissions suspends across an XPC probe, so an explicit Refresh can land
            // while a passive tick is in flight; queue it instead of silently dropping it.
            if force {
                self.pendingForcedCheck = true
            }
            return
        }

        let now = Date()
        if !force, let lastCheck, now.timeIntervalSince(lastCheck) < self.minimumCheckInterval {
            return
        }

        self.isChecking = true

        self.logger.info("Checking permissions...")

        let shouldCheckOptionalPermissions = self.includeOptionalPermissions &&
            (force || self.shouldCheckOptionalPermissions(now: now))
        await self.permissionsService.checkPermissions(
            includeOptionalPermissions: shouldCheckOptionalPermissions,
            forceScreenRecordingProbe: force)

        if shouldCheckOptionalPermissions {
            self.lastOptionalCheck = now
        }

        self.lastCheck = Date()
        self.isChecking = false

        if self.pendingForcedCheck {
            self.pendingForcedCheck = false
            await self.check(force: true)
        }
    }

    private func shouldCheckOptionalPermissions(now: Date) -> Bool {
        guard let lastOptionalCheck else { return true }
        return now.timeIntervalSince(lastOptionalCheck) >= self.optionalCheckInterval
    }
}
