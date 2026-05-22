import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite("GameBridge Detection Tests")
struct GameBridgeDetectionTests {
    @available(macOS 14.0, *)
    @Test
    func `Known app is recognized`() {
        #expect(GameBridgeDetectionService.isGameBridgeApp(appName: "firestaff"))
        #expect(GameBridgeDetectionService.isGameBridgeApp(appName: "Firestaff"))
    }

    @available(macOS 14.0, *)
    @Test
    func `Unknown app is not recognized`() {
        #expect(!GameBridgeDetectionService.isGameBridgeApp(appName: "Safari"))
        #expect(!GameBridgeDetectionService.isGameBridgeApp(appName: nil))
        #expect(!GameBridgeDetectionService.isGameBridgeApp(appName: ""))
    }

    @available(macOS 14.0, *)
    @Test
    func `Manifest parsing from temp file`() throws {
        let json = """
        {
          "version": 1,
          "app": "firestaff",
          "gameState": "gameplay",
          "framebuffer": { "width": 320, "height": 200 },
          "elements": [
            {
              "id": "MOVE_FWD",
              "type": "button",
              "label": "Forward",
              "bounds": { "x": 144, "y": 137, "w": 32, "h": 20 },
              "enabled": true,
              "value": null
            },
            {
              "id": "VIEWPORT",
              "type": "region",
              "label": "Dungeon View",
              "bounds": { "x": 0, "y": 0, "w": 224, "h": 136 },
              "enabled": true,
              "value": null
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let manifest = try JSONDecoder().decode(
            GameBridgeDetectionService.GameManifest.self,
            from: data
        )

        #expect(manifest.version == 1)
        #expect(manifest.app == "firestaff")
        #expect(manifest.gameState == "gameplay")
        #expect(manifest.framebuffer.width == 320)
        #expect(manifest.framebuffer.height == 200)
        #expect(manifest.elements.count == 2)
        #expect(manifest.elements[0].id == "MOVE_FWD")
        #expect(manifest.elements[0].type == "button")
        #expect(manifest.elements[0].bounds.x == 144)
        #expect(manifest.elements[1].id == "VIEWPORT")
    }

    @available(macOS 14.0, *)
    @Test
    func `Manifest elements default omitted optional Firestaff fields`() throws {
        let json = """
        {
          "version": 1,
          "app": "firestaff",
          "gameState": "gameplay",
          "framebuffer": { "width": 320, "height": 200 },
          "elements": [
            {
              "id": "MOVE_FWD",
              "type": "button",
              "label": "Forward",
              "bounds": { "x": 144, "y": 137, "w": 32, "h": 20 }
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let manifest = try JSONDecoder().decode(
            GameBridgeDetectionService.GameManifest.self,
            from: data
        )

        #expect(manifest.elements.count == 1)
        #expect(manifest.elements[0].enabled)
        #expect(manifest.elements[0].value == nil)
    }

    @available(macOS 14.0, *)
    @Test
    func `Element scaling with window bounds`() throws {
        let json = """
        {
          "version": 1,
          "app": "firestaff",
          "gameState": "gameplay",
          "framebuffer": { "width": 320, "height": 200 },
          "elements": [
            {
              "id": "B1",
              "type": "button",
              "label": "Test",
              "bounds": { "x": 160, "y": 100, "w": 32, "h": 20 },
              "enabled": true,
              "value": null
            }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let manifest = try JSONDecoder().decode(
            GameBridgeDetectionService.GameManifest.self,
            from: data
        )

        // Window is 2x the framebuffer at offset (50, 50)
        let windowBounds = CGRect(x: 50, y: 50, width: 640, height: 400)
        let elements = GameBridgeDetectionService.detectElements(
            from: manifest,
            windowBounds: windowBounds
        )

        #expect(elements.count == 1)
        let e = elements[0]
        // 160 * (640/320) + 50 = 370
        #expect(e.bounds.origin.x == 370)
        // 100 * (400/200) + 50 = 250
        #expect(e.bounds.origin.y == 250)
        // 32 * 2 = 64
        #expect(e.bounds.width == 64)
        // 20 * 2 = 40
        #expect(e.bounds.height == 40)
    }

    @available(macOS 14.0, *)
    @Test
    func `tryDetect returns nil for unknown app`() {
        let context = WindowContext(
            applicationName: "Safari",
            applicationBundleId: "com.apple.Safari",
            applicationProcessId: 1234,
            windowTitle: "Test",
            windowID: 1,
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            shouldFocusWebContent: false,
            traversalBudget: nil
        )
        let result = GameBridgeDetectionService.tryDetect(
            windowContext: context,
            snapshotId: "test-snap"
        )
        #expect(result == nil)
    }

    @available(macOS 14.0, *)
    @Test
    func `Snapshot ID is preserved`() throws {
        let json = """
        {"version":1,"app":"firestaff","gameState":"test",
         "framebuffer":{"width":320,"height":200},"elements":[]}
        """
        let manifestRootURL = try self.writeFirestaffManifest(json)
        defer { try? FileManager.default.removeItem(at: manifestRootURL) }

        let context = WindowContext(
            applicationName: "firestaff",
            applicationBundleId: nil,
            applicationProcessId: nil,
            windowTitle: nil,
            windowID: nil,
            windowBounds: nil,
            shouldFocusWebContent: false,
            traversalBudget: nil
        )
        let result = GameBridgeDetectionService.tryDetect(
            windowContext: context,
            snapshotId: "my-custom-snapshot-id",
            manifestRootURL: manifestRootURL
        )

        #expect(result != nil)
        #expect(result?.snapshotId == "my-custom-snapshot-id")
        #expect(result?.metadata.method == "gameBridge")
    }

    @available(macOS 14.0, *)
    @Test
    func `Static text is not grouped as text field`() throws {
        let json = """
        {"version":1,"app":"firestaff","gameState":"test",
         "framebuffer":{"width":320,"height":200},
         "elements":[{"id":"LABEL","type":"text","label":"Status",
         "bounds":{"x":10,"y":20,"w":40,"h":10}}]}
        """
        let manifestRootURL = try self.writeFirestaffManifest(json)
        defer { try? FileManager.default.removeItem(at: manifestRootURL) }

        let context = WindowContext(
            applicationName: "firestaff",
            applicationBundleId: nil,
            applicationProcessId: nil,
            windowTitle: nil,
            windowID: nil,
            windowBounds: nil,
            shouldFocusWebContent: false,
            traversalBudget: nil
        )
        let result = try #require(GameBridgeDetectionService.tryDetect(
            windowContext: context,
            snapshotId: "static-text-snapshot",
            manifestRootURL: manifestRootURL
        ))

        #expect(result.elements.textFields.isEmpty)
        #expect(result.elements.other.count == 1)
        #expect(result.elements.other[0].type == .staticText)
    }

    @available(macOS 14.0, *)
    @Test
    func `Stale manifest is ignored`() throws {
        let json = """
        {"version":1,"app":"firestaff","gameState":"stale",
         "framebuffer":{"width":320,"height":200},"elements":[]}
        """
        let manifestRootURL = try self.writeFirestaffManifest(json)
        defer { try? FileManager.default.removeItem(at: manifestRootURL) }

        let manifestPath = manifestRootURL
            .appendingPathComponent(".firestaff")
            .appendingPathComponent("accessibility.json")
        let staleDate = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: manifestPath.path)

        let context = WindowContext(
            applicationName: "firestaff",
            applicationBundleId: nil,
            applicationProcessId: nil,
            windowTitle: nil,
            windowID: nil,
            windowBounds: nil,
            shouldFocusWebContent: false,
            traversalBudget: nil
        )
        let result = GameBridgeDetectionService.tryDetect(
            windowContext: context,
            snapshotId: "stale-snapshot",
            manifestRootURL: manifestRootURL
        )

        #expect(result == nil)
    }

    private func writeFirestaffManifest(_ json: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-gamebridge-tests-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".firestaff")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestPath = dir.appendingPathComponent("accessibility.json")
        try json.write(to: manifestPath, atomically: true, encoding: .utf8)
        return root
    }
}
