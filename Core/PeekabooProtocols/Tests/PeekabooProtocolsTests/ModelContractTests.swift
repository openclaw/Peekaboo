import Foundation
import PeekabooProtocols
import Testing

struct ModelContractTests {
    @Test
    func `log levels sort by severity`() {
        let levels: [LogLevel] = [.critical, .warning, .trace, .error, .debug, .info]

        #expect(levels.sorted() == [.trace, .debug, .info, .warning, .error, .critical])
        #expect(!(LogLevel.info < .info))
    }

    @Test
    func `log levels keep their numeric wire values`() throws {
        let levels: [LogLevel] = [.trace, .debug, .info, .warning, .error, .critical]
        let wireValues = Data("[0,1,2,3,4,5]".utf8)

        #expect(try JSONEncoder().encode(levels) == wireValues)
        #expect(try JSONDecoder().decode([LogLevel].self, from: wireValues) == levels)
    }

    @Test
    func `detected element defaults to enabled without label or value`() {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 30)
        let element = DetectedElement(id: "button-1", type: .button, bounds: bounds)

        #expect(element.id == "button-1")
        #expect(element.type == .button)
        #expect(element.bounds == bounds)
        #expect(element.label == nil)
        #expect(element.value == nil)
        #expect(element.isEnabled)
    }

    @Test
    func `detected element codable preserves explicit values`() throws {
        let element = DetectedElement(
            id: "field-2",
            type: .textField,
            bounds: CGRect(x: -20, y: 15, width: 120, height: 25),
            label: "Search",
            value: "query",
            isEnabled: false)

        let data = try JSONEncoder().encode(element)
        let decoded = try JSONDecoder().decode(DetectedElement.self, from: data)

        #expect(decoded.id == element.id)
        #expect(decoded.type == element.type)
        #expect(decoded.bounds == element.bounds)
        #expect(decoded.label == element.label)
        #expect(decoded.value == element.value)
        #expect(decoded.isEnabled == false)
    }
}
