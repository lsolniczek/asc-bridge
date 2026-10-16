import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite,
              value.rounded() == value, value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }

    public func encodedString(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct TeamCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let keyID: String
    public let issuerID: String
    public let privateKeyPEM: String
    public init(keyID: String, issuerID: String, privateKeyPEM: String) {
        self.keyID = keyID; self.issuerID = issuerID; self.privateKeyPEM = privateKeyPEM
    }
    public var description: String { "TeamCredentials([REDACTED])" }
    public var debugDescription: String { description }
}

public protocol CredentialStore: Sendable {
    func load() async throws -> TeamCredentials?
    func save(_ credentials: TeamCredentials) async throws
    func delete() async throws
}

public protocol MCPTokenStore: Sendable {
    func loadOrCreate() async throws -> String
}

public enum ASCOperation: String, CaseIterable, Sendable {
    case listApps = "asc_list_apps"
    case listVersions = "asc_list_versions"
    case listLocalizations = "asc_list_localizations"
    case createVersion = "asc_create_version"
    case createLocalization = "asc_create_localization"
    case updateLocalization = "asc_update_localization"

    public var isMutation: Bool {
        switch self {
        case .createVersion, .createLocalization, .updateLocalization: true
        default: false
        }
    }
}

public protocol ASCServing: Sendable {
    func call(_ operation: ASCOperation, arguments: [String: JSONValue]) async throws -> JSONValue
}

public enum BridgeError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case credentialsMissing
    case keychain(Int32)
    case apple(status: Int, message: String)
    case transport(String)
    case auditUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .credentialsMissing: "Najpierw dodaj klucz App Store Connect w aplikacji ASC Bridge."
        case .keychain(let status): "Nie udało się uzyskać dostępu do Keychain (\(status))."
        case .apple(let status, let message): "App Store Connect (HTTP \(status)): \(message)"
        case .transport(let message): message
        case .auditUnavailable: "Nie można zapisać historii MCP. Operacja nie została rozpoczęta."
        }
    }
}
