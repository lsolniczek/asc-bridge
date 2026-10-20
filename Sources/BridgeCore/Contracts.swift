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
    case getApp = "asc_get_app"
    case getVersion = "asc_get_version"
    case listAppInfos = "asc_list_app_infos"
    case listAppInfoLocalizations = "asc_list_app_info_localizations"
    case createAppInfoLocalization = "asc_create_app_info_localization"
    case updateAppInfoLocalization = "asc_update_app_info_localization"
    case listBuilds = "asc_list_builds"
    case getBuild = "asc_get_build"
    case getVersionBuild = "asc_get_version_build"
    case setVersionBuild = "asc_set_version_build"
    case listBetaGroups = "asc_list_beta_groups"
    case listBetaBuildLocalizations = "asc_list_beta_build_localizations"
    case createBetaBuildLocalization = "asc_create_beta_build_localization"
    case updateBetaBuildLocalization = "asc_update_beta_build_localization"
    case listCustomerReviews = "asc_list_customer_reviews"
    case getCustomerReviewResponse = "asc_get_customer_review_response"
    case upsertCustomerReviewResponse = "asc_upsert_customer_review_response"

    public var isMutation: Bool {
        switch self {
        case .createVersion, .createLocalization, .updateLocalization,
             .createAppInfoLocalization, .updateAppInfoLocalization, .setVersionBuild,
             .createBetaBuildLocalization, .updateBetaBuildLocalization,
             .upsertCustomerReviewResponse: true
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
        case .credentialsMissing:
            String(localized: "Add your App Store Connect API key in ASC Bridge first.", bundle: .module, comment: "Shown when a request needs App Store Connect credentials that have not been added yet.")
        case .keychain(let status):
            String(localized: "Keychain access failed (\(status, format: .number.grouping(.never))).", bundle: .module, comment: "Shown when macOS Keychain access fails. Keep the interpolated OSStatus code unchanged and ungrouped.")
        case .apple(let status, let message):
            String(localized: "App Store Connect (HTTP \(status, format: .number.grouping(.never))): \(message)", bundle: .module, comment: "Prefix for an App Store Connect HTTP error. Keep the HTTP status ungrouped and the supplied Apple error text unchanged.")
        case .transport(let message): message
        case .auditUnavailable:
            String(localized: "The MCP request could not be recorded. The operation was not started.", bundle: .module, comment: "Shown when audit history cannot be saved before an MCP operation begins.")
        }
    }
}
