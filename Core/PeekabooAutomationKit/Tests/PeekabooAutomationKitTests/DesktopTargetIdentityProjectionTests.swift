import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DesktopTargetIdentityProjectionTests {
    @Test
    func `process projection round trips its generation above JSON integer precision`() throws {
        let identity = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993))
        let projection = identity.projection

        #expect(projection.kind == .process)
        #expect(projection.processIdentifier == 42)
        #expect(projection.processStartIdentityDecimal == "9007199254740993")
        #expect(projection.windowID == nil)

        let data = try JSONEncoder().encode(projection)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "process")
        #expect(object["pid"] as? Int == 42)
        #expect(object["process_start_identity_decimal"] as? String == "9007199254740993")
        #expect(object["window_id"] == nil)
        #expect(try JSONDecoder().decode(DesktopTargetIdentity.Projection.self, from: data) == projection)
    }

    @Test
    func `window projection adds only its stable WindowServer identifier`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(
                processIdentifier: 73,
                processStartIdentity: UInt64.max - 3),
            windowID: 901)
        let projection = fixture.windowTargetIdentity.projection

        #expect(projection.kind == .window)
        #expect(projection.processIdentifier == 73)
        #expect(projection.processStartIdentityDecimal == String(UInt64.max - 3))
        #expect(projection.windowID == 901)

        let data = try JSONEncoder().encode(projection)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "window")
        #expect(object["window_id"] as? Int == 901)
        #expect(try JSONDecoder().decode(DesktopTargetIdentity.Projection.self, from: data) == projection)
    }
}
