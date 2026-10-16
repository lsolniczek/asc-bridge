import Foundation
import Security

/// Stores the App Store Connect team key in the user's macOS Keychain.
/// The protected ACL trusts only the calling app for sensitive item access.
public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    private let backend: any KeychainItemBackend

    public init(service: String = "com.ascbridge.credentials") {
        self.service = service
        self.backend = SystemKeychainItemBackend()
    }

    init(service: String, backend: any KeychainItemBackend) {
        self.service = service
        self.backend = backend
    }

    public func load() async throws -> TeamCredentials? {
        guard let data = try await backend.read(service: service, account: "team-credentials") else {
            return nil
        }
        do {
            return try JSONDecoder().decode(TeamCredentials.self, from: data)
        } catch {
            throw BridgeError.transport("The saved App Store Connect credentials could not be read. Reimport the team key.")
        }
    }

    public func save(_ credentials: TeamCredentials) async throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw BridgeError.transport("The App Store Connect credentials could not be saved.")
        }
        try await backend.write(data, service: service, account: "team-credentials")
    }

    public func delete() async throws {
        try await backend.delete(service: service, account: "team-credentials")
    }
}

/// A separate random bearer token used only to authenticate local MCP clients.
public actor KeychainMCPTokenStore: MCPTokenStore {
    private let service: String
    private let backend: any KeychainItemBackend

    public init(service: String = "com.ascbridge.mcp-token") {
        self.service = service
        self.backend = SystemKeychainItemBackend()
    }

    init(service: String, backend: any KeychainItemBackend) {
        self.service = service
        self.backend = backend
    }

    public func loadOrCreate() async throws -> String {
        if let data = try await backend.read(service: service, account: "mcp-token"),
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw BridgeError.keychain(status) }
        let token = Data(bytes).base64URLString
        try await backend.write(Data(token.utf8), service: service, account: "mcp-token")
        return token
    }
}

protocol KeychainItemBackend: Sendable {
    func read(service: String, account: String) async throws -> Data?
    func write(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
}

private struct SystemKeychainItemBackend: KeychainItemBackend {
    func read(service: String, account: String) async throws -> Data? {
        var query = itemQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BridgeError.keychain(status) }
        guard let data = result as? Data else { throw BridgeError.keychain(errSecDecode) }
        return data
    }

    func write(_ data: Data, service: String, account: String) async throws {
        let access = try appRestrictedAccess(account: account)
        let query = itemQuery(service: service, account: account)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccess as String: access,
        ]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccess as String] = access
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BridgeError.keychain(status) }
    }

    func delete(service: String, account: String) async throws {
        let status = SecItemDelete(itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BridgeError.keychain(status)
        }
    }

    private func appRestrictedAccess(account: String) throws -> SecAccess {
        var access: SecAccess?
        // A nil trusted application list means only the calling application is
        // trusted for restricted operations such as reading this generic password.
        let status = SecAccessCreate("ASC Bridge \(account)" as CFString, nil, &access)
        guard status == errSecSuccess, let access else { throw BridgeError.keychain(status) }
        return access
    }

    private func itemQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The app-restricted SecAccess ACL applies to the legacy macOS
            // keychain; keep these secrets local and out of iCloud sync.
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

extension Data {
    fileprivate var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
