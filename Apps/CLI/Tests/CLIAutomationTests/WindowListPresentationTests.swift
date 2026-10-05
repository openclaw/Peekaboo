import Commander
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
        let result = try await InProcessCommandRunner.runWithOwnedRuntime(arguments, services: Self.services())

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

    @Test(arguments: [nil, "PID:42", "pid:42", " \tPiD:42\n", "PID:00042"] as [String?])
    func `JSON keeps the same owner and window inventory for equivalent PID aliases`(alias: String?) async throws {
        let services = Self.services()
        let applications = try #require(services.applications as? StubApplicationService)
        let result = try await InProcessCommandRunner.runWithOwnedRuntime(
            ["window", "list", "--pid", "42", "--no-remote", "--json"] +
                (alias.map { ["--app", $0] } ?? []),
            services: services
        )
        #expect(result.exitStatus == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        let windows = try #require(data["windows"] as? [[String: Any]])
        let target = try #require(data["target_application_info"] as? [String: Any])
        #expect(target["pid"] as? Int == 42)
        #expect(windows.map { $0["window_id"] as? Int } == [903, 907, 909])
        #expect(applications.findApplicationRequests == [
            alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "PID:42",
        ])
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

    @Test(arguments: ["PID:42", "pid:42", " \tPiD:42\n", "PID:00042"])
    func `redundant PID aliases still refuse window mutation before lookup`(alias: String) async throws {
        let services = Self.services()
        let applications = try #require(services.applications as? StubApplicationService)
        let windows = try #require(services.windows as? StubWindowService)
        let failure = try #require(await #expect(throws: ValidationError.self) {
            try await InProcessCommandRunner.runWithOwnedRuntime(
                ["window", "move", "--app", alias, "--pid", "42", "--x", "10", "--y", "20", "--json", "--no-remote"],
                services: services
            )
        })
        #expect(String(describing: failure) == "Use either --app or --pid, not both.")
        #expect(applications.findApplicationRequests.isEmpty)
        #expect(windows.moveCalls.isEmpty)
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
