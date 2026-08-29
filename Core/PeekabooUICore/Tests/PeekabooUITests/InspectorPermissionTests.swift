import Testing
@testable import PeekabooUICore

@Suite(.tags(.permissions))
@MainActor
struct InspectorPermissionTests {
    @Test(arguments: [true, false])
    func `Permission providers update status without prompt`(initiallyGranted: Bool) {
        var granted = initiallyGranted
        var checks = 0
        var prompts = 0
        let permissions = InspectorPermissionState(check: {
            checks += 1
            return granted
        }, prompt: {
            prompts += 1
            return !granted
        })

        #expect(permissions.status == .checking)
        #expect(checks == 0)
        #expect(prompts == 0)

        let changed = permissions.checkPermissions()
        #expect(changed)
        #expect(permissions.status == (granted ? .granted : .denied))
        #expect(checks == 1)
        #expect(prompts == 0)

        let unchanged = permissions.checkPermissions()
        #expect(!unchanged)
        #expect(permissions.status == (granted ? .granted : .denied))
        #expect(checks == 2)
        #expect(prompts == 0)

        granted.toggle()
        let changedAgain = permissions.checkPermissions(prompt: false)
        #expect(changedAgain)
        #expect(permissions.status == (granted ? .granted : .denied))
        #expect(checks == 3)
        #expect(prompts == 0)
    }

    @Test(arguments: [true, false])
    func `Prompt uses prompt provider`(granted: Bool) {
        var checks = 0
        var prompts = 0
        let permissions = InspectorPermissionState(check: {
            checks += 1
            return !granted
        }, prompt: {
            prompts += 1
            return granted
        })

        #expect(permissions.status == .checking)
        #expect(checks == 0)
        #expect(prompts == 0)

        let changed = permissions.checkPermissions(prompt: true)
        #expect(changed)
        #expect(permissions.status == (granted ? .granted : .denied))
        #expect(checks == 0)
        #expect(prompts == 1)
    }
}
