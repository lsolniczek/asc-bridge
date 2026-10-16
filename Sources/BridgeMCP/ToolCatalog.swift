import Foundation
import MCP
import BridgeCore

struct ToolExecution: Sendable {
    let result: CallTool.Result
    let status: String
    let summary: String
}

enum ToolCatalog {
    private enum FieldKind {
        case string
        case integer
        case platform
    }

    private struct Definition {
        let name: String
        let operation: ASCOperation
        let properties: [String: MCP.Value]
        let required: Set<String>
        let fieldKinds: [String: FieldKind]
        let annotations: Tool.Annotations
        let description: String
    }

    private static let platforms = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"]

    private static let definitions: [String: Definition] = {
        let limit = property("integer", "Maximum number of records to return (1–200).", constraints: ["minimum": 1, "maximum": 200])
        let cursor = property("string", "Opaque pagination cursor returned by the previous page.", constraints: ["maxLength": 2_048])
        let platform = enumProperty(platforms, "App Store Connect platform.")
        let appID = property("string", "The App Store Connect app resource ID.", constraints: ["minLength": 1, "maxLength": 128])
        let versionID = property("string", "The App Store Connect version resource ID.", constraints: ["minLength": 1, "maxLength": 128])
        let localizationID = property("string", "The App Store Connect localization resource ID.", constraints: ["minLength": 1, "maxLength": 128])
        let textDescription = property("string", "Localized App Store description text.", constraints: ["maxLength": 4_000])
        let whatsNew = property("string", "What's new in this version for the selected locale.", constraints: ["maxLength": 4_000])
        let promotionalText = property("string", "Promotional text for the selected locale.", constraints: ["maxLength": 170])
        let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        let addOnly = Tool.Annotations(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
        let update = Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true)

        let all: [Definition] = [
            Definition(
                name: "asc_list_apps", operation: .listApps,
                properties: ["limit": limit, "cursor": cursor], required: [],
                fieldKinds: ["limit": .integer, "cursor": .string], annotations: readOnly,
                description: "List App Store Connect apps visible to the configured team key. Use the returned app ID with asc_list_versions."
            ),
            Definition(
                name: "asc_list_versions", operation: .listVersions,
                properties: [
                    "appId": appID,
                    "platform": platform, "limit": limit, "cursor": cursor,
                ], required: ["appId"],
                fieldKinds: ["appId": .string, "platform": .platform, "limit": .integer, "cursor": .string], annotations: readOnly,
                description: "List versions for an app, optionally filtered by platform. Use a returned version ID with asc_list_localizations."
            ),
            Definition(
                name: "asc_list_localizations", operation: .listLocalizations,
                properties: [
                    "versionId": versionID,
                    "limit": limit, "cursor": cursor,
                ], required: ["versionId"],
                fieldKinds: ["versionId": .string, "limit": .integer, "cursor": .string], annotations: readOnly,
                description: "List localized version metadata, including description, What's New, and promotional text."
            ),
            Definition(
                name: "asc_create_version", operation: .createVersion,
                properties: [
                    "appId": appID,
                    "platform": platform,
                    "versionString": property("string", "The marketing version string, such as 2.4.0.", constraints: ["minLength": 1, "maxLength": 18]),
                ], required: ["appId", "platform", "versionString"],
                fieldKinds: ["appId": .string, "platform": .platform, "versionString": .string], annotations: addOnly,
                description: "Create a new App Store version for an app and platform with Apple's MANUAL release type."
            ),
            Definition(
                name: "asc_create_localization", operation: .createLocalization,
                properties: [
                    "versionId": versionID,
                    "locale": property("string", "Locale configured for this app in App Store Connect App Info, such as en-US or pl.", constraints: ["minLength": 1, "maxLength": 20]),
                    "description": textDescription, "whatsNew": whatsNew, "promotionalText": promotionalText,
                ], required: ["versionId", "locale"],
                fieldKinds: ["versionId": .string, "locale": .string, "description": .string, "whatsNew": .string, "promotionalText": .string], annotations: addOnly,
                description: "Add localized version metadata. The locale must match a locale configured in the app's App Store Connect App Info. Provide any of description, whatsNew, and promotionalText."
            ),
            Definition(
                name: "asc_update_localization", operation: .updateLocalization,
                properties: [
                    "localizationId": localizationID,
                    "description": textDescription, "whatsNew": whatsNew, "promotionalText": promotionalText,
                ], required: ["localizationId"],
                fieldKinds: ["localizationId": .string, "description": .string, "whatsNew": .string, "promotionalText": .string], annotations: update,
                description: "Update one or more localized metadata fields. Omitted fields are left unchanged; empty text clears that field."
            ),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }()

    static func tools() -> [Tool] {
        definitions.values.sorted { $0.name < $1.name }.map { definition in
            Tool(
                name: definition.name,
                title: definition.name.replacingOccurrences(of: "_", with: " "),
                description: definition.description,
                inputSchema: objectSchema(properties: definition.properties, required: definition.required),
                annotations: definition.annotations
            )
        }
    }

    static func safeAuditParameters(toolName: String?, raw: JSONValue?) -> JSONValue? {
        guard let toolName, let definition = definitions[toolName],
              let object = raw?.objectValue else { return nil }
        var safe: [String: JSONValue] = [:]
        for (key, value) in object where definition.fieldKinds[key] != nil {
            switch (definition.fieldKinds[key]!, value) {
            case (.string, .string(let string)):
                safe[key] = .string(SecretSanitizer.redactText(string, maximumLength: 20_000))
            case (.integer, .number(let number)) where number.isFinite && number.rounded() == number:
                safe[key] = .number(number)
            case (.platform, .string(let string)):
                safe[key] = .string(SecretSanitizer.redactText(string, maximumLength: 100))
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
        guard Set(arguments.keys).isSubset(of: Set(definition.fieldKinds.keys)) else {
            throw ToolInputError(message: "Unknown argument supplied.")
        }
        guard definition.required.isSubset(of: Set(arguments.keys)) else {
            throw ToolInputError(message: "Required arguments are missing.")
        }

        var output: [String: JSONValue] = [:]
        for (key, value) in arguments {
            switch (definition.fieldKinds[key]!, value) {
            case (.string, .string(let string)):
                guard !definition.required.contains(key) || !string.isEmpty else {
                    throw ToolInputError(message: "Required text arguments must not be empty.")
                }
                let length = key == "cursor" ? string.utf8.count : string.count
                if let maximum = maximumLength(for: key), length > maximum {
                    throw ToolInputError(message: "A text argument exceeds its allowed length.")
                }
                output[key] = .string(string)
            case (.integer, .int(let number)):
                guard (1...200).contains(number) else {
                    throw ToolInputError(message: "Limit must be between 1 and 200.")
                }
                output[key] = .number(Double(number))
            case (.platform, .string(let value)) where platforms.contains(value):
                output[key] = .string(value)
            case (.platform, .string):
                throw ToolInputError(message: "Platform must be IOS, MAC_OS, TV_OS, or VISION_OS.")
            default:
                throw ToolInputError(message: "An argument has the wrong type.")
            }
        }

        if definition.name == "asc_update_localization",
           !["description", "whatsNew", "promotionalText"].contains(where: { arguments[$0] != nil }) {
            throw ToolInputError(message: "Provide at least one localized metadata field to update.")
        }
        return output
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

    private static func maximumLength(for key: String) -> Int? {
        switch key {
        case "description", "whatsNew": 4_000
        case "promotionalText": 170
        case "versionString": 18
        case "locale": 20
        case "appId", "versionId", "localizationId": 128
        case "cursor": 2_048
        default: nil
        }
    }

    private static func property(
        _ type: String,
        _ description: String,
        constraints: [String: MCP.Value] = [:]
    ) -> MCP.Value {
        var value: [String: MCP.Value] = ["type": .string(type), "description": .string(description)]
        value.merge(constraints) { _, new in new }
        return .object(value)
    }

    private static func enumProperty(_ values: [String], _ description: String) -> MCP.Value {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map(MCP.Value.string)),
        ])
    }

    private static func objectSchema(properties: [String: MCP.Value], required: Set<String>) -> MCP.Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
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
