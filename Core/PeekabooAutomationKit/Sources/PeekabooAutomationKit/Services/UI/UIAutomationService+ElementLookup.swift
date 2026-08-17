import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

private struct UIAutomationAXSearchResult {
    let element: Element
    let frame: CGRect
    let label: String?
}

private struct UIAutomationAXSearchOutcome {
    let element: Element
    let frame: CGRect
    let label: String?
    let warnings: [String]
}

extension UIAutomationService {
    // MARK: - Accessibility and Focus

    public func hasAccessibilityPermission() async -> Bool {
        self.logger.debug("Checking accessibility permission")
        return AXPermissionHelpers.hasAccessibilityPermissions()
    }

    @MainActor
    public func getFocusedElement() -> UIFocusInfo? {
        self.logger.debug("Getting focused element")

        let systemWide = Element.systemWide()

        guard let focusedElement = systemWide.focusedUIElement() else {
            self.logger.debug("No focused element found")
            return nil
        }

        let elementPid = focusedElement.pid()
        let resolvedPid: pid_t? = {
            if let elementPid, elementPid > 0 {
                return elementPid
            }

            let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if let frontmostPid, frontmostPid > 0 {
                return frontmostPid
            }

            return nil
        }()

        return self.focusInfo(for: focusedElement, processIdentifier: resolvedPid)
    }

    public func getFocusedElement(targetProcessIdentifier: pid_t) async -> UIFocusInfo? {
        self.focusedElementNow(targetProcessIdentifier: targetProcessIdentifier)
    }

    private func focusedElementNow(targetProcessIdentifier: pid_t) -> UIFocusInfo? {
        guard targetProcessIdentifier > 0,
              let app = AXApp(pid: targetProcessIdentifier)
        else {
            return nil
        }

        app.element.setMessagingTimeout(0.25)
        defer { app.element.setMessagingTimeout(0) }
        guard let focusedElement = app.element.focusedUIElement() else { return nil }
        focusedElement.setMessagingTimeout(0.05)
        defer { focusedElement.setMessagingTimeout(0) }
        return self.focusInfo(for: focusedElement, processIdentifier: targetProcessIdentifier)
    }

    func requireExactWindowKeyboardFocus(
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect,
        expectedFocusedElement: FocusedElementIdentity? = nil) async throws
    {
        let identityValidator = self.exactWindowIdentityValidator
        let targetProcessIdentifier = expectedWindowIdentity.ownerProcessIdentifier
        let focused: ExactWindowFocusSnapshot?
        do {
            if let expectedFocusedElement {
                let reader = self.exactFocusedElementReader
                let result = try await ElementDetectionTimeoutRunner.runDetached(
                    targetProcessIdentifier: targetProcessIdentifier,
                    targetProcessStartIdentity: expectedWindowIdentity.ownerProcessStartIdentity,
                    seconds: 0.2)
                {
                    reader(expectedFocusedElement)
                }
                switch result {
                case let .success(value):
                    focused = value
                case let .failure(error):
                    throw error
                }
            } else {
                let reader = self.exactWindowFocusReader
                focused = try await ElementDetectionTimeoutRunner.runDetached(
                    targetProcessIdentifier: targetProcessIdentifier,
                    targetProcessStartIdentity: expectedWindowIdentity.ownerProcessStartIdentity,
                    seconds: 0.2)
                {
                    reader(targetProcessIdentifier)
                }
            }
        } catch let error as FocusedElementReceiptError {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Exact focused-element receipt is stale: \(error.localizedDescription)")
        } catch {
            throw self.exactWindowKeyboardFocusChangedError()
        }
        guard let focused,
              focused.processIdentifier == targetProcessIdentifier,
              focused.windowID == expectedWindowIdentity.windowID,
              !focused.frame.isEmpty,
              expectedWindowBounds.contains(CGPoint(x: focused.frame.midX, y: focused.frame.midY)),
              Self.focusedElementMatches(focused, expected: expectedFocusedElement),
              identityValidator(expectedWindowIdentity, expectedWindowBounds)
        else {
            throw self.exactWindowKeyboardFocusChangedError()
        }
    }

    private static func focusedElementMatches(
        _ focused: ExactWindowFocusSnapshot,
        expected: FocusedElementIdentity?) -> Bool
    {
        guard let expected else { return true }
        guard let windowID = focused.windowID, let role = focused.role else { return false }
        return FocusedElementReceiptResolver.matches(
            FocusedElementIdentity(
                processIdentifier: focused.processIdentifier,
                windowID: windowID,
                role: role,
                title: focused.title,
                identifier: focused.identifier,
                frame: focused.frame),
            expected: expected)
    }

    private func exactWindowKeyboardFocusChangedError() -> PeekabooError {
        PeekabooError.invalidInput(
            field: "target",
            reason: "Exact-window keyboard focus is not on the target window at dispatch. " +
                BackgroundKeyboardFocusRemediation.message)
    }

    private func focusInfo(for element: Element, processIdentifier: pid_t?) -> UIFocusInfo {
        let app = processIdentifier.flatMap { AXApp(pid: $0) }
        let runningApp = processIdentifier.flatMap { NSRunningApplication(processIdentifier: $0) }
        let window = element.attribute(Attribute<Element>(AXAttributeNames.kAXWindowAttribute))
        window?.setMessagingTimeout(0.05)
        defer { window?.setMessagingTimeout(0) }
        let windowID = AXWindowResolver().windowID(from: element.underlyingElement).map(Int.init) ?? window.flatMap {
            WindowIdentityService().getWindowID(from: $0, messagingTimeout: 0.05)
        }.map(Int.init)
        return UIFocusInfo(
            role: element.role() ?? "Unknown",
            title: element.title(),
            value: element.stringValue(),
            frame: element.frame() ?? .zero,
            applicationName: app?.localizedName ?? runningApp?.localizedName ?? "Unknown",
            bundleIdentifier: app?.bundleIdentifier ?? runningApp?.bundleIdentifier ?? "Unknown",
            processId: processIdentifier.map(Int.init) ?? 0,
            windowID: windowID,
            identifier: element.identifier())
    }

    // MARK: - Wait for Element

    public func waitForElement(
        target: ClickTarget,
        timeout: TimeInterval,
        snapshotId: String?) async throws -> WaitForElementResult
    {
        self.logger.debug("Waiting for element - target: \(String(describing: target)), timeout: \(timeout)s")

        var accumulatedWarnings: [String] = []

        if case .coordinates = target {
            return WaitForElementResult(found: true, element: nil, waitTime: 0, warnings: accumulatedWarnings)
        }

        let startTime = Date()
        let deadline = startTime.addingTimeInterval(timeout)
        let retryInterval: UInt64 = 100_000_000 // 100ms

        while Date() < deadline {
            let result = await self.locateElementForWait(target: target, snapshotId: snapshotId)
            accumulatedWarnings.append(contentsOf: result.warnings)
            if let element = result.element {
                let waitTime = Date().timeIntervalSince(startTime)
                self.logger.debug("Found element for target \(String(describing: target)) after \(waitTime)s")
                return WaitForElementResult(
                    found: true,
                    element: element,
                    waitTime: waitTime,
                    warnings: accumulatedWarnings)
            }

            try await Task.sleep(nanoseconds: retryInterval)
        }

        self.logger.debug("Element not found after \(timeout)s timeout")
        return WaitForElementResult(found: false, element: nil, waitTime: timeout, warnings: accumulatedWarnings)
    }

    public func findElement(
        matching criteria: UIElementSearchCriteria,
        in appName: String?) async throws -> DetectedElement
    {
        self.logger.debug("Finding element matching criteria in app: \(appName ?? "any")")

        let captureResult: CaptureResult
        if let appName {
            let appService = ApplicationService()
            _ = try await appService.findApplication(identifier: appName)

            captureResult = try await self.screenCaptureService.captureWindow(
                appIdentifier: appName,
                windowIndex: nil)
        } else {
            captureResult = try await self.screenCaptureService.captureScreen(displayIndex: nil)
        }

        let detectionResult = try await detectElements(
            in: captureResult.imageData,
            snapshotId: nil,
            windowContext: nil)

        let allElements = detectionResult.elements.all

        for element in allElements {
            switch criteria {
            case let .label(searchLabel):
                let searchLower = searchLabel.lowercased()
                if let label = element.label?.lowercased(), label.contains(searchLower) {
                    return element
                }
                if let value = element.value?.lowercased(), value.contains(searchLower) {
                    return element
                }

            case let .identifier(searchId):
                if element.id == searchId {
                    return element
                }

            case let .type(searchType):
                if element.type.rawValue.lowercased() == searchType.lowercased() {
                    return element
                }
            }
        }

        let description = switch criteria {
        case let .label(label):
            "with label '\(label)'"
        case let .identifier(id):
            "with ID '\(id)'"
        case let .type(type):
            "of type '\(type)'"
        }

        throw PeekabooError.elementNotFound("element \(description) in \(appName ?? "screen")")
    }

    // MARK: - Private Helpers

    private func locateElementForWait(
        target: ClickTarget,
        snapshotId: String?) async -> (element: DetectedElement?, warnings: [String])
    {
        switch target {
        case let .elementId(id):
            guard let snapshotId,
                  let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId)
            else {
                return (nil, [])
            }
            return (detectionResult.elements.findById(id), [])

        case let .query(query):
            if let element = await self.findElementInSession(query: query, snapshotId: snapshotId) {
                return (element, [])
            }
            guard let info = self.findElementByAccessibility(matching: query) else {
                return (nil, [])
            }
            return (
                DetectedElement(
                    id: "wait_found",
                    type: .other,
                    label: info.label ?? query,
                    value: nil,
                    bounds: info.frame,
                    isEnabled: true),
                info.warnings)

        case .coordinates:
            return (nil, [])
        }
    }

    private func findElementInSession(query: String, snapshotId: String?) async -> DetectedElement? {
        guard let snapshotId,
              let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId)
        else {
            return nil
        }

        return ClickService.resolveTargetElement(query: query, in: detectionResult)
    }

    private func findElementByAccessibility(matching query: String) -> UIAutomationAXSearchOutcome? {
        guard let app = MouseLocationUtilities.findApplicationAtMouseLocation() else {
            return nil
        }

        let appElement = AXApp(app).element

        let deadline = Date().addingTimeInterval(self.searchLimits.timeBudget)
        let searchContext = SearchContext(
            query: query.lowercased(),
            limits: self.searchLimits,
            deadline: deadline)
        let (result, warnings) = self.searchElementRecursively(
            in: appElement,
            depth: 0,
            context: searchContext,
            warnings: [])

        guard let result else { return nil }
        return UIAutomationAXSearchOutcome(
            element: result.element,
            frame: result.frame,
            label: result.label,
            warnings: warnings)
    }

    private struct SearchContext {
        let query: String
        let limits: UIAutomationSearchLimits
        let deadline: Date
    }

    private func searchElementRecursively(
        in element: Element,
        depth: Int,
        context: SearchContext,
        warnings: [String]) -> (result: UIAutomationAXSearchResult?, warnings: [String])
    {
        var currentWarnings = warnings

        let limits = context.limits
        if depth > limits.maxDepth {
            self.logger.debug("AX search aborted: maxDepth reached at depth \(depth)")
            currentWarnings.append("depth_limit")
            return (nil, currentWarnings)
        }

        if Date() > context.deadline {
            self.logger.debug("AX search aborted: time budget exceeded")
            currentWarnings.append("time_budget_exceeded")
            return (nil, currentWarnings)
        }

        let title = element.title()?.lowercased() ?? ""
        let label = element.label()?.lowercased() ?? ""
        let value = element.stringValue()?.lowercased() ?? ""
        let roleDescription = element.roleDescription()?.lowercased() ?? ""

        if title.contains(context.query) || label.contains(context.query) ||
            value.contains(context.query) || roleDescription.contains(context.query)
        {
            if let frame = element.frame() {
                let displayLabel = element.title() ?? element.label() ?? element.roleDescription()
                return (
                    UIAutomationAXSearchResult(element: element, frame: frame, label: displayLabel),
                    currentWarnings)
            }
        }

        if let children = element.children() {
            let limitedChildren = children.prefix(limits.maxChildren)
            for child in limitedChildren {
                let (found, childWarnings) = self.searchElementRecursively(
                    in: child,
                    depth: depth + 1,
                    context: context,
                    warnings: currentWarnings)
                if let found {
                    return (found, childWarnings)
                }
            }

            if children.count > limits.maxChildren {
                self.logger.debug("AX search truncated children: \(children.count) > \(limits.maxChildren)")
                currentWarnings.append("child_limit")
            }
        }

        return (nil, currentWarnings)
    }
}
