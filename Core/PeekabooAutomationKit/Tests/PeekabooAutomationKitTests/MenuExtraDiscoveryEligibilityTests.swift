import AppKit
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuExtraDiscoveryEligibilityTests {
    @Test(arguments: [NSApplication.ActivationPolicy.regular, .accessory])
    func `ordinary and menu-bar-only GUI applications remain eligible`(_ policy: NSApplication.ActivationPolicy) {
        #expect(MenuExtraDiscoveryReaders.permitsApplicationExtrasScan(
            activationPolicy: policy, isTerminated: false))
    }

    @Test
    func `background-only non-UI agents are excluded from the per-application extras scan`() {
        #expect(!MenuExtraDiscoveryReaders.permitsApplicationExtrasScan(
            activationPolicy: .prohibited, isTerminated: false))
    }

    @Test(arguments: [NSApplication.ActivationPolicy.regular, .accessory, .prohibited])
    func `terminated applications never enter the extras scan`(_ policy: NSApplication.ActivationPolicy) {
        #expect(!MenuExtraDiscoveryReaders.permitsApplicationExtrasScan(
            activationPolicy: policy, isTerminated: true))
    }

    @Test(arguments: [NSApplication.ActivationPolicy.regular, .accessory])
    func `eligible GUI owner read failures remain incomplete rather than empty`(
        _ policy: NSApplication.ActivationPolicy) throws
    {
        guard MenuExtraDiscoveryReaders.permitsApplicationExtrasScan(
            activationPolicy: policy, isTerminated: false)
        else {
            Issue.record("GUI status-item owner was excluded")
            return
        }
        var reads = 0
        do {
            _ = try MenuExtraAXReader.readSynchronously(
                owner: .init(processIdentifier: 42, processStartIdentity: 99),
                deadline: .now.advanced(by: .seconds(1)),
                copyAttribute: { _, name in
                    #expect(name == "AXExtrasMenuBar")
                    reads += 1
                    return (nil, .cannotComplete)
                },
                processGeneration: { _ in 99 },
                setMessagingTimeout: { _, _ in .success })
            Issue.record("Incomplete GUI owner read was accepted as an empty inventory")
        } catch let PeekabooError.accessibilityIncomplete(message) {
            #expect(message.contains("scope=application"))
            #expect(message.contains("attribute=AXExtrasMenuBar"))
            #expect(message.contains("native_error=\(AXError.cannotComplete.rawValue)"))
        }
        #expect(reads == 1)
    }
}
