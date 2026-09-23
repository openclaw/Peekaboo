import Foundation
import MCP
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAgentRuntime

struct MCPActionOutcomeResolutionTests {
    @Test
    func `canonical outcomes preserve typed fields through metadata resolution`() throws {
        let maximumUnitCount = try #require(DesktopActionOutcome.DispatchUnitCount(rawValue: Int.max))
        let outcomes = DesktopActionOutcomeFixtures.canonicalOutcomes + [
            DesktopActionOutcome.confirmedChange(
                delivery: DesktopActionOutcomeFixtures.backgroundAccessibilityDelivery,
                unitCount: maximumUnitCount),
        ]
        for outcome in outcomes {
            let resolution = try MCPToolResponseMetadataProjector.actionOutcomeResolution(
                from: Value(outcome.projection))
            #expect(resolution.projection == outcome.projection)
        }
    }

    @Test
    func `missing required fields remain absent`() throws {
        #expect(Self.isAbsent(MCPToolResponseMetadataProjector.actionOutcomeResolution(from: nil)))
        #expect(Self.isAbsent(MCPToolResponseMetadataProjector.actionOutcomeResolution(from: .null)))
        let fields = try MCPToolResponseMetadataProjector
            .fields(for: DesktopActionOutcome.confirmedNoChange().projection)
        for key in MCPToolResponseMetadataProjector.requiredActionOutcomeKeys {
            var incomplete = fields
            incomplete.removeValue(forKey: key)
            #expect(Self.isAbsent(MCPToolResponseMetadataProjector.actionOutcomeResolution(from: .object(incomplete))))
        }
    }

    @Test
    func `unsupported and contradictory outcome fields remain invalid`() throws {
        let fields = try MCPToolResponseMetadataProjector
            .fields(for: DesktopActionOutcome.confirmedNoChange().projection)
        let invalidFields: [(String, Value)] = [
            ("state", .string(String(repeating: "é", count: 65))),
            ("state", .string("unknown")),
            ("state", .null),
            ("retry_safe", .int(0)),
            ("mutation_dispatched", .bool(true)),
            ("dispatched_unit_count", .int(-1)),
            ("dispatched_unit_count", .double(1)),
            ("dispatched_unit_count", .array([])),
            ("dispatched_unit_count", .object([:])),
            ("dispatched_unit_count", .data(Data([1]))),
        ]
        for (key, value) in invalidFields {
            var invalid = fields
            invalid[key] = value
            let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: .object(invalid))
            guard case .invalid = resolution else {
                Issue.record("Expected invalid outcome for \(key): \(value)")
                continue
            }
        }
    }

    @Test
    func `unrelated metadata and null optional fields preserve canonical resolution`() throws {
        let outcome = DesktopActionOutcome.confirmedNoChange()
        var fields = try MCPToolResponseMetadataProjector.fields(for: outcome.projection)
        fields["delivery_mechanism"] = .null
        fields["delivery_mode"] = .null
        fields["dispatched_unit_count"] = .null
        fields["refusal_reason"] = .null
        fields["provider_meta"] = .object(["diagnostics": .string(String(repeating: "x", count: 1000))])

        let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(from: .object(fields))
        #expect(resolution.projection == outcome.projection)
    }

    private static func isAbsent(_ resolution: MCPToolResponseMetadataProjector.ActionOutcomeResolution) -> Bool {
        if case .absent = resolution {
            return true
        }
        return false
    }
}
