import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogMetadataContractTests {
    @Test
    func `absent dialog metadata uses defaults but empty strings remain empty`() async throws {
        let absent = try await Self.read([.init(974_001)])
        #expect(absent.dialogInfo.title == "Untitled Dialog")
        #expect(absent.dialogInfo.role == "Unknown")
        #expect(absent.dialogInfo.subrole == nil)
        #expect(absent.dialogInfo.bounds == .zero)
        #expect(!absent.dialogInfo.isFileDialog)
        #expect(absent.buttons.isEmpty)
        #expect(absent.textFields.isEmpty)
        #expect(absent.staticTexts.isEmpty)
        #expect(absent.otherElements.isEmpty)
        #expect(absent.resolvedTarget == nil)
        #expect(absent.discovery == nil)

        let empty = try await Self.read([.init(974_002, attributes: [
            "AXTitle": "" as CFString,
            "AXRole": "" as CFString,
            "AXSubrole": "" as CFString,
        ])])
        #expect(empty.dialogInfo.title.isEmpty)
        #expect(empty.dialogInfo.role.isEmpty)
        #expect(empty.dialogInfo.subrole?.isEmpty == true)
    }

    @Test
    func `buttons omit absent titles but preserve empty titles and boolean defaults`() async throws {
        let untitled = DialogMetadataFixture.Node(974_011, role: "AXButton")
        let empty = DialogMetadataFixture.Node(974_012, role: "AXButton", attributes: ["AXTitle": "" as CFString])
        let disabled = DialogMetadataFixture.Node(974_013, role: "AXButton", attributes: [
            "AXTitle": "Confirm" as CFString,
            "AXEnabled": kCFBooleanFalse,
            "AXDefault": kCFBooleanTrue,
        ])
        let numeric = DialogMetadataFixture.Node(974_014, role: "AXButton", attributes: [
            "AXTitle": "Numeric booleans" as CFString,
            "AXEnabled": NSNumber(value: 0),
            "AXDefault": NSNumber(value: 1),
        ])
        let root = DialogMetadataFixture.Node(974_010, role: "AXSheet", children: [untitled, empty, disabled, numeric])

        let result = try await Self.read([root, untitled, empty, disabled, numeric])

        #expect(result.buttons.map(\.title) == ["", "Confirm", "Numeric booleans"])
        #expect(result.buttons.map(\.isEnabled) == [true, false, false])
        #expect(result.buttons.map(\.isDefault) == [false, true, true])
        #expect(result.buttons.allSatisfy { $0.supportsAXPress == nil })
    }

    @Test(arguments: MetadataTextSample.allCases)
    func `AX values accept only strings and attributed strings without stringification`(
        _ sample: MetadataTextSample) async throws
    {
        let base = 974_100 + Int32(sample.rawValue * 10)
        let attributes = sample.value.map { ["AXValue": $0] } ?? [:]
        let field = DialogMetadataFixture.Node(base + 1, role: "AXTextField", attributes: attributes)
        let label = DialogMetadataFixture.Node(base + 2, role: "AXStaticText", attributes: attributes.merging([
            "AXTitle": "Fallback" as CFString,
        ]) { current, _ in current })
        let other = DialogMetadataFixture.Node(base + 3, role: "AXCheckBox", attributes: attributes)
        let root = DialogMetadataFixture.Node(base, role: "AXSheet", children: [field, label, other])

        let result = try await Self.read([root, field, label, other])

        #expect(result.textFields.map(\.value) == [sample.expected])
        #expect(result.otherElements.map(\.value) == [sample.expected])
        let staticText = sample.expected.flatMap { $0.isEmpty ? nil : $0 } ?? "Fallback"
        #expect(result.staticTexts == [staticText])
        #expect(result.textFields[0].title == nil)
        #expect(result.textFields[0].placeholder == nil)
        #expect(result.textFields[0].isEnabled)
    }

    @Test
    func `static text selects the first nonblank source and preserves its whitespace`() async throws {
        let value = DialogMetadataFixture.Node(974_201, role: "AXStaticText", attributes: [
            "AXValue": "  Content\n" as CFString,
            "AXTitle": "Title" as CFString,
            "AXLabel": "Label" as CFString,
            "AXDescription": "Description" as CFString,
        ])
        let title = DialogMetadataFixture.Node(974_202, role: "AXStaticText", attributes: [
            "AXValue": " \n" as CFString,
            "AXTitle": "  Title\n" as CFString,
            "AXLabel": "Label" as CFString,
            "AXDescription": "Description" as CFString,
        ])
        let label = DialogMetadataFixture.Node(974_203, role: "AXStaticText", attributes: [
            "AXTitle": "\t" as CFString,
            "AXLabel": "  Label\n" as CFString,
            "AXDescription": "Description" as CFString,
        ])
        let description = DialogMetadataFixture.Node(974_204, role: "AXStaticText", attributes: [
            "AXLabel": " " as CFString,
            "AXDescription": "  Description\n" as CFString,
        ])
        let blank = DialogMetadataFixture.Node(974_205, role: "AXStaticText", attributes: [
            "AXValue": "\t\n" as CFString,
        ])
        let root = DialogMetadataFixture.Node(974_200, role: "AXSheet", children: [
            value, title, label, description, blank,
        ])

        let result = try await Self.read([root, value, title, label, description, blank])

        #expect(result.staticTexts == ["  Content\n", "  Title\n", "  Label\n", "  Description\n"])
        #expect(result.dialogInfo.title == "Untitled Dialog")
    }

    @Test
    func `depth first identity deduplication preserves equal text and field order through cycles`() async throws {
        let firstText = DialogMetadataFixture.Node(974_211, role: "AXStaticText", attributes: [
            "AXValue": "Repeated" as CFString,
        ])
        let secondText = DialogMetadataFixture.Node(974_212, role: "AXStaticText", attributes: [
            "AXValue": "Repeated" as CFString,
        ])
        let firstField = DialogMetadataFixture.Node(974_213, role: "AXTextArea", attributes: [
            "AXTitle": "Notes" as CFString,
            "AXValue": "First" as CFString,
            "AXPlaceholderValue": "Notes placeholder" as CFString,
            "AXEnabled": kCFBooleanFalse,
        ])
        let secondField = DialogMetadataFixture.Node(974_214, role: "AXTextField", attributes: [
            "AXTitle": "" as CFString,
            "AXValue": "Second" as CFString,
            "AXPlaceholderValue": "" as CFString,
        ])
        let firstButton = DialogMetadataFixture.Node(974_215, role: "AXButton", attributes: [
            "AXTitle": "Repeated" as CFString,
        ])
        let secondButton = DialogMetadataFixture.Node(974_216, role: "AXButton", attributes: [
            "AXTitle": "Repeated" as CFString,
        ])
        let group = DialogMetadataFixture.Node(974_217, role: "AXGroup", attributes: [
            "AXChildren": NSArray(array: [
                firstText.element, firstField.element, firstButton.element, AXUIElementCreateApplication(974_210),
            ]),
        ])
        let root = DialogMetadataFixture.Node(974_210, role: "AXSheet", children: [
            group, firstText, secondField, secondText, secondButton, group,
        ])

        let result = try await Self.read([
            root, group, firstText, secondText, firstField, secondField, firstButton, secondButton,
        ])

        #expect(result.staticTexts == ["Repeated", "Repeated"])
        #expect(result.buttons.map(\.title) == ["Repeated", "Repeated"])
        #expect(result.textFields.map(\.title) == ["Notes", ""])
        #expect(result.textFields.map(\.value) == ["First", "Second"])
        #expect(result.textFields.map(\.placeholder) == ["Notes placeholder", ""])
        #expect(result.textFields.map(\.index) == [0, 1])
        #expect(result.textFields.map(\.isEnabled) == [false, true])
    }

    @Test
    func `other elements are immediate children with known roles only`() async throws {
        let nested = DialogMetadataFixture.Node(974_221, role: "AXCheckBox", attributes: [
            "AXTitle": "Nested" as CFString,
        ])
        let group = DialogMetadataFixture.Node(974_222, role: "AXGroup", children: [nested])
        let missingRole = DialogMetadataFixture.Node(974_223)
        let emptyRole = DialogMetadataFixture.Node(974_224, role: "", attributes: ["AXTitle": "" as CFString])
        let excluded = ["AXButton", "AXTextField", "AXTextArea", "AXStaticText"].enumerated().map {
            DialogMetadataFixture.Node(974_225 + Int32($0.offset), role: $0.element)
        }
        let root = DialogMetadataFixture.Node(974_220, role: "AXSheet", children: [
            group, missingRole, emptyRole,
        ] + excluded)

        let result = try await Self.read([root, group, nested, missingRole, emptyRole] + excluded)

        #expect(result.otherElements.map(\.role) == ["AXGroup", ""])
        #expect(result.otherElements.map(\.title) == [nil, ""])
    }

    @Test(arguments: Array(DialogMetadataFixture.alternativeChildren.enumerated()))
    func `legacy alternate children serve controls and immediate metadata but not static text`(
        index: Int,
        attribute: String) async throws
    {
        let base = 975_000 + Int32(index * 10)
        let direct = DialogMetadataFixture.Node(base + 1, role: "AXButton", attributes: [
            "AXTitle": "Direct" as CFString,
        ])
        let alternate = DialogMetadataFixture.Node(base + 2, role: "AXButton", attributes: [
            "AXTitle": "Alternate" as CFString,
        ])
        let field = DialogMetadataFixture.Node(base + 3, role: "AXTextField")
        let text = DialogMetadataFixture.Node(base + 4, role: "AXStaticText", attributes: [
            "AXValue": "Outside structural children" as CFString,
        ])
        let other = DialogMetadataFixture.Node(base + 5, role: "AXCheckBox")
        let root = DialogMetadataFixture.Node(
            base,
            role: "AXSheet",
            attributes: [
                attribute: NSArray(array: [
                    direct.element, alternate.element, field.element, text.element, other.element,
                ]),
            ],
            children: [direct])

        let result = try await Self.read([root, direct, alternate, field, text, other])

        #expect(result.buttons.map(\.title) == ["Direct", "Alternate"])
        #expect(result.textFields.map(\.index) == [0])
        #expect(result.otherElements.map(\.role) == ["AXCheckBox"])
        #expect(result.staticTexts.isEmpty)
    }

    @Test
    func `legacy alternative attributes retain their collection order`() async throws {
        let buttons = DialogMetadataFixture.alternativeChildren.enumerated().map {
            DialogMetadataFixture.Node(974_301 + Int32($0.offset), role: "AXButton", attributes: [
                "AXTitle": $0.element as CFString,
            ])
        }
        let attributes = Dictionary(uniqueKeysWithValues: zip(DialogMetadataFixture.alternativeChildren, buttons).map {
            ($0.0, NSArray(array: [$0.1.element]) as CFTypeRef)
        })
        let root = DialogMetadataFixture.Node(974_300, role: "AXSheet", attributes: attributes)

        let result = try await Self.read([root] + buttons)

        #expect(result.buttons.map(\.title) == DialogMetadataFixture.alternativeChildren)
    }

    @Test
    func `metadata traversal includes the selected root`() async throws {
        for (index, role) in ["AXButton", "AXTextField", "AXStaticText"].enumerated() {
            let root = DialogMetadataFixture.Node(974_320 + Int32(index), role: role, attributes: [
                "AXTitle": "Root title" as CFString,
                "AXValue": "Root content" as CFString,
            ])
            let result = try await Self.read([root])
            #expect(result.buttons.map(\.title) == (role == "AXButton" ? ["Root title"] : []))
            #expect(result.textFields.map(\.value) == (role == "AXTextField" ? ["Root content"] : []))
            #expect(result.staticTexts == (role == "AXStaticText" ? ["Root content"] : []))
        }
    }

    @Test
    func `a selected application retains its strict windows and focused child collection`() async throws {
        let direct = DialogMetadataFixture.Node(974_331, role: "AXStaticText", attributes: [
            "AXValue": "Direct" as CFString,
        ])
        let windowText = DialogMetadataFixture.Node(974_332, role: "AXStaticText", attributes: [
            "AXValue": "Window collection" as CFString,
        ])
        let focused = DialogMetadataFixture.Node(974_333, role: "AXStaticText", attributes: [
            "AXValue": "Focused" as CFString,
        ])
        let group = DialogMetadataFixture.Node(974_334, role: "AXGroup", children: [windowText])
        let root = DialogMetadataFixture.Node(
            974_330,
            role: "AXApplication",
            attributes: [
                "AXWindows": NSArray(array: [group.element]),
                "AXFocusedUIElement": focused.element,
            ],
            children: [direct])

        let result = try await Self.read([root, direct, windowText, focused, group])

        #expect(result.staticTexts == ["Direct", "Window collection", "Focused"])
    }

    @Test
    func `static text excludes nested applications and windows while controls retain legacy traversal`() async throws {
        let inside = DialogMetadataFixture.Node(974_231, role: "AXStaticText", attributes: [
            "AXValue": "Selected message" as CFString,
        ])
        let outside = DialogMetadataFixture.Node(974_232, role: "AXStaticText", attributes: [
            "AXValue": "Outside message" as CFString,
        ])
        let windowButton = DialogMetadataFixture.Node(974_233, role: "AXButton", attributes: [
            "AXTitle": "Window button" as CFString,
        ])
        let window = DialogMetadataFixture.Node(974_234, role: "AXWindow", children: [outside, windowButton])
        let focused = DialogMetadataFixture.Node(974_235, role: "AXTextField", attributes: [
            "AXTitle": "Focused field" as CFString,
        ])
        let application = DialogMetadataFixture.Node(974_236, role: "AXApplication", attributes: [
            "AXWindows": NSArray(array: [window.element]),
            "AXFocusedUIElement": focused.element,
        ])
        let group = DialogMetadataFixture.Node(974_237, role: "AXGroup", children: [inside, application, window])
        let root = DialogMetadataFixture.Node(974_230, role: "AXWindow", children: [group])

        let result = try await Self.read([root, group, inside, outside, windowButton, window, focused, application])

        #expect(result.staticTexts == ["Selected message"])
        #expect(result.buttons.map(\.title) == ["Window button"])
        #expect(result.textFields.map(\.title) == ["Focused field"])
    }

    @Test
    func `file dialog evidence preserves identifier case and title substring matching`() async throws {
        let cases: [(String, String, Bool)] = [
            ("AXIdentifier", "prefixNSOpenPanelSuffix", true),
            ("AXIdentifier", "prefixNSSavePanelSuffix", true),
            ("AXIdentifier", "nsopenpanel", false),
            ("AXTitle", "Please SAVE this document", true),
            ("AXTitle", "Choose destination", true),
            ("AXTitle", "Replace existing document", true),
            ("AXTitle", "Confirmation", false),
            ("AXRoleDescription", "file dialog", false),
            ("AXSubrole", "AXDialog", false),
        ]
        for (index, item) in cases.enumerated() {
            let root = DialogMetadataFixture.Node(974_250 + Int32(index), role: "AXSheet", attributes: [
                item.0: item.1 as CFString,
            ])
            let result = try await Self.read([root])
            #expect(result.dialogInfo.isFileDialog == item.2)
        }
    }

    @Test
    func `file dialog button fallback needs cancel plus primary title or exact identifier`() async throws {
        let cases: [((String?, String?), (String?, String?), Bool)] = [
            (("CANCEL", nil), ("Save", nil), true),
            (("Cancel", nil), ("Open", nil), true),
            (("Cancel", nil), ("Choose", nil), true),
            (("Cancel", nil), ("Replace", nil), true),
            (("Cancel", nil), ("Export", nil), true),
            (("Cancel", nil), ("Import", nil), true),
            ((nil, "CancelButton"), (nil, "OKButton"), true),
            (("Cancel", nil), ("OK", nil), false),
            ((" Cancel ", nil), ("Save", nil), false),
            (("Cancel", nil), (" Save ", nil), false),
            ((nil, "cancelbutton"), (nil, "OKButton"), false),
            (("Cancel", nil), (nil, "okbutton"), false),
        ]
        for (index, item) in cases.enumerated() {
            let base = 976_000 + Int32(index * 10)
            let cancel = Self.button(base + 1, title: item.0.0, identifier: item.0.1)
            let primary = Self.button(base + 2, title: item.1.0, identifier: item.1.1)
            let root = DialogMetadataFixture.Node(base, role: "AXSheet", children: [cancel, primary])
            let result = try await Self.read([root, cancel, primary])
            #expect(result.dialogInfo.isFileDialog == item.2)
        }
    }

    @Test
    func `bounds require typed point and size values and otherwise remain zero`() async throws {
        var point = CGPoint(x: -40, y: 80)
        var size = CGSize(width: 320, height: 240)
        let position = try #require(AXValueCreate(.cgPoint, &point))
        let dimensions = try #require(AXValueCreate(.cgSize, &size))
        let cases: [([String: CFTypeRef], CGRect)] = [
            (["AXPosition": position, "AXSize": dimensions], CGRect(origin: point, size: size)),
            (["AXPosition": position], .zero),
            (["AXSize": dimensions], .zero),
            (["AXPosition": dimensions, "AXSize": position], .zero),
            (["AXPosition": "-40,80" as CFString, "AXSize": dimensions], .zero),
        ]
        for (index, item) in cases.enumerated() {
            let result = try await Self.read([.init(974_270 + Int32(index), attributes: item.0)])
            #expect(result.dialogInfo.bounds == item.1)
        }
    }

    @Test(arguments: [AXError.failure, .cannotComplete, .apiDisabled, .invalidUIElement, .notImplemented])
    func `metadata read failures remain optional and never admit stale payloads`(_ error: AXError) async throws {
        let base = 977_000 + abs(error.rawValue) * 10
        let button = DialogMetadataFixture.Node(
            base + 1,
            role: "AXButton",
            attributes: [
                "AXTitle": "Continue" as CFString,
                "AXEnabled": kCFBooleanFalse,
                "AXDefault": kCFBooleanTrue,
            ],
            failures: ["AXEnabled": error, "AXDefault": error])
        let field = DialogMetadataFixture.Node(
            base + 2,
            role: "AXTextField",
            attributes: ["AXValue": "Stale" as CFString],
            failures: ["AXValue": error])
        let root = DialogMetadataFixture.Node(
            base,
            role: "AXSheet",
            attributes: ["AXTitle": "Stale title" as CFString],
            children: [button, field],
            failures: ["AXTitle": error])

        let result = try await Self.read([root, button, field])

        #expect(result.dialogInfo.title == "Untitled Dialog")
        #expect(result.buttons.map(\.isEnabled) == [true])
        #expect(result.buttons.map(\.isDefault) == [false])
        #expect(result.textFields.map(\.value) == [nil])
    }

    @Test
    func `successful absent or malformed optional metadata retains output defaults`() async throws {
        let absent = DialogMetadataFixture.Node(974_340, failures: [
            "AXTitle": .success,
            "AXRole": .success,
            "AXChildren": .success,
        ])
        let malformed = DialogMetadataFixture.Node(974_341, attributes: [
            "AXTitle": NSNumber(value: 42),
            "AXRole": NSArray(array: ["AXSheet"]),
            "AXChildren": NSArray(array: ["not an AX element"]),
        ])
        for root in [absent, malformed] {
            let result = try await Self.read([root])
            #expect(result.dialogInfo.title == "Untitled Dialog")
            #expect(result.dialogInfo.role == "Unknown")
            #expect(result.buttons.isEmpty)
            #expect(result.textFields.isEmpty)
            #expect(result.staticTexts.isEmpty)
            #expect(result.otherElements.isEmpty)
        }
    }
}

extension DialogMetadataContractTests {
    private static func read(_ nodes: [DialogMetadataFixture.Node]) async throws -> DialogElements {
        let root = try #require(nodes.first)
        let fixture = DialogMetadataFixture(nodes: nodes)
        return try await DialogMetadataReader.read(
            Element(root.element),
            owner: ApplicationProcessIdentity(processIdentifier: root.pid, processStartIdentity: 123),
            budget: DialogOperationDeadline.bounded(timeoutSeconds: 5, operationName: "metadata contract"),
            copyAttribute: { element, name in fixture.copyAttribute(element, name: name) })
    }

    private static func button(_ pid: Int32, title: String?, identifier: String?) -> DialogMetadataFixture.Node {
        var attributes: [String: CFTypeRef] = ["AXEnabled": kCFBooleanFalse]
        if let title {
            attributes["AXTitle"] = title as CFString
        }
        if let identifier {
            attributes["AXIdentifier"] = identifier as CFString
        }
        return DialogMetadataFixture.Node(pid, role: "AXButton", attributes: attributes)
    }
}

enum MetadataTextSample: Int, CaseIterable, Sendable {
    case string, attributed, empty, numeric, opaque, null, absent

    var value: CFTypeRef? {
        switch self {
        case .string: "  Content\n" as CFString
        case .attributed: NSAttributedString(string: "  Styled\n")
        case .empty: "" as CFString
        case .numeric: NSNumber(value: 42)
        case .opaque: NSArray(array: ["Not text content"])
        case .null: NSNull()
        case .absent: nil
        }
    }

    var expected: String? {
        switch self {
        case .string: "  Content\n"
        case .attributed: "  Styled\n"
        case .empty: ""
        case .numeric, .opaque, .null, .absent: nil
        }
    }
}

/// The fixture is immutable after construction; its retained CF objects are only read by the worker.
private struct DialogMetadataFixture: @unchecked Sendable {
    let nodes: [Node]

    static let alternativeChildren = [
        "AXVisibleChildren", "AXWebAreaChildren", "AXApplicationNavigation", "AXApplicationElements",
        "AXBodyArea", "AXSplitGroupContents", "AXLayoutAreaChildren", "AXGroupChildren", "AXContents",
        "AXChildrenInNavigationOrder", "AXSelectedChildren", "AXRows", "AXColumns", "AXTabs",
    ]

    func copyAttribute(_ element: AXUIElement, name: String) -> (error: AXError, value: CFTypeRef?) {
        guard let node = self.nodes.first(where: { CFEqual($0.element, element) }) else {
            return (.invalidUIElement, nil)
        }
        if let error = node.failures[name] {
            return (error, node.attributes[name])
        }
        guard let value = node.attributes[name] else { return (.attributeUnsupported, nil) }
        return (.success, value)
    }

    struct Node {
        let pid: Int32
        let element: AXUIElement
        let attributes: [String: CFTypeRef]
        let failures: [String: AXError]

        init(
            _ pid: Int32,
            role: String? = nil,
            attributes: [String: CFTypeRef] = [:],
            children: [Node] = [],
            failures: [String: AXError] = [:])
        {
            self.pid = pid
            self.element = AXUIElementCreateApplication(pid)
            var values = attributes
            if let role {
                values["AXRole"] = role as CFString
            }
            if !children.isEmpty {
                values["AXChildren"] = NSArray(array: children.map(\.element))
            }
            self.attributes = values
            self.failures = failures
        }
    }
}
