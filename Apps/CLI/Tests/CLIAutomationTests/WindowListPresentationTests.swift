import CoreGraphics
import Foundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@MainActor
@Suite(.serialized, .tags(.safe))
struct WindowListPresentationTests {
    @Test(arguments: [false, true])
    func `text lists distinguish off-screen windows from minimized windows`(groupBySpace: Bool) async throws {
        let arguments = ["window", "list", "--pid", "42", "--no-remote"] +
            (groupBySpace ? ["--group-by-space"] : [])
        let result = try await InProcessCommandRunner.run(arguments, services: Self.services())

        #expect(result.exitStatus == 0)
        let lines = result.stdout.split(separator: "\n")
        let hidden = try #require(lines.first { $0.contains("\"Hidden fixture\"") })
        let minimized = try #require(lines.first { $0.contains("\"Minimized fixture\"") })
        let visible = try #require(lines.first { $0.contains("\"Visible fixture\"") })
        #expect(hidden.contains("[3]"))
        #expect(!hidden.contains("[minimized]"))
        #expect(minimized.contains("[7]"))
        #expect(minimized.contains("[minimized]"))
        #expect(!visible.contains("[minimized]"))
        #expect(result.stdout.contains("Position: (100, 200)"))
        #expect(result.stdout.contains("Size: 800x600"))
    }

    @Test
    func `JSON keeps native visibility without adding a minimized presentation field`() async throws {
        let result = try await InProcessCommandRunner.run(
            ["window", "list", "--pid", "42", "--no-remote", "--json"],
            services: Self.services()
        )
        #expect(result.exitStatus == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let windows = try #require(data["windows"] as? [[String: Any]])
        #expect(windows.map { $0["is_on_screen"] as? Bool } == [false, false, true])
        #expect(windows.map { $0["window_index"] as? Int } == [3, 7, 9])
        for window in windows {
            #expect(Set(window.keys) == [
                "window_title",
                "window_id",
                "window_index",
                "bounds",
                "is_on_screen",
                "layer"
            ])
        }
    }

    private static func services() -> PeekabooServices {
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Window fixture"
        )
        let states = [
            (title: "Hidden fixture", index: 3, minimized: false, onScreen: false),
            (title: "Minimized fixture", index: 7, minimized: true, onScreen: false),
            (title: "Visible fixture", index: 9, minimized: false, onScreen: true),
        ]
        let windows = states.map { state in
            ServiceWindowInfo(
                windowID: 900 + state.index,
                title: state.title,
                bounds: CGRect(x: 100, y: 200, width: 800, height: 600),
                isMinimized: state.minimized,
                index: state.index,
                isOnScreen: state.onScreen
            )
        }
        return TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [application]),
            windows: StubWindowService(windowsByApp: ["PID:42": windows])
        )
    }
}
