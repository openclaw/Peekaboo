import PeekabooFoundation
import Testing

struct InteractionTargetSelectorPIDAliasTests {
    @Test(arguments: ["  PID:42  ", "pid:42", "  PiD:42  "])
    func `redundant CLI process aliases use the same normalized owner`(application: String) throws {
        let selector = InteractionTargetSelector(applicationIdentifier: application, processIdentifier: 42)
        try selector.validate(policy: .windowCLI())
        #expect(try selector.normalizedApplicationTarget(policy: .windowCLI()) ==
            selector.normalizedApplicationIdentifier)
    }

    @Test
    func `normalized aliases retain conflict and malformed PID diagnostics`() {
        #expect(throws: InteractionTargetSelector.ValidationError.conflictingProcessIdentifiers(
            application: 41, explicit: 42))
        {
            try InteractionTargetSelector(applicationIdentifier: "  pid:41  ", processIdentifier: 42)
                .validate(policy: .windowCLI())
        }
        #expect(throws: InteractionTargetSelector.ValidationError.invalidApplicationProcessIdentifier) {
            try InteractionTargetSelector(applicationIdentifier: "  pid:not-a-number  ", processIdentifier: 42)
                .validate(policy: .windowCLI())
        }
        #expect(throws: InteractionTargetSelector.ValidationError.applicationAndProcessIdentifier) {
            try InteractionTargetSelector(applicationIdentifier: "Preview", processIdentifier: 42)
                .validate(policy: .windowCLI())
        }
        #expect(throws: InteractionTargetSelector.ValidationError.applicationAndProcessIdentifier) {
            try InteractionTargetSelector(applicationIdentifier: "pid:42", processIdentifier: 42)
                .validate(policy: .interaction)
        }
    }
}
