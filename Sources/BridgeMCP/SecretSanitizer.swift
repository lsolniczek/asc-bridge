import Foundation
import BridgeCore

enum SecretSanitizer {
    private static let textPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(
            pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#
        ),
        try! NSRegularExpression(pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#),
        try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#),
        try! NSRegularExpression(
            pattern: #"(?i)\b(api[_-]?key|access[_-]?token|private[_-]?key|client[_-]?secret|authorization|credential|jwt|token|secret|password)\s*[:=]\s*[^\s,;]+"#
        ),
    ]

    static func redact(_ value: JSONValue, depth: Int = 0) -> JSONValue {
        guard depth < 20 else { return .string("[nested value omitted]") }
        switch value {
        case .object(let object):
            var sanitized: [String: JSONValue] = [:]
            for (key, child) in object {
                if isSensitiveField(key) {
                    sanitized[key] = .string("[REDACTED]")
                } else {
                    sanitized[key] = redact(child, depth: depth + 1)
                }
            }
            return .object(sanitized)
        case .array(let array):
            return .array(array.map { redact($0, depth: depth + 1) })
        case .string(let string):
            return .string(redactText(string))
        case .number, .bool, .null:
            return value
        }
    }

    static func redactText(_ value: String, maximumLength: Int = 20_000) -> String {
        var result = value
        for pattern in textPatterns.reversed() {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: "[REDACTED]"
            )
        }
        guard result.count > maximumLength else { return result }
        return String(result.prefix(maximumLength)) + "…[truncated]"
    }

    static func safeIdentifier(_ value: String, maximumLength: Int) -> String? {
        guard value.count <= maximumLength,
              value.rangeOfCharacter(from: .controlCharacters) == nil,
              redactText(value, maximumLength: maximumLength) == value
        else { return nil }
        return value
    }

    static func isSensitiveField(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["privatekey", "secret", "token", "authorization", "credential", "jwt", "bearer"]
            .contains(where: normalized.contains) {
            return true
        }

        for suffix in ["key", "keyid", "keyname"] where normalized.hasSuffix(suffix) {
            let rawSuffix = String(key.suffix(suffix.count))
            guard rawSuffix.lowercased() == suffix else { continue }
            if rawSuffix.first?.isUppercase == true || key.count == suffix.count {
                return true
            }
            let prefix = key.dropLast(suffix.count)
            if prefix.last.map({ !$0.isLetter && !$0.isNumber }) == true {
                return true
            }
        }
        return false
    }
}
