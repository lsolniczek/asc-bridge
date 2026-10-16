import Foundation
import Testing
@testable import BridgeCore

@Test func jsonRoundTrip() throws {
    let value: JSONValue = .object(["text": .string("Zażółć gęślą"), "count": .number(2), "ok": .bool(true)])
    #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
}

@Test func credentialsDescriptionIsRedacted() {
    let credentials = TeamCredentials(keyID: "fake", issuerID: "fake", privateKeyPEM: "secret-fixture")
    #expect(!String(describing: credentials).contains("secret-fixture"))
    #expect(!String(reflecting: credentials).contains("secret-fixture"))
}
