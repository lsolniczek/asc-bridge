import Foundation
import MCP
import BridgeCore

struct ToolExecution: Sendable {
    let result: CallTool.Result
    let status: String
    let summary: String
}

enum ToolCatalog {
    private enum ValueKind: Equatable {
        case string
        case integer
    }

    private enum Validation {
        case none
        case identifier
        case locale
        case visibleText
        case multilineText
        case nonWhitespaceMultilineText
        case url
        case territory
        case cursor
    }

    private struct Field {
        let kind: ValueKind
        let description: String
        let minimum: Int?
        let maximum: Int?
        let minLength: Int?
        let maxLength: Int?
        let maxUTF8Bytes: Int?
        let allowedValues: [String]?
        let pattern: String?
        let validation: Validation

        static func string(
            _ description: String,
            minLength: Int? = nil,
            maxLength: Int? = nil,
            maxUTF8Bytes: Int? = nil,
            allowedValues: [String]? = nil,
            pattern: String? = nil,
            validation: Validation = .none
        ) -> Field {
            Field(
                kind: .string, description: description, minimum: nil, maximum: nil,
                minLength: minLength, maxLength: maxLength, maxUTF8Bytes: maxUTF8Bytes,
                allowedValues: allowedValues, pattern: pattern, validation: validation
            )
        }

        static func integer(_ description: String, minimum: Int, maximum: Int) -> Field {
            Field(
                kind: .integer, description: description, minimum: minimum, maximum: maximum,
                minLength: nil, maxLength: nil, maxUTF8Bytes: nil,
                allowedValues: nil, pattern: nil, validation: .none
            )
        }

        var schema: MCP.Value {
            var value: [String: MCP.Value] = [
                "type": .string(kind == .integer ? "integer" : "string"),
                "description": .string(description),
            ]
            if let minimum { value["minimum"] = .int(minimum) }
            if let maximum { value["maximum"] = .int(maximum) }
            if let minLength { value["minLength"] = .int(minLength) }
            if let maxLength { value["maxLength"] = .int(maxLength) }
            if let allowedValues { value["enum"] = .array(allowedValues.map(MCP.Value.string)) }
            if let pattern { value["pattern"] = .string(pattern) }
            return .object(value)
        }
    }

    private struct Definition {
        let operation: ASCOperation
        let fields: [String: Field]
        let required: Set<String>
        let atLeastOneOf: Set<String>
        let annotations: Tool.Annotations
        let description: String
    }

    private static let platforms = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"]
    private static let processingStates = ["PROCESSING", "FAILED", "INVALID", "VALID"]
    private static let buildSorts = ["version", "-version", "uploadedDate", "-uploadedDate", "preReleaseVersion", "-preReleaseVersion"]
    private static let reviewSorts = ["rating", "-rating", "createdDate", "-createdDate"]

    private static let limit = Field.integer("Maximum number of records to return (1–200).", minimum: 1, maximum: 200)
    private static let cursor = Field.string("Opaque pagination cursor returned by the previous page. At most 2048 UTF-8 bytes; control characters are rejected.", maxLength: 2_048, validation: .cursor)
    private static let safeIDPattern = "^[A-Za-z0-9_-]{1,128}$"
    private static let appID = Field.string("The App Store Connect app resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let versionID = Field.string("The App Store Connect version resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let localizationID = Field.string("The App Store Connect localization resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let appInfoID = Field.string("The App Store Connect app info resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let appInfoLocalizationID = Field.string("The App Store Connect app info localization resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let buildID = Field.string("The App Store Connect build resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let betaBuildLocalizationID = Field.string("The App Store Connect beta build localization resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let reviewID = Field.string("The App Store Connect customer review resource ID (1–128 safe identifier characters).", minLength: 1, maxLength: 128, pattern: safeIDPattern, validation: .identifier)
    private static let locale = Field.string("Locale configured in App Store Connect, such as en-US or pl.", minLength: 1, maxLength: 20, pattern: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", validation: .locale)
    private static let platform = Field.string("App Store Connect platform.", allowedValues: platforms)
    private static let versionString = Field.string("The marketing version string, such as 2.4.0.", minLength: 1, maxLength: 18, validation: .visibleText)
    private static let descriptionText = Field.string("Localized App Store description text.", maxLength: 4_000, validation: .multilineText)
    private static let whatsNew = Field.string("What's new text for the selected locale.", maxLength: 4_000, validation: .multilineText)
    private static let promotionalText = Field.string("Promotional text for the selected locale.", maxLength: 170, validation: .multilineText)
    private static let keywords = Field.string("Search keywords. Maximum 100 UTF-8 bytes.", maxLength: 100, maxUTF8Bytes: 100, validation: .multilineText)
    private static let metadataURL = Field.string("Absolute http(s) URL, or empty text to clear it; at most 2000 characters.", maxLength: 2_000, validation: .url)
    private static let appInfoName = Field.string("Localized App Store name (2–30 non-whitespace characters).", minLength: 2, maxLength: 30, validation: .visibleText)
    private static let appInfoSubtitle = Field.string("Localized App Store subtitle (at most 30 characters).", maxLength: 30, validation: .multilineText)
    private static let privacyPolicyText = Field.string("Privacy policy text, at most 4000 characters.", maxLength: 4_000, validation: .multilineText)
    private static let buildNumber = Field.string("Build number filter (1–100 visible characters).", minLength: 1, maxLength: 100, validation: .visibleText)
    private static let marketingVersion = Field.string("Marketing version filter (1–100 visible characters).", minLength: 1, maxLength: 100, validation: .visibleText)
    private static let processingState = Field.string("Build processing state.", allowedValues: processingStates)
    private static let buildSort = Field.string("Build ordering; defaults to -uploadedDate.", allowedValues: buildSorts)
    private static let betaWhatsNew = Field.string("What to Test text for this beta build, at most 4000 characters.", maxLength: 4_000, validation: .multilineText)
    private static let territory = Field.string("Uppercase three-letter App Store territory code.", minLength: 3, maxLength: 3, pattern: "^[A-Z]{3}$", validation: .territory)
    private static let rating = Field.integer("Customer review rating from 1 to 5.", minimum: 1, maximum: 5)
    private static let reviewSort = Field.string("Review ordering; defaults to -createdDate.", allowedValues: reviewSorts)
    private static let responseBody = Field.string("Public customer review response. This creates or replaces the response; at most 5970 characters.", minLength: 1, maxLength: 5_970, validation: .nonWhitespaceMultilineText)

    private static let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
    private static let addOnly = Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
    private static let update = Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true)
    private static let upsert = Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)

    private static let definitions: [String: Definition] = {
        let all: [Definition] = [
            Definition(operation: .listApps, fields: ["limit": limit, "cursor": cursor], required: [], atLeastOneOf: [], annotations: readOnly,
                       description: "List App Store Connect apps visible to the configured team key. Use the returned app ID with asc_list_versions."),
            Definition(operation: .listVersions, fields: ["appId": appID, "platform": platform, "limit": limit, "cursor": cursor], required: ["appId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List versions for an app, optionally filtered by platform. Use a returned version ID with asc_list_localizations."),
            Definition(operation: .listLocalizations, fields: ["versionId": versionID, "limit": limit, "cursor": cursor], required: ["versionId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List localized version metadata, including description, What's New, promotional text, keywords, and URLs."),
            Definition(operation: .createVersion, fields: ["appId": appID, "platform": platform, "versionString": versionString], required: ["appId", "platform", "versionString"], atLeastOneOf: [], annotations: addOnly,
                       description: "Create a new App Store version for an app and platform with Apple's MANUAL release type."),
            Definition(operation: .createLocalization, fields: ["versionId": versionID, "locale": locale, "description": descriptionText, "whatsNew": whatsNew, "promotionalText": promotionalText, "keywords": keywords, "marketingUrl": metadataURL, "supportUrl": metadataURL], required: ["versionId", "locale"], atLeastOneOf: [], annotations: addOnly,
                       description: "Add localized version metadata. The locale must match a locale configured in the app's App Store Connect App Info."),
            Definition(operation: .updateLocalization, fields: ["localizationId": localizationID, "description": descriptionText, "whatsNew": whatsNew, "promotionalText": promotionalText, "keywords": keywords, "marketingUrl": metadataURL, "supportUrl": metadataURL], required: ["localizationId"], atLeastOneOf: ["description", "whatsNew", "promotionalText", "keywords", "marketingUrl", "supportUrl"], annotations: update,
                       description: "Update one or more localized version metadata fields. Omitted fields are left unchanged; empty text or URLs clear optional fields."),
            Definition(operation: .getApp, fields: ["appId": appID], required: ["appId"], atLeastOneOf: [], annotations: readOnly,
                       description: "Get one App Store Connect app by its resource ID."),
            Definition(operation: .getVersion, fields: ["versionId": versionID], required: ["versionId"], atLeastOneOf: [], annotations: readOnly,
                       description: "Get one App Store version by its resource ID."),
            Definition(operation: .listAppInfos, fields: ["appId": appID, "limit": limit, "cursor": cursor], required: ["appId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List App Info records for an app."),
            Definition(operation: .listAppInfoLocalizations, fields: ["appInfoId": appInfoID, "limit": limit, "cursor": cursor], required: ["appInfoId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List localized App Info metadata for an App Info record."),
            Definition(operation: .createAppInfoLocalization, fields: ["appInfoId": appInfoID, "locale": locale, "name": appInfoName, "subtitle": appInfoSubtitle, "privacyPolicyUrl": metadataURL, "privacyChoicesUrl": metadataURL, "privacyPolicyText": privacyPolicyText], required: ["appInfoId", "locale", "name"], atLeastOneOf: [], annotations: addOnly,
                       description: "Create localized App Info metadata for a configured locale."),
            Definition(operation: .updateAppInfoLocalization, fields: ["appInfoLocalizationId": appInfoLocalizationID, "name": appInfoName, "subtitle": appInfoSubtitle, "privacyPolicyUrl": metadataURL, "privacyChoicesUrl": metadataURL, "privacyPolicyText": privacyPolicyText], required: ["appInfoLocalizationId"], atLeastOneOf: ["name", "subtitle", "privacyPolicyUrl", "privacyChoicesUrl", "privacyPolicyText"], annotations: update,
                       description: "Update one or more App Info localization fields. Omitted fields are left unchanged; empty optional text or URLs clear those fields."),
            Definition(operation: .listBuilds, fields: ["appId": appID, "platform": platform, "buildNumber": buildNumber, "marketingVersion": marketingVersion, "processingState": processingState, "sort": buildSort, "limit": limit, "cursor": cursor], required: ["appId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List builds for an app with optional platform, build number, marketing version, processing state, and ordering filters."),
            Definition(operation: .getBuild, fields: ["buildId": buildID], required: ["buildId"], atLeastOneOf: [], annotations: readOnly,
                       description: "Get one App Store Connect build by its resource ID."),
            Definition(operation: .getVersionBuild, fields: ["versionId": versionID], required: ["versionId"], atLeastOneOf: [], annotations: readOnly,
                       description: "Get the build attached to an App Store version; data may be null when none is attached."),
            Definition(operation: .setVersionBuild, fields: ["versionId": versionID, "buildId": buildID], required: ["versionId", "buildId"], atLeastOneOf: [], annotations: update,
                       description: "Attach a build to an App Store version. This does not submit or release the version."),
            Definition(operation: .listBetaGroups, fields: ["appId": appID, "limit": limit, "cursor": cursor], required: ["appId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List beta testing groups for an app."),
            Definition(operation: .listBetaBuildLocalizations, fields: ["buildId": buildID, "limit": limit, "cursor": cursor], required: ["buildId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List localized What to Test text for a beta build."),
            Definition(operation: .createBetaBuildLocalization, fields: ["buildId": buildID, "locale": locale, "whatsNew": betaWhatsNew], required: ["buildId", "locale"], atLeastOneOf: [], annotations: addOnly,
                       description: "Create localized What to Test text for a beta build."),
            Definition(operation: .updateBetaBuildLocalization, fields: ["betaBuildLocalizationId": betaBuildLocalizationID, "whatsNew": betaWhatsNew], required: ["betaBuildLocalizationId", "whatsNew"], atLeastOneOf: [], annotations: update,
                       description: "Replace localized What to Test text for a beta build; empty text clears it."),
            Definition(operation: .listCustomerReviews, fields: ["appId": appID, "territory": territory, "rating": rating, "sort": reviewSort, "limit": limit, "cursor": cursor], required: ["appId"], atLeastOneOf: [], annotations: readOnly,
                       description: "List customer reviews for an app with optional territory, star rating, and ordering filters."),
            Definition(operation: .getCustomerReviewResponse, fields: ["reviewId": reviewID], required: ["reviewId"], atLeastOneOf: [], annotations: readOnly,
                       description: "Get the public response associated with a customer review; data may be null when no response exists."),
            Definition(operation: .upsertCustomerReviewResponse, fields: ["reviewId": reviewID, "responseBody": responseBody], required: ["reviewId", "responseBody"], atLeastOneOf: [], annotations: upsert,
                       description: "Create or replace a public response to a customer review. Apple may take time to publish it; any existing response is replaced."),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.operation.rawValue, $0) })
    }()

    static func tools() -> [Tool] {
        definitions.values.sorted { $0.operation.rawValue < $1.operation.rawValue }.map { definition in
            let name = definition.operation.rawValue
            return Tool(
                name: name,
                title: name.replacingOccurrences(of: "_", with: " "),
                description: definition.description,
                inputSchema: objectSchema(fields: definition.fields, required: definition.required),
                annotations: definition.annotations
            )
        }
    }

    static func safeAuditParameters(toolName: String?, raw: JSONValue?) -> JSONValue? {
        guard let toolName, let definition = definitions[toolName],
              let object = raw?.objectValue else { return nil }
        var safe: [String: JSONValue] = [:]
        for (key, value) in object {
            guard let field = definition.fields[key] else { continue }
            switch (field.kind, value) {
            case (.string, .string(let string)):
                let maximum = field.maxLength.map { min(max($0, 100), 20_000) } ?? 20_000
                safe[key] = .string(SecretSanitizer.redactText(string, maximumLength: maximum))
            case (.integer, .number(let number)) where number.isFinite && number.rounded() == number:
                if let minimum = field.minimum, number < Double(minimum) { continue }
                if let maximum = field.maximum, number > Double(maximum) { continue }
                safe[key] = .number(number)
            default:
                safe[key] = .string("[invalid value omitted]")
            }
        }
        return safe.isEmpty ? nil : SecretSanitizer.redact(.object(safe))
    }

    static func execute(
        service: any ASCServing,
        name: String,
        arguments: [String: MCP.Value]?
    ) async -> ToolExecution {
        guard let definition = definitions[name] else {
            return failure("Unknown tool.", status: "rejected", summary: "Unknown tool request.")
        }
        do {
            let parsed = try parseArguments(arguments ?? [:], for: definition)
            let output = try await service.call(definition.operation, arguments: parsed)
            let safeOutput = SecretSanitizer.redact(output)
            let encoded = try safeOutput.encodedString(pretty: true)
            let structured = try? MCP.Value(safeOutput)
            return ToolExecution(
                result: CallTool.Result(
                    content: [.text(text: encoded, annotations: nil, _meta: nil)],
                    structuredContent: structured,
                    isError: false
                ),
                status: "success",
                summary: "\(name) completed successfully."
            )
        } catch let error as ToolInputError {
            return failure(error.message, status: "rejected", summary: "Tool input rejected.")
        } catch {
            let message = SecretSanitizer.redactText(error.localizedDescription, maximumLength: 800)
            return failure(message, status: "error", summary: "\(name) failed: \(message)")
        }
    }

    private static func parseArguments(
        _ arguments: [String: MCP.Value],
        for definition: Definition
    ) throws -> [String: JSONValue] {
        guard Set(arguments.keys).isSubset(of: Set(definition.fields.keys)) else {
            throw ToolInputError(message: "Unknown argument supplied.")
        }
        guard definition.required.isSubset(of: Set(arguments.keys)) else {
            throw ToolInputError(message: "Required arguments are missing.")
        }

        var output: [String: JSONValue] = [:]
        for (key, value) in arguments {
            let field = definition.fields[key]!
            switch (field.kind, value) {
            case (.string, .string(let string)):
                try validate(string, for: field)
                output[key] = .string(string)
            case (.integer, .int(let number)):
                if let minimum = field.minimum, number < minimum {
                    throw ToolInputError(message: "A numeric argument is outside its allowed range.")
                }
                if let maximum = field.maximum, number > maximum {
                    throw ToolInputError(message: "A numeric argument is outside its allowed range.")
                }
                output[key] = .number(Double(number))
            default:
                throw ToolInputError(message: "An argument has the wrong type.")
            }
        }

        guard definition.atLeastOneOf.isEmpty || !definition.atLeastOneOf.isDisjoint(with: Set(arguments.keys)) else {
            throw ToolInputError(message: "Provide at least one metadata field to update.")
        }
        return output
    }

    private static func validate(_ string: String, for field: Field) throws {
        if let minLength = field.minLength, string.count < minLength {
            throw ToolInputError(message: "A text argument is shorter than its allowed length.")
        }
        if let maxLength = field.maxLength, string.count > maxLength {
            throw ToolInputError(message: "A text argument exceeds its allowed length.")
        }
        if let maxUTF8Bytes = field.maxUTF8Bytes, string.utf8.count > maxUTF8Bytes {
            throw ToolInputError(message: "A text argument exceeds its UTF-8 byte limit.")
        }
        if let allowedValues = field.allowedValues, !allowedValues.contains(string) {
            throw ToolInputError(message: "A text argument is not one of the allowed values.")
        }
        if let pattern = field.pattern,
           string.range(of: pattern, options: .regularExpression) == nil {
            throw ToolInputError(message: "A text argument does not match its required format.")
        }

        switch field.validation {
        case .none:
            break
        case .identifier:
            guard string.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
                throw ToolInputError(message: "Resource IDs must contain only letters, digits, underscores, or hyphens.")
            }
        case .locale:
            guard string.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
                throw ToolInputError(message: "Locale must be an App Store Connect locale code such as en-US or zh-Hans.")
            }
        case .visibleText:
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ToolInputError(message: "Text must contain visible characters and no control characters.")
            }
        case .multilineText:
            guard !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
                throw ToolInputError(message: "Text contains unsupported control characters.")
            }
        case .nonWhitespaceMultilineText:
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
                throw ToolInputError(message: "Text must contain visible characters and no unsupported control characters.")
            }
        case .url:
            guard string.isEmpty || isSafeHTTPURL(string) else {
                throw ToolInputError(message: "URL must be an absolute http(s) URL without credentials or whitespace.")
            }
        case .territory:
            guard string.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
                throw ToolInputError(message: "Territory must be an uppercase three-letter code.")
            }
        case .cursor:
            guard string.utf8.count <= 2_048,
                  !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ToolInputError(message: "Cursor must be at most 2048 UTF-8 bytes and contain no control characters.")
            }
        }

    }

    private static func isSafeHTTPURL(_ value: String) -> Bool {
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.url != nil else { return false }
        return true
    }

    private static func failure(_ message: String, status: String, summary: String) -> ToolExecution {
        ToolExecution(
            result: CallTool.Result(
                content: [.text(text: SecretSanitizer.redactText(message, maximumLength: 800), annotations: nil, _meta: nil)],
                isError: true
            ),
            status: status,
            summary: SecretSanitizer.redactText(summary, maximumLength: 1_000)
        )
    }

    private static func objectSchema(fields: [String: Field], required: Set<String>) -> MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object(fields.mapValues(\.schema)),
            "required": .array(required.sorted().map(MCP.Value.string)),
            "additionalProperties": .bool(false),
        ])
    }
}

private struct ToolInputError: Error {
    let message: String
}

private extension SecretSanitizer {
    static func redact(_ value: JSONValue) -> JSONValue {
        SecretSanitizer.redact(value, depth: 0)
    }
}
