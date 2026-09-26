import XCTest
@testable import Tokenroom

/// Claude Code's settings are the user's file: one key changes, every other byte stays.
final class JSONTextEditTests: XCTestCase {
    private var statusLine: [String: Any] {
        ["type": "command", "command": "/tmp/new.sh"]
    }

    /// `statusLine` as the edit writes it: compact, sorted, slashes as they are.
    private let statusLineText = #"{"command":"/tmp/new.sh","type":"command"}"#

    func testReplacingAKeyKeepsEverythingElseByteForByte() throws {
        let old = #"{"type": "command", "command": "echo mine", "padding": 2}"#
        let text = """
        {
            "model": "opus",   "statusLine": \(old),
          "env": {"LANG": "pt_BR.UTF-8", "NOTE": "café ☕"},
            "hooks": []
        }

        """
        let edited = try XCTUnwrap(JSONTextEdit.setting("statusLine", to: statusLine, in: text))
        XCTAssertEqual(edited, text.replacingOccurrences(of: old, with: statusLineText))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(edited.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["statusLine"] as? [String: Any])?["command"] as? String, "/tmp/new.sh")
        XCTAssertEqual((parsed["env"] as? [String: Any])?["NOTE"] as? String, "café ☕", "Multi-byte text before and after is untouched")
    }

    func testAMissingKeyIsAddedLastAtTheSameIndentation() throws {
        let text = "{\n    \"model\": \"opus\",\n    \"env\": {}\n}\n"
        XCTAssertEqual(
            JSONTextEdit.setting("statusLine", to: statusLine, in: text),
            "{\n    \"model\": \"opus\",\n    \"env\": {},\n    \"statusLine\": \(statusLineText)\n}\n"
        )
        XCTAssertEqual(JSONTextEdit.setting("statusLine", to: statusLine, in: "{}"), "{\n  \"statusLine\": \(statusLineText)\n}")
        XCTAssertEqual(JSONTextEdit.setting("statusLine", to: statusLine, in: " { \n } "), " {\n  \"statusLine\": \(statusLineText)\n} ", "Space around the object stays")
        XCTAssertEqual(JSONTextEdit.setting("padding", to: 2, in: #"{"a":true}"#), "{\"a\":true,\n\"padding\": 2}", "Plain values work too; a one-line file has no indentation to copy")
    }

    func testRemovingAKeyTakesItsComma() {
        XCTAssertEqual(JSONTextEdit.removing("statusLine", in: #"{"a": 1, "statusLine": {"x": [1, 2]}, "b": 2}"#), #"{"a": 1, "b": 2}"#, "In the middle")
        XCTAssertEqual(JSONTextEdit.removing("statusLine", in: "{\n  \"a\": 1,\n  \"statusLine\": {}\n}\n"), "{\n  \"a\": 1\n}\n", "Last")
        XCTAssertEqual(JSONTextEdit.removing("statusLine", in: "{\n  \"statusLine\": {},\n  \"b\": 2\n}"), "{\n  \"b\": 2\n}", "First")
        XCTAssertEqual(JSONTextEdit.removing("statusLine", in: #"{ "statusLine": "x" }"#), "{\n}", "Only")
        XCTAssertEqual(JSONTextEdit.removing("statusLine", in: #"{"a": 1}"#), #"{"a": 1}"#, "Missing: unchanged")
    }

    func testBracesAndQuotesInsideStringsDontEndAValue() throws {
        let text = #"{"env": {"A": "} ] \" {", "B": ["]", {"c": "\\"}]}, "statusLine": "echo \"}\"", "z": [1, {"y": "{"}]}"#
        let edited = try XCTUnwrap(JSONTextEdit.setting("statusLine", to: statusLine, in: text))
        XCTAssertEqual(edited, text.replacingOccurrences(of: #""echo \"}\"""#, with: statusLineText))
        let removed = try XCTUnwrap(JSONTextEdit.removing("env", in: text))
        XCTAssertEqual(removed, #"{"statusLine": "echo \"}\"", "z": [1, {"y": "{"}]}"#)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(removed.utf8)))
    }

    func testAddedLinesEndLikeTheTextsOwn() throws {
        let crlf = "{\r\n  \"model\": \"opus\"\r\n}\r\n"
        let added = try XCTUnwrap(JSONTextEdit.setting("statusLine", to: statusLine, in: crlf))
        XCTAssertEqual(added, "{\r\n  \"model\": \"opus\",\r\n  \"statusLine\": \(statusLineText)\r\n}\r\n")
        XCTAssertEqual(JSONTextEdit.removing("statusLine", in: added), crlf, "Removing it gives the text back exactly")
        XCTAssertEqual(JSONTextEdit.setting("statusLine", to: statusLine, in: "{\r\n}"), "{\r\n  \"statusLine\": \(statusLineText)\r\n}")
        XCTAssertEqual(JSONTextEdit.removing("statusLine", in: "{\r\n  \"statusLine\": {}\r\n}"), "{\r\n}", "Only")
    }

    func testAKeySetTwiceIsRefused() {
        // Foundation reads the first of duplicate keys and Node (Claude Code) the last.
        let text = #"{"statusLine": {"command": "a"}, "model": "opus", "statusLine": {"command": "b"}}"#
        XCTAssertEqual(JSONTextEdit.count(of: "statusLine", in: text), 2)
        XCTAssertEqual(JSONTextEdit.count(of: "model", in: text), 1)
        XCTAssertEqual(JSONTextEdit.count(of: "env", in: text), 0)
        XCTAssertNil(JSONTextEdit.count(of: "statusLine", in: "[1, 2]"))
        XCTAssertNil(JSONTextEdit.setting("statusLine", to: statusLine, in: text))
        XCTAssertNil(JSONTextEdit.removing("statusLine", in: text))

        let otherTwice = #"{"env": {}, "env": {"A": "1"}, "statusLine": "x"}"#
        XCTAssertEqual(
            JSONTextEdit.setting("statusLine", to: statusLine, in: otherTwice),
            #"{"env": {}, "env": {"A": "1"}, "statusLine": \#(statusLineText)}"#,
            "Another key set twice doesn't stop the edit"
        )
    }

    func testRefusesWhatIsntOneJSONObject() {
        for text in ["[1, 2]", #""statusLine""#, "", "   ", #"{"a": 1} trailing"#, #"{"a": 1}{"b": 2}"#, #"{"a": 1,}"#, #"{"a" 1}"#, #"{"a": "unterminated}"#, #"{"a": {"b": 1}"#] {
            XCTAssertNil(JSONTextEdit.setting("statusLine", to: statusLine, in: text), text)
            XCTAssertNil(JSONTextEdit.removing("statusLine", in: text), text)
        }
        XCTAssertNil(JSONTextEdit.setting("statusLine", to: Date(), in: "{}"), "A value JSON can't hold")
    }
}
