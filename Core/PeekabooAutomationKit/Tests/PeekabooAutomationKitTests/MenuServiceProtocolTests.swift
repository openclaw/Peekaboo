import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct MenuServiceProtocolTests {
    private let identity = ApplicationProcessIdentity(
        processIdentifier: 701,
        processStartIdentity: 9001)

    @Test
    func `application menu requests default and decode as background`() throws {
        let path = try MenuItemActionRequest(
            appIdentifier: "PID:701",
            itemPath: "File > New",
            expectedIdentity: self.identity)
        let named = try MenuItemByNameActionRequest(
            appIdentifier: "PID:701",
            itemName: "New",
            expectedIdentity: self.identity)

        #expect(path.deliveryMode == .background)
        #expect(named.deliveryMode == .background)
        #expect(try self.decodingWithoutDeliveryMode(path).deliveryMode == .background)
        #expect(try self.decodingWithoutDeliveryMode(named).deliveryMode == .background)
    }

    @Test
    func `foreground application menu delivery remains explicit`() throws {
        let path = try MenuItemActionRequest(
            appIdentifier: "PID:701",
            itemPath: "File > New",
            expectedIdentity: self.identity,
            deliveryMode: .foreground)
        let named = try MenuItemByNameActionRequest(
            appIdentifier: "PID:701",
            itemName: "New",
            expectedIdentity: self.identity,
            deliveryMode: .foreground)

        #expect(path.deliveryMode == .foreground)
        #expect(named.deliveryMode == .foreground)
    }

    @Test
    func `menu list requests require the expected PID identifier`() throws {
        let request = try MenuListRequest(
            appIdentifier: "PID:701",
            expectedIdentity: self.identity)
        let decoded = try JSONDecoder().decode(
            MenuListRequest.self,
            from: JSONEncoder().encode(request))

        #expect(decoded == request)
        #expect(throws: (any Error).self) {
            try MenuListRequest(appIdentifier: "Fixture", expectedIdentity: self.identity)
        }
    }

    @Test
    @MainActor
    func `menu list requests reject a substituted process generation`() async throws {
        let replacement = ServiceApplicationInfo(
            processIdentifier: self.identity.processIdentifier,
            processStartIdentity: self.identity.processStartIdentity + 1,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")
        let service = LegacyMenuProtocolProbe(menuStructure: MenuStructure(application: replacement, menus: []))
        let request = try MenuListRequest(
            appIdentifier: "PID:701",
            expectedIdentity: self.identity)

        do {
            _ = try await service.listMenus(request: request)
            Issue.record("Expected a substituted menu generation to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.targetReceipt?.processIdentifier == self.identity.processIdentifier)
            #expect(failure.targetReceipt?.processStartIdentity == self.identity.processStartIdentity)
        }
        #expect(service.listIdentifiers == ["PID:701"])
    }

    @Test
    @MainActor
    func `legacy app menu result adapters describe background delivery`() async throws {
        let service: any MenuServiceProtocol = LegacyMenuProtocolProbe()

        let path = try await service.clickMenuItemResult(app: "Fixture", itemPath: "File > New")
        let named = try await service.clickMenuItemByNameResult(app: "Fixture", itemName: "New")

        #expect(path.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .background))
        #expect(named.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .background))
    }

    private func decodingWithoutDeliveryMode<Value: Codable>(_ value: Value) throws -> Value {
        let encoded = try JSONEncoder().encode(value)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "deliveryMode")
        let legacyShape = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Value.self, from: legacyShape)
    }
}

@MainActor
private final class LegacyMenuProtocolProbe: MenuServiceProtocol {
    let menuStructure: MenuStructure?
    private(set) var listIdentifiers: [String] = []

    init(menuStructure: MenuStructure? = nil) {
        self.menuStructure = menuStructure
    }

    func listMenus(for identifier: String) async throws -> MenuStructure {
        self.listIdentifiers.append(identifier)
        guard let menuStructure else {
            throw PeekabooError.notImplemented("unused")
        }
        return menuStructure
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {}
    func clickMenuItemByName(app _: String, itemName _: String) async throws {}
    func clickMenuExtra(title _: String) async throws {}

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named name: String) async throws -> ClickResult {
        .init(elementDescription: name, location: nil)
    }

    func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        .init(elementDescription: String(index), location: nil)
    }
}
