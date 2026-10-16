import CryptoKit
import Foundation

public actor ASCClient: ASCServing {
    private let credentials: any CredentialStore
    private let transport: any ASCHTTPTransport
    private let now: @Sendable () -> Date

    public init(credentials: any CredentialStore) {
        self.credentials = credentials
        self.transport = URLSessionHTTPTransport()
        self.now = { Date() }
    }

    init(
        credentials: any CredentialStore,
        transport: any ASCHTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public static func validate(_ credentials: TeamCredentials) throws {
        guard credentials.keyID.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil else {
            throw BridgeError.invalidInput("Key ID musi zawierać 10 znaków alfanumerycznych.")
        }
        guard UUID(uuidString: credentials.issuerID) != nil,
              credentials.issuerID.range(of: "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil else {
            throw BridgeError.invalidInput("Issuer ID musi być poprawnym identyfikatorem UUID.")
        }
        do {
            _ = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
        } catch {
            throw BridgeError.invalidInput("Plik klucza musi zawierać prawidłowy prywatny klucz P-256 w formacie PEM.")
        }
    }

    public func call(_ operation: ASCOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        let plan = try RequestPlan.make(operation: operation, arguments: arguments)
        guard let credentials = try await credentials.load() else { throw BridgeError.credentialsMissing }
        try Self.validate(credentials)

        let jwt = try Self.makeJWT(credentials: credentials, now: now())
        let url = try Self.url(path: plan.path, query: plan.query)
        var headers = ["Accept": "application/json", "Authorization": "Bearer \(jwt)"]
        var body: Data?
        if let json = plan.body {
            headers["Content-Type"] = "application/json"
            body = try JSONEncoder().encode(json)
        }
        let request = ASCHTTPRequest(method: plan.method, url: url, headers: headers, body: body)

        let response: ASCHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw BridgeError.transport(Self.sanitized(error.localizedDescription, limit: 300))
        }

        if (300..<400).contains(response.statusCode) {
            throw BridgeError.transport("App Store Connect redirected the request. Redirects are blocked for security.")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw BridgeError.apple(status: response.statusCode, message: Self.appleErrorMessage(response.data))
        }

        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: response.data)
        } catch {
            throw BridgeError.transport("App Store Connect returned an unreadable response.")
        }
        guard case .object(let object) = decoded, let data = object["data"] else {
            throw BridgeError.transport("App Store Connect returned a response without resource data.")
        }

        return .object([
            "data": Self.removingLinks(from: data),
            "nextCursor": Self.safeNextCursor(from: object["links"], expectedPath: plan.path),
        ])
    }

    private static func makeJWT(credentials: TeamCredentials, now: Date) throws -> String {
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKeyPEM)
        } catch {
            throw BridgeError.invalidInput("The saved App Store Connect private key is invalid.")
        }
        let issuedAt = Int64(now.timeIntervalSince1970.rounded(.down))
        let header = JWTHeader(alg: "ES256", kid: credentials.keyID, typ: "JWT")
        let claims = JWTClaims(iss: credentials.issuerID, iat: issuedAt, exp: issuedAt + 600, aud: "appstoreconnect-v1")
        let unsigned = "\(try Self.base64URL(JSONEncoder().encode(header))).\(try Self.base64URL(JSONEncoder().encode(claims)))"
        do {
            let signature = try key.signature(for: Data(unsigned.utf8))
            // CryptoKit's P256 ECDSA raw representation is the ES256 R || S form.
            return "\(unsigned).\(signature.rawRepresentation.base64URLString)"
        } catch {
            throw BridgeError.transport("The App Store Connect request could not be signed.")
        }
    }

    private static func base64URL(_ data: Data) -> String { data.base64URLString }

    private static func url(path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(string: "https://api.appstoreconnect.apple.com\(path)") else {
            throw BridgeError.transport("The App Store Connect request URL could not be created.")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url,
              url.scheme == "https",
              url.host == "api.appstoreconnect.apple.com",
              url.user == nil, url.password == nil else {
            throw BridgeError.transport("The App Store Connect request URL is invalid.")
        }
        return url
    }

    private static func safeNextCursor(from linksValue: JSONValue?, expectedPath: String) -> JSONValue {
        guard let links = linksValue?.objectValue,
              let next = links["next"]?.stringValue,
              let components = URLComponents(string: next),
              components.scheme == "https",
              components.host == "api.appstoreconnect.apple.com",
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              components.path == expectedPath,
              let cursor = components.queryItems?.first(where: { $0.name == "cursor" })?.value,
              Self.isSafeCursor(cursor) else {
            return .null
        }
        return .string(cursor)
    }

    private static func isSafeCursor(_ cursor: String) -> Bool {
        cursor.utf8.count <= 2_048 && !cursor.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func removingLinks(from value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, entry in
                guard entry.key != "links" else { return }
                result[entry.key] = removingLinks(from: entry.value)
            })
        case .array(let array):
            return .array(array.map(removingLinks(from:)))
        default:
            return value
        }
    }

    private static func appleErrorMessage(_ data: Data) -> String {
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        let errors: [JSONValue]
        if case .object(let root)? = decoded, case .array(let values)? = root["errors"] {
            errors = values
        } else {
            errors = []
        }
        guard let first = errors.first?.objectValue else {
            return "Apple could not process the request."
        }
        let code = first["code"]?.stringValue.map { sanitized($0, limit: 80) }
        let title = first["title"]?.stringValue.map { sanitized($0, limit: 180) }
        let detail = first["detail"]?.stringValue.map { sanitized($0, limit: 400) }
        var pieces: [String] = []
        if let title, !title.isEmpty { pieces.append(title) }
        if let detail, !detail.isEmpty, detail != title { pieces.append(detail) }
        if pieces.isEmpty, let code, !code.isEmpty { pieces.append("Apple error code \(code)") }
        if pieces.isEmpty { return "Apple could not process the request." }
        return String(pieces.joined(separator: ": ").prefix(500))
    }

    private static func sanitized(_ value: String, limit: Int) -> String {
        var result = value
        result = result.replacingOccurrences(
            of: "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
            with: "[REDACTED PRIVATE KEY]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)bearer\\s+[^\\s,;]+",
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])",
            with: "[REDACTED TOKEN]",
            options: .regularExpression
        )
        result = result.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" ? " " : String($0) }.joined()
        return String(result.prefix(limit))
    }
}

private struct JWTHeader: Encodable {
    let alg: String
    let kid: String
    let typ: String
}

private struct JWTClaims: Encodable {
    let iss: String
    let iat: Int64
    let exp: Int64
    let aud: String
}

private struct RequestPlan {
    let method: String
    let path: String
    let query: [(String, String)]
    let body: JSONValue?

    static func make(operation: ASCOperation, arguments: [String: JSONValue]) throws -> RequestPlan {
        switch operation {
        case .listApps:
            try allow(arguments, keys: ["limit", "cursor"])
            return RequestPlan(method: "GET", path: "/v1/apps", query: try pagination(arguments), body: nil)

        case .listVersions:
            try allow(arguments, keys: ["appId", "platform", "limit", "cursor"])
            let appID = try identifier(arguments, "appId")
            var query = try pagination(arguments)
            if let platform = try optionalString(arguments, "platform") {
                query.append(("filter[platform]", try platformValue(platform)))
            }
            return RequestPlan(method: "GET", path: "/v1/apps/\(appID)/appStoreVersions", query: query, body: nil)

        case .listLocalizations:
            try allow(arguments, keys: ["versionId", "limit", "cursor"])
            let versionID = try identifier(arguments, "versionId")
            return RequestPlan(method: "GET", path: "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", query: try pagination(arguments), body: nil)

        case .createVersion:
            try allow(arguments, keys: ["appId", "platform", "versionString"])
            let appID = try identifier(arguments, "appId")
            let platform = try platformValue(requiredString(arguments, "platform"))
            let version = try requiredString(arguments, "versionString")
            guard !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  version.count <= 18,
                  !version.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw BridgeError.invalidInput("versionString must be 1 to 18 visible characters.")
            }
            let body: JSONValue = .object(["data": .object([
                "type": .string("appStoreVersions"),
                "attributes": .object([
                    "platform": .string(platform),
                    "versionString": .string(version),
                    "releaseType": .string("MANUAL"),
                ]),
                "relationships": .object(["app": .object(["data": .object([
                    "type": .string("apps"), "id": .string(appID),
                ])])]),
            ])])
            return RequestPlan(method: "POST", path: "/v1/appStoreVersions", query: [], body: body)

        case .createLocalization:
            try allow(arguments, keys: ["versionId", "locale", "description", "whatsNew", "promotionalText"])
            let versionID = try identifier(arguments, "versionId")
            let locale = try localeValue(requiredString(arguments, "locale"))
            let attributes = try localizationAttributes(arguments, includeLocale: locale)
            let body: JSONValue = .object(["data": .object([
                "type": .string("appStoreVersionLocalizations"),
                "attributes": .object(attributes),
                "relationships": .object(["appStoreVersion": .object(["data": .object([
                    "type": .string("appStoreVersions"), "id": .string(versionID),
                ])])]),
            ])])
            return RequestPlan(method: "POST", path: "/v1/appStoreVersionLocalizations", query: [], body: body)

        case .updateLocalization:
            try allow(arguments, keys: ["localizationId", "description", "whatsNew", "promotionalText"])
            let localizationID = try identifier(arguments, "localizationId")
            let attributes = try localizationAttributes(arguments, includeLocale: nil)
            guard !attributes.isEmpty else {
                throw BridgeError.invalidInput("Provide at least one of description, whatsNew, or promotionalText.")
            }
            let body: JSONValue = .object(["data": .object([
                "type": .string("appStoreVersionLocalizations"),
                "id": .string(localizationID),
                "attributes": .object(attributes),
            ])])
            return RequestPlan(method: "PATCH", path: "/v1/appStoreVersionLocalizations/\(localizationID)", query: [], body: body)
        }
    }

    private static func allow(_ arguments: [String: JSONValue], keys: Set<String>) throws {
        if arguments.keys.contains(where: { !keys.contains($0) }) {
            throw BridgeError.invalidInput("The request contains an unknown argument.")
        }
    }

    private static func requiredString(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        guard let value = arguments[key]?.stringValue else {
            throw BridgeError.invalidInput("\(key) must be a string.")
        }
        return value
    }

    private static func optionalString(_ arguments: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value.stringValue else { throw BridgeError.invalidInput("\(key) must be a string.") }
        return string
    }

    private static func identifier(_ arguments: [String: JSONValue], _ key: String) throws -> String {
        let value = try requiredString(arguments, key)
        guard value.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw BridgeError.invalidInput("\(key) must be a safe App Store Connect resource ID.")
        }
        return value
    }

    private static func pagination(_ arguments: [String: JSONValue]) throws -> [(String, String)] {
        var query: [(String, String)] = []
        if let value = arguments["limit"] {
            guard let limit = value.intValue, (1...200).contains(limit) else {
                throw BridgeError.invalidInput("limit must be an integer from 1 to 200.")
            }
            query.append(("limit", String(limit)))
        } else {
            query.append(("limit", "50"))
        }
        if let cursor = try optionalString(arguments, "cursor") {
            guard isSafeCursor(cursor) else { throw BridgeError.invalidInput("cursor must be at most 2048 characters and contain no control characters.") }
            query.append(("cursor", cursor))
        }
        return query
    }

    private static func isSafeCursor(_ cursor: String) -> Bool {
        cursor.utf8.count <= 2_048 && !cursor.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func platformValue(_ value: String) throws -> String {
        let allowed = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"]
        guard allowed.contains(value) else {
            throw BridgeError.invalidInput("platform must be IOS, MAC_OS, TV_OS, or VISION_OS.")
        }
        return value
    }

    private static func localeValue(_ value: String) throws -> String {
        guard value.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            throw BridgeError.invalidInput("locale must be an App Store Connect locale code such as en-US or zh-Hans.")
        }
        return value
    }

    private static func localizationAttributes(
        _ arguments: [String: JSONValue],
        includeLocale locale: String?
    ) throws -> [String: JSONValue] {
        var attributes: [String: JSONValue] = [:]
        if let locale { attributes["locale"] = .string(locale) }
        let bounds = ["description": 4_000, "whatsNew": 4_000, "promotionalText": 170]
        for (key, maximum) in bounds {
            if let value = try optionalString(arguments, key) {
                guard value.count <= maximum else {
                    throw BridgeError.invalidInput("\(key) must be at most \(maximum) characters.")
                }
                guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
                    throw BridgeError.invalidInput("\(key) contains unsupported control characters.")
                }
                attributes[key] = .string(value)
            }
        }
        return attributes
    }
}

struct ASCHTTPRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
}

struct ASCHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

protocol ASCHTTPTransport: Sendable {
    func send(_ request: ASCHTTPRequest) async throws -> ASCHTTPResponse
}

private actor URLSessionHTTPTransport: ASCHTTPTransport {
    private let session: URLSession
    private let redirectDelegate: NoRedirectDelegate

    init() {
        let delegate = NoRedirectDelegate()
        self.redirectDelegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func send(_ request: ASCHTTPRequest) async throws -> ASCHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeError.transport("App Store Connect returned an invalid HTTP response.")
        }
        return ASCHTTPResponse(statusCode: http.statusCode, data: data)
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
