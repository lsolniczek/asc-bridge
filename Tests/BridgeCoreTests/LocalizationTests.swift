import Foundation
import Testing
@testable import BridgeCore

@Test func bridgeErrorsUseEnglishCatalogEntries() {
    #expect(Bundle.module.developmentLocalization == "en")
    #expect(Bundle.module.url(forResource: "Localizable", withExtension: "strings") != nil)
    #expect(Bundle.module.localizedString(forKey: "Keychain access failed (%@).", value: "missing", table: "Localizable") == "Keychain access failed (%@).")
    #expect(Bundle.module.localizedString(forKey: "App Store Connect (HTTP %@): %@", value: "missing", table: "Localizable") == "App Store Connect (HTTP %@): %@")
    #expect(Bundle.module.localizedString(forKey: "Apple error code %@", value: "missing", table: "Localizable") == "Apple error code %@")

    #expect(BridgeError.credentialsMissing.errorDescription == "Add your App Store Connect API key in ASC Bridge first.")
    #expect(BridgeError.keychain(-25293).errorDescription == "Keychain access failed (-25293).")
    #expect(BridgeError.apple(status: 422, message: "Invalid locale").errorDescription == "App Store Connect (HTTP 422): Invalid locale")
    #expect(BridgeError.auditUnavailable.errorDescription == "The MCP request could not be recorded. The operation was not started.")
    #expect(BridgeError.invalidInput("raw argument text").errorDescription == "raw argument text")
    #expect(BridgeError.transport("system error text").errorDescription == "system error text")
}

@Test func credentialAndInputValidationErrorsUseEnglishCatalogEntries() async {
    #expect(credentialValidationMessage(TeamCredentials(
        keyID: "short",
        issuerID: "57246542-96fe-1a63-e053-0824d011072a",
        privateKeyPEM: "synthetic invalid key"
    )) == "Key ID must contain 10 alphanumeric characters.")
    #expect(credentialValidationMessage(TeamCredentials(
        keyID: "ABCDEF1234",
        issuerID: "not-an-issuer",
        privateKeyPEM: "synthetic invalid key"
    )) == "Issuer ID must be a valid UUID.")
    #expect(credentialValidationMessage(TeamCredentials(
        keyID: "ABCDEF1234",
        issuerID: "57246542-96fe-1a63-e053-0824d011072a",
        privateKeyPEM: "synthetic invalid key"
    )) == "The key file must contain a valid P-256 private key in PEM format.")

    let client = ASCClient(credentials: LocalizationCredentialStore())
    do {
        _ = try await client.call(.updateLocalization, arguments: [
            "localizationId": .string("localization-1"),
            "description": .string(String(repeating: "a", count: 4_001)),
        ])
        Issue.record("Expected overlong metadata to fail validation")
    } catch let error as BridgeError {
        #expect(error.errorDescription == "description must be at most 4000 characters.")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

private struct LocalizationCredentialStore: CredentialStore {
    func load() async throws -> TeamCredentials? { nil }
    func save(_ credentials: TeamCredentials) async throws {}
    func delete() async throws {}
}

private func credentialValidationMessage(_ credentials: TeamCredentials) -> String? {
    do {
        try ASCClient.validate(credentials)
        return nil
    } catch let error as BridgeError {
        return error.errorDescription
    } catch {
        return String(describing: error)
    }
}
