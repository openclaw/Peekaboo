import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    func determineMode() -> PeekabooCore.CaptureMode {
        if let mode = self.mode {
            mode
        } else if self.region != nil {
            .area
        } else if self.screenIndex != nil {
            .screen
        } else if self.app != nil || self.pid != nil || self.windowTitle != nil || self.windowIndex != nil ||
            self.windowId != nil {
            .window
        } else {
            .frontmost
        }
    }

    func observationTargetForCaptureWithDetectionIfPossible() throws -> DesktopObservationTargetRequest? {
        try self.validateInteractionTargetSelectors()
        if self.menubar {
            let hint = self.menuBarAppHint()
            return .menubarPopover(
                hints: MenuBarPopoverResolverContext.normalizedHints([hint]),
                openIfNeeded: MenuBarPopoverOpenOptions(clickHint: hint)
            )
        }

        switch self.determineMode() {
        case .window:
            if let windowId {
                guard self.windowTitle == nil else {
                    throw ValidationError("--window-id cannot be combined with --window-title")
                }
                let selection = WindowSelection.id(CGWindowID(windowId))
                if let pid = try self.resolveExplicitPIDObservationTarget() {
                    return .pid(pid, window: selection)
                }
                if self.app != nil {
                    return try .app(identifier: self.resolveApplicationIdentifier(), window: selection)
                }
                return .windowID(CGWindowID(windowId))
            }

            if let appValue = self.app?.lowercased() {
                switch appValue {
                case "menubar":
                    return .menubar
                case "frontmost":
                    return .frontmost
                default:
                    break
                }
            }

            if let pid = try self.resolveExplicitPIDObservationTarget() {
                return .pid(pid, window: self.seeWindowSelection)
            }

            if self.app != nil || self.pid != nil {
                return try .app(identifier: self.resolveApplicationIdentifier(), window: self.seeWindowSelection)
            }

            throw ValidationError("Provide --window-id, or --app/--pid for window mode")

        case .frontmost:
            return .frontmost

        case .screen:
            return .screen(index: self.screenIndex)

        case .multi:
            return nil

        case .area:
            return try .area(self.areaCaptureRect())
        }
    }

    func makeObservationRequest(
        target: DesktopObservationTargetRequest,
        snapshotID: String? = nil
    ) throws -> DesktopObservationRequest {
        try DesktopObservationRequest(
            target: target,
            capture: DesktopCaptureOptions(
                engine: self.observationCaptureEnginePreference,
                scale: self.retina ? .native : .logical1x,
                visualizerMode: .none,
                roi: self.captureROI()
            ),
            detection: self.observationDetectionOptions(for: target),
            output: DesktopObservationOutputOptions(
                path: self.screenshotOutputPath(snapshotID: snapshotID),
                format: self.format,
                saveRawScreenshot: true,
                saveAnnotatedScreenshot: self.annotate && self.allowsAnnotation(for: target),
                saveSnapshot: true,
                snapshotID: snapshotID
            ),
            timeout: DesktopObservationTimeouts(
                overall: self.overallTimeoutSeconds,
                detection: self.overallTimeoutSeconds,
                ocr: self.ocr ? self.overallTimeoutSeconds : nil
            )
        )
    }

    func observationTargetDescription(_ target: DesktopObservationTargetRequest) -> String {
        switch target {
        case let .screen(index):
            "screen:\(index.map(String.init) ?? "primary")"
        case .allScreens:
            "all-screens"
        case .frontmost:
            "frontmost"
        case let .app(identifier, _):
            "app:\(identifier)"
        case let .pid(pid, _):
            "pid:\(pid)"
        case let .windowID(windowID):
            "window-id:\(windowID)"
        case let .area(rect):
            "area:\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width))x\(Int(rect.height))"
        case .menubar:
            "menubar"
        case .menubarPopover:
            "menubar-popover"
        }
    }

    private var seeWindowSelection: WindowSelection {
        if let windowTitle {
            return .title(windowTitle)
        }
        if let windowIndex {
            return .index(windowIndex)
        }
        return .automatic
    }

    func allowsAnnotation(for target: DesktopObservationTargetRequest) -> Bool {
        switch target {
        case .screen, .allScreens, .menubar:
            false
        default:
            true
        }
    }

    private func observationDetectionOptions(for target: DesktopObservationTargetRequest) -> DesktopDetectionOptions {
        switch target {
        case .menubarPopover:
            DesktopDetectionOptions(
                mode: .none,
                allowWebFocusFallback: false,
                preferOCR: true,
                traversalBudget: self.axTraversalBudget()
            )
        default:
            DesktopDetectionOptions(
                mode: self.ocr ? .accessibilityAndOCR : .accessibility,
                allowWebFocusFallback: self.webFocus,
                preferOCR: false,
                traversalBudget: self.axTraversalBudget()
            )
        }
    }

    func axTraversalBudget() -> AXTraversalBudget {
        AXTraversalBudget.resolved(
            maxDepth: self.validatedTraversalLimit(self.depth, option: "--depth"),
            maxElementCount: self.validatedTraversalLimit(self.maxElements, option: "--max-elements"),
            maxChildrenPerNode: self.validatedTraversalLimit(self.maxChildren, option: "--max-children")
        )
    }

    private func validatedTraversalLimit(_ value: Int?, option: String) -> Int? {
        guard let value else { return nil }
        guard value > 0 else {
            self.logger.warn("\(option) must be positive; using default AX traversal budget")
            return nil
        }
        return value
    }

    private var observationCaptureEnginePreference: CaptureEnginePreference {
        if let safetyOverride = self.runtime?.captureEngineSafetyOverride {
            return safetyOverride
        }
        return ObservationCommandSupport.captureEnginePreference(
            cliValue: self.captureEngine,
            configuredValue: self.configuredCaptureEnginePreference
        )
    }
}
