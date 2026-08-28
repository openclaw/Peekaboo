import Foundation
@testable import Peekaboo

@MainActor
func makeTestSettings() -> PeekabooSettings {
    let fixture = CredentialCoordinatorFixture()
    return PeekabooSettings(credentialCoordinator: fixture.coordinator())
}
