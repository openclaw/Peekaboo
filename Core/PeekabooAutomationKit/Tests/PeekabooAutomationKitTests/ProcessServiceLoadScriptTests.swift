import AppKit
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@available(macOS 14.0, *)
@MainActor
final class ProcessServiceLoadScriptTests: XCTestCase {
    func testLoadScriptRejectsNestedNonLegacyParametersWithFlatSchemaHint() async throws {
        let processService = self.makeProcessService()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).peekaboo.json")

        let badScript = """
        {
          "description": "bad script",
          "steps": [
            {
              "stepId": "bad-params",
              "comment": null,
              "command": "app",
              "params": {
                "generic": {
                  "name": "Playground"
                }
              }
            }
          ]
        }
        """
        try badScript.data(using: .utf8)?.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await processService.loadScript(from: url.path)
            XCTFail("Expected loadScript to throw")
        } catch let error as PeekabooError {
            switch error {
            case let .invalidInput(message):
                XCTAssertTrue(message.contains("Invalid script JSON"), "Unexpected message: \(message)")
                XCTAssertTrue(message.contains("flat params object"), "Missing flat-schema tip: \(message)")
            default:
                XCTFail("Expected invalidInput, got: \(error)")
            }
        }
    }

    func testLoadScriptDecodesFlatModelFriendlyParameters() async throws {
        let processService = self.makeProcessService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flat-\(UUID().uuidString).peekaboo.json")
        let script = """
        {
          "description": "flat params",
          "steps": [
            {
              "stepId": "background-hotkey",
              "command": "hotkey",
              "params": {
                "pid": 4242,
                "key": "p",
                "modifiers": ["command", "shift"],
                "foreground": false,
                "snapshot": null
              }
            }
          ]
        }
        """
        try script.data(using: .utf8)?.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try await processService.loadScript(from: url.path)

        guard case let .generic(params) = loaded.steps.first?.params else {
            return XCTFail("Expected flat params to decode as generic parameters for command normalization")
        }
        XCTAssertEqual(params["pid"], "4242")
        XCTAssertEqual(params["key"], "p")
        XCTAssertEqual(params["modifiers"], "command,shift")
        XCTAssertEqual(params["foreground"], "false")
        XCTAssertNil(params["snapshot"])
    }

    func testScriptEncodingUsesFlatParametersAndRoundTrips() throws {
        let script = PeekabooScript(description: "round trip", steps: [
            ScriptStep(
                stepId: "type",
                comment: nil,
                command: "type",
                params: .type(.init(
                    text: "hello",
                    app: "TextEdit",
                    foreground: false,
                    clearFirst: true))),
        ])

        let data = try JSONEncoder().encode(script)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""params":{"#))
        XCTAssertTrue(json.contains(#""app":"TextEdit""#))
        XCTAssertFalse(json.contains(#""_0""#))
        XCTAssertFalse(json.contains(#""generic""#))

        let decoded = try JSONDecoder().decode(PeekabooScript.self, from: data)
        guard case let .generic(params) = decoded.steps.first?.params else {
            return XCTFail("Expected stable flat params after round trip")
        }
        XCTAssertEqual(params["text"], "hello")
        XCTAssertEqual(params["app"], "TextEdit")
        XCTAssertEqual(params["foreground"], "false")
        XCTAssertEqual(params["clearFirst"], "true")
    }

    func testLoadScriptStillAcceptsLegacyEnumParameters() async throws {
        let processService = self.makeProcessService()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).peekaboo.json")
        let script = """
        {
          "description": "legacy params",
          "steps": [{
            "stepId": "sleep",
            "command": "sleep",
            "params": {"generic": {"_0": {"duration": "0.1"}}}
          }]
        }
        """
        try script.data(using: .utf8)?.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try await processService.loadScript(from: url.path)

        guard case let .generic(params) = loaded.steps.first?.params else {
            return XCTFail("Expected legacy generic parameters")
        }
        XCTAssertEqual(params["duration"], "0.1")
    }

    func testCheckedInRunFixturesUseLoadableFlatSchema() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtures = repositoryRoot.appendingPathComponent("docs/testing/fixtures")
        let fixtureNames = [
            "clipboard-smoke.peekaboo.json",
            "playground-no-fail-fast.peekaboo.json",
            "playground-smoke.peekaboo.json",
        ]
        let processService = self.makeProcessService()

        for fixtureName in fixtureNames {
            let script = try await processService.loadScript(
                from: fixtures.appendingPathComponent(fixtureName).path)
            XCTAssertFalse(script.steps.isEmpty, "\(fixtureName) should contain runnable steps")
            XCTAssertTrue(script.steps.allSatisfy { step in
                guard let params = step.params else { return true }
                guard case .generic = params else { return false }
                return true
            }, "\(fixtureName) should decode through the stable flat params schema")
        }
    }

    func testLoadScriptExpandsHomeDirectoryPath() async throws {
        let processService = self.makeProcessService()
        let relativePath = "Library/Caches/peekaboo-script-\(UUID().uuidString).peekaboo.json"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        let tildePath = "~/\(relativePath)"
        let script = """
        {
          "description": "home path script",
          "steps": []
        }
        """
        try script.data(using: .utf8)?.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try await processService.loadScript(from: tildePath)

        XCTAssertEqual(loaded.description, "home path script")
    }

    private func makeProcessService() -> ProcessService {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)

        return ProcessService(
            applicationService: UnusedApplicationService(),
            screenCaptureService: UnusedScreenCaptureService(),
            snapshotManager: UnusedSnapshotManager(),
            uiAutomationService: UnusedUIAutomationService(),
            windowManagementService: UnusedWindowManagementService(),
            menuService: UnusedMenuService(),
            dockService: UnusedDockService(),
            clipboardService: clipboard)
    }
}
