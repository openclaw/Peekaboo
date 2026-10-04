import AXorcist
import CoreGraphics
import os.log
import PeekabooFoundation

extension BackgroundInputDriver {
    private static let positionalClickLogger = Logger(subsystem: "boo.peekaboo.core", category: "BackgroundInputDriver")
    private static let nonPressableContainerRoles: Set<String> = [
        "AXApplication", "AXGroup", "AXLayoutArea", "AXRadioGroup", "AXScrollArea", "AXWebArea", "AXWindow",
    ]

    struct PositionalClickObservation {
        let element: any AutomationElementRepresenting
        let authoritativeHit: Bool
        let frame: CGRect?
        let role: String?
        let subrole: String?
        let actions: [String]
        let isEnabled: Bool
        let isSelectedSettable: Bool
        let isFocusedSettable: Bool
    }

    enum PositionalClickResolution {
        case accessibility(element: any AutomationElementRepresenting, action: PositionalClickAction)
        case unsupported
    }

    static func isPositionalPressRole(_ role: String?) -> Bool {
        !self.nonPressableContainerRoles.contains(role ?? "")
    }

    /// Keeps hit, descendant, then ancestor ordering. Only the native hit bypasses the frame check.
    @MainActor
    static func positionalClickTarget(
        inObservations observations: [PositionalClickObservation],
        at point: CGPoint,
        button: MouseButton) -> (element: any AutomationElementRepresenting, action: PositionalClickAction)?
    {
        let spatiallyValid = observations.filter { $0.authoritativeHit || $0.frame?.contains(point) == true }
        let requiredAction = button == .right ? AXActionNames.kAXShowMenuAction : AXActionNames.kAXPressAction
        if let actionable = spatiallyValid.first(where: {
            $0.isEnabled &&
                $0.actions.contains(requiredAction) &&
                (button == .right || self.isPositionalPressRole($0.role))
        }) {
            let role = actionable.role ?? "<none>"
            let frame = String(describing: actionable.frame)
            self.positionalClickLogger.debug(
                """
                Resolved background positional click to role=\(role, privacy: .public) \
                action=\(requiredAction, privacy: .public) frame=\(frame, privacy: .public)
                """)
            return (actionable.element, button == .right ? .showMenu : .press)
        }

        guard button == .left else { return nil }
        if let row = spatiallyValid.first(where: {
            $0.isEnabled && $0.role == AXRoleNames.kAXRowRole && $0.isSelectedSettable
        }) {
            return (row.element, .select)
        }
        if let focusable = spatiallyValid.first(where: {
            $0.isFocusedSettable && self.isPositionalFocusRole($0.role, subrole: $0.subrole)
        }) {
            let role = focusable.role ?? "<none>"
            let frame = String(describing: focusable.frame)
            self.positionalClickLogger.debug(
                """
                Resolved background positional click to role=\(role, privacy: .public) \
                action=focus frame=\(frame, privacy: .public)
                """)
            return (focusable.element, .focus)
        }
        self.positionalClickLogger.debug("No actionable background positional click target resolved")
        return nil
    }

    @MainActor
    static func performSinglePositionalClick(
        resolveAccessibilityTarget: () throws -> PositionalClickResolution,
        allowsAccessibilityValueDelivery: Bool,
        routedClick: () async throws -> DesktopActionOutcome) async throws -> DesktopActionOutcome
    {
        try Task.checkCancellation()
        switch try resolveAccessibilityTarget() {
        case .unsupported:
            // Only a complete unsupported observation admits fallback; unreadable AX state must throw.
            return try await routedClick()
        case let .accessibility(element, action):
            return try await self.performPositionalClickAction(
                action,
                on: element,
                allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
        }
    }
}
