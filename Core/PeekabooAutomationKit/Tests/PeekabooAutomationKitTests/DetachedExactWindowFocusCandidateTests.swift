import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

struct DetachedExactWindowFocusCandidateTests {
    @Test(arguments: [KeyboardFocusValidationPhase.initial, .continuation])
    func `candidate filtering preserves role and frame decisions`(phase: KeyboardFocusValidationPhase) {
        let expected = FocusedElementIdentity(
            processIdentifier: 42,
            windowID: 7,
            role: "AXTextField",
            title: "Expected title",
            identifier: "expected-field",
            frame: CGRect(x: 10, y: 20, width: 100, height: 30))
        let roles: [String?] = [nil, "AXButton", expected.role]
        let frames: [CGRect?] = [nil, .zero, expected.frame, CGRect(x: 10, y: 20, width: 100, height: 60)]

        for role in roles {
            for frame in frames {
                var probes: [String] = []
                func readFrame() -> CGRect? {
                    probes.append("frame")
                    return frame
                }
                func readTitle() -> String? {
                    probes.append("title")
                    return "Observed title"
                }
                func readIdentifier() -> String? {
                    probes.append("identifier")
                    return "observed-field"
                }

                let candidate = DetachedExactWindowFocusReader.candidateIdentity(
                    observedRole: role,
                    expected: expected,
                    phase: phase,
                    frame: readFrame(),
                    metadata: (title: readTitle(), identifier: readIdentifier()))
                let previouslyEligible = role == expected.role && (phase == .continuation || frame == expected.frame)
                let previousCandidate: FocusedElementIdentity? = previouslyEligible
                    ? FocusedElementIdentity(
                        processIdentifier: expected.processIdentifier,
                        windowID: expected.windowID,
                        role: role ?? "",
                        title: "Observed title",
                        identifier: "observed-field",
                        frame: frame ?? .zero)
                    : nil

                #expect(candidate == previousCandidate)
                #expect(probes == (previouslyEligible ? ["frame", "title", "identifier"] :
                        role == expected.role ? ["frame"] : []))
            }
        }
    }
}
