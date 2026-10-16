import Foundation
import MCP
import Hummingbird
import NIOCore
import HTTPTypes
import BridgeCore

public actor MCPHost {
    public static let defaultPort = 43129
    public static let endpointPath = "/mcp"
    private static let maximumBodyBytes = 256 * 1_024
    private static let exchangeTimeoutSeconds = 30
    private static let bodyTimeoutSeconds = 15

    private let service: any ASCServing
    private let audit: AuditStore
    private let token: String
    private let port: Int

    public var endpoint: URL {
        URL(string: "http://127.0.0.1:\(port)\(Self.endpointPath)")!
    }

    public init(service: any ASCServing, audit: AuditStore, token: String, port: Int = MCPHost.defaultPort) {
        self.service = service
        self.audit = audit
        self.token = token
        self.port = port
    }

    /// Runs the loopback HTTP listener until the calling task is cancelled.
    /// `onReady` runs only after Hummingbird has successfully bound its socket.
    public func run(onReady: @Sendable @escaping () async -> Void = {}) async throws {
        guard (1...65_535).contains(port), !token.isEmpty else {
            throw MCPHostError.invalidConfiguration
        }

        let router = Router()
        router.post("/mcp") { [weak self] request, _ in
            guard let self else { return Self.httpResponse(status: 503, text: "Service unavailable.") }
            return await self.receive(request)
        }
        router.get("/mcp") { [weak self] request, _ in
            guard let self else { return Self.httpResponse(status: 503, text: "Service unavailable.") }
            return await self.rejectMethod(request)
        }
        router.delete("/mcp") { [weak self] request, _ in
            guard let self else { return Self.httpResponse(status: 503, text: "Service unavailable.") }
            return await self.rejectMethod(request)
        }

        let app = Application(
            router: router,
            server: .http1(configuration: .init(idleTimeout: .seconds(30))),
            configuration: .init(address: .hostname("127.0.0.1", port: port)),
            onServerRunning: { _ in await onReady() }
        )
        let serverTask = Task { try await app.run() }
        try await withTaskCancellationHandler {
            try await serverTask.value
        } onCancel: {
            serverTask.cancel()
        }
    }

    private func receive(_ request: Request) async -> Response {
        let startedAt = Date()
        let host = request.head.authority
        guard isAllowedHost(host) else {
            return await reject(request: "HTTP POST", status: 421, summary: "Request rejected: host is not allowed.", startedAt: startedAt)
        }
        guard isAllowedOrigin(request.headers[.origin]) else {
            return await reject(request: "HTTP POST", status: 403, summary: "Request rejected: origin is not allowed.", startedAt: startedAt)
        }
        guard bearerTokenMatches(request.headers[.authorization]) else {
            return await reject(request: "HTTP POST", status: 401, summary: "Request rejected: authorization failed.", startedAt: startedAt)
        }

        if let contentLength = request.headers[.contentLength],
           let length = Int(contentLength), length > Self.maximumBodyBytes {
            return await reject(request: "request_too_large", status: 413, summary: "Request body exceeded the size limit.", startedAt: startedAt)
        }

        let bodyBuffer = await withTimeout(seconds: Self.bodyTimeoutSeconds) {
            var mutableRequest = request
            return try? await mutableRequest.collectBody(upTo: Self.maximumBodyBytes)
        }
        guard let bodyBuffer else {
            return await reject(request: "request_body_unavailable", status: 413, summary: "Request body was too large or did not arrive in time.", startedAt: startedAt)
        }
        let body = Data(buffer: bodyBuffer)
        let metadata = RequestMetadata.parse(body)
        if metadata.isBatch {
            do {
                let exchange = try await begin(metadata: metadata, startedAt: startedAt)
                try await exchange.finish(status: "rejected", summary: "JSON-RPC batches are not supported.")
            } catch {
                return Self.httpResponse(status: 503, text: "Audit history is unavailable; request was not dispatched.")
            }
            return Self.httpResponse(status: 400, text: "JSON-RPC batches are not supported.")
        }

        let exchange: AuditExchange
        do {
            exchange = try await begin(metadata: metadata, startedAt: startedAt)
        } catch {
            return Self.httpResponse(status: 503, text: "Audit history is unavailable; request was not dispatched.")
        }

        let requestHeaders = sdkHeaders(from: request, host: host)
        let mcpRequest = MCP.HTTPRequest(method: request.method.rawValue, headers: requestHeaders, body: body, path: Self.endpointPath)
        let pipeline = StandardValidationPipeline(validators: [
            OriginValidator(
                allowedHosts: ["127.0.0.1:\(port)", "localhost:\(port)"],
                allowedOrigins: ["http://127.0.0.1:\(port)", "http://localhost:\(port)"]
            ),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ])
        let transport = StatelessHTTPServerTransport(validationPipeline: pipeline)
        let server = Server(
            name: "ASCBridge",
            version: "0.1.0",
            instructions: "Use the typed App Store Connect tools to inspect apps and manage version metadata.",
            capabilities: .init(tools: .init())
        )

        do {
            try await server.start(transport: transport)
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: ToolCatalog.tools())
            }
            await server.withMethodHandler(CallTool.self) { [service, exchange] parameters in
                let execution = await ToolCatalog.execute(
                    service: service,
                    name: parameters.name,
                    arguments: parameters.arguments
                )
                do {
                    try await exchange.finish(status: execution.status, summary: execution.summary)
                } catch {
                    throw MCPError.internalError(
                        "The App Store Connect request may have completed, but its audit completion could not be saved. Check App Store Connect before retrying."
                    )
                }
                return execution.result
            }
        } catch {
            try? await exchange.finish(status: "error", summary: "MCP server could not start for this request.")
            return Self.httpResponse(status: 500, text: "MCP request could not be processed.")
        }

        let sdkResponse = await withTimeout(seconds: Self.exchangeTimeoutSeconds) {
            await transport.handleRequest(mcpRequest)
        }
        await server.stop()

        guard let sdkResponse else {
            await transport.disconnect()
            do {
                try await exchange.finish(
                    status: "error",
                    summary: "MCP request timed out. A write may have completed; check App Store Connect before retrying."
                )
            } catch {
                return Self.httpResponse(status: 503, text: "The request outcome may be uncertain. Check App Store Connect before retrying.")
            }
            return Self.httpResponse(status: 504, text: "MCP request timed out. Check App Store Connect before retrying.")
        }

        do {
            let outcome = Self.outcome(for: sdkResponse, metadata: metadata)
            try await exchange.finish(status: outcome.status, summary: outcome.summary)
        } catch {
            await transport.disconnect()
            return Self.httpResponse(status: 503, text: "The request outcome may be uncertain because its audit completion could not be saved. Check App Store Connect before retrying.")
        }
        return Self.hummingbirdResponse(for: sdkResponse)
    }

    private func rejectMethod(_ request: Request) async -> Response {
        let startedAt = Date()
        let status = await reject(request: "HTTP \(request.method.rawValue)", status: 405, summary: "Only POST is supported by the stateless MCP endpoint.", startedAt: startedAt)
        var response = status
        response.headers[.allow] = "POST"
        return response
    }

    private func reject(request method: String, status: Int, summary: String, startedAt: Date) async -> Response {
        do {
            let id = try await audit.begin(method: method, startedAt: startedAt)
            try await audit.finish(id: id, status: "rejected", durationMS: max(0, Date().timeIntervalSince(startedAt) * 1_000), summary: summary)
        } catch {
            return Self.httpResponse(status: 503, text: "Audit history is unavailable.")
        }
        return Self.httpResponse(status: status, text: summary)
    }

    private func begin(metadata: RequestMetadata, startedAt: Date) async throws -> AuditExchange {
        let id = try await audit.begin(
            method: metadata.method,
            toolName: metadata.toolName,
            parameters: metadata.parameters,
            requestID: metadata.requestID,
            startedAt: startedAt
        )
        return AuditExchange(id: id, startedAt: startedAt, store: audit)
    }

    private func isAllowedHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let normalized = host.lowercased()
        return normalized == "127.0.0.1:\(port)" || normalized == "localhost:\(port)"
    }

    private func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil,
              components.port == port
        else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    private func bearerTokenMatches(_ header: String?) -> Bool {
        guard let header, let separator = header.firstIndex(of: " ") else { return false }
        let scheme = header[..<separator]
        let candidate = header[header.index(after: separator)...]
        guard scheme.caseInsensitiveCompare("Bearer") == .orderedSame else { return false }
        let left = Array(candidate.utf8)
        let right = Array(token.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private func sdkHeaders(from request: Request, host: String?) -> [String: String] {
        var headers: [String: String] = [:]
        if let host { headers["Host"] = host }
        for (name, field) in [
            ("Origin", HTTPField.Name.origin),
            ("Accept", HTTPField.Name.accept),
            ("Content-Type", HTTPField.Name.contentType),
            ("MCP-Protocol-Version", HTTPField.Name("MCP-Protocol-Version")!),
        ] {
            if let value = request.headers[field] { headers[name] = value }
        }
        return headers
    }

    private static func outcome(for response: MCP.HTTPResponse, metadata: RequestMetadata) -> (status: String, summary: String) {
        if response.statusCode == 202 {
            return ("success", "MCP notification accepted.")
        }
        guard (200..<300).contains(response.statusCode), let data = response.bodyData else {
            return (response.statusCode >= 400 && response.statusCode < 500 ? "rejected" : "error", "MCP request failed with HTTP \(response.statusCode).")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("error", "MCP response could not be interpreted.")
        }
        if object["error"] != nil {
            if metadata.method == "unknown" || metadata.method == "invalid_json" || metadata.method == "invalid_jsonrpc" {
                return ("rejected", "MCP request was rejected by protocol validation.")
            }
            return ("error", "MCP request returned a protocol error.")
        }
        if let result = object["result"] as? [String: Any], (result["isError"] as? Bool) == true {
            return ("error", "MCP tool reported an error.")
        }
        return ("success", "\(metadata.toolName ?? metadata.method) completed successfully.")
    }

    private static func hummingbirdResponse(for response: MCP.HTTPResponse) -> Response {
        var headers = HTTPFields()
        if let contentType = response.headers["Content-Type"] { headers[.contentType] = contentType }
        if let allow = response.headers["Allow"] { headers[.allow] = allow }
        let status = HTTPResponse.Status(code: response.statusCode)
        let body = response.bodyData.map { ResponseBody(byteBuffer: ByteBuffer(data: $0)) } ?? ResponseBody()
        return Response(status: status, headers: headers, body: body)
    }

    private static func httpResponse(status: Int, text: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/plain; charset=utf-8"
        return Response(
            status: HTTPResponse.Status(code: status),
            headers: headers,
            body: ResponseBody(byteBuffer: ByteBuffer(string: SecretSanitizer.redactText(text, maximumLength: 1_000)))
        )
    }
}

private struct RequestMetadata {
    let method: String
    let toolName: String?
    let parameters: JSONValue?
    let requestID: String?
    let isBatch: Bool

    static func parse(_ data: Data) -> RequestMetadata {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return RequestMetadata(method: "invalid_json", toolName: nil, parameters: nil, requestID: nil, isBatch: false)
        }
        guard case .object(let object) = root else {
            let isBatch: Bool
            if case .array = root { isBatch = true } else { isBatch = false }
            return RequestMetadata(method: isBatch ? "batch" : "invalid_jsonrpc", toolName: nil, parameters: nil, requestID: nil, isBatch: isBatch)
        }
        guard object["jsonrpc"]?.stringValue == "2.0",
              let rawMethod = object["method"]?.stringValue
        else {
            return RequestMetadata(method: "invalid_jsonrpc", toolName: nil, parameters: nil, requestID: safeRequestID(object["id"]), isBatch: false)
        }

        let knownMethods: Set<String> = ["initialize", "ping", "tools/list", "tools/call", "notifications/initialized", "notifications/cancelled"]
        let method = knownMethods.contains(rawMethod) ? rawMethod : "unknown"
        let params = object["params"]?.objectValue ?? [:]
        let rawTool = method == "tools/call" ? params["name"]?.stringValue : nil
        let toolName = rawTool.flatMap { SecretSanitizer.safeIdentifier($0, maximumLength: 100) }
        let arguments = method == "tools/call" ? params["arguments"] : nil
        let sanitizedParameters = method == "tools/call" ? ToolCatalog.safeAuditParameters(toolName: toolName, raw: arguments) : nil
        return RequestMetadata(
            method: method,
            toolName: toolName,
            parameters: sanitizedParameters,
            requestID: safeRequestID(object["id"]),
            isBatch: false
        )
    }

    private static func safeRequestID(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let string): SecretSanitizer.safeIdentifier(string, maximumLength: 128)
        case .number(let number) where number.isFinite: String(number)
        default: nil
        }
    }
}

private actor AuditExchange {
    private let id: UUID
    private let startedAt: Date
    private let store: AuditStore
    private var isFinished = false

    init(id: UUID, startedAt: Date, store: AuditStore) {
        self.id = id
        self.startedAt = startedAt
        self.store = store
    }

    func finish(status: String, summary: String) async throws {
        guard !isFinished else { return }
        isFinished = true
        let duration = max(0, Date().timeIntervalSince(startedAt) * 1_000)
        try await store.finish(id: id, status: status, durationMS: duration, summary: summary)
    }
}

private enum MCPHostError: Error {
    case invalidConfiguration
}

private final class TimeoutLatch<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var resolved = false
    private var timer: Task<Void, Never>?

    init(continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func install(timer: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            timer.cancel()
        } else {
            self.timer = timer
            lock.unlock()
        }
    }

    @discardableResult
    func resolve(_ value: Value?) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: value)
        return true
    }
}

private func withTimeout<Value: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async -> Value?
) async -> Value? {
    await withCheckedContinuation { continuation in
        let latch = TimeoutLatch<Value>(continuation: continuation)
        let operationTask = Task {
            let value = await operation()
            latch.resolve(value)
        }
        let timerTask = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            if latch.resolve(nil) { operationTask.cancel() }
        }
        latch.install(timer: timerTask)
    }
}
