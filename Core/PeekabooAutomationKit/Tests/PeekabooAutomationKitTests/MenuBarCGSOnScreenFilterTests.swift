import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct MenuBarCGSOnScreenFilterTests {
    @Test
    func `failed and negative counts never reach allocation or list retrieval`() {
        let cases: [(Int32, Int32)] = [(0, -1), (-1, 2)]
        for (statusCode, capacity) in cases {
            var listCalled = false
            let result = CGSWindowIDList.read(
                count: {
                    $0.pointee = capacity
                    return statusCode
                },
                list: { _, _, _ in
                    listCalled = true
                    return 0
                })
            #expect(result == nil)
            #expect(!listCalled)
        }
    }

    @Test
    func `zero count returns empty without passing an empty buffer to CGS`() {
        var listCalled = false
        let result = CGSWindowIDList.read(
            count: {
                $0.pointee = 0
                return 0
            },
            list: { _, _, _ in
                listCalled = true
                return 0
            })
        #expect(result == [])
        #expect(!listCalled)
    }

    @Test
    func `list status and returned count are validated against allocated capacity`() {
        let cases: [(Int32, Int32, [CGWindowID]?)] = [
            (-1, 2, nil), (0, -1, nil), (0, 3, nil),
            (0, 0, []), (0, 1, [10]), (0, 2, [10, 20]),
        ]
        for (statusCode, actualCount, expected) in cases {
            var listCalls = 0
            let result = CGSWindowIDList.read(
                count: {
                    $0.pointee = 2
                    return 0
                },
                list: { capacity, ids, returnedCount in
                    listCalls += 1
                    #expect(capacity == 2)
                    ids[0] = 10
                    ids[1] = 20
                    returnedCount.pointee = actualCount
                    return statusCode
                })
            #expect(result == expected)
            #expect(listCalls == 1)
        }
    }
}
