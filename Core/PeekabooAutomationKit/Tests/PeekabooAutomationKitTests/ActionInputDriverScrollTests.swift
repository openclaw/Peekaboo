import AppKit
import ApplicationServices
import AXorcist
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

extension ActionInputDriverTests {
    @Test
    func `ambiguous scroll action failure is not fallback eligible`() {
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .targetUnavailable))
        #expect(ActionInputDriver.scrollFallbackErrorForTesting(from: .targetUnavailable) == .targetUnavailable)
    }

    @Test
    func `scroll action keeps stale and permission errors as hard failures`() {
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .staleElement))
        #expect(!ActionInputDriver.shouldContinueTryingScrollActionForTesting(after: .permissionDenied))
        #expect(ActionInputDriver.scrollFallbackErrorForTesting(from: .staleElement) == .staleElement)
    }

    @MainActor
    @Test
    func `directional scroll ignores scroll to visible action`() {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollToVisible"])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)
            Issue.record("Expected scroll-to-visible-only element to fall back")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
            #expect(element.performedActions.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func `directional scroll performs page scroll action`() throws {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(result.outcome.dispatchState.unitCount == .one)
        #expect(element.performedActions == ["AXScrollDownByPage"])
    }

    @MainActor
    @Test
    func `multi page scroll reports every accepted page unit`() throws {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 3)

        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(element.performedActions == Array(repeating: "AXScrollDownByPage", count: 3))
    }

    @MainActor
    @Test
    func `accepted page prefix stops before scrollbar fallback`() {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: "unknown",
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar],
            actionFailureAfterSuccesses: 1,
            sequencedActionFailure: AccessibilitySystemError(.actionUnsupported))

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed partial page-scroll failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollArea.performedActions == ["AXScrollDownByPage"])
        #expect(scrollBar.attemptedActions.isEmpty)
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `ambiguous page failure counts the possible unit and stops fallback`() {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: "unknown",
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar],
            actionFailureAfterSuccesses: 1,
            sequencedActionFailure: AccessibilitySystemError(.cannotComplete))

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed indeterminate page-scroll failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollArea.performedActions == ["AXScrollDownByPage"])
        #expect(scrollBar.attemptedActions.isEmpty)
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test(arguments: ["AXScrollDownByPage", "AXIncrement"], [false, true])
    func `first ambiguous native scroll unit stops without replay`(actionName: String, rejectsValueWrite: Bool) {
        let isPageAction = actionName == "AXScrollDownByPage"
        let initialValue: UIElementValue = rejectsValueWrite ? .double(0.2) : .string("unknown")
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: initialValue.accessibilityValue,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            actionErrors: isPageAction ? [:] : [actionName: AccessibilitySystemError(.cannotComplete)],
            valueSetterError: rejectsValueWrite ? AccessibilitySystemError(.attributeUnsupported) : nil)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: isPageAction ? [actionName, "AXPageDown"] : [],
            children: [scrollBar],
            actionErrors: isPageAction ? [actionName: AccessibilitySystemError(.cannotComplete)] : [:])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 4)
            Issue.record("Expected a typed indeterminate first-unit failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollArea.attemptedActions + scrollBar.attemptedActions == [actionName])
        #expect(scrollArea.performedActions.isEmpty)
        #expect(scrollBar.performedActions.isEmpty)
        #expect(scrollBar.setValues == (rejectsValueWrite ? [.double(0.2 + 0.1 * 4)] : []))
    }

    @MainActor
    @Test
    func `directional scroll reports fallback page action that actually ran`() throws {
        let element = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXPageDown"])

        let result = try ActionInputDriver().tryScrollForTesting(element: element, direction: .down, pages: 1)

        #expect(result.actionName == "AXPageDown")
        #expect(element.performedActions == ["AXPageDown"])
    }

    @MainActor
    @Test
    func `numeric scroll bar takes priority over advertised page and increment actions`() throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            actionErrors: [AXActionNames.kAXIncrementAction: AccessibilitySystemError(.cannotComplete)])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar],
            actionErrors: ["AXScrollDownByPage": AccessibilitySystemError(.cannotComplete)])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: .down,
            pages: 3)

        #expect(result.actionName == "AXSetValue")
        #expect(result.elementRole == AXRoleNames.kAXScrollBarRole)
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.outcome.dispatchState.unitCount == .one)
        #expect(scrollBar.setValues == [.double(0.5)])
        #expect(scrollArea.attemptedActions.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [0.05, 1e-10, 2.0])
    func `numeric scroll honors every positive finite increment`(increment: Double) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            doubleAttributes: [AXAttributeNames.kAXValueIncrementAttribute: increment])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollBar, direction: .down, pages: 3)

        let expectedValue = min(1, 0.2 + min(increment, 1) * 3)
        #expect(scrollBar.setValues == [.double(expectedValue)])
        #expect(scrollBar.attemptedActions.isEmpty)
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.outcome.dispatchState.unitCount == .one)
    }

    @MainActor
    @Test(arguments: [0.0, -0.1, Double.nan, Double.infinity, -Double.infinity])
    func `invalid advertised increment uses one tenth of numeric range`(increment: Double) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true,
            doubleAttributes: [AXAttributeNames.kAXValueIncrementAttribute: increment])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollBar, direction: .down, pages: 3)

        #expect(scrollBar.setValues == [.double(0.5)])
        #expect(result.outcome.dispatchState.unitCount == .one)
    }

    @MainActor
    @Test
    func `numeric scroll respects advertised bounds and accumulates units into one write`() throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 14.0,
            isValueSettable: true,
            doubleAttributes: [
                AXAttributeNames.kAXMinValueAttribute: 10,
                AXAttributeNames.kAXMaxValueAttribute: 30,
                AXAttributeNames.kAXValueIncrementAttribute: 3,
            ])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollBar, direction: .down, pages: 4)

        #expect(scrollBar.setValues == [.double(26)])
        #expect(result.outcome.dispatchState.unitCount == .one)
    }

    @MainActor
    @Test(arguments: [false, true])
    func `numeric scroll clamps at either boundary and does not dispatch an existing boundary`(towardEnd: Bool) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.5,
            actionNames: [AXActionNames.kAXIncrementAction, AXActionNames.kAXDecrementAction],
            isValueSettable: true)
        let direction: PeekabooFoundation.ScrollDirection = towardEnd ? .down : .up

        let changed = try ActionInputDriver().tryScrollForTesting(element: scrollBar, direction: direction, pages: 20)
        let unchanged = try ActionInputDriver().tryScrollForTesting(element: scrollBar, direction: direction, pages: 20)

        #expect(scrollBar.setValues == [.double(towardEnd ? 1 : 0)])
        #expect(scrollBar.attemptedActions.isEmpty)
        #expect(changed.outcome.state == .confirmedChange)
        #expect(changed.outcome.dispatchState.unitCount == .one)
        #expect(unchanged.outcome.state == .confirmedNoChange)
        #expect(unchanged.outcome.dispatchState == .none)
    }

    @MainActor
    @Test(arguments: [
        UIElementValue.bool(true),
        .string("0.2"),
        .double(.nan),
        .double(.infinity),
        .double(-.infinity),
        .double(-0.1),
        .double(1.1),
    ])
    func `ineligible numeric scroll values retain the page action route`(value: UIElementValue) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: value.accessibilityValue,
            isValueSettable: true)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 2)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(scrollArea.attemptedActions == ["AXScrollDownByPage", "AXScrollDownByPage"])
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test(arguments: [false, true])
    func `missing or read only numeric scroll value retains the page route`(missingValue: Bool) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: missingValue ? nil : 0.2,
            isValueSettable: missingValue)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 1)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test(arguments: [
        (Double.nan, 1.0),
        (-Double.infinity, 1.0),
        (0.0, Double.nan),
        (0.0, Double.infinity),
        (1.0, 0.0),
        (0.5, 0.5),
        (-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude),
    ])
    func `invalid numeric scroll ranges retain the page action route`(bounds: (Double, Double)) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true,
            doubleAttributes: [
                AXAttributeNames.kAXMinValueAttribute: bounds.0,
                AXAttributeNames.kAXMaxValueAttribute: bounds.1,
            ])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 1)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `horizontal scroll selects the horizontal descendant scroll bar`() throws {
        let vertical = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true)
        let horizontal = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 0, y: 400, width: 300, height: 16),
            value: 0.7,
            isValueSettable: true)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [vertical, horizontal])

        _ = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: .left,
            pages: 2)

        #expect(vertical.setValues.isEmpty)
        guard case let .double(value) = horizontal.setValues.first else {
            Issue.record("Expected a direct numeric scroll-bar update")
            return
        }
        #expect(abs(value - 0.5) < 1e-9)
    }

    @MainActor
    @Test(arguments: [false, true], [false, true])
    func `known scroll orientation establishes axis without usable shape`(
        horizontal: Bool,
        missingFrame: Bool) throws
    {
        let orientation = horizontal ? kAXHorizontalOrientationValue as String : kAXVerticalOrientationValue as String
        let pageAction = horizontal ? "AXScrollRightByPage" : "AXScrollDownByPage"
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: missingFrame ? nil : CGRect(x: 10, y: 20, width: 16, height: 16),
            value: 0.2,
            isValueSettable: true,
            stringAttributes: [kAXOrientationAttribute as String: orientation])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: [pageAction],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: horizontal ? .right : .down,
            pages: 2)

        #expect(result.actionName == "AXSetValue")
        #expect(scrollBar.setValues == [.double(0.4)])
        #expect(scrollArea.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [false, true])
    func `matching known scroll orientation overrides conflicting shape`(horizontal: Bool) throws {
        let orientation = horizontal ? kAXHorizontalOrientationValue as String : kAXVerticalOrientationValue as String
        let pageAction = horizontal ? "AXScrollRightByPage" : "AXScrollDownByPage"
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 10, y: 20, width: horizontal ? 16 : 400, height: horizontal ? 400 : 16),
            value: 0.2,
            isValueSettable: true,
            stringAttributes: [kAXOrientationAttribute as String: orientation])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: [pageAction],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: horizontal ? .right : .down,
            pages: 2)

        #expect(result.actionName == "AXSetValue")
        #expect(scrollBar.setValues == [.double(0.4)])
        #expect(scrollArea.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [false, true])
    func `wrong known scroll orientation cannot use matching shape to preempt page action`(horizontal: Bool) throws {
        let orientation = horizontal ? kAXVerticalOrientationValue as String : kAXHorizontalOrientationValue as String
        let pageAction = horizontal ? "AXScrollRightByPage" : "AXScrollDownByPage"
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 10, y: 20, width: horizontal ? 400 : 16, height: horizontal ? 16 : 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            stringAttributes: [kAXOrientationAttribute as String: orientation])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: [pageAction],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: horizontal ? .right : .down,
            pages: 1)

        #expect(result.actionName == pageAction)
        #expect(scrollArea.attemptedActions == [pageAction])
        #expect(scrollBar.setValues.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [nil, "AXUnknownOrientation", "unrecognized"] as [String?], [false, true])
    func `unproven orientation can use independently valid scroll geometry`(
        orientation: String?,
        horizontal: Bool) throws
    {
        let pageAction = horizontal ? "AXScrollRightByPage" : "AXScrollDownByPage"
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 10, y: 20, width: horizontal ? 400 : 16, height: horizontal ? 16 : 400),
            value: 0.2,
            isValueSettable: true,
            stringAttributes: orientation.map { [kAXOrientationAttribute as String: $0] } ?? [:])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: [pageAction],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: horizontal ? .right : .down,
            pages: 2)

        #expect(result.actionName == "AXSetValue")
        #expect(scrollBar.setValues == [.double(0.4)])
        #expect(scrollArea.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [
        nil,
        CGRect(x: 10, y: 20, width: 16, height: 16),
        CGRect(x: 10, y: 20, width: 0, height: 400),
        CGRect(x: 10, y: 20, width: 16, height: 0),
        CGRect(x: 10, y: 20, width: -16, height: 400),
        CGRect(x: 10, y: 20, width: 16, height: -400),
        CGRect(x: 10, y: 20, width: CGFloat.nan, height: 400),
        CGRect(x: 10, y: 20, width: 16, height: CGFloat.infinity),
        CGRect(x: CGFloat.infinity, y: 20, width: 16, height: 400),
        CGRect(x: 10, y: CGFloat.nan, width: 16, height: 400),
    ] as [CGRect?], [false, true])
    func `unproven scroll axis preserves the working page route`(frame: CGRect?, unknownOrientation: Bool) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: frame,
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            stringAttributes: unknownOrientation ? [
                kAXOrientationAttribute as String: kAXUnknownOrientationValue as String,
            ] : [:])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 1)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(scrollArea.attemptedActions == ["AXScrollDownByPage"])
        #expect(scrollBar.setValues.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test
    func `scroll chooses the requested area bar before a nested area bar`() throws {
        let nestedBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 280, y: 20, width: 16, height: 120),
            value: 0.3,
            isValueSettable: true)
        let nestedArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [nestedBar])
        let targetBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.1,
            isValueSettable: true)
        let targetArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [
                ActionInputMockAutomationElement(role: AXRoleNames.kAXGroupRole, children: [nestedArea]),
                targetBar,
            ])

        _ = try ActionInputDriver().tryScrollForTesting(
            element: targetArea,
            direction: .down,
            pages: 1)

        #expect(targetBar.setValues == [.double(0.2)])
        #expect(nestedBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `scroll does not borrow a nested area bar when the target has none`() {
        let nestedBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 280, y: 20, width: 16, height: 120),
            value: 0.3,
            isValueSettable: true)
        let targetArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [
                ActionInputMockAutomationElement(
                    role: AXRoleNames.kAXGroupRole,
                    children: [ActionInputMockAutomationElement(
                        role: AXRoleNames.kAXScrollAreaRole,
                        children: [nestedBar])]),
            ])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(
                element: targetArea,
                direction: .down,
                pages: 1)
            Issue.record("Expected a target without its own vertical scroll bar to fail")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(nestedBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `scroll bar increment action remains available without a numeric value route`() throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: "unknown",
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(
            element: scrollArea,
            direction: .down,
            pages: 2)

        #expect(result.actionName == AXActionNames.kAXIncrementAction)
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(scrollBar.performedActions == [AXActionNames.kAXIncrementAction, AXActionNames.kAXIncrementAction])
        #expect(scrollBar.setValues.isEmpty)
    }

    @MainActor
    @Test
    func `accepted scrollbar prefix stops without replay`() {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: "unknown",
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            actionFailureAfterSuccesses: 1,
            sequencedActionFailure: AccessibilitySystemError(.actionUnsupported))
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [scrollBar])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed partial scrollbar failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 1)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollBar.performedActions == [AXActionNames.kAXIncrementAction])
        #expect(scrollBar.setValues.isEmpty)
    }
}

extension ActionInputDriverTests {
    @MainActor
    @Test
    func `unchanged numeric AXValue readback is indeterminate without action fallback`() {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            valueSetterDoesNotChange: true)
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected a typed indeterminate AXValue failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollBar.setValues == [.double(0.5)])
        #expect(scrollArea.attemptedActions.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [AXError.cannotComplete, AXError.failure])
    func `ambiguous numeric AXValue failure stops without action fallback`(error: AXError) {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            valueSetterError: AccessibilitySystemError(error))
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 4)
            Issue.record("Expected a typed indeterminate AXValue failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollBar.setValues == [.double(0.2 + 0.1 * 4)])
        #expect(scrollBar.value as? Double == 0.2)
        #expect(scrollArea.attemptedActions.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func `nonfinite numeric scroll readback remains unverified without action fallback`(readback: Double) throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            valueSetterReadbackOverride: .double(readback))
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)

        #expect(result.actionName == "AXSetValue")
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.outcome.dispatchState.unitCount == .one)
        #expect(result.outcome.retrySafety == .unsafe)
        #expect(scrollBar.setValues == [.double(0.5)])
        #expect(scrollArea.attemptedActions.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test
    func `targeted scroll never mutates a sibling scroll area`() {
        let targetArea = ActionInputMockAutomationElement(role: AXRoleNames.kAXScrollAreaRole)
        let siblingBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            isValueSettable: true)
        _ = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXGroupRole,
            children: [
                targetArea,
                ActionInputMockAutomationElement(role: AXRoleNames.kAXScrollAreaRole, children: [siblingBar]),
            ])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(
                element: targetArea,
                direction: .down,
                pages: 1)
            Issue.record("Expected the target without a native scroll control to fail")
        } catch let error as ActionInputError {
            #expect(error == .unsupported(.actionUnsupported))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(siblingBar.setValues.isEmpty)
    }

    @MainActor
    @Test(arguments: [1, 4])
    func `definitively rejected numeric value falls back to page actions without inflating dispatch count`(
        pages: Int) throws
    {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            valueSetterError: AccessibilitySystemError(.attributeUnsupported))
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: pages)

        #expect(result.actionName == "AXScrollDownByPage")
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.evidence == .deliveryAccepted)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(result.outcome.dispatchState.unitCount?.rawValue == pages)
        #expect(scrollArea.attemptedActions == Array(repeating: "AXScrollDownByPage", count: pages))
        #expect(scrollArea.performedActions == scrollArea.attemptedActions)
        #expect(scrollBar.setValues == [.double(0.2 + 0.1 * Double(pages))])
        #expect(scrollBar.value as? Double == 0.2)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test
    func `definitively rejected numeric value falls back to increment when page action is unavailable`() throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            valueSetterError: AccessibilitySystemError(.attributeUnsupported))
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)

        #expect(result.actionName == AXActionNames.kAXIncrementAction)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(scrollArea.attemptedActions.isEmpty)
        #expect(scrollBar.attemptedActions == Array(repeating: AXActionNames.kAXIncrementAction, count: 3))
        #expect(scrollBar.performedActions == scrollBar.attemptedActions)
        #expect(scrollBar.setValues == [.double(0.5)])
        #expect(scrollBar.value as? Double == 0.2)
    }

    @MainActor
    @Test
    func `rejected numeric value then accepted page prefix stays partial without increment replay`() {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            valueSetterError: AccessibilitySystemError(.attributeUnsupported))
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar],
            actionFailureAfterSuccesses: 1,
            sequencedActionFailure: AccessibilitySystemError(.actionUnsupported))

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected the accepted page prefix to remain authoritative")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .background))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollBar.setValues == [.double(0.5)])
        #expect(scrollBar.value as? Double == 0.2)
        #expect(scrollArea.attemptedActions == ["AXScrollDownByPage", "AXScrollDownByPage"])
        #expect(scrollArea.performedActions == ["AXScrollDownByPage"])
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test(arguments: [AXError.invalidUIElement, AXError.apiDisabled])
    func `stale or permission denied numeric value setter never falls back to actions`(axError: AXError) {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            valueSetterError: AccessibilitySystemError(axError))
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        do {
            _ = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)
            Issue.record("Expected the stale or permission error to stop scroll routing")
        } catch let error as ActionInputError {
            #expect(error == (axError == .apiDisabled ? .permissionDenied : .staleElement))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(scrollBar.setValues == [.double(0.5)])
        #expect(scrollBar.value as? Double == 0.2)
        #expect(scrollArea.attemptedActions.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }

    @MainActor
    @Test
    func `numeric route uses advertised increments even when mock page actions work`() throws {
        let scrollBar = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollBarRole,
            frame: CGRect(x: 300, y: 0, width: 16, height: 400),
            value: 0.2,
            actionNames: [AXActionNames.kAXIncrementAction],
            isValueSettable: true,
            doubleAttributes: [AXAttributeNames.kAXValueIncrementAttribute: 0.05])
        let scrollArea = ActionInputMockAutomationElement(
            role: AXRoleNames.kAXScrollAreaRole,
            actionNames: ["AXScrollDownByPage"],
            children: [scrollBar])

        let result = try ActionInputDriver().tryScrollForTesting(element: scrollArea, direction: .down, pages: 3)

        #expect(result.actionName == "AXSetValue")
        #expect(result.outcome.state == .confirmedChange)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.outcome.dispatchState.unitCount == .one)
        #expect(scrollBar.setValues == [.double(0.2 + 0.05 * 3)])
        #expect(scrollArea.attemptedActions.isEmpty)
        #expect(scrollBar.attemptedActions.isEmpty)
    }
}
