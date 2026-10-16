import CryptoKit
import Foundation
import Testing
@testable import BridgeCore

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

@Test func validatesTeamCredentialsWithoutExposingKeyMaterial() throws {
    let key = P256.Signing.PrivateKey()
    let valid = TeamCredentials(keyID: "ABCDEF1234", issuerID: "57246542-96fe-1a63-e053-0824d011072a", privateKeyPEM: key.pemRepresentation)
    try ASCClient.validate(valid)

    #expect(throws: BridgeError.self) {
        try ASCClient.validate(TeamCredentials(keyID: "short", issuerID: valid.issuerID, privateKeyPEM: key.pemRepresentation))
    }
    #expect(throws: BridgeError.self) {
        try ASCClient.validate(TeamCredentials(keyID: valid.keyID, issuerID: "not-an-issuer", privateKeyPEM: key.pemRepresentation))
    }
    #expect(throws: BridgeError.self) {
        try ASCClient.validate(TeamCredentials(keyID: valid.keyID, issuerID: valid.issuerID, privateKeyPEM: "private-key-fixture"))
    }
    #expect(!String(describing: valid).contains(key.pemRepresentation))
    #expect(!String(reflecting: valid).contains(key.pemRepresentation))
}

@Test func signsARealES256JWTForAppleRequestAndKeepsItOutOfTheResult() async throws {
    let privateKey = P256.Signing.PrivateKey()
    let credentials = makeCredentials(privateKey: privateKey)
    let fixture = try jsonData(["data": [["type": "apps", "id": "123", "attributes": ["name": "Demo"]]]])
    let transport = StubTransport(responses: [ASCHTTPResponse(statusCode: 200, data: fixture)])
    let client = ASCClient(credentials: FixedCredentialStore(credentials), transport: transport, now: { fixedNow })

    let result = try await client.call(.listApps, arguments: [:])
    let request = try #require(await transport.requests.first)
    let authorization = try #require(request.headers["Authorization"])
    #expect(authorization.hasPrefix("Bearer "))
    let token = String(authorization.dropFirst("Bearer ".count))
    let parts = token.split(separator: ".")
    #expect(parts.count == 3)
    let header = try decodeJWTPart(parts[0])
    let claims = try decodeJWTPart(parts[1])
    #expect(header["alg"] as? String == "ES256")
    #expect(header["kid"] as? String == credentials.keyID)
    #expect(header["typ"] as? String == "JWT")
    #expect(claims["iss"] as? String == credentials.issuerID)
    #expect(claims["aud"] as? String == "appstoreconnect-v1")
    #expect(claims["iat"] as? Int == 1_700_000_000)
    #expect(claims["exp"] as? Int == 1_700_000_600)

    let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
    let signatureBytes = try #require(Data(base64URL: String(parts[2])))
    #expect(signatureBytes.count == 64)
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
    #expect(privateKey.publicKey.isValidSignature(signature, for: signingInput))

    let encodedResult = try result.encodedString()
    #expect(!encodedResult.contains(token))
    #expect(!encodedResult.contains("Authorization"))
    #expect(request.url.host == "api.appstoreconnect.apple.com")
    #expect(request.url.scheme == "https")
}

@Test func implementsAllSixTypedAppleOperations() async throws {
    let privateKey = P256.Signing.PrivateKey()
    let responseData = try jsonData(["data": ["type": "resource", "id": "result-id", "attributes": [:]]])
    let transport = StubTransport(responses: (0..<6).map { _ in ASCHTTPResponse(statusCode: 201, data: responseData) })
    let client = ASCClient(credentials: FixedCredentialStore(makeCredentials(privateKey: privateKey)), transport: transport, now: { fixedNow })

    _ = try await client.call(.listApps, arguments: ["limit": .number(13), "cursor": .string("a/b+c")])
    _ = try await client.call(.listVersions, arguments: ["appId": .string("12345"), "platform": .string("IOS"), "limit": .number(4)])
    _ = try await client.call(.listLocalizations, arguments: ["versionId": .string("version-1")])
    _ = try await client.call(.createVersion, arguments: ["appId": .string("12345"), "platform": .string("MAC_OS"), "versionString": .string("2.1")])
    _ = try await client.call(.createLocalization, arguments: ["versionId": .string("version-1"), "locale": .string("en-US"), "description": .string("Description"), "whatsNew": .string("")])
    _ = try await client.call(.updateLocalization, arguments: ["localizationId": .string("localization-1"), "promotionalText": .string("")])

    let requests = await transport.requests
    #expect(requests.count == 6)
    #expect(requests[0].method == "GET")
    #expect(requests[0].url.path == "/v1/apps")
    let firstQuery = try #require(URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(firstQuery.first(where: { $0.name == "limit" })?.value == "13")
    #expect(firstQuery.first(where: { $0.name == "cursor" })?.value == "a/b+c")

    #expect(requests[1].method == "GET")
    #expect(requests[1].url.path == "/v1/apps/12345/appStoreVersions")
    let versionsQuery = try #require(URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(versionsQuery.first(where: { $0.name == "filter[platform]" })?.value == "IOS")

    #expect(requests[2].method == "GET")
    #expect(requests[2].url.path == "/v1/appStoreVersions/version-1/appStoreVersionLocalizations")

    #expect(requests[3].method == "POST")
    #expect(requests[3].url.path == "/v1/appStoreVersions")
    let versionBody = try bodyObject(requests[3])
    let versionData = try #require(versionBody["data"] as? [String: Any])
    let versionAttributes = try #require(versionData["attributes"] as? [String: Any])
    let versionRelationships = try #require(versionData["relationships"] as? [String: Any])
    #expect(versionData["type"] as? String == "appStoreVersions")
    #expect(versionAttributes["platform"] as? String == "MAC_OS")
    #expect(versionAttributes["versionString"] as? String == "2.1")
    #expect(versionAttributes["releaseType"] as? String == "MANUAL")
    #expect(((versionRelationships["app"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String == "12345")

    #expect(requests[4].method == "POST")
    #expect(requests[4].url.path == "/v1/appStoreVersionLocalizations")
    let createLocalization = try bodyObject(requests[4])
    let localizationData = try #require(createLocalization["data"] as? [String: Any])
    let localizationAttributes = try #require(localizationData["attributes"] as? [String: Any])
    #expect(localizationData["type"] as? String == "appStoreVersionLocalizations")
    #expect(localizationAttributes["locale"] as? String == "en-US")
    #expect(localizationAttributes["description"] as? String == "Description")
    #expect(localizationAttributes["whatsNew"] as? String == "")
    let createRelationships = try #require(localizationData["relationships"] as? [String: Any])
    let versionRelationship = try #require(createRelationships["appStoreVersion"] as? [String: Any])
    let versionRelationshipData = try #require(versionRelationship["data"] as? [String: Any])
    #expect(versionRelationshipData["type"] as? String == "appStoreVersions")
    #expect(versionRelationshipData["id"] as? String == "version-1")

    #expect(requests[5].method == "PATCH")
    #expect(requests[5].url.path == "/v1/appStoreVersionLocalizations/localization-1")
    let updateLocalization = try bodyObject(requests[5])
    let updateData = try #require(updateLocalization["data"] as? [String: Any])
    let updateAttributes = try #require(updateData["attributes"] as? [String: Any])
    #expect(updateData["id"] as? String == "localization-1")
    #expect(updateAttributes["promotionalText"] as? String == "")
    #expect(updateAttributes["locale"] == nil)
}

@Test func rejectsUnknownArgumentsWrongTypesUnsafeIDsAndOversizedText() async throws {
    let client = ASCClient(credentials: EmptyCredentialStore(), transport: StubTransport(responses: []), now: { fixedNow })
    let cases: [(ASCOperation, [String: JSONValue])] = [
        (.listApps, ["unexpected": .string("x")]),
        (.listApps, ["limit": .string("10")]),
        (.listVersions, ["appId": .string("../123")]),
        (.listVersions, ["appId": .string("123"), "platform": .string("ios")]),
        (.createVersion, ["appId": .string("123"), "platform": .string("IOS"), "versionString": .string("1.0"), "extra": .bool(true)]),
        (.createLocalization, ["versionId": .string("v1"), "locale": .number(1)]),
        (.createLocalization, ["versionId": .string("v1"), "locale": .string("en"), "promotionalText": .string(String(repeating: "x", count: 171))]),
        (.createLocalization, ["versionId": .string("v1"), "locale": .string("en"), "description": .string(String(repeating: "x", count: 4_001))]),
        (.updateLocalization, ["localizationId": .string("l1"), "whatsNew": .string(String(repeating: "x", count: 4_001))]),
        (.updateLocalization, ["localizationId": .string("l1")]),
        (.updateLocalization, ["localizationId": .string("l1"), "whatsNew": .number(4)]),
    ]
    for (operation, arguments) in cases {
        do {
            _ = try await client.call(operation, arguments: arguments)
            Issue.record("Expected invalidInput for \(operation.rawValue)")
        } catch BridgeError.invalidInput {
            // The validation layer must reject each input before credentials are loaded.
        } catch {
            Issue.record("Expected invalidInput for \(operation.rawValue)")
        }
    }

    do {
        _ = try await client.call(.listApps, arguments: [:])
        Issue.record("Expected credentialsMissing for a valid request")
    } catch BridgeError.credentialsMissing {
        // A valid request proceeds to credential lookup.
    } catch {
        Issue.record("Expected credentialsMissing for a valid request")
    }
}

@Test func returnsOnlySafePaginationCursorAndStripsAppleLinks() async throws {
    let privateKey = P256.Signing.PrivateKey()
    let fixture = try jsonData([
        "data": [[
            "type": "apps", "id": "1",
            "attributes": ["name": "Demo"],
            "relationships": ["versions": ["links": ["related": "https://evil.example/steal"]]],
            "links": ["self": "https://evil.example/steal"],
        ]],
        "links": ["next": "https://api.appstoreconnect.apple.com/v1/apps?limit=50&cursor=opaque%2Fcursor%2Bvalue&extra=hidden"],
    ])
    let transport = StubTransport(responses: [ASCHTTPResponse(statusCode: 200, data: fixture)])
    let client = ASCClient(credentials: FixedCredentialStore(makeCredentials(privateKey: privateKey)), transport: transport, now: { fixedNow })

    let result = try await client.call(.listApps, arguments: [:])
    let object = try #require(result.objectValue)
    #expect(object["nextCursor"] == .string("opaque/cursor+value"))
    let encoded = try result.encodedString()
    #expect(!encoded.contains("evil.example"))
    #expect(!encoded.contains("extra=hidden"))
}

@Test func ignoresNextLinksOutsideTheFixedAppleEndpoint() async throws {
    let privateKey = P256.Signing.PrivateKey()
    let fixture = try jsonData(["data": [], "links": ["next": "https://evil.example/v1/apps?cursor=secret"]])
    let transport = StubTransport(responses: [ASCHTTPResponse(statusCode: 200, data: fixture)])
    let client = ASCClient(credentials: FixedCredentialStore(makeCredentials(privateKey: privateKey)), transport: transport, now: { fixedNow })
    let result = try await client.call(.listApps, arguments: [:])
    #expect(result.objectValue?["nextCursor"] == .null)
}

@Test func sanitizesAppleErrorsAndDoesNotRetryMutationsOrFollowRedirects() async throws {
    let privateKey = P256.Signing.PrivateKey()
    let credentials = makeCredentials(privateKey: privateKey)
    let secretLikeValue = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ0ZXN0In0.abcdefghijklmnopqrstuvwxyz0123456789"
    let errorFixture = try jsonData(["errors": [[
        "code": "ENTITY_ERROR.ATTRIBUTE.INVALID", "title": "Editable state required",
        "detail": "Bearer local-secret \(secretLikeValue) -----BEGIN EC PRIVATE KEY-----hidden-----END EC PRIVATE KEY-----",
    ]]])
    let failedMutationTransport = StubTransport(responses: [ASCHTTPResponse(statusCode: 422, data: errorFixture)])
    let failedMutationClient = ASCClient(credentials: FixedCredentialStore(credentials), transport: failedMutationTransport, now: { fixedNow })

    do {
        _ = try await failedMutationClient.call(.createVersion, arguments: ["appId": .string("123"), "platform": .string("IOS"), "versionString": .string("1.0")])
        Issue.record("Expected Apple validation error")
    } catch {
        let message = error.localizedDescription
        #expect(message.contains("Editable state required"))
        #expect(!message.contains("local-secret"))
        #expect(!message.contains(secretLikeValue))
        #expect(!message.contains("hidden"))
    }
    #expect(await failedMutationTransport.sendCount == 1)

    let redirectTransport = StubTransport(responses: [ASCHTTPResponse(statusCode: 307, data: Data())])
    let redirectClient = ASCClient(credentials: FixedCredentialStore(credentials), transport: redirectTransport, now: { fixedNow })
    do {
        _ = try await redirectClient.call(.listApps, arguments: [:])
        Issue.record("Expected redirect rejection")
    } catch {
        #expect(error.localizedDescription.contains("Redirects are blocked"))
    }
    #expect(await redirectTransport.sendCount == 1)
}

@Test func keychainStoresUseInjectedBackendWithoutTouchingUserKeychain() async throws {
    let backend = MemoryKeychainBackend()
    let credentialsStore = KeychainCredentialStore(service: "test.credentials", backend: backend)
    let key = P256.Signing.PrivateKey()
    let credentials = makeCredentials(privateKey: key)
    #expect(try await credentialsStore.load() == nil)
    try await credentialsStore.save(credentials)
    #expect(try await credentialsStore.load()?.keyID == credentials.keyID)
    try await credentialsStore.delete()
    #expect(try await credentialsStore.load() == nil)

    let tokenStore = KeychainMCPTokenStore(service: "test.token", backend: backend)
    let token = try await tokenStore.loadOrCreate()
    #expect(token.utf8.count >= 43)
    #expect(token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
    #expect(try await tokenStore.loadOrCreate() == token)
}

private func makeCredentials(privateKey: P256.Signing.PrivateKey) -> TeamCredentials {
    TeamCredentials(keyID: "ABCDEF1234", issuerID: "57246542-96fe-1a63-e053-0824d011072a", privateKeyPEM: privateKey.pemRepresentation)
}

private func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }

private func bodyObject(_ request: ASCHTTPRequest) throws -> [String: Any] {
    try #require(request.body).withUnsafeBytes { bytes in
        let data = Data(bytes)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private func decodeJWTPart(_ part: Substring) throws -> [String: Any] {
    let data = try #require(Data(base64URL: String(part)))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private struct FixedCredentialStore: CredentialStore {
    let value: TeamCredentials
    init(_ value: TeamCredentials) { self.value = value }
    func load() async throws -> TeamCredentials? { value }
    func save(_ credentials: TeamCredentials) async throws {}
    func delete() async throws {}
}

private struct EmptyCredentialStore: CredentialStore {
    func load() async throws -> TeamCredentials? { nil }
    func save(_ credentials: TeamCredentials) async throws {}
    func delete() async throws {}
}

private actor StubTransport: ASCHTTPTransport {
    private(set) var requests: [ASCHTTPRequest] = []
    private var responses: [ASCHTTPResponse]
    private(set) var sendCount = 0

    init(responses: [ASCHTTPResponse]) { self.responses = responses }

    func send(_ request: ASCHTTPRequest) async throws -> ASCHTTPResponse {
        requests.append(request)
        sendCount += 1
        guard !responses.isEmpty else { throw BridgeError.transport("No fixture response") }
        return responses.removeFirst()
    }
}

private actor MemoryKeychainBackend: KeychainItemBackend {
    private struct Key: Hashable, Sendable {
        let service: String
        let account: String
    }
    private var values: [Key: Data] = [:]

    func read(service: String, account: String) async throws -> Data? {
        values[Key(service: service, account: account)]
    }
    func write(_ data: Data, service: String, account: String) async throws {
        values[Key(service: service, account: account)] = data
    }
    func delete(service: String, account: String) async throws {
        values.removeValue(forKey: Key(service: service, account: account))
    }
}

private extension Data {
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 { value += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: value)
    }
}
