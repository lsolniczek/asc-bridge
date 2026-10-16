import Foundation
import Darwin
import BridgeCore

public struct AuditEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let method: String
    public let toolName: String?
    public let parameters: JSONValue?
    public let requestID: String?
    public var status: String
    public var durationMS: Double?
    public var summary: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        method: String,
        toolName: String? = nil,
        parameters: JSONValue? = nil,
        requestID: String? = nil,
        status: String = "pending",
        durationMS: Double? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.method = method
        self.toolName = toolName
        self.parameters = parameters
        self.requestID = requestID
        self.status = status
        self.durationMS = durationMS
        self.summary = summary
    }
}

/// Append-only, owner-only JSONL history for MCP requests.
public actor AuditStore {
    private let fileURL: URL
    private var fileDescriptor: Int32 = -1
    private var entriesByID: [UUID: AuditEntry] = [:]
    private var entryOrder: [UUID] = []
    private var injectedFailureAfterBytes: Int?

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        try Self.prepareStorage(at: fileURL)
        let recovered = try Self.recoverEntries(at: fileURL)
        self.entriesByID = recovered.entriesByID
        self.entryOrder = recovered.entryOrder
        let descriptor = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.storageError() }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            Darwin.close(descriptor)
            throw Self.storageError()
        }
        self.fileDescriptor = descriptor
    }

    deinit {
        if fileDescriptor >= 0 { Darwin.close(fileDescriptor) }
    }

    /// Starts a durable audit record. Call this before dispatching the request.
    @discardableResult
    public func begin(
        method: String,
        toolName: String? = nil,
        parameters: JSONValue? = nil,
        requestID: String? = nil,
        startedAt: Date = Date()
    ) throws -> UUID {
        let entry = AuditEntry(
            startedAt: startedAt,
            method: SecretSanitizer.safeIdentifier(method, maximumLength: 80) ?? "unknown",
            toolName: toolName.flatMap { SecretSanitizer.safeIdentifier($0, maximumLength: 100) },
            parameters: parameters.map { SecretSanitizer.redact($0) },
            requestID: requestID.flatMap { SecretSanitizer.safeIdentifier($0, maximumLength: 128) }
        )
        try append(entry)
        return entry.id
    }

    /// Adds the final snapshot for an existing request. The initial pending snapshot remains
    /// in the file, so an interrupted write can be identified after restart.
    public func finish(
        id: UUID,
        status: String,
        durationMS: Double?,
        summary: String?
    ) throws {
        guard var entry = entriesByID[id], entry.status == "pending" else { return }
        let finalStatus = ["success", "error", "rejected"].contains(status) ? status : "error"
        entry.status = finalStatus
        entry.durationMS = durationMS.flatMap { $0.isFinite ? max(0, $0) : nil }
        entry.summary = summary.map { SecretSanitizer.redactText($0, maximumLength: 1_000) }
        try append(entry)
    }

    /// Returns the newest records first. Persistent history is never truncated.
    public func recentEntries(limit: Int = 500) throws -> [AuditEntry] {
        guard limit > 0 else { return [] }
        let boundedLimit = min(limit, 500)
        return entryOrder.reversed().prefix(boundedLimit).compactMap { entriesByID[$0] }
    }

    /// Test seam for verifying that a torn write poisons this store until recovery on restart.
    func failNextAppendForTesting(afterWritingBytes count: Int) {
        injectedFailureAfterBytes = max(0, count)
    }

    private func append(_ entry: AuditEntry) throws {
        guard fileDescriptor >= 0 else { throw Self.storageError() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        var failureBytesRemaining = injectedFailureAfterBytes
        injectedFailureAfterBytes = nil
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    if failureBytesRemaining == 0 { throw Self.storageError() }
                    let remaining = rawBuffer.count - written
                    let writeLength = failureBytesRemaining.map { min(remaining, $0) } ?? remaining
                    let count = Darwin.write(fileDescriptor, baseAddress.advanced(by: written), writeLength)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Self.storageError() }
                    written += count
                    if let remaining = failureBytesRemaining {
                        failureBytesRemaining = remaining - count
                    }
                }
            }
            guard Darwin.fsync(fileDescriptor) == 0 else { throw Self.storageError() }
        } catch {
            poison()
            throw error
        }
        if entriesByID[entry.id] == nil { entryOrder.append(entry.id) }
        entriesByID[entry.id] = entry
    }

    private func poison() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }

    private static func recoverEntries(at fileURL: URL) throws -> (entriesByID: [UUID: AuditEntry], entryOrder: [UUID]) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([:], []) }
        let data = try Data(contentsOf: fileURL)
        let validByteCount: Int
        if data.last == 0x0A {
            validByteCount = data.count
        } else if let newline = data.lastIndex(of: 0x0A) {
            validByteCount = newline + 1
        } else {
            validByteCount = 0
        }

        if validByteCount != data.count {
            let descriptor = Darwin.open(fileURL.path, O_WRONLY)
            guard descriptor >= 0 else { throw Self.storageError() }
            let truncateResult = Darwin.ftruncate(descriptor, off_t(validByteCount))
            let syncResult = truncateResult == 0 ? Darwin.fsync(descriptor) : -1
            Darwin.close(descriptor)
            guard truncateResult == 0, syncResult == 0 else { throw Self.storageError() }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var recovered: [UUID: AuditEntry] = [:]
        var order: [UUID] = []
        var lineStart = 0
        while lineStart < validByteCount {
            guard let newline = data[lineStart..<validByteCount].firstIndex(of: 0x0A) else { break }
            let line = Data(data[lineStart..<newline])
            guard !line.isEmpty, let entry = try? decoder.decode(AuditEntry.self, from: line) else {
                throw Self.corruptHistoryError()
            }
            if recovered[entry.id] == nil { order.append(entry.id) }
            recovered[entry.id] = entry
            lineStart = newline + 1
        }
        return (recovered, order)
    }

    private static func prepareStorage(at fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        guard Darwin.chmod(directory.path, mode_t(S_IRWXU)) == 0 else { throw storageError() }

        let descriptor = Darwin.open(fileURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw storageError() }
        let chmodResult = Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))
        Darwin.close(descriptor)
        guard chmodResult == 0 else { throw storageError() }
    }

    private static func storageError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: "MCP audit storage"])
    }

    private static func corruptHistoryError() -> NSError {
        NSError(
            domain: "ASCBridge.AuditStore",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "MCP audit history contains an invalid complete record."]
        )
    }
}
