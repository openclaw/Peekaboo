import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite("GameBridge Detection Tests")
struct GameBridgeDetectionTests {

    @available(macOS 14.0, *)
    @Test("Known app is recognized")
    func knownAppRecognized() {
        #expect(GameBridgeDetectionService.isGameBridgeApp(appName: "firestaff"))
        #expect(GameBridgeDetectionService.isGameBridgeApp(appName: "Firestaff"))
    }

    @available(macOS 14.0, *)
    @Test("Unknown app is not recognized")
    func unknownAppNotRecognized() {
        #expect(!GameBridgeDetectionService.isGameBridgeApp(appName: "Safari"))
        #expect(!GameBridgeDetectionService.isGameBridgeApp(appName: nil))
        #expect(!GameBridgeDetectionService.isGameBridgeApp(appName: ""))
    }

    @available(macOS 14.0, *)
    @Test("Manifest parsing from temp file")
    func manifestParsing() throws {
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
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(
            GameBridgeDetectionService.GameManifest.self,
            from: data)

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
    @Test("Manifest elements default omitted optional Firestaff fields")
    func manifestElementDefaults() throws {
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
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(
            GameBridgeDetectionService.GameManifest.self,
            from: data)

        #expect(manifest.elements.count == 1)
        #expect(manifest.elements[0].enabled)
        #expect(manifest.elements[0].value == nil)
    }

    @available(macOS 14.0, *)
    @Test("Element scaling with window bounds")
    func elementScaling() throws {
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
        let data = json.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(
            GameBridgeDetectionService.GameManifest.self,
            from: data)

        // Window is 2x the framebuffer at offset (50, 50)
        let windowBounds = CGRect(x: 50, y: 50, width: 640, height: 400)
        let elements = GameBridgeDetectionService.detectElements(
            from: manifest,
            windowBounds: windowBounds)

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
    @Test("tryDetect returns nil for unknown app")
    func tryDetectUnknownApp() {
        let context = WindowContext(
            applicationName: "Safari",
            applicationBundleId: "com.apple.Safari",
            applicationProcessId: 1234,
            windowTitle: "Test",
            windowID: 1,
            windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            shouldFocusWebContent: false,
            traversalBudget: nil)
        let result = GameBridgeDetectionService.tryDetect(
            windowContext: context,
            snapshotId: "test-snap")
        #expect(result == nil)
    }

    @available(macOS 14.0, *)
    @Test("Snapshot ID is preserved")
    func snapshotIdPreserved() throws {
        let json = """
        {"version":1,"app":"firestaff","gameState":"test",
         "framebuffer":{"width":320,"height":200},"elements":[]}
        """
        let restoreManifest = try writeFirestaffManifest(json)
        defer { restoreManifest() }

        let context = WindowContext(
            applicationName: "firestaff",
            applicationBundleId: nil,
            applicationProcessId: nil,
            windowTitle: nil,
            windowID: nil,
            windowBounds: nil,
            shouldFocusWebContent: false,
            traversalBudget: nil)
        let result = GameBridgeDetectionService.tryDetect(
            windowContext: context,
            snapshotId: "my-custom-snapshot-id")

        #expect(result != nil)
        #expect(result?.snapshotId == "my-custom-snapshot-id")
        #expect(result?.metadata.method == "gameBridge")
    }

    private func writeFirestaffManifest(_ json: String) throws -> () -> Void {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".firestaff")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestPath = dir.appendingPathComponent("accessibility.json")
        let previousData = try? Data(contentsOf: manifestPath)

        try json.write(to: manifestPath, atomically: true, encoding: .utf8)

        return {
            if let previousData {
                try? previousData.write(to: manifestPath, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: manifestPath)
            }
        }
    }
}
