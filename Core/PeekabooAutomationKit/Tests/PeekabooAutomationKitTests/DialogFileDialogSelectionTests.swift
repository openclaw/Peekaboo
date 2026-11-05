import ApplicationServices
import struct AXorcist.Element
import enum AXorcist.MouseButton
import enum AXorcist.SpecialKey
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("File dialog file selection")
struct DialogFileDialogSelectionTests {
    @Test
    func `Path derivation follows file and directory intent`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("alpha.txt")
        try Data("alpha".utf8).write(to: file)
        let dottedDirectory = directory.appendingPathComponent("folder.ext")
        try FileManager.default.createDirectory(at: dottedDirectory, withIntermediateDirectories: true)
        let cases: [(String?, String?, String?)] = [
            (directory.path, "alpha.txt", file.path),
            (file.path, "other.txt", directory.appendingPathComponent("other.txt").path),
            (file.path, nil, file.path),
            (
                directory.appendingPathComponent("missing.txt").path,
                nil,
                directory.appendingPathComponent("missing.txt").path),
            (directory.path, nil, nil),
            (dottedDirectory.path, nil, nil),
            (dottedDirectory.path, "alpha.txt", dottedDirectory.appendingPathComponent("alpha.txt").path),
            (directory.appendingPathComponent("missing").path, nil, nil),
            (nil, "alpha.txt", nil),
            ("~/missing.txt", nil, ("~/missing.txt" as NSString).expandingTildeInPath),
            (
                "~",
                "alpha.txt",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("alpha.txt").path),
        ]
        for (path, filename, expected) in cases {
            #expect(DialogService.fileToSelect(path: path, filename: filename) == expected)
        }
    }

    @Test(arguments: ["column", "icon", "list", "table"])
    func `Selected elements prove each view shape`(view: String) async throws {
        let item = Self.item(view: view, name: "ALPHA.TXT", selected: true)
        let panel = Self.panel(children: [item])
        #expect(try await Self.hasSelection(panel))
        let fixture = try SelectionFixture(panel: panel)
        #expect(try await fixture.service().fileDialogHasSelectedFile(
            "/files/alpha.txt", in: panel, execution: fixture.execution, budget: Self.budget()))
    }

    @Test(arguments: ["AXSelectedChildren", "AXSelectedRows"])
    func `Container selection attributes prove unflagged descendants`(attribute: String) async throws {
        let item = Self.element(
            role: attribute == "AXSelectedRows" ? "AXRow" : "AXGroup",
            children: [Self.element(role: "AXCell", children: [
                Self.element(role: "AXStaticText", name: "alpha.txt"),
            ])])
        let container = Self.element(role: attribute == "AXSelectedRows" ? "AXOutline" : "AXList")
        let panel = Self.panel(children: [container])
        let fixture = try SelectionFixture(panel: panel)
        fixture.selectedItems[container] = try Self.readSelectedItems(attribute: attribute, item: item)
        #expect(try await fixture.service().fileDialogHasSelectedFile(
            "/files/alpha.txt", in: panel, execution: fixture.execution, budget: Self.budget()))
        #expect(!fixture.deadlines.isEmpty)
        #expect(fixture.deadlines.allSatisfy { $0 == fixture.deadlines.first })
    }

    @Test(arguments: ["Macintosh HD", "files", "other.txt"])
    func `Unrelated selected sidebar folder or file is refused`(name: String) async throws {
        let panel = Self.panel(children: [Self.item(view: "list", name: name, selected: true)])
        #expect(try await !Self.hasSelection(panel))
    }

    @Test
    func `A bare stem counts only when the panel displays the file that way`() async throws {
        #expect(DialogService.fileDialogSelectionNames(path: "/files/alpha.txt") { _ in "Alpha" } ==
            ["alpha.txt", "alpha"])
        #expect(DialogService.fileDialogSelectionNames(path: "/files/alpha.txt") { _ in "alpha.txt" } == ["alpha.txt"])
        #expect(try await !Self.hasSelection(Self.panel(children: [
            Self.item(view: "column", name: "alpha", selected: true),
        ])))
    }

    @Test
    func `A container reporting another selection is not walked row by row`() async throws {
        let target = Self.item(view: "column", name: "alpha.txt", selected: true)
        let container = Self.element(role: "AXList", children: [target])
        let other = Self.element(role: "AXGroup", children: [Self.element(role: "AXStaticText", name: "beta.txt")])
        let panel = Self.panel(children: [container])
        let fixture = try SelectionFixture(panel: panel)
        fixture.selectedItems[container] = try Self.readSelectedItems(attribute: "AXSelectedChildren", item: other)
        #expect(try await !fixture.service().fileDialogHasSelectedFile(
            "/files/alpha.txt", in: panel, execution: fixture.execution, budget: Self.budget()))
    }

    @Test
    func `Unselected matching file and enabled button do not prove selection`() async throws {
        let panel = Self.panel(children: [
            Self.item(view: "column", name: "alpha.txt", selected: false), Self.button(),
        ])
        #expect(try await !Self.hasSelection(panel))
    }

    @Test(arguments: [false, true])
    func `Nested structural dialogs and foreign roots cannot prove selection`(bounded: Bool) async throws {
        let selected = Self.item(view: "column", name: "alpha.txt", selected: true)
        let panel = Self.panel(children: [
            Self.element(role: "AXSheet", children: [selected]),
            Self.element(role: "AXApplication", children: [selected]),
            Self.element(role: "AXWindow", children: [selected]),
        ])
        if bounded {
            let fixture = try SelectionFixture(panel: panel)
            #expect(try await !fixture.service().fileDialogHasSelectedFile(
                "/files/alpha.txt", in: panel, execution: fixture.execution, budget: Self.budget()))
        } else {
            #expect(try await !Self.hasSelection(panel))
        }
    }

    @Test
    func `Selected item name search has a bounded descendant depth`() async throws {
        var item = Self.element(role: "AXStaticText", name: "alpha.txt")
        for _ in 0..<5 {
            item = Self.element(role: "AXGroup", children: [item])
        }
        var attributes = item.attributes ?? [:]
        attributes["AXSelected"] = .bool(true)
        item.attributes = attributes
        #expect(try await !Self.hasSelection(Self.panel(children: [item])))
    }

    @Test
    func `Legacy traversal stops at its node cap`() async throws {
        let children = (0..<4100).map { _ in Self.element(role: "AXGroup") } + [
            Self.item(view: "icon", name: "alpha.txt", selected: true),
        ]
        await #expect(throws: PeekabooError.self) {
            try await Self.hasSelection(Self.panel(children: children))
        }
    }

    @Test
    func `Open route types full path and refuses unverified confirmation`() async throws {
        let driver = SelectionInputDriver()
        let search = Self.field(identifier: "Search")
        let path = Self.field(identifier: "PathTextField")
        let panel = Self.panel(children: [search, path, Self.button()])
        let service = DialogService(syntheticInputDriver: driver)
        let route = try await service.navigateFileDialog(
            path: "/files",
            filename: "alpha.txt",
            in: panel,
            ensureExpanded: false,
            appName: nil,
            fileIsMissing: { _ in false })
        #expect(route.selectedFile == "/files/alpha.txt")
        #expect(route.navigation.method == "go_to_folder_file_selection")
        #expect(driver.typed == ["/files/alpha.txt"])
        #expect(driver.hotkeys == [["cmd", "shift", "g"], ["cmd", "a"]])
        #expect((search.value() as? String)?.isEmpty == true)
        #expect((path.value() as? String)?.isEmpty == true)
        do {
            _ = try await service.confirmFileDialog(in: panel, buttonText: "Open", selectedFile: route.selectedFile)
            Issue.record("Expected selection verification refusal")
        } catch let error as DialogError {
            guard case .fileSelectionNotVerified(path: "/files/alpha.txt") = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            var sequence = DesktopActionSequenceAccumulator()
            if let outcome = route.navigation.outcome {
                sequence.record(.outcome(outcome))
            }
            let failure = try #require(DialogService.preservingFileDialogFailure(
                error, after: sequence, target: nil) as? DesktopActionFailure)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(driver.clicks == 0)
    }

    @Test
    func `Save panel retains directory navigation and native filename entry`() async throws {
        let driver = SelectionInputDriver()
        let save = Self.field(identifier: "saveAsNameTextField")
        let panel = Self.panel(children: [save, Self.field(identifier: "Search")])
        let service = DialogService(syntheticInputDriver: driver)
        let route = try await service.navigateFileDialog(
            path: "/files/old.txt", filename: "alpha.txt", in: panel, ensureExpanded: false, appName: nil)
        #expect(route.selectedFile == nil)
        #expect(route.navigation.method == "go_to_folder")
        #expect(driver.typed == ["/files"])
        _ = try await service.updateFilename("alpha.txt", in: panel)
        #expect(driver.typed == ["/files", "alpha.txt"])
    }

    @Test
    func `A missing file is refused before any Go to Folder input`() async throws {
        let driver = SelectionInputDriver()
        let panel = Self.panel(children: [Self.field(identifier: "Search"), Self.button()])
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt").path
        do {
            _ = try await DialogService(syntheticInputDriver: driver).navigateFileDialog(
                path: missing, filename: nil, in: panel, ensureExpanded: false, appName: nil)
            Issue.record("Expected a missing-file refusal")
        } catch let DialogError.fileSelectionTargetMissing(path) {
            #expect(path == missing)
        }
        #expect(driver.typed.isEmpty)
        #expect(driver.hotkeys.isEmpty)
    }

    @Test
    func `Only a confirmed absence counts as missing`() {
        #expect(DialogService.fileDialogFileIsMissing("/nonexistent-\(UUID().uuidString)"))
        #expect(!DialogService.fileDialogFileIsMissing(FileManager.default.temporaryDirectory.path))
    }

    @Test
    func `Verified Open selection passes verification`() async throws {
        let panel = Self.panel(children: [Self.item(view: "icon", name: "alpha.txt", selected: true)])
        try await DialogService().verifyFileSelection("/files/alpha.txt", in: panel)
    }

    @Test(arguments: ["AXValue", "AXTitle", "AXDescription"])
    func `Each supported name attribute can independently prove selection`(attribute: String) async throws {
        var selected = Self.element(role: "AXImage", selected: true)
        for name in ["AXValue", "AXTitle", "AXDescription"] {
            selected.attributes?[name] = .string(name == attribute ? "alpha.txt" : "")
        }
        #expect(try await Self.hasSelection(Self.panel(children: [selected])))
    }

    @Test
    func `Selection polling observes a delayed bounded selection`() async throws {
        let item = Self.item(view: "icon", name: "alpha.txt", selected: false)
        let panel = Self.panel(children: [item])
        let fixture = try SelectionFixture(panel: panel)
        fixture.selectAfterReads = 3
        fixture.selectedItems[panel] = [item]
        try await fixture.service().verifyFileSelection("/files/alpha.txt", in: panel, execution: fixture.execution)
        #expect(fixture.reads >= 3)
    }

    private static func hasSelection(_ panel: Element) async throws -> Bool {
        try await DialogService().fileDialogHasSelectedFile("/files/alpha.txt", in: panel, budget: self.budget())
    }

    private static func budget() throws -> DialogOperationDeadline {
        try .bounded(timeoutSeconds: 5, operationName: "selection test")
    }

    private static func readSelectedItems(attribute: String, item: Element) throws -> [Element] {
        let raw = try DialogFileSelectionReader.readAttributes(budget: Self.budget()) { name in
            name == attribute ? ([item.underlyingElement] as CFArray, .success) : (nil, .noValue)
        }
        return raw.selectedItems.map { _ in item }
    }

    static func panel(children: [Element]) -> Element {
        self.element(role: "AXSheet", children: children)
    }

    private static var nextElementIdentifier: Int32 = -1_000_000

    static func element(
        role: String, name: String = "", selected: Bool = false, children: [Element] = []) -> Element
    {
        self.nextElementIdentifier -= 1
        return Element(
            AXUIElementCreateApplication(self.nextElementIdentifier),
            attributes: [
                "AXRole": .string(role), "AXSubrole": .string(""), "AXIdentifier": .string(""),
                "AXRoleDescription": .string(""), "AXTitle": .string(name), "AXValue": .string(name),
                "AXDescription": .string(name), "AXSelected": .bool(selected), "AXEnabled": .bool(true),
            ],
            children: children,
            actions: [])
    }

    private static func item(view: String, name: String, selected: Bool) -> Element {
        switch view {
        case "column":
            self.element(role: "AXBrowser", children: [self.element(role: "AXScrollArea", children: [
                self.element(role: "AXList", children: [self.element(role: "AXGroup", children: [
                    self.element(role: "AXTextField", name: name, selected: selected),
                ])]),
            ])])
        case "icon":
            self.element(role: "AXList", children: [self.element(role: "AXGroup", children: [
                self.element(role: "AXImage", name: name, selected: selected),
            ])])
        default:
            self.element(role: view == "table" ? "AXTable" : "AXOutline", children: [
                self.element(role: "AXRow", selected: selected, children: [
                    self.element(role: "AXCell", children: [self.element(role: "AXStaticText", name: name)]),
                ]),
            ])
        }
    }

    private static func field(identifier: String) -> Element {
        var field = Self.element(role: "AXTextField")
        field.attributes?["AXIdentifier"] = .string(identifier)
        field.attributes?["AXFocused"] = .bool(true)
        return field
    }

    private static func button() -> Element {
        var button = Self.element(role: "AXButton", name: "Open")
        button.attributes?["AXPosition"] = .dictionary(["x": .double(100), "y": .double(100)])
        button.attributes?["AXSize"] = .dictionary(["width": .double(80), "height": .double(24)])
        return button
    }
}

@MainActor
private final class SelectionFixture {
    let execution: DialogService.FileExecution
    var selectedItems: [Element: [Element]] = [:]
    var deadlines: [ContinuousClock.Instant] = []
    var selectAfterReads = 0
    var reads = 0

    init(panel: Element) throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let target = try UIAutomationTarget.ExactWindow(identity: WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds), bounds: bounds)
        let window = ServiceWindowInfo(
            windowID: 700, title: "Fixture", bounds: bounds, index: 0, mutationIdentity: target.identity)
        let proof = try WindowSelectorResolutionProof.make(
            selection: .title("Fixture"),
            candidates: [window],
            selected: window,
            processIdentity: target.identity.processIdentity)
        let evidence = try ResolvedDialogTargetEvidence(
            target: target,
            application: ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 9001,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"),
            window: window,
            windowResolutionProof: proof)
        self.execution = try DialogService.FileExecution(
            request: DialogFileExecutionRequest(target: DialogTargetSelector(processIdentifier: 42, windowID: 700)),
            resolution: .init(
                element: panel,
                dialogIdentifier: "open-panel",
                foundVia: "fixture",
                target: target,
                window: DialogFileDialogSelectionTests.element(role: "AXWindow"),
                resolvedTarget: evidence))
    }

    func service() -> DialogService {
        var readers = DialogDiscoveryReaders()
        readers.hierarchyNode = { element, owner, budget in
            #expect(owner == self.execution.target.identity.processIdentity)
            self.deadlines.append(budget.deadline)
            return DialogHierarchyNode(
                evidence: DialogElementClassifier.evidence(for: element), children: element.children() ?? [])
        }
        readers.fileSelection = { element, owner, budget in
            #expect(owner == self.execution.target.identity.processIdentity)
            self.deadlines.append(budget.deadline)
            self.reads += 1
            let metadata = DialogFileSelectionMetadata.readDirect(element)
            return DialogFileSelectionMetadata(
                isSelected: metadata.isSelected,
                names: metadata.names,
                selectedItems: self.reads >= self.selectAfterReads ? self.selectedItems[element] ?? [] : [])
        }
        return DialogService(syntheticInputDriver: SelectionInputDriver(), discoveryReaders: readers)
    }
}

@MainActor
private final class SelectionInputDriver: SyntheticInputDriving {
    var typed: [String] = []
    var hotkeys: [[String]] = []
    var clicks = 0

    func click(at _: CGPoint, button _: MouseButton, count _: Int) throws -> DesktopActionOutcome {
        self.clicks += 1
        return .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier _: pid_t) async throws -> DesktopActionOutcome
    {
        try self.click(at: point, button: button, count: count)
    }

    func move(to _: CGPoint) throws {}
    func currentLocation() -> CGPoint? {
        nil
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}
    func scroll(deltaX _: Double, deltaY _: Double, at _: CGPoint?) throws {}
    func type(_ text: String, delayPerCharacter _: TimeInterval) throws {
        self.typed.append(text)
    }

    func tapKey(_: SpecialKey, modifiers _: CGEventFlags) throws {}
    func hotkey(keys: [String], holdDuration _: TimeInterval) throws {
        self.hotkeys.append(keys)
    }
}
