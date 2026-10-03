import Foundation
import Testing
@testable import PeekabooAgentRuntime

@Suite("Agent tool-call argument preview")
struct AgentToolCallArgumentPreviewTests {
    @Test
    func `redacts sensitive JSON keys recursively`() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "command": "echo ok",
            "apiKey": "sk-testSECRET123456789",
            "nested": [
                "authorization": "Bearer liveSECRET123",
                "safe": "visible",
            ],
        ])

        let preview = AgentToolCallArgumentPreview.redacted(from: data)

        #expect(preview.contains("\"command\":\"echo ok\""))
        #expect(preview.contains("\"safe\":\"visible\""))
        #expect(!preview.contains("sk-testSECRET123456789"))
        #expect(!preview.contains("liveSECRET123"))
        #expect(preview.contains("\"apiKey\":\"***\""))
        #expect(preview.contains("\"authorization\":\"***\""))
    }

    @Test
    func `redacts non-JSON secret patterns and truncates`() {
        let raw = "token=abcdef1234567890 " + String(repeating: "x", count: 400)
        let preview = AgentToolCallArgumentPreview.redacted(from: Data(raw.utf8), maxLength: 40)

        #expect(!preview.contains("abcdef1234567890"))
        #expect(preview.hasSuffix("…"))
        #expect(preview.count == 41)
    }

    @Test(arguments: ["dataBase64", "DATABASE64", "DataBase64"])
    func `redacts exact inline payload keys recursively without hiding adjacent metadata`(key: String) throws {
        let payload = Data("synthetic private payload".utf8).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: [
            key: payload,
            "nested": [[key: payload]],
            "uti": "public.html",
            "dataBase64Label": "visible",
        ])

        let preview = AgentToolCallArgumentPreview.redacted(from: data)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any])
        let nested = try #require(decoded["nested"] as? [[String: String]])

        #expect(decoded[key] as? String == "***")
        #expect(nested.first?[key] == "***")
        #expect(decoded["uti"] as? String == "public.html")
        #expect(decoded["dataBase64Label"] as? String == "visible")
        #expect(!preview.contains(payload))
    }

    @Test(arguments: ["", "P", "PHA", "PHA+", "not-yet-valid-base64"])
    func `streaming partial payload values are redacted without decoding`(fragment: String) throws {
        let data = try JSONEncoder().encode(["dataBase64": fragment, "uti": "public.html"])

        let preview = AgentToolCallArgumentPreview.redacted(from: data)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: String])

        #expect(decoded == ["dataBase64": "***", "uti": "public.html"])
        #expect(try JSONDecoder().decode([String: String].self, from: data)["dataBase64"] == fragment)
    }

    @Test
    func `long inline payloads are redacted before preview truncation`() throws {
        let payload = String(repeating: "QUJD", count: 1000)
        let data = try JSONEncoder().encode(["dataBase64": payload, "uti": "public.data"])

        let preview = AgentToolCallArgumentPreview.redacted(from: data)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: String])

        #expect(decoded == ["dataBase64": "***", "uti": "public.data"])
        #expect(!preview.contains("QUJD"))
        #expect(!preview.hasSuffix("…"))
    }
}
