import Commander
import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
extension SeeCommand {
    func determineMode() -> PeekabooCore.CaptureMode {
        if let mode = self.mode {
            mode
        } else if self.app != nil || self.pid != nil || self.windowTitle != nil || self.windowId != nil {
            .window
        } else {
            .frontmost
        }
    }

    func observationTargetForCaptureWithDetectionIfPossible() throws -> DesktopObservationTargetRequest? {
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
            if let screenIndex {
                return .screen(index: screenIndex)
            }
            if self.analyze != nil {
                return .screen(index: 0)
            }
            return nil

        case .multi:
            return nil

        case .area:
            throw ValidationError(
                "Area capture mode is not supported by `see`; use `image --mode area --region x,y,width,height` " +
                    "or a window/screen target."
            )
        }
    }

    func makeObservationRequest(
        target: DesktopObservationTargetRequest,
        snapshotID: String? = nil
    ) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: target,
            capture: DesktopCaptureOptions(
                engine: self.observationCaptureEnginePreference,
                scale: .logical1x,
                visualizerMode: .screenshotFlash
            ),
            detection: self.observationDetectionOptions(for: target),
            output: DesktopObservationOutputOptions(
                path: self.screenshotOutputPath(snapshotID: snapshotID),
                saveRawScreenshot: true,
                saveAnnotatedScreenshot: self.annotate && self.allowsAnnotation(for: target),
                saveSnapshot: true,
                snapshotID: snapshotID
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
                mode: .accessibility,
                allowWebFocusFallback: !self.noWebFocus,
                traversalBudget: self.axTraversalBudget()
            )
        }
    }

    func axTraversalBudget() -> AXTraversalBudget {
        AXTraversalBudget.resolved(
            maxDepth: self.validatedTraversalLimit(self.maxDepth, option: "--max-depth"),
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
        ObservationCommandSupport.captureEnginePreference(
            cliValue: self.captureEngine,
            configuredValue: self.configuredCaptureEnginePreference
        )
    }
}
