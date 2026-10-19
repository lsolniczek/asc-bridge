import Foundation
import Testing
import MCP
import BridgeCore
@testable import BridgeMCP

private let fixtureJWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
private let fixturePEM = "-----BEGIN PRIVATE KEY-----\nfake-private-material\n-----END PRIVATE KEY-----"

@Test func auditPersistsRequestsRedactsSecretsAndRecoversTrailingWrite() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.jsonl")

    let store = try AuditStore(fileURL: fileURL)
    let id = try await store.begin(
        method: "tools/call",
        toolName: "asc_update_localization",
        parameters: .object([
            "description": .string("Release text with token=\(fixtureJWT)"),
            "privateKey": .string(fixturePEM),
        ]),
        requestID: "77"
    )
    try await store.finish(id: id, status: "success", durationMS: 12.5, summary: "Updated with Bearer \(fixtureJWT)")
    _ = try await store.begin(method: "tools/call", toolName: "asc_create_version", requestID: "unfinished")

    let permissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700)

    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{partial trailing write".utf8))
    try handle.close()

    let recovered = try AuditStore(fileURL: fileURL)
    let entries = try await recovered.recentEntries()
    #expect(entries.count == 2)
    #expect(entries[0].status == "pending")
    #expect(entries[0].requestID == "unfinished")
    #expect(entries[1].status == "success")
    #expect(entries[1].durationMS == 12.5)
    #expect(entries[1].summary?.contains("[REDACTED]") == true)

    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(contents.contains("[REDACTED]"))
    #expect(!contents.contains(fixtureJWT))
    #expect(!contents.contains("fake-private-material"))
    #expect(contents.hasSuffix("\n"))
}

@Test func auditBoundsHistoryProjectionWithoutTruncatingDisk() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.jsonl")
    let store = try AuditStore(fileURL: fileURL)

    for index in 0..<3 {
        _ = try await store.begin(method: "ping", requestID: "\(index)")
    }

    #expect(try await store.recentEntries(limit: 2).count == 2)
    #expect(try await store.recentEntries(limit: 0).isEmpty)
    #expect(try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n").count == 3)
}

@Test func auditPoisonsAfterPartialAppendUntilRestartRecovery() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.jsonl")
    let store = try AuditStore(fileURL: fileURL)
    _ = try await store.begin(method: "ping", requestID: "stable")
    await store.failNextAppendForTesting(afterWritingBytes: 4)

    do {
        _ = try await store.begin(method: "tools/call", requestID: "torn")
        Issue.record("Expected the injected partial append to fail.")
    } catch { }

    do {
        _ = try await store.begin(method: "tools/call", requestID: "must-not-append")
        Issue.record("A poisoned audit store must reject later appends.")
    } catch { }

    let recovered = try AuditStore(fileURL: fileURL)
    let entries = try await recovered.recentEntries()
    #expect(entries.count == 1)
    #expect(entries[0].requestID == "stable")
    #expect(try String(contentsOf: fileURL, encoding: .utf8).hasSuffix("\n"))
}

@Test func auditFailsClosedOnMalformedCompleteRecord() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("history.jsonl")
    try Data("{malformed complete line}\n".utf8).write(to: fileURL)

    do {
        _ = try AuditStore(fileURL: fileURL)
        Issue.record("Expected malformed complete history to fail closed.")
    } catch { }
}

@Test func toolCatalogExposesTwentyThreeClosedSchemasWithAnnotations() throws {
    let tools = ToolCatalog.tools()
    #expect(Set(tools.map(\.name)) == Set(ASCOperation.allCases.map(\.rawValue)))
    #expect(tools.count == 23)

    for tool in tools {
        guard case .object(let schema) = tool.inputSchema else {
            Issue.record("Expected object input schema for \(tool.name)")
            continue
        }
        #expect(schema["type"] == .string("object"))
        #expect(schema["additionalProperties"] == .bool(false))
        #expect(schema["properties"]?.objectValue != nil)
        #expect(schema["required"]?.arrayValue != nil)
        if let operation = ASCOperation(rawValue: tool.name) {
            #expect(tool.annotations.readOnlyHint == !operation.isMutation)
        } else {
            Issue.record("Unexpected tool name: \(tool.name)")
        }
    }

    let readTool = try #require(tools.first { $0.name == "asc_list_apps" })
    #expect(readTool.annotations.readOnlyHint == true)
    let readSchema = try #require(readTool.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(readSchema["cursor"]?.objectValue?["maxLength"] == .int(2_048))
    let mutation = try #require(tools.first { $0.name == "asc_update_localization" })
    #expect(mutation.annotations.readOnlyHint == false)
    let mutationSchema = try #require(mutation.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(mutationSchema["localizationId"]?.objectValue?["maxLength"] == .int(128))
    #expect(mutationSchema["keywords"]?.objectValue?["maxLength"] == .int(100))
    #expect(mutationSchema["marketingUrl"]?.objectValue?["maxLength"] == .int(2_000))
    #expect(mutationSchema["marketingUrl"]?.objectValue?["format"] == nil)

    let builds = try #require(tools.first { $0.name == "asc_list_builds" })
    let buildFields = try #require(builds.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(buildFields["processingState"]?.objectValue?["enum"] == .array(["PROCESSING", "FAILED", "INVALID", "VALID"].map(MCP.Value.string)))
    #expect(buildFields["sort"]?.objectValue?["enum"] == .array(["version", "-version", "uploadedDate", "-uploadedDate", "preReleaseVersion", "-preReleaseVersion"].map(MCP.Value.string)))

    let reviews = try #require(tools.first { $0.name == "asc_list_customer_reviews" })
    let reviewFields = try #require(reviews.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(reviewFields["rating"]?.objectValue?["type"] == .string("integer"))
    #expect(reviewFields["rating"]?.objectValue?["minimum"] == .int(1))
    #expect(reviewFields["rating"]?.objectValue?["maximum"] == .int(5))
    #expect(reviewFields["territory"]?.objectValue?["pattern"] == .string("^[A-Z]{3}$"))

    let reply = try #require(tools.first { $0.name == "asc_upsert_customer_review_response" })
    let replyFields = try #require(reply.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(replyFields["responseBody"]?.objectValue?["maxLength"] == .int(5_970))
    #expect(reply.annotations.readOnlyHint == false)
    #expect(reply.annotations.destructiveHint == true)
    #expect(reply.annotations.idempotentHint == false)

    let create = try #require(tools.first { $0.name == "asc_create_beta_build_localization" })
    #expect(create.annotations.readOnlyHint == false)
    #expect(create.annotations.destructiveHint == false)
    #expect(create.annotations.idempotentHint == false)
    let setBuild = try #require(tools.first { $0.name == "asc_set_version_build" })
    #expect(setBuild.annotations.readOnlyHint == false)
    #expect(setBuild.annotations.destructiveHint == true)
    #expect(setBuild.annotations.idempotentHint == true)
    let updateInfo = try #require(tools.first { $0.name == "asc_update_app_info_localization" })
    #expect(updateInfo.annotations.destructiveHint == true)
    #expect(updateInfo.annotations.idempotentHint == true)
    let updateBeta = try #require(tools.first { $0.name == "asc_update_beta_build_localization" })
    #expect(updateBeta.annotations.destructiveHint == true)
    #expect(updateBeta.annotations.idempotentHint == true)
}

@Test func eachToolMapsToItsTypedASCOperationAndSanitizesReturnedContent() async throws {
    let service = RecordingASCService()
    let calls: [(String, [String: MCP.Value])] = [
        ("asc_list_apps", ["limit": .int(20), "cursor": .string("page-2")]),
        ("asc_list_versions", ["appId": .string("app-1"), "platform": .string("IOS")]),
        ("asc_list_localizations", ["versionId": .string("version-1"), "limit": .int(5)]),
        ("asc_create_version", ["appId": .string("app-1"), "platform": .string("MAC_OS"), "versionString": .string("2.4.0")]),
        ("asc_create_localization", ["versionId": .string("version-1"), "locale": .string("pl"), "description": .string("Opis"), "keywords": .string("app,sklep\nmobile"), "marketingUrl": .string(""), "supportUrl": .string("https://example.com/help")]),
        ("asc_update_localization", ["localizationId": .string("localization-1"), "whatsNew": .string("Poprawki"), "keywords": .string("release"), "marketingUrl": .string("")]),
        ("asc_get_app", ["appId": .string("app-1")]),
        ("asc_get_version", ["versionId": .string("version-1")]),
        ("asc_list_app_infos", ["appId": .string("app-1"), "limit": .int(25)]),
        ("asc_list_app_info_localizations", ["appInfoId": .string("info-1"), "cursor": .string("next")]),
        ("asc_create_app_info_localization", ["appInfoId": .string("info-1"), "locale": .string("en-US"), "name": .string("Example App"), "subtitle": .string("A useful app"), "privacyPolicyUrl": .string("https://example.com/privacy"), "privacyChoicesUrl": .string(""), "privacyPolicyText": .string("Privacy details")]),
        ("asc_update_app_info_localization", ["appInfoLocalizationId": .string("info-loc-1"), "name": .string("Renamed App")]),
        ("asc_list_builds", ["appId": .string("app-1"), "platform": .string("IOS"), "buildNumber": .string("42"), "marketingVersion": .string("2.4.0"), "processingState": .string("VALID"), "sort": .string("-uploadedDate"), "limit": .int(10)]),
        ("asc_get_build", ["buildId": .string("build-1")]),
        ("asc_get_version_build", ["versionId": .string("version-1")]),
        ("asc_set_version_build", ["versionId": .string("version-1"), "buildId": .string("build-1")]),
        ("asc_list_beta_groups", ["appId": .string("app-1")]),
        ("asc_list_beta_build_localizations", ["buildId": .string("build-1")]),
        ("asc_create_beta_build_localization", ["buildId": .string("build-1"), "locale": .string("pl"), "whatsNew": .string("Nowe możliwości")]),
        ("asc_update_beta_build_localization", ["betaBuildLocalizationId": .string("beta-loc-1"), "whatsNew": .string("")]),
        ("asc_list_customer_reviews", ["appId": .string("app-1"), "territory": .string("USA"), "rating": .int(4), "sort": .string("-createdDate")]),
        ("asc_get_customer_review_response", ["reviewId": .string("review-1")]),
        ("asc_upsert_customer_review_response", ["reviewId": .string("review-1"), "responseBody": .string("Thank you for your review.")]),
    ]

    for (name, arguments) in calls {
        let result = await ToolCatalog.execute(service: service, name: name, arguments: arguments)
        #expect(result.status == "success")
        #expect(result.result.isError == false)
        let text = try #require(result.result.content.compactMap { block -> String? in
            if case .text(let text, _, _) = block { text } else { nil }
        }.first)
        #expect(text.contains("[REDACTED]"))
        #expect(!text.contains(fixtureJWT))
        #expect(!text.contains("sensitive-value"))
    }

    let recorded = await service.recordedCalls
    #expect(recorded.map(\.operation) == ASCOperation.allCases.map(\.rawValue))
    #expect(recorded[0].arguments["limit"] == .number(20))
    #expect(recorded[1].arguments["platform"] == .string("IOS"))
    #expect(recorded[3].arguments["versionString"] == .string("2.4.0"))
    #expect(recorded[4].arguments["locale"] == .string("pl"))
    #expect(recorded[5].arguments["whatsNew"] == .string("Poprawki"))
    #expect(recorded[4].arguments["marketingUrl"] == .string(""))
    #expect(recorded[4].arguments["keywords"] == .string("app,sklep\nmobile"))
    #expect(recorded[5].arguments["supportUrl"] == nil)
    #expect(recorded[12].arguments["processingState"] == .string("VALID"))
    #expect(recorded[20].arguments["rating"] == .number(4))
    #expect(recorded[22].arguments["responseBody"] == .string("Thank you for your review."))
}

@Test func invalidToolArgumentsAreRejectedWithoutCallingASC() async {
    let service = RecordingASCService()

    let unknownArgument = await ToolCatalog.execute(
        service: service,
        name: "asc_list_apps",
        arguments: ["privateKey": .string(fixturePEM)]
    )
    #expect(unknownArgument.status == "rejected")
    #expect(unknownArgument.result.isError == true)

    let invalidLimit = await ToolCatalog.execute(
        service: service,
        name: "asc_list_apps",
        arguments: ["limit": .int(201)]
    )
    #expect(invalidLimit.status == "rejected")

    let longResourceID = await ToolCatalog.execute(
        service: service,
        name: "asc_list_versions",
        arguments: ["appId": .string(String(repeating: "a", count: 129))]
    )
    #expect(longResourceID.status == "rejected")

    let oversizedCursor = await ToolCatalog.execute(
        service: service,
        name: "asc_list_apps",
        arguments: ["cursor": .string(String(repeating: "ø", count: 1_025))]
    )
    #expect(oversizedCursor.status == "rejected")

    let unsafeID = await ToolCatalog.execute(service: service, name: "asc_get_build", arguments: ["buildId": .string("build/1")])
    #expect(unsafeID.status == "rejected")

    let invalidBuildState = await ToolCatalog.execute(service: service, name: "asc_list_builds", arguments: ["appId": .string("app-1"), "processingState": .string("READY")])
    #expect(invalidBuildState.status == "rejected")

    let stringRating = await ToolCatalog.execute(service: service, name: "asc_list_customer_reviews", arguments: ["appId": .string("app-1"), "rating": .string("4")])
    #expect(stringRating.status == "rejected")
    let outOfRangeRating = await ToolCatalog.execute(service: service, name: "asc_list_customer_reviews", arguments: ["appId": .string("app-1"), "rating": .int(6)])
    #expect(outOfRangeRating.status == "rejected")

    let badTerritory = await ToolCatalog.execute(service: service, name: "asc_list_customer_reviews", arguments: ["appId": .string("app-1"), "territory": .string("us")])
    #expect(badTerritory.status == "rejected")

    let badURL = await ToolCatalog.execute(service: service, name: "asc_update_app_info_localization", arguments: ["appInfoLocalizationId": .string("info-loc-1"), "privacyPolicyUrl": .string("javascript:alert(1)")])
    #expect(badURL.status == "rejected")

    let oversizedKeywords = await ToolCatalog.execute(service: service, name: "asc_update_localization", arguments: ["localizationId": .string("localization-1"), "keywords": .string(String(repeating: "é", count: 51))])
    #expect(oversizedKeywords.status == "rejected")

    let emptyVersionUpdate = await ToolCatalog.execute(service: service, name: "asc_update_localization", arguments: ["localizationId": .string("localization-1")])
    #expect(emptyVersionUpdate.status == "rejected")

    let emptyAppInfoUpdate = await ToolCatalog.execute(service: service, name: "asc_update_app_info_localization", arguments: ["appInfoLocalizationId": .string("info-loc-1")])
    #expect(emptyAppInfoUpdate.status == "rejected")

    let whitespaceReply = await ToolCatalog.execute(service: service, name: "asc_upsert_customer_review_response", arguments: ["reviewId": .string("review-1"), "responseBody": .string(" \n\t")])
    #expect(whitespaceReply.status == "rejected")

    let unknownTool = await ToolCatalog.execute(service: service, name: "asc_raw_http", arguments: [:])
    #expect(unknownTool.status == "rejected")
    #expect(await service.recordedCalls.isEmpty)
}

@Test func toolErrorsRedactJWTBearerAndPEMFromResponsesAndSummaries() async throws {
    let result = await ToolCatalog.execute(
        service: ThrowingASCService(),
        name: "asc_list_apps",
        arguments: [:]
    )
    #expect(result.status == "error")
    #expect(result.result.isError == true)
    let text = try #require(result.result.content.compactMap { block -> String? in
        if case .text(let text, _, _) = block { text } else { nil }
    }.first)
    #expect(text.contains("[REDACTED]"))
    #expect(!text.contains(fixtureJWT))
    #expect(!text.contains("private-material"))
    #expect(!result.summary.contains("private-material"))
}

@Test func auditParameterAllowlistOmitsUnknownInputsAndRedactsTextSecrets() throws {
    let safe = ToolCatalog.safeAuditParameters(
        toolName: "asc_create_localization",
        raw: .object([
            "versionId": .string("version-1"),
            "locale": .string("en-US"),
            "description": .string("Text \(fixtureJWT)"),
            "unrecognized": .string(fixturePEM),
        ])
    )
    #expect(safe?.objectValue?["versionId"] == .string("version-1"))
    #expect(safe?.objectValue?["unrecognized"] == nil)
    #expect(safe?.objectValue?["description"]?.stringValue?.contains("[REDACTED]") == true)
    let safeValue = try #require(safe)
    let encoded = try safeValue.encodedString()
    #expect(!encoded.contains(fixtureJWT))

    let review = ToolCatalog.safeAuditParameters(
        toolName: "asc_list_customer_reviews",
        raw: .object([
            "appId": .string("app-1"),
            "rating": .number(5),
            "territory": .string("USA"),
            "privateKey": .string(fixturePEM),
        ])
    )
    #expect(review?.objectValue?["rating"] == .number(5))
    #expect(review?.objectValue?["territory"] == .string("USA"))
    #expect(review?.objectValue?["privateKey"] == nil)
}

@Test func sanitizerRecognizesCamelCaseSecretFieldsWithoutRedactingOrdinaryWords() {
    let input: JSONValue = .object([
        "apiKey": .string("key-secret"),
        "keyId": .string("key-id-secret"),
        "accessToken": .string("token-secret"),
        "privateKeyPEM": .string(fixturePEM),
        "monkey": .string("ordinary-value"),
    ])
    let sanitized = SecretSanitizer.redact(input)
    let fields = sanitized.objectValue
    #expect(fields?["apiKey"] == .string("[REDACTED]"))
    #expect(fields?["keyId"] == .string("[REDACTED]"))
    #expect(fields?["accessToken"] == .string("[REDACTED]"))
    #expect(fields?["privateKeyPEM"] == .string("[REDACTED]"))
    #expect(fields?["monkey"] == .string("ordinary-value"))
}

@Test func sanitizerRedactsSecretsBeforeClippingLongText() {
    let sanitized = SecretSanitizer.redactText("prefix Bearer \(fixtureJWT) suffix", maximumLength: 20)
    #expect(!sanitized.contains("eyJ"))
    #expect(!sanitized.contains("SflKxw"))
    #expect(sanitized.hasSuffix("…[truncated]"))
}

@Test func localHTTPLogsAuthenticationOriginHostAndProtocolRejections() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audit = try AuditStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let token = "test-only-mcp-token"
    let port = Int.random(in: 43_000...60_000)
    let service = RecordingASCService()
    let host = MCPHost(service: service, audit: audit, token: token, port: port)
    let (readyStream, readyContinuation) = AsyncStream<Void>.makeStream()
    let serverTask = Task {
        try await host.run(onReady: { readyContinuation.yield(()) })
    }
    defer {
        serverTask.cancel()
        readyContinuation.finish()
    }

    let didStart = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = readyStream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(3))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
    #expect(didStart)
    guard didStart else {
        serverTask.cancel()
        _ = try? await serverTask.value
        Issue.record("The local MCP listener did not report ready.")
        return
    }

    let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
    func send(
        method: String = "POST",
        body: String? = nil,
        authorization: String? = "Bearer \(token)",
        origin: String? = nil,
        hostHeader: String? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let hostHeader { request.setValue(hostHeader, forHTTPHeaderField: "Host") }
        if let body { request.httpBody = Data(body.utf8) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    let (_, unauthorizedStatus) = try await send(authorization: "Bearer wrong-secret")
    #expect(unauthorizedStatus == 401)

    let (_, originStatus) = try await send(origin: "https://attacker.invalid")
    #expect(originStatus == 403)

    let (_, hostStatus) = try await send(hostHeader: "attacker.invalid")
    #expect(hostStatus == 421)

    let (_, methodStatus) = try await send(method: "GET")
    #expect(methodStatus == 405)

    let (_, pingStatus) = try await send(
        body: #"{"jsonrpc":"2.0","id":77,"method":"ping"}"#,
        origin: "http://127.0.0.1:\(port)"
    )
    #expect(pingStatus == 200)

    let (_, notificationStatus) = try await send(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    #expect(notificationStatus == 202)

    let (initializeData, initializeStatus) = try await send(body: #"{"jsonrpc":"2.0","id":78,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
    #expect(initializeStatus == 200)
    let decodedInitialize = try JSONDecoder().decode(JSONValue.self, from: initializeData)
    let initializeResponse = try #require(decodedInitialize.objectValue)
    let initializeResult = try #require(initializeResponse["result"]?.objectValue)
    let serverCapabilities = try #require(initializeResult["capabilities"]?.objectValue)
    #expect(serverCapabilities["tools"]?.objectValue != nil)

    let (_, listStatus) = try await send(body: #"{"jsonrpc":"2.0","id":79,"method":"tools/list","params":{}}"#)
    #expect(listStatus == 200)

    let (_, unknownMethodStatus) = try await send(body: #"{"jsonrpc":"2.0","id":80,"method":"unknown/method"}"#)
    #expect(unknownMethodStatus == 200)

    let (_, malformedStatus) = try await send(body: "not-json")
    #expect(malformedStatus == 400)

    let (_, batchStatus) = try await send(body: #"[{"jsonrpc":"2.0","id":81,"method":"ping"}]"#)
    #expect(batchStatus == 400)

    let (_, oversizedStatus) = try await send(body: String(repeating: "x", count: 256 * 1_024 + 1))
    #expect(oversizedStatus == 413)

    let entries = try await audit.recentEntries(limit: 20)
    #expect(entries.count == 12)
    #expect(entries.filter { $0.status == "rejected" }.count == 8)
    #expect(entries.contains { $0.method == "ping" && $0.status == "success" })
    #expect(entries.contains { $0.method == "notifications/initialized" && $0.status == "success" })
    #expect(entries.contains { $0.method == "initialize" && $0.status == "success" })
    #expect(entries.contains { $0.method == "tools/list" && $0.status == "success" })
    #expect(entries.contains { $0.method == "unknown" && $0.status == "rejected" })
    #expect(entries.contains { $0.method == "invalid_json" && $0.status == "rejected" })
    #expect(entries.contains { $0.method == "batch" && $0.status == "rejected" })
    #expect(entries.contains { $0.method == "request_too_large" && $0.status == "rejected" })
    let log = try String(contentsOf: directory.appendingPathComponent("history.jsonl"), encoding: .utf8)
    #expect(!log.contains(token))
    #expect(!log.contains("wrong-secret"))

    await audit.failNextAppendForTesting(afterWritingBytes: 4)
    let (_, auditFailureStatus) = try await send(body: #"{"jsonrpc":"2.0","id":81,"method":"tools/call","params":{"name":"asc_list_apps","arguments":{}}}"#)
    #expect(auditFailureStatus == 503)
    #expect(await service.recordedCalls.isEmpty)
    let afterFailedAudit = try AuditStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    #expect(try await afterFailedAudit.recentEntries().count == 12)

    serverTask.cancel()
    _ = try? await serverTask.value
}

private struct RecordedCall: Sendable {
    let operation: String
    let arguments: [String: JSONValue]
}

private actor RecordingASCService: ASCServing {
    private(set) var recordedCalls: [RecordedCall] = []

    func call(_ operation: ASCOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        recordedCalls.append(RecordedCall(operation: operation.rawValue, arguments: arguments))
        return .object([
            "name": .string(operation.rawValue),
            "apiKey": .string("sensitive-value"),
            "token": .string("Bearer \(fixtureJWT)"),
            "notes": .string("Safe response"),
        ])
    }
}

private struct ThrowingASCService: ASCServing {
    func call(_ operation: ASCOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        throw FixtureASCError()
    }
}

private struct FixtureASCError: LocalizedError {
    var errorDescription: String? {
        "Request failed: Bearer \(fixtureJWT); token=\(fixtureJWT); \(fixturePEM)"
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("BridgeMCPTests-\(UUID().uuidString)", isDirectory: true)
}
