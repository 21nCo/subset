import Foundation

/// The JSON grammar of RFC 8259, as JavaScript's `JSON.parse` reads it, checked over UTF-8 bytes before Foundation
/// parses them. `JSONSerialization` is more lenient than `JSON.parse` (it reads trailing commas, and UTF-16 or UTF-32
/// text without a byte order mark), so without this check the app would accept feeds, cached copies and receipts that
/// the `subset` command refuses. One difference is the other way round, on purpose: a property name that appears twice
/// in an object is refused here, because `JSON.parse` keeps the last value and `JSONSerialization` the first, so the two
/// readers would otherwise see different documents.
enum StrictJSON {
    /// Why `bytes` is not one JSON text, or nil when it is. The bytes must already be valid UTF-8.
    static func problem(_ bytes: [UInt8]) -> String? {
        var scanner = Scanner(bytes: bytes)
        return scanner.run()
    }

    private struct Refusal: Error {
        let text: String

        init(_ text: String) {
            self.text = text
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        /// An open object (with the property names read so far, as UTF-16 code units) or array.
        enum Frame {
            case object(Set<[UInt16]>)
            case array

            var isObject: Bool {
                if case .object = self { return true }
                return false
            }
        }

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        // Iterative, so a deeply nested document cannot overflow the stack.
        mutating func run() -> String? {
            var stack: [Frame] = []
            while true {
                // A value is expected here.
                skipWhitespace()
                guard index < bytes.count else { return "it ends where a value is expected" }
                switch bytes[index] {
                case UInt8(ascii: "{"):
                    index += 1
                    skipWhitespace()
                    if peek(UInt8(ascii: "}")) {
                        index += 1
                    } else {
                        var names = Set<[UInt16]>()
                        if let problem = propertyName(into: &names) { return problem }
                        stack.append(.object(names))
                        continue
                    }
                case UInt8(ascii: "["):
                    index += 1
                    skipWhitespace()
                    if peek(UInt8(ascii: "]")) {
                        index += 1
                    } else {
                        stack.append(.array)
                        continue
                    }
                case UInt8(ascii: "\""):
                    if case .failure(let refusal) = string() { return refusal.text }
                case UInt8(ascii: "t"):
                    if let problem = literal("true") { return problem }
                case UInt8(ascii: "f"):
                    if let problem = literal("false") { return problem }
                case UInt8(ascii: "n"):
                    if let problem = literal("null") { return problem }
                case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                    if let problem = number() { return problem }
                default:
                    return unexpected()
                }
                // A value has ended: close containers until another value is expected, or the text ends.
                while true {
                    skipWhitespace()
                    guard let frame = stack.last else {
                        return index == bytes.count ? nil : unexpected("after the JSON value")
                    }
                    guard index < bytes.count else { return "it ends inside an \(frame.isObject ? "object" : "array")" }
                    let byte = bytes[index]
                    if byte == UInt8(ascii: ",") {
                        index += 1
                        skipWhitespace()
                        if case .object(var names) = frame {
                            if let problem = propertyName(into: &names, afterComma: true) { return problem }
                            stack[stack.count - 1] = .object(names)
                        } else if peek(UInt8(ascii: "]")) {
                            return "a trailing comma at byte \(index - 1)"
                        }
                        break
                    }
                    if byte == UInt8(ascii: frame.isObject ? "}" : "]") {
                        index += 1
                        stack.removeLast()
                        continue
                    }
                    return unexpected("in an \(frame.isObject ? "object" : "array")")
                }
            }
        }

        // A property name and its colon, refusing one already in `names`.
        mutating func propertyName(into names: inout Set<[UInt16]>, afterComma: Bool = false) -> String? {
            guard peek(UInt8(ascii: "\"")) else {
                if afterComma, peek(UInt8(ascii: "}")) { return "a trailing comma before byte \(index)" }
                return unexpected("where a property name is expected")
            }
            let start = index
            switch string() {
            case .failure(let refusal): return refusal.text
            case .success(let name):
                guard names.insert(name).inserted else { return "the property name at byte \(start) appears twice in its object" }
            }
            skipWhitespace()
            guard peek(UInt8(ascii: ":")) else { return unexpected("where a colon is expected") }
            index += 1
            return nil
        }

        // A string, returned as UTF-16 code units (the unit property names are compared in).
        mutating func string() -> Result<[UInt16], Refusal> {
            let start = index
            index += 1
            var units: [UInt16] = []
            var run = index
            func flush(_ end: Int) {
                units += String(decoding: bytes[run ..< end], as: UTF8.self).utf16
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flush(index)
                    index += 1
                    return .success(units)
                }
                if byte < 0x20 { return .failure(Refusal("a control character (byte \(index)) in a string")) }
                if byte != UInt8(ascii: "\\") {
                    index += 1
                    continue
                }
                flush(index)
                guard index + 1 < bytes.count else { break }
                let escape = bytes[index + 1]
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): units.append(UInt16(escape))
                case UInt8(ascii: "b"): units.append(0x08)
                case UInt8(ascii: "f"): units.append(0x0C)
                case UInt8(ascii: "n"): units.append(0x0A)
                case UInt8(ascii: "r"): units.append(0x0D)
                case UInt8(ascii: "t"): units.append(0x09)
                case UInt8(ascii: "u"):
                    guard index + 6 <= bytes.count,
                          let unit = UInt16(String(decoding: bytes[index + 2 ..< index + 6], as: UTF8.self), radix: 16),
                          bytes[index + 2 ..< index + 6].allSatisfy(\.isHexDigit)
                    else { return .failure(Refusal("a bad \\u escape at byte \(index)")) }
                    units.append(unit)
                    index += 4
                default:
                    return .failure(Refusal("a bad escape at byte \(index)"))
                }
                index += 2
                run = index
            }
            return .failure(Refusal("the string that starts at byte \(start) does not end"))
        }

        mutating func literal(_ word: String) -> String? {
            let expected = Array(word.utf8)
            guard bytes.count - index >= expected.count, Array(bytes[index ..< index + expected.count]) == expected else {
                return unexpected()
            }
            index += expected.count
            return nil
        }

        // -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
        mutating func number() -> String? {
            let start = index
            if peek(UInt8(ascii: "-")) { index += 1 }
            if peek(UInt8(ascii: "0")) {
                index += 1
            } else if digits() == 0 {
                return "a bad number at byte \(start)"
            }
            if peek(UInt8(ascii: ".")) {
                index += 1
                if digits() == 0 { return "a bad number at byte \(start)" }
            }
            if peek(UInt8(ascii: "e")) || peek(UInt8(ascii: "E")) {
                index += 1
                if peek(UInt8(ascii: "+")) || peek(UInt8(ascii: "-")) { index += 1 }
                if digits() == 0 { return "a bad number at byte \(start)" }
            }
            return nil
        }

        mutating func digits() -> Int {
            let start = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            return index - start
        }

        // RFC 8259 whitespace: space, tab, line feed and carriage return only.
        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        func peek(_ byte: UInt8) -> Bool {
            index < bytes.count && bytes[index] == byte
        }

        func unexpected(_ place: String = "") -> String {
            guard index < bytes.count else { return "it ends too early" }
            let byte = bytes[index]
            let shown = (0x21 ..< 0x7F).contains(byte) ? "\"\(Character(Unicode.Scalar(byte)))\"" : String(format: "byte 0x%02X", byte)
            return "unexpected \(shown) at byte \(index)\(place.isEmpty ? "" : " \(place)")"
        }
    }
}

private extension UInt8 {
    var isHexDigit: Bool {
        (0x30 ... 0x39).contains(self) || (0x41 ... 0x46).contains(self) || (0x61 ... 0x66).contains(self)
    }
}
