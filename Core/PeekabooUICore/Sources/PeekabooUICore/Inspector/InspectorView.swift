//
//  InspectorView.swift
//  PeekabooUICore
//
//  Main Inspector UI component
//

import AppKit
import AXorcist
import Observation
import PeekabooCore
import SwiftUI

/// Configuration for the Inspector view
public struct InspectorConfiguration {
    public var showPermissionAlert: Bool = true
    public var enableOverlay: Bool = true
    public var defaultDetailLevel: OverlayManager.DetailLevel = .moderate

    public init() {}
}

/// Main Inspector view for UI element inspection
public struct InspectorView: View {
    @State private var overlayManager = OverlayManager()
    @State private var showPermissionAlert = false
    @State private var permissions = InspectorPermissionState(
        check: { AXPermissionHelpers.hasAccessibilityPermissions() },
        prompt: { AXPermissionHelpers.askForAccessibilityIfNeeded() })
    @State private var permissionCheckTimer: Timer?

    private let configuration: InspectorConfiguration

    public enum PermissionStatus {
        case checking
        case granted
        case denied
    }

    public init(configuration: InspectorConfiguration = InspectorConfiguration()) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(spacing: 0) {
            self.headerView

            Divider()

            if self.permissions.status == .denied {
                PermissionDeniedView()
            } else if self.permissions.status == .checking {
                ProgressView("Checking permissions...")
                    .padding()
            } else {
                self.mainContent
            }
        }
        .frame(width: 450, height: 700)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            self.startPermissionMonitoring()
            if self.configuration.enableOverlay {
                self.openOverlayWindow()
            }
        }
        .onDisappear {
            self.stopPermissionMonitoring()
        }
    }

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Peekaboo Inspector")
                        .font(.headline)
                    Text(self.overlayStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("Overlay", isOn: self.$overlayManager.isOverlayActive)
                    .toggleStyle(.switch)
            }
            .padding()

            Divider()

            AppSelectorView(overlayManager: self.overlayManager)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let hoveredElement = overlayManager.hoveredElement {
                    ElementDetailsView(element: hoveredElement)
                } else {
                    Text("Hover over an element to see details")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }

                Divider()

                AllElementsView(overlayManager: self.overlayManager)
            }
            .padding()
        }
    }

    private func checkPermissions(prompt: Bool = false) {
        let statusChanged = withAnimation {
            self.permissions.checkPermissions(prompt: prompt)
        }

        if statusChanged, self.permissions.status == .granted {
            self.overlayManager.refreshAllApplications()
        }
    }

    private var overlayStatusText: String {
        guard !self.overlayManager.applications.isEmpty else {
            return "Hover over UI elements to inspect"
        }

        let count = self.overlayManager.applications.count
        let suffix = count == 1 ? "" : "s"
        return "Monitoring \(count) app\(suffix)"
    }

    private func startPermissionMonitoring() {
        // Initial check with prompt
        self.checkPermissions(prompt: self.configuration.showPermissionAlert)

        // Start periodic checking without prompt
        self.permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                self.checkPermissions(prompt: false)
            }
        }
    }

    private func stopPermissionMonitoring() {
        self.permissionCheckTimer?.invalidate()
        self.permissionCheckTimer = nil
    }

    private func openOverlayWindow() {
        // This would be implemented by the host application
        // as it needs to manage actual window creation
    }
}
