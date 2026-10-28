import Foundation

/// Validates JSON against the checked-in schemas in `native/system/schemas/`. It implements the JSON Schema 2020-12
/// keywords those files use and rejects a schema with any other keyword, so a schema can never rely on a keyword this
/// silently ignores.
struct SchemaValidator {
    /// The copy in the test bundle (Xcode), else the checked-in folder (`swift test`).
    static let folder = Bundle(for: BundleToken.self).url(forResource: "schemas", withExtension: nil)
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../schemas").standardizedFileURL

    private static let annotations: Set<String> = ["$schema", "$id", "title", "description", "$defs"]
    private static let keywords: Set<String> = [
        "$ref", "allOf", "anyOf", "type", "enum", "const", "required", "properties", "additionalProperties", "items",
        "minimum", "maximum", "exclusiveMinimum", "maxItems", "pattern", "format"
    ]

    private var documents: [String: Any] = [:]

    /// The problems found validating `instance` against `schemaFile`; empty when it is valid.
    mutating func errors(_ instance: Any, schemaFile: String) throws -> [String] {
        var errors: [String] = []
        try check(instance, against: try document(schemaFile), file: schemaFile, at: "$", errors: &errors)
        return errors
    }

    /// The problems found validating `instance` against an inline schema whose references are relative to `base`.
    mutating func errors(_ instance: Any, schema: [String: Any], base: String = "common.schema.json") throws -> [String] {
        var errors: [String] = []
        try check(instance, against: schema, file: base, at: "$", errors: &errors)
        return errors
    }

    /// Parses `text` as JSON and validates it.
    mutating func errors(json text: String, schemaFile: String) throws -> [String] {
        try errors(try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]), schemaFile: schemaFile)
    }

    private mutating func document(_ file: String) throws -> Any {
        if let cached = documents[file] { return cached }
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.folder.appendingPathComponent(file)))
        documents[file] = parsed
        return parsed
    }

    private mutating func resolve(_ reference: String, from file: String) throws -> (Any, String) {
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts[0].isEmpty ? file : parts[0]
        var node = try document(target)
        for token in (parts.count > 1 ? parts[1] : "").split(separator: "/") {
            guard let object = node as? [String: Any], let next = object[String(token)] else {
                throw ValidationSetupError("Unresolvable $ref \(reference) in \(file)")
            }
            node = next
        }
        return (node, target)
    }

    private mutating func check(_ value: Any, against schema: Any, file: String, at path: String,
                                errors: inout [String]) throws {
        if let flag = schema as? NSNumber, Self.isBool(flag) {
            if !flag.boolValue { errors.append("\(path): no value is allowed here") }
            return
        }
        guard let schema = schema as? [String: Any] else { throw ValidationSetupError("Schema at \(path) is not an object") }
        if let unknown = schema.keys.first(where: { !Self.keywords.contains($0) && !Self.annotations.contains($0) }) {
            throw ValidationSetupError("Unsupported keyword \(unknown) in \(file)")
        }
        if let reference = schema["$ref"] as? String {
            let (target, targetFile) = try resolve(reference, from: file)
            try check(value, against: target, file: targetFile, at: path, errors: &errors)
        }
        for sub in schema["allOf"] as? [Any] ?? [] {
            try check(value, against: sub, file: file, at: path, errors: &errors)
        }
        if let options = schema["anyOf"] as? [Any] {
            var matched = false
            for option in options {
                var optionErrors: [String] = []
                try check(value, against: option, file: file, at: path, errors: &optionErrors)
                if optionErrors.isEmpty { matched = true; break }
            }
            if !matched { errors.append("\(path): matches none of anyOf") }
        }
        if let type = schema["type"] {
            let allowed = (type as? [String]) ?? [type as? String].compactMap { $0 }
            if !allowed.contains(where: { Self.matches(value, type: $0) }) {
                errors.append("\(path): \(Self.describe(value)) is not \(allowed.joined(separator: " or "))")
                return
            }
        }
        if let options = schema["enum"] as? [Any], !options.contains(where: { Self.equal($0, value) }) {
            errors.append("\(path): \(Self.describe(value)) is not one of the allowed values")
        }
        if let constant = schema["const"], !Self.equal(constant, value) {
            errors.append("\(path): \(Self.describe(value)) is not the constant \(constant)")
        }
        if let number = value as? NSNumber, !Self.isBool(number) {
            let double = number.doubleValue
            if let minimum = (schema["minimum"] as? NSNumber)?.doubleValue, double < minimum {
                errors.append("\(path): \(double) is below \(minimum)")
            }
            if let maximum = (schema["maximum"] as? NSNumber)?.doubleValue, double > maximum {
                errors.append("\(path): \(double) is above \(maximum)")
            }
            if let minimum = (schema["exclusiveMinimum"] as? NSNumber)?.doubleValue, double <= minimum {
                errors.append("\(path): \(double) is not above \(minimum)")
            }
        }
        if let string = value as? String {
            if let pattern = schema["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil {
                errors.append("\(path): \"\(string)\" does not match \(pattern)")
            }
            if schema["format"] as? String == "date-time" {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let plain = ISO8601DateFormatter()
                if formatter.date(from: string) == nil && plain.date(from: string) == nil {
                    errors.append("\(path): \"\(string)\" is not a date-time")
                }
            }
        }
        if let array = value as? [Any] {
            if let maxItems = schema["maxItems"] as? Int, array.count > maxItems {
                errors.append("\(path): \(array.count) items, more than \(maxItems)")
            }
            if let items = schema["items"] {
                for (index, item) in array.enumerated() {
                    try check(item, against: items, file: file, at: "\(path)[\(index)]", errors: &errors)
                }
            }
        }
        if let object = value as? [String: Any] {
            for key in schema["required"] as? [String] ?? [] where object[key] == nil {
                errors.append("\(path): missing \(key)")
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, member) in object.sorted(by: { $0.key < $1.key }) {
                if let property = properties[key] {
                    try check(member, against: property, file: file, at: "\(path).\(key)", errors: &errors)
                } else if let additional = schema["additionalProperties"] {
                    try check(member, against: additional, file: file, at: "\(path).\(key)", errors: &errors)
                }
            }
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "boolean": return (value as? NSNumber).map(isBool) ?? false
        case "number": return (value as? NSNumber).map { !isBool($0) } ?? false
        case "integer":
            guard let number = value as? NSNumber, !isBool(number) else { return false }
            return number.doubleValue.rounded() == number.doubleValue
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return false
        }
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case (is NSNull, is NSNull): return true
        case let (left as String, right as String): return left == right
        case let (left as NSNumber, right as NSNumber): return isBool(left) == isBool(right) && left == right
        default: return false
        }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case is NSNull: "null"
        case let string as String: "\"\(string.prefix(60))\""
        case is [Any]: "an array"
        case is [String: Any]: "an object"
        default: "\(value)"
        }
    }
}

private final class BundleToken {}

struct ValidationSetupError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
