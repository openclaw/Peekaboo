import ApplicationServices
import struct AXorcist.Element
import enum AXorcist.MouseButton
import enum AXorcist.SpecialKey
import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("File dialog filename fields")
struct DialogFileDialogFilenameTests {
    @Test
    func `Search-only panel refuses filename input without changing the field`() async {
        let driver = RecordingFilenameInputDriver()
        let search = Self.field(identifier: "Search", roleDescription: "search text field")
        let dialog = Element(
            AXUIElementCreateApplication(946_101),
            attributes: ["AXRole": .string("AXSheet")],
            children: [search],
            actions: [])

        do {
            _ = try await DialogService(syntheticInputDriver: driver).updateFilename("alpha.txt", in: dialog)
            Issue.record("Expected Search-only filename refusal")
        } catch let error as DialogError {
            guard case .noFilenameField = error else {
                Issue.record("Expected noFilenameField, got \(error)")
                return
            }
            #expect(error.errorDescription ==
                "No safe filename field found in the file dialog. Complete the file selection manually, or retry with a dialog that exposes a filename field.")
        } catch {
            Issue.record("Expected DialogError.noFilenameField, got \(error)")
        }
        #expect((search.value() as? String)?.isEmpty == true)
        #expect(driver.events.isEmpty)
    }

    @Test
    func `Native save field receives filename input while Search remains unchanged`() async throws {
        let driver = RecordingFilenameInputDriver()
        let search = Self.field(identifier: "Search", roleDescription: "search text field")
        let save = Self.field(identifier: "saveAsNameTextField", title: "Save As")
        let dialog = Element(
            AXUIElementCreateApplication(946_102),
            attributes: ["AXRole": .string("AXSheet")],
            children: [search, save],
            actions: [])

        _ = try await DialogService(syntheticInputDriver: driver).updateFilename("alpha.txt", in: dialog)

        #expect((search.value() as? String)?.isEmpty == true)
        #expect(driver.events == [
            .hotkey(keys: ["cmd", "a"], holdDuration: 0.05),
            .type("alpha.txt", delayPerCharacter: 0.005),
        ])
    }

    @Test
    func `Search refusal preserves earlier navigation dispatch without filename input`() async throws {
        let driver = RecordingFilenameInputDriver()
        let search = Self.field(identifier: "Search", roleDescription: "search text field")
        let dialog = Element(
            AXUIElementCreateApplication(946_103),
            attributes: ["AXRole": .string("AXSheet")],
            children: [search],
            actions: [])
        var earlierActions = DesktopActionSequenceAccumulator()
        earlierActions.record(.outcome(.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .init(3))))

        do {
            _ = try await DialogService(syntheticInputDriver: driver).updateFilename("alpha.txt", in: dialog)
            Issue.record("Expected Search-only filename refusal")
        } catch {
            let preserved = DialogService.preservingFileDialogFailure(error, after: earlierActions, target: nil)
            let failure = try #require(preserved as? DesktopActionFailure)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .init(3)))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(driver.events.isEmpty)
    }

    @Test(arguments: [
        FieldMetadata(identifier: "Search", roleDescription: "search text field"),
        FieldMetadata(subrole: "AXSearchField", roleDescription: "campo de texto"),
        FieldMetadata(identifier: "filenameSearchField"),
        FieldMetadata(identifier: "filenamesearchfield"),
        FieldMetadata(identifier: "filterfield"),
        FieldMetadata(title: "Search file name"),
        FieldMetadata(placeholder: "Filter by filename"),
        FieldMetadata(identifier: "tagField", title: "Tags"),
        FieldMetadata(identifier: "nstagfield"),
        FieldMetadata(identifier: "commentField", title: "Comments"),
    ])
    func `Unsafe accessory metadata refuses filename input`(_ metadata: FieldMetadata) async {
        let driver = RecordingFilenameInputDriver()
        let field = Self.field(
            identifier: metadata.identifier,
            title: metadata.title,
            placeholder: metadata.placeholder,
            subrole: metadata.subrole,
            roleDescription: metadata.roleDescription)
        let dialog = Element(
            AXUIElementCreateApplication(946_104),
            attributes: ["AXRole": .string("AXSheet")],
            children: [field],
            actions: [])

        await #expect(throws: DialogError.self) {
            try await DialogService(syntheticInputDriver: driver).updateFilename("alpha.txt", in: dialog)
        }
        #expect(driver.events.isEmpty)
    }

    @Test
    func `Name and Comment panel refuses ambiguous filename input`() async {
        let driver = RecordingFilenameInputDriver()
        let name = Self.field(title: "Name")
        let comment = Self.field(title: "Comment")
        let dialog = Element(
            AXUIElementCreateApplication(946_106),
            attributes: ["AXRole": .string("AXSheet")],
            children: [name, comment],
            actions: [])

        await #expect(throws: DialogError.self) {
            try await DialogService(syntheticInputDriver: driver).updateFilename("alpha.txt", in: dialog)
        }
        #expect(driver.events.isEmpty)
    }

    @Test
    func `Multiple generic fields refuse filename input rather than rank geometry`() async {
        let driver = RecordingFilenameInputDriver()
        let dialog = Element(
            AXUIElementCreateApplication(946_107),
            attributes: ["AXRole": .string("AXSheet")],
            children: [Self.field(title: "Name"), Self.field(title: "Description")],
            actions: [])

        await #expect(throws: DialogError.self) {
            try await DialogService(syntheticInputDriver: driver).updateFilename("alpha.txt", in: dialog)
        }
        #expect(driver.events.isEmpty)
    }

    @Test
    func `Generic localized field preserves legacy filename fallback`() async throws {
        let driver = RecordingFilenameInputDriver()
        let generic = Self.field(roleDescription: "campo de texto")
        let dialog = Element(
            AXUIElementCreateApplication(946_105),
            attributes: ["AXRole": .string("AXSheet")],
            children: [generic],
            actions: [])

        _ = try await DialogService(syntheticInputDriver: driver).updateFilename("alpha.txt", in: dialog)

        #expect(driver.events == [
            .hotkey(keys: ["cmd", "a"], holdDuration: 0.05),
            .type("alpha.txt", delayPerCharacter: 0.005),
        ])
    }

    private static func field(
        identifier: String = "",
        title: String = "",
        placeholder: String = "",
        subrole: String = "",
        roleDescription: String = "text field") -> Element
    {
        Element(
            AXUIElementCreateApplication(-Int32.random(in: 900_000...999_999)),
            attributes: [
                "AXRole": .string("AXTextField"),
                "AXSubrole": .string(subrole),
                "AXIdentifier": .string(identifier),
                "AXTitle": .string(title),
                "AXPlaceholderValue": .string(placeholder),
                "AXDescription": .string(""),
                "AXRoleDescription": .string(roleDescription),
                "AXEnabled": .bool(true),
                "AXFocused": .bool(true),
                "AXValue": .string(""),
                "AXPosition": .dictionary(["x": .double(100), "y": .double(100)]),
                "AXSize": .dictionary(["width": .double(200), "height": .double(24)]),
            ],
            children: [],
            actions: [])
    }
}

struct FieldMetadata: Sendable {
    let identifier: String
    let title: String
    let placeholder: String
    let subrole: String
    let roleDescription: String

    init(
        identifier: String = "",
        title: String = "",
        placeholder: String = "",
        subrole: String = "",
        roleDescription: String = "text field")
    {
        self.identifier = identifier
        self.title = title
        self.placeholder = placeholder
        self.subrole = subrole
        self.roleDescription = roleDescription
    }
}

@MainActor
private final class RecordingFilenameInputDriver: SyntheticInputDriving {
    enum Event: Equatable {
        case hotkey(keys: [String], holdDuration: TimeInterval)
        case type(String, delayPerCharacter: TimeInterval)
    }

    private(set) var events: [Event] = []

    func click(at _: CGPoint, button _: MouseButton, count _: Int) throws -> DesktopActionOutcome {
        .dispatchedUnverified(
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

    func type(_ text: String, delayPerCharacter: TimeInterval) throws {
        self.events.append(.type(text, delayPerCharacter: delayPerCharacter))
    }

    func tapKey(_: SpecialKey, modifiers _: CGEventFlags) throws {}

    func hotkey(keys: [String], holdDuration: TimeInterval) throws {
        self.events.append(.hotkey(keys: keys, holdDuration: holdDuration))
    }
}
