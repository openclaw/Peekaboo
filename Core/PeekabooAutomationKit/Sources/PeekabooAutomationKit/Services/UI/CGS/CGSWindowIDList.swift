import CoreGraphics

enum CGSWindowIDList {
    static func read(
        count: (UnsafeMutablePointer<Int32>) -> Int32,
        list: (Int32, UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32) -> [CGWindowID]?
    {
        var capacity: Int32 = 0
        guard count(&capacity) == 0, capacity >= 0 else { return nil }
        guard capacity > 0 else { return [] }

        var ids = [CGWindowID](repeating: 0, count: Int(capacity))
        var actualCount: Int32 = 0
        guard list(capacity, &ids, &actualCount) == 0,
              (0...capacity).contains(actualCount)
        else { return nil }
        return Array(ids.prefix(Int(actualCount)))
    }
}
