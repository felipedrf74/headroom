import Foundation

/// Edits one top-level key of a JSON object in place, leaving the rest of the text (formatting,
/// key order, comments-free spacing) exactly as the user wrote it. Returns nil when the text
/// isn't a JSON object it can edit safely, or sets the key more than once: Foundation reads the
/// first of duplicate keys and Node (Claude Code) the last, so editing either might not count.
enum JSONTextEdit {
    /// The text with `key`'s value replaced, or the key added at the end when it's missing. An
    /// added line ends like the text's own lines (CRLF or LF).
    static func setting(_ key: String, to value: Any, in text: String) -> String? {
        guard let valueText = compact(value) else { return nil }
        var bytes = Array(text.utf8)
        guard let object = scanObject(bytes), object.count(of: key) <= 1 else { return nil }
        if let member = object.members.first(where: { $0.key == key }) {
            bytes.replaceSubrange(member.valueRange, with: Array(valueText.utf8))
            return String(decoding: bytes, as: UTF8.self)
        }
        let keyText = compact(key) ?? "\"\(key)\""
        let indent = object.members.last.map { indentation(before: $0.keyStart, in: bytes) } ?? "  "
        let newline = lineEnding(in: bytes)
        let insertion: String
        if let last = object.members.last {
            insertion = ",\(newline)\(indent)\(keyText): \(valueText)"
            bytes.insert(contentsOf: Array(insertion.utf8), at: last.valueRange.upperBound)
        } else {
            insertion = "\(newline)\(indent)\(keyText): \(valueText)\(newline)"
            bytes.replaceSubrange((object.open + 1)..<object.close, with: Array(insertion.utf8))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The text without `key`, and without the comma that separated it.
    static func removing(_ key: String, in text: String) -> String? {
        var bytes = Array(text.utf8)
        guard let object = scanObject(bytes), object.count(of: key) <= 1 else { return nil }
        guard let index = object.members.firstIndex(where: { $0.key == key }) else { return text }
        let member = object.members[index]
        let range: Range<Int>
        var replacement: [UInt8] = []
        if index > 0 {
            // From the end of the previous value: drops ", "key": value".
            range = object.members[index - 1].valueRange.upperBound..<member.valueRange.upperBound
        } else if object.members.count > 1 {
            // First of several: drops ""key": value, " up to the next key.
            range = member.keyStart..<object.members[index + 1].keyStart
        } else {
            range = (object.open + 1)..<object.close
            replacement = Array(lineEnding(in: bytes).utf8)
        }
        bytes.replaceSubrange(range, with: replacement)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// How many times the object sets `key` at the top level; nil when the text isn't a JSON
    /// object these edits can handle.
    static func count(of key: String, in text: String) -> Int? {
        scanObject(Array(text.utf8))?.count(of: key)
    }

    // MARK: Scanning

    private struct Member {
        var key: String
        var keyStart: Int
        var valueRange: Range<Int>
    }

    private struct Object {
        var open: Int
        var close: Int
        var members: [Member]

        func count(of key: String) -> Int {
            members.filter { $0.key == key }.count
        }
    }

    private static func compact(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8)
        else { return nil }
        // Serialized inside an array so strings and numbers work too; drop the brackets.
        return String(array.dropFirst().dropLast())
    }

    /// CRLF when the text's first line break is one, else LF. JSON strings can't hold a raw line
    /// break, so any in the text is layout.
    private static func lineEnding(in bytes: [UInt8]) -> String {
        guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return "\n" }
        return newline > 0 && bytes[newline - 1] == UInt8(ascii: "\r") ? "\r\n" : "\n"
    }

    private static func indentation(before position: Int, in bytes: [UInt8]) -> String {
        var start = position
        while start > 0, bytes[start - 1] == UInt8(ascii: " ") || bytes[start - 1] == UInt8(ascii: "\t") {
            start -= 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// The top-level object's braces and members, or nil for anything else.
    private static func scanObject(_ bytes: [UInt8]) -> Object? {
        var index = skipWhitespace(bytes, 0)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "{") else { return nil }
        let open = index
        index += 1
        var members: [Member] = []
        index = skipWhitespace(bytes, index)
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            return trailingIsEmpty(bytes, index + 1) ? Object(open: open, close: index, members: []) : nil
        }
        while index < bytes.count {
            index = skipWhitespace(bytes, index)
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let keyEnd = endOfString(bytes, index) else { return nil }
            let keyStart = index
            guard let key = try? JSONSerialization.jsonObject(with: Data(bytes[index..<keyEnd]), options: .fragmentsAllowed) as? String else { return nil }
            index = skipWhitespace(bytes, keyEnd)
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index = skipWhitespace(bytes, index + 1)
            guard let valueEnd = endOfValue(bytes, index) else { return nil }
            members.append(Member(key: key, keyStart: keyStart, valueRange: index..<valueEnd))
            index = skipWhitespace(bytes, valueEnd)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                return trailingIsEmpty(bytes, index + 1) ? Object(open: open, close: index, members: members) : nil
            } else {
                return nil
            }
        }
        return nil
    }

    private static func trailingIsEmpty(_ bytes: [UInt8], _ index: Int) -> Bool {
        skipWhitespace(bytes, index) == bytes.count
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: Int) -> Int {
        var index = index
        while index < bytes.count, [UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")].contains(bytes[index]) {
            index += 1
        }
        return index
    }

    /// One past the closing quote of the string starting at `index`.
    private static func endOfString(_ bytes: [UInt8], _ index: Int) -> Int? {
        var index = index + 1
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\\"):
                index += 2
            case UInt8(ascii: "\""):
                return index + 1
            default:
                index += 1
            }
        }
        return nil
    }

    /// One past the end of the value starting at `index`: a string, an object or array (nesting
    /// counted, strings skipped), or a literal.
    private static func endOfValue(_ bytes: [UInt8], _ index: Int) -> Int? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "\""):
            return endOfString(bytes, index)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            var position = index
            while position < bytes.count {
                switch bytes[position] {
                case UInt8(ascii: "\""):
                    guard let end = endOfString(bytes, position) else { return nil }
                    position = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return position + 1 }
                default:
                    break
                }
                position += 1
            }
            return nil
        default:
            var position = index
            while position < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t")].contains(bytes[position]) {
                position += 1
            }
            return position > index ? position : nil
        }
    }
}
