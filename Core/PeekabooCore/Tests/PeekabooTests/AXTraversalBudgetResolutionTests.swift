import Foundation
@_spi(Testing) import PeekabooAutomationKit
import Testing

@Suite(.serialized, .tags(.fast))
struct AXTraversalBudgetResolutionTests {
    @Test
    func `built in defaults use wider traversal caps`() {
        let budget = AXTraversalBudget()

        #expect(budget.maxDepth == 12)
        #expect(budget.maxElementCount == 1000)
        #expect(budget.maxChildrenPerNode == 250)
    }

    @Test
    func `env values are read with whitespace and newline trimming`() {
        let environment = [
            "PEEKABOO_AX_MAX_DEPTH": " 14\n",
            "PEEKABOO_AX_MAX_ELEMENTS": "\t1500 ",
            "PEEKABOO_AX_MAX_CHILDREN": " 500\n",
        ]

        let budget = AXTraversalBudget.resolved(environment: environment)

        #expect(budget.maxDepth == 14)
        #expect(budget.maxElementCount == 1500)
        #expect(budget.maxChildrenPerNode == 500)
    }

    @Test
    func `invalid env values fall back to built in defaults`() {
        let environment = [
            "PEEKABOO_AX_MAX_DEPTH": "",
            "PEEKABOO_AX_MAX_ELEMENTS": "-1",
            "PEEKABOO_AX_MAX_CHILDREN": "nope",
        ]

        let budget = AXTraversalBudget.resolved(environment: environment)

        #expect(budget == AXTraversalBudget())
    }

    @Test
    func `explicit values win over environment values`() {
        let environment = [
            "PEEKABOO_AX_MAX_DEPTH": "20",
            "PEEKABOO_AX_MAX_ELEMENTS": "2000",
            "PEEKABOO_AX_MAX_CHILDREN": "600",
        ]

        let budget = AXTraversalBudget.resolved(
            maxDepth: 3,
            maxElementCount: 4,
            maxChildrenPerNode: 5,
            environment: environment)

        #expect(budget.maxDepth == 3)
        #expect(budget.maxElementCount == 4)
        #expect(budget.maxChildrenPerNode == 5)
    }

    @Test
    func `single env helper rejects zero negative and non numeric values`() {
        #expect(AXTraversalBudget.intFromEnv("LIMIT", default: 7, environment: [:]) == 7)
        #expect(AXTraversalBudget.intFromEnv("LIMIT", default: 7, environment: ["LIMIT": "0"]) == 7)
        #expect(AXTraversalBudget.intFromEnv("LIMIT", default: 7, environment: ["LIMIT": "-1"]) == 7)
        #expect(AXTraversalBudget.intFromEnv("LIMIT", default: 7, environment: ["LIMIT": "x"]) == 7)
        #expect(AXTraversalBudget.intFromEnv("LIMIT", default: 7, environment: ["LIMIT": "1"]) == 1)
    }

    @Test
    func `desktop detection options default resolves environment overrides`() throws {
        try withTraversalEnvironment(depth: 15, elements: 1600, children: 550) {
            let options = DesktopDetectionOptions()

            #expect(options.traversalBudget.maxDepth == 15)
            #expect(options.traversalBudget.maxElementCount == 1600)
            #expect(options.traversalBudget.maxChildrenPerNode == 550)
        }
    }

    @Test
    func `old desktop detection payload resolves environment overrides when budget is absent`() throws {
        try withTraversalEnvironment(depth: 16, elements: 1700, children: 560) {
            let options = DesktopDetectionOptions(
                mode: .accessibility,
                allowWebFocusFallback: false,
                includeMenuBarElements: true,
                preferOCR: false)
            let encoded = try JSONEncoder().encode(options)
            var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            payload.removeValue(forKey: "traversalBudget")
            let data = try JSONSerialization.data(withJSONObject: payload)

            let decoded = try JSONDecoder().decode(DesktopDetectionOptions.self, from: data)

            #expect(decoded.traversalBudget.maxDepth == 16)
            #expect(decoded.traversalBudget.maxElementCount == 1700)
            #expect(decoded.traversalBudget.maxChildrenPerNode == 560)
        }
    }
}

private func withTraversalEnvironment(
    depth: Int,
    elements: Int,
    children: Int,
    _ body: () throws -> Void) throws
{
    setenv(AXTraversalBudget.maxDepthEnvironmentKey, String(depth), 1)
    setenv(AXTraversalBudget.maxElementCountEnvironmentKey, String(elements), 1)
    setenv(AXTraversalBudget.maxChildrenPerNodeEnvironmentKey, String(children), 1)
    defer { unsetTraversalEnvironment() }
    try body()
}

private func unsetTraversalEnvironment() {
    unsetenv(AXTraversalBudget.maxDepthEnvironmentKey)
    unsetenv(AXTraversalBudget.maxElementCountEnvironmentKey)
    unsetenv(AXTraversalBudget.maxChildrenPerNodeEnvironmentKey)
}
