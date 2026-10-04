import PeekabooFoundation

extension BackgroundInputDriver {
    @MainActor
    static func performSinglePositionalClick(
        resolveAccessibilityTarget: () throws -> (
            element: any AutomationElementRepresenting,
            action: PositionalClickAction)?,
        allowsAccessibilityValueDelivery: Bool,
        routedClick: () async throws -> DesktopActionOutcome) async throws -> DesktopActionOutcome
    {
        try Task.checkCancellation()
        guard let resolved = try resolveAccessibilityTarget() else {
            // Only the read-only resolver's unsupported result admits native fallback, never a failed AX write.
            return try await routedClick()
        }
        return try await self.performPositionalClickAction(
            resolved.action,
            on: resolved.element,
            allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery)
    }
}
