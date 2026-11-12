import Foundation

/// Pulls the JSON object out of a reply from a model that cannot be held to a schema: thinking, code fences,
/// and words around it go, trailing commas go, and a reply cut off mid-object is closed.
enum JSONRepair {
    static func extract(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var out = ""
        var closers: [Character] = []
        var inString = false, escaped = false
        for c in cleaned[start...] {
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true; out.append(c)
            case "{": closers.append("}"); out.append(c)
            case "[": closers.append("]"); out.append(c)
            case "}", "]":
                dropTrailingComma(&out)
                out.append(c)
                closers.removeLast()
                if closers.isEmpty { return out }
            default: out.append(c)
            }
        }
        // Cut off: close what is open.
        if inString { out.append("\"") }
        for closer in closers.reversed() {
            dropTrailingComma(&out)
            out.append(closer)
        }
        return out
    }

    private static func dropTrailingComma(_ s: inout String) {
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)].isWhitespace { end = s.index(before: end) }
        if end > s.startIndex, s[s.index(before: end)] == "," { s.removeSubrange(s.index(before: end)...) }
    }

    /// The words that ask a model for JSON when the request cannot carry the schema itself.
    static func instructions(_ schema: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return "Reply with one JSON object and nothing else. It must match this JSON Schema exactly:\n" + String(decoding: data, as: UTF8.self)
    }

    /// The reply decoded, or what is wrong with it in words a model can act on.
    static func read<Output: Decodable>(_ text: String?, schema: [String: Any], as: Output.Type) -> (output: Output?, problems: [String]) {
        guard let text, let json = extract(text) else { return (nil, ["the reply has no JSON object"]) }
        guard var value = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return (nil, ["the reply is not valid JSON"]) }
        let problems = SchemaCheck.fill(&value, schema: schema)
        guard problems.isEmpty else { return (nil, problems) }
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let output = try? JSONDecoder().decode(Output.self, from: data) else { return (nil, ["the JSON does not match the schema"]) }
        return (output, [])
    }

    /// The message that asks for the reply again.
    static func correction(_ problems: [String]) -> String {
        "That reply does not match the JSON Schema: " + problems.prefix(8).joined(separator: "; ")
            + ". Reply again with only the corrected JSON object."
    }
}

/// Checks a decoded JSON value against the subset of JSON Schema Mossad uses, and fills what a model may leave
/// out: a missing nullable field becomes null, a missing list becomes empty, and a value outside an open list
/// becomes "other".
enum SchemaCheck {
    /// Text fields that came after the first replies, where "" means none: a model that leaves one out has none,
    /// and the reply is not asked for again.
    static let blankWhenMissing: Set<String> = ["why"]

    static func fill(_ value: inout Any, schema: [String: Any], path: String = "") -> [String] {
        if let choices = schema["anyOf"] as? [[String: Any]] {
            let nullable = choices.contains { $0["type"] as? String == "null" }
            if value is NSNull, nullable { return [] }
            for choice in choices where choice["type"] as? String != "null" {
                var copy = value
                if fill(&copy, schema: choice, path: path).isEmpty { value = copy; return [] }
            }
            let names = choices.compactMap { $0["type"] as? String }.filter { $0 != "null" }.map(article)
            return ["\(path) must be \(names.joined(separator: " or "))\(nullable ? " or null" : "")"]
        }
        switch schema["type"] as? String {
        case "object":
            guard var object = value as? [String: Any] else { return ["\(name(path)) must be an object"] }
            var problems: [String] = []
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(schema["required"] as? [String] ?? Array(properties.keys))
            // An open list: a field whose values include "other", with a text field `<name>_label` next to it.
            // A value outside the list, or none, is an "other" with the raw text as its label, and a missing
            // label is "". A model that names a behavior in its own word must not lose the whole reply for it.
            for (key, sub) in properties {
                guard let options = sub["enum"] as? [String], options.contains("other"), properties["\(key)_label"]?["type"] as? String == "string" else { continue }
                let label = (object["\(key)_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let value = object[key] as? String, options.contains(value) {
                    object["\(key)_label"] = object["\(key)_label"] as? String ?? ""
                } else {
                    let raw = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    object[key] = "other"
                    object["\(key)_label"] = label.isEmpty ? raw : label
                }
            }
            for key in properties.keys.sorted() {
                let sub = properties[key]!
                let subPath = path.isEmpty ? key : "\(path).\(key)"
                guard var field = object[key] else {
                    if allowsNull(sub) { object[key] = NSNull() } else if sub["type"] as? String == "array" { object[key] = [Any]() }
                    else if blankWhenMissing.contains(key), sub["type"] as? String == "string" { object[key] = "" }
                    else if required.contains(key) { problems.append("\(subPath) is missing") }
                    continue
                }
                problems += fill(&field, schema: sub, path: subPath)
                object[key] = field
            }
            value = object
            return problems
        case "array":
            guard var list = value as? [Any] else { return ["\(name(path)) must be a list"] }
            let items = schema["items"] as? [String: Any] ?? [:]
            var problems: [String] = []
            for i in list.indices { problems += fill(&list[i], schema: items, path: "\(path)[\(i)]") }
            value = list
            return problems
        case "string":
            guard let s = value as? String else { return ["\(name(path)) must be a string"] }
            if let options = schema["enum"] as? [String], !options.contains(s) {
                return ["\(name(path)) must be one of: \(options.joined(separator: ", "))"]
            }
            return []
        case "number", "integer":
            if let n = value as? NSNumber, !isBool(n) { return [] }
            if let s = value as? String, let d = Double(s) { value = d; return [] }
            return ["\(name(path)) must be a number"]
        case "boolean":
            if let n = value as? NSNumber, isBool(n) { return [] }
            if let s = value as? String, ["true", "false"].contains(s.lowercased()) { value = s.lowercased() == "true"; return [] }
            return ["\(name(path)) must be true or false"]
        case "null":
            return value is NSNull ? [] : ["\(name(path)) must be null"]
        default:
            return []
        }
    }

    private static func name(_ path: String) -> String { path.isEmpty ? "the reply" : path }
    private static func article(_ type: String) -> String { type == "object" || type == "integer" ? "an \(type)" : "a \(type)" }
    private static func allowsNull(_ schema: [String: Any]) -> Bool {
        (schema["anyOf"] as? [[String: Any]])?.contains { $0["type"] as? String == "null" } == true || schema["type"] as? String == "null"
    }
    private static func isBool(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
}
