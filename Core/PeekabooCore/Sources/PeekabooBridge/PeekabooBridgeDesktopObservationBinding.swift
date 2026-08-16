import CoreGraphics
import Foundation
import PeekabooAutomationKit

/// Typed request/result validation shared by the live 1.29 path and offline receipt verification.
///
/// Target attribution proves who owned a response. This validator additionally proves that the
/// response is the observation the client requested, including selectors that are not part of a
/// stable process/window receipt (for example a title, window index, screen index, or area).
enum PeekabooBridgeDesktopObservationBinding {
    static func mismatch(
        request: DesktopObservationRequest,
        result: DesktopObservationResult,
        requireSelectorResolutionProof: Bool = false,
        requireContentDigest: Bool = true) -> String?
    {
        if let mismatch = self.validateMutationTarget(request.target, result: result) {
            return mismatch
        }
        if case .app = request.target, result.target.app == nil {
            return "requested application identity"
        }
        if let mismatch = self.validateRequestedTarget(request.target, result: result) {
            return mismatch
        }
        if let mismatch = PeekabooBridgeSelectorResolutionBinding.observationMismatch(
            request: request,
            result: result,
            requireProof: requireSelectorResolutionProof)
        {
            return "selector proof \(mismatch)"
        }
        if let mismatch = self.validateCaptureMode(
            result.capture.metadata.mode,
            request: request.target,
            target: result.target)
        {
            return mismatch
        }
        if let mismatch = self.validateCaptureOptions(request.capture, result: result) {
            return mismatch
        }
        if let mismatch = self.validateDetectionOptions(request.detection, result: result) {
            return mismatch
        }
        if let mismatch = self.validateOutputOptions(
            request.output,
            result: result,
            requireContentDigest: requireContentDigest)
        {
            return mismatch
        }
        if let mismatch = self.validateApplicationEvidence(result) {
            return mismatch
        }
        if let mismatch = self.validateWindowEvidence(result) {
            return mismatch
        }
        if let mismatch = self.validateDisplayEvidence(request.target, result: result) {
            return mismatch
        }
        return self.validateDiagnosticEvidence(request.target, result: result)
    }

    private static func validateMutationTarget(
        _ request: DesktopObservationTargetRequest,
        result: DesktopObservationResult) -> String?
    {
        guard let target = result.target.mutationTargetIdentity else { return nil }
        guard case let .menubarPopover(_, openIfNeeded) = request,
              openIfNeeded != nil
        else {
            return "unexpected observation mutation target"
        }
        guard target.processIdentity.processIdentifier > 0 else {
            return "menu-bar mutation owner identity"
        }
        if let windowIdentity = target.windowIdentity {
            guard windowIdentity.windowID > 0,
                  windowIdentity.processIdentity == target.processIdentity,
                  let windowBounds = target.windowBounds,
                  self.isValidBounds(windowBounds),
                  windowBounds == windowIdentity.capturedBounds
            else {
                return "menu-bar mutation window identity"
            }
        } else if target.windowBounds != nil {
            return "menu-bar mutation window identity"
        }
        return nil
    }

    private static func validateRequestedTarget(
        _ request: DesktopObservationTargetRequest,
        result: DesktopObservationResult) -> String?
    {
        let resolved = result.target
        let mismatch: String? = switch request {
        case let .screen(index):
            self.validateScreen(index: index, resolved: resolved)
        case .allScreens:
            "all-screens composite target"
        case .frontmost:
            self.validateFrontmost(resolved, result: result)
        case let .app(identifier, selection):
            self.validateApplication(identifier: identifier, selection: selection, resolved: resolved)
        case let .pid(processIdentifier, selection):
            self.validateProcess(processIdentifier, selection: selection, resolved: resolved)
        case let .windowID(windowID):
            self.validateWindowID(windowID, resolved: resolved)
        case let .area(bounds):
            self.validateArea(bounds, resolved: resolved)
        case .menubar:
            self.validateMenuBar(resolved)
        case let .menubarPopover(hints, openIfNeeded):
            self.validateMenuBarPopover(
                resolved,
                hints: hints,
                openIfNeeded: openIfNeeded,
                diagnostics: result.diagnostics.target)
        }
        return mismatch ?? self.validateResolvedKindInternals(resolved)
    }

    private static func validateScreen(
        index: Int?,
        resolved: ResolvedObservationTarget) -> String?
    {
        guard case let .screen(actualIndex) = resolved.kind,
              actualIndex == index,
              resolved.app == nil,
              resolved.window == nil,
              resolved.bounds == nil,
              resolved.detectionContext == nil
        else {
            return "screen target kind or index"
        }
        return nil
    }

    private static func validateFrontmost(
        _ resolved: ResolvedObservationTarget,
        result: DesktopObservationResult) -> String?
    {
        let kindMismatch: String? = switch resolved.kind {
        case .frontmost, .appWindow, .windowID:
            resolved.app == nil ? "frontmost application identity" : nil
        case .screen, .area, .menubar, .menubarPopover:
            "frontmost target kind"
        }
        guard kindMismatch == nil else { return kindMismatch }
        guard let emittedFrontmost = result.diagnostics.stateSnapshot?.frontmostApplication else {
            return "frontmost application snapshot"
        }
        guard emittedFrontmost == resolved.app else {
            return "frontmost application snapshot identity"
        }
        return nil
    }

    private static func validateApplication(
        identifier: String,
        selection: WindowSelection?,
        resolved: ResolvedObservationTarget) -> String?
    {
        guard let app = resolved.app, self.application(app, matches: identifier) else {
            return "application selector"
        }
        return self.validateWindowSelection(selection, resolved: resolved)
    }

    private static func validateProcess(
        _ processIdentifier: Int32,
        selection: WindowSelection?,
        resolved: ResolvedObservationTarget) -> String?
    {
        guard resolved.app?.processIdentifier == processIdentifier else {
            return "process selector"
        }
        return self.validateWindowSelection(selection, resolved: resolved)
    }

    private static func validateWindowID(
        _ windowID: CGWindowID,
        resolved: ResolvedObservationTarget) -> String?
    {
        guard case let .windowID(actualWindowID) = resolved.kind,
              actualWindowID == windowID,
              resolved.window?.windowID == Int(windowID)
        else {
            return "window ID selector"
        }
        return nil
    }

    private static func validateArea(
        _ bounds: CGRect,
        resolved: ResolvedObservationTarget) -> String?
    {
        guard case let .area(actualBounds) = resolved.kind,
              actualBounds == bounds,
              resolved.bounds == bounds,
              self.isValidBounds(bounds),
              resolved.app == nil,
              resolved.window == nil,
              resolved.detectionContext == nil
        else {
            return "area target bounds"
        }
        return nil
    }

    private static func validateMenuBar(_ resolved: ResolvedObservationTarget) -> String? {
        guard case .menubar = resolved.kind,
              let bounds = resolved.bounds,
              self.isValidBounds(bounds),
              resolved.app == nil,
              resolved.window == nil
        else {
            return "menu-bar target"
        }
        return nil
    }

    private static func validateMenuBarPopover(
        _ resolved: ResolvedObservationTarget,
        hints: [String],
        openIfNeeded: MenuBarPopoverOpenOptions?,
        diagnostics: DesktopObservationTargetDiagnostics?) -> String?
    {
        guard case .menubarPopover = resolved.kind,
              let bounds = resolved.bounds,
              self.isValidBounds(bounds)
        else {
            return "menu-bar popover target"
        }
        guard let diagnostics else {
            return "menu-bar popover request diagnostics"
        }
        guard diagnostics.hints == hints else {
            return "menu-bar popover hints"
        }
        guard diagnostics.openIfNeeded == (openIfNeeded != nil) else {
            return "menu-bar popover open-if-needed policy"
        }
        let clickHint = openIfNeeded?.clickHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard diagnostics.clickHint == clickHint else {
            return "menu-bar popover click hint"
        }
        return nil
    }

    private static func validateWindowSelection(
        _ selection: WindowSelection?,
        resolved: ResolvedObservationTarget) -> String?
    {
        let hasApplicationWindowKind = switch resolved.kind {
        case .appWindow, .windowID: true
        case .screen, .frontmost, .area, .menubar, .menubarPopover: false
        }
        guard hasApplicationWindowKind else {
            return "application window target kind"
        }
        switch selection ?? .automatic {
        case .automatic:
            return nil
        case let .id(expected):
            guard self.resolvedWindowID(resolved) == expected,
                  resolved.window?.windowID == Int(expected)
            else { return "application window ID selector" }
        case let .title(expected):
            guard let title = resolved.window?.title,
                  title.localizedCaseInsensitiveContains(expected)
            else { return "application window title selector" }
        case let .index(expected):
            guard resolved.window?.index == expected else {
                return "application window index selector"
            }
        }
        return nil
    }

    private static func validateResolvedKindInternals(_ target: ResolvedObservationTarget) -> String? {
        switch target.kind {
        case let .windowID(windowID):
            guard target.window?.windowID == Int(windowID), target.app != nil else {
                return "resolved exact-window identity"
            }
        case .appWindow, .frontmost:
            guard target.app != nil else { return "resolved application identity" }
        case let .area(bounds):
            guard target.bounds == bounds else { return "resolved area identity" }
        case .menubar, .menubarPopover:
            guard target.bounds.map(self.isValidBounds) == true else {
                return "resolved menu bounds"
            }
        case .screen:
            break
        }
        if let window = target.window, target.bounds != window.bounds {
            return "resolved window bounds"
        }
        return nil
    }

    private static func validateCaptureMode(
        _ mode: CaptureMode,
        request: DesktopObservationTargetRequest,
        target: ResolvedObservationTarget) -> String?
    {
        let matches = switch request {
        case .screen: mode == .screen
        case .allScreens: false
        case .frontmost: mode == .frontmost
        case .app, .pid, .windowID: mode == .window
        case .area, .menubar: mode == .area
        case .menubarPopover: target.window == nil ? mode == .area : mode == .window
        }
        return matches ? nil : "capture mode"
    }

    private static func validateCaptureOptions(
        _ request: DesktopCaptureOptions,
        result: DesktopObservationResult) -> String?
    {
        guard let diagnostics = result.capture.metadata.diagnostics else {
            return "capture diagnostics"
        }
        guard diagnostics.requestedScale == request.scale else {
            return "capture scale"
        }
        guard diagnostics.finalPixelSize == result.capture.metadata.size,
              self.isValidSize(diagnostics.finalPixelSize),
              diagnostics.nativeScale.isFinite,
              diagnostics.nativeScale > 0,
              diagnostics.outputScale.isFinite,
              diagnostics.outputScale > 0
        else {
            return "capture raster diagnostics"
        }
        let expectedEngine: String? = switch request.engine {
        case .auto: nil
        case .modern: "ScreenCaptureKit"
        case .legacy: "CGWindowList"
        }
        guard let engine = diagnostics.engine,
              ["ScreenCaptureKit", "CGWindowList"].contains(engine),
              expectedEngine.map({ $0 == engine }) ?? true
        else {
            return "capture engine"
        }
        return nil
    }

    private static func validateDetectionOptions(
        _ request: DesktopDetectionOptions,
        result: DesktopObservationResult) -> String?
    {
        switch request.mode {
        case .none:
            guard result.elements == nil, result.ocr == nil else {
                return "unexpected detection result"
            }
            return nil
        case .accessibility, .accessibilityAndOCR:
            guard let elements = result.elements else {
                return "accessibility detection result"
            }
            if request.mode == .accessibilityAndOCR || request.preferOCR {
                guard result.ocr != nil else { return "OCR detection result" }
            }
            guard let context = elements.metadata.windowContext,
                  context.shouldFocusWebContent == request.allowWebFocusFallback,
                  context.includeMenuBarElements == request.includeMenuBarElements,
                  context.traversalBudget == request.traversalBudget
            else {
                return "detection request options"
            }
            return nil
        }
    }

    private static func validateOutputOptions(
        _ request: DesktopObservationOutputOptions,
        result: DesktopObservationResult,
        requireContentDigest: Bool) -> String?
    {
        let files = result.files
        let requiresRawArtifact =
            request.saveRawScreenshot || request.saveAnnotatedScreenshot || request.saveSnapshot

        if requiresRawArtifact {
            guard let rawPath = files.rawScreenshotPath,
                  !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return "requested raw screenshot output"
            }
            if let requestedPath = request.path,
               !requestedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let expectedPath = ObservationOutputPathResolver.resolve(
                    path: requestedPath,
                    format: request.format,
                    defaultFileName: URL(fileURLWithPath: rawPath).lastPathComponent)
                guard self.pathsMatch(rawPath, expectedPath.path) else {
                    return "raw screenshot output path"
                }
            }
        } else if let rawPath = files.rawScreenshotPath {
            guard let capturePath = result.capture.savedPath,
                  self.pathsMatch(rawPath, capturePath)
            else {
                return "unexpected raw screenshot output"
            }
        }

        if request.saveAnnotatedScreenshot {
            guard let rawPath = files.rawScreenshotPath,
                  let annotatedPath = files.annotatedScreenshotPath,
                  self.pathsMatch(
                      annotatedPath,
                      ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: rawPath))
            else {
                return "requested annotated screenshot output"
            }
        } else if files.annotatedScreenshotPath != nil {
            return "unexpected annotated screenshot output"
        }

        if let requestedSnapshotID = request.snapshotID,
           let elements = result.elements,
           elements.snapshotId != requestedSnapshotID
        {
            return "requested snapshot ID"
        }
        if request.saveSnapshot {
            let expectedSnapshotID = request.snapshotID ?? result.elements?.snapshotId
            guard let expectedSnapshotID,
                  !expectedSnapshotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  files.publishedSnapshotID == expectedSnapshotID
            else {
                return "snapshot publication"
            }
        } else if files.publishedSnapshotID != nil {
            return "unexpected snapshot publication"
        }

        return requireContentDigest ? self.validateCaptureContentDigest(result) : nil
    }

    private static func validateCaptureContentDigest(_ result: DesktopObservationResult) -> String? {
        guard let digest = result.captureContentDigest,
              self.isCanonicalSHA256(digest.captureImageSHA256)
        else {
            return "capture-content digest"
        }
        guard (result.files.rawScreenshotPath != nil) == (digest.rawScreenshotSHA256 != nil),
              digest.rawScreenshotSHA256.map(self.isCanonicalSHA256) ?? true
        else {
            return "raw screenshot content digest"
        }
        guard (result.files.annotatedScreenshotPath != nil) == (digest.annotatedScreenshotSHA256 != nil),
              digest.annotatedScreenshotSHA256.map(self.isCanonicalSHA256) ?? true
        else {
            return "annotated screenshot content digest"
        }
        return nil
    }

    private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !rhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func validateApplicationEvidence(_ result: DesktopObservationResult) -> String? {
        guard let targetApp = result.target.app else {
            if result.capture.metadata.applicationInfo != nil ||
                result.target.detectionContext?.applicationProcessId != nil ||
                result.elements?.metadata.windowContext?.applicationProcessId != nil
            {
                return "unexpected application evidence"
            }
            return nil
        }

        if result.target.window != nil {
            guard let captureApp = result.capture.metadata.applicationInfo,
                  let targetGeneration = targetApp.processStartIdentity,
                  captureApp.processIdentity == ApplicationProcessIdentity(
                      processIdentifier: targetApp.processIdentifier,
                      processStartIdentity: targetGeneration),
                  captureApp.bundleIdentifier == targetApp.bundleIdentifier,
                  captureApp.name == targetApp.name
            else {
                return "captured application identity"
            }
        }

        if let captureApp = result.capture.metadata.applicationInfo,
           captureApp.processIdentifier != targetApp.processIdentifier ||
           captureApp.bundleIdentifier != targetApp.bundleIdentifier ||
           captureApp.name != targetApp.name
        {
            return "captured application identity"
        }
        for context in self.windowContexts(result) {
            if let processIdentifier = context.applicationProcessId,
               processIdentifier != targetApp.processIdentifier
            {
                return "window-context process identity"
            }
            if let bundleIdentifier = context.applicationBundleId,
               bundleIdentifier != targetApp.bundleIdentifier
            {
                return "window-context application bundle"
            }
            if let name = context.applicationName, name != targetApp.name {
                return "window-context application name"
            }
        }

        let generations = [
            targetApp.processStartIdentity,
            result.capture.metadata.applicationInfo?.processStartIdentity,
            result.target.detectionContext?.windowMutationIdentity?.ownerProcessStartIdentity,
            result.capture.metadata.windowInfo?.mutationIdentity?.ownerProcessStartIdentity,
            result.elements?.metadata.windowContext?.windowMutationIdentity?.ownerProcessStartIdentity,
        ].compactMap(\.self)
        if let first = generations.first, generations.contains(where: { $0 != first }) {
            return "application process generation"
        }
        return nil
    }

    private static func validateWindowEvidence(_ result: DesktopObservationResult) -> String? {
        guard let targetWindow = result.target.window else {
            if result.capture.metadata.windowInfo != nil ||
                result.target.detectionContext?.windowID != nil ||
                result.elements?.metadata.windowContext?.windowID != nil
            {
                return "unexpected window evidence"
            }
            return nil
        }

        guard let captureWindow = result.capture.metadata.windowInfo,
              let targetIdentity = result.target.detectionContext?.windowMutationIdentity,
              captureWindow.mutationIdentity == targetIdentity
        else {
            return "captured window identity"
        }

        if captureWindow.windowID != targetWindow.windowID ||
            captureWindow.title != targetWindow.title ||
            captureWindow.bounds != targetWindow.bounds ||
            captureWindow.index != targetWindow.index
        {
            return "captured window identity"
        }
        for context in self.windowContexts(result) {
            if let windowID = context.windowID, windowID != targetWindow.windowID {
                return "window-context window ID"
            }
            if let title = context.windowTitle, title != targetWindow.title {
                return "window-context window title"
            }
            if let bounds = context.windowBounds, bounds != targetWindow.bounds {
                return "window-context window bounds"
            }
            if let identity = context.windowMutationIdentity,
               identity.windowID != targetWindow.windowID ||
               identity.ownerProcessIdentifier != result.target.app?.processIdentifier ||
               identity.capturedBounds != targetWindow.bounds
            {
                return "window-context exact-window receipt"
            }
        }
        if let identity = result.capture.metadata.windowInfo?.mutationIdentity,
           identity.windowID != targetWindow.windowID ||
           identity.ownerProcessIdentifier != result.target.app?.processIdentifier ||
           identity.capturedBounds != targetWindow.bounds
        {
            return "captured exact-window receipt"
        }
        return nil
    }

    private static func validateDisplayEvidence(
        _ request: DesktopObservationTargetRequest,
        result: DesktopObservationResult) -> String?
    {
        switch request {
        case let .screen(index):
            guard let display = result.capture.metadata.displayInfo else {
                return "captured screen identity"
            }
            if display.index != (index ?? 0) || !self.isValidBounds(display.bounds) {
                return "captured screen index"
            }
        case .allScreens:
            break
        case let .area(bounds):
            guard let display = result.capture.metadata.displayInfo else {
                return "captured area identity"
            }
            if display.bounds != bounds {
                return "captured area bounds"
            }
        case .menubar:
            guard let display = result.capture.metadata.displayInfo else {
                return "captured menu identity"
            }
            if display.bounds != result.target.bounds {
                return "captured menu bounds"
            }
        case .menubarPopover:
            guard let display = result.capture.metadata.displayInfo else {
                return "captured menu identity"
            }
            if result.target.window == nil {
                if display.bounds != result.target.bounds {
                    return "captured menu bounds"
                }
            } else if !self.isValidBounds(display.bounds) {
                return "captured menu display bounds"
            }
        case .frontmost, .app, .pid, .windowID:
            break
        }
        return nil
    }

    private static func validateDiagnosticEvidence(
        _ request: DesktopObservationTargetRequest,
        result: DesktopObservationResult) -> String?
    {
        guard let diagnostics = result.diagnostics.target else { return nil }
        guard diagnostics.requestedKind == self.requestedKind(request),
              diagnostics.resolvedKind == self.resolvedKind(result.target.kind),
              diagnostics.windowID == result.target.window?.windowID,
              diagnostics.bounds == result.target.bounds
        else {
            return "observation target diagnostics"
        }
        return nil
    }

    private static func application(_ app: ApplicationIdentity, matches identifier: String) -> Bool {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if identifier.uppercased().hasPrefix("PID:"),
           let processIdentifier = Int32(identifier.dropFirst("PID:".count))
        {
            return app.processIdentifier == processIdentifier
        }
        return ApplicationIdentifierMatcher.matches(app, identifier: identifier)
    }

    private static func resolvedWindowID(_ target: ResolvedObservationTarget) -> CGWindowID? {
        guard case let .windowID(windowID) = target.kind else { return nil }
        return windowID
    }

    private static func windowContexts(_ result: DesktopObservationResult) -> [WindowContext] {
        [result.target.detectionContext, result.elements?.metadata.windowContext].compactMap(\.self)
    }

    private static func isValidBounds(_ bounds: CGRect) -> Bool {
        bounds.origin.x.isFinite && bounds.origin.y.isFinite &&
            bounds.width.isFinite && bounds.height.isFinite &&
            bounds.width > 0 && bounds.height > 0
    }

    private static func isValidSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func requestedKind(_ target: DesktopObservationTargetRequest) -> String {
        switch target {
        case .screen: "screen"
        case .allScreens: "all-screens"
        case .frontmost: "frontmost"
        case .app: "app"
        case .pid: "pid"
        case .windowID: "window-id"
        case .area: "area"
        case .menubar: "menubar"
        case .menubarPopover: "menubar-popover"
        }
    }

    private static func resolvedKind(_ kind: ResolvedObservationKind) -> String {
        switch kind {
        case .screen: "screen"
        case .frontmost: "frontmost"
        case .appWindow: "app-window"
        case .windowID: "window-id"
        case .area: "area"
        case .menubar: "menubar"
        case .menubarPopover: "menubar-popover"
        }
    }
}
