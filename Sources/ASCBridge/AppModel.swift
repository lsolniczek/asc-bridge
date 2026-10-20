import AppKit
import BridgeCore
import BridgeMCP
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum ServerState: Equatable {
        case starting, running, failed
        var label: String {
            switch self {
            case .starting: String(localized: "Starting", bundle: .module, comment: "Local MCP server status.")
            case .running: String(localized: "MCP running locally", bundle: .module, comment: "Local MCP server status.")
            case .failed: String(localized: "MCP unavailable", bundle: .module, comment: "Local MCP server status.")
            }
        }
    }

    @Published var keyID = ""
    @Published var issuerID = ""
    @Published private(set) var hasCredentials = false
    @Published private(set) var importedFileName: String?
    @Published private(set) var isBusy = false
    @Published private(set) var notice: String?
    @Published private(set) var noticeIsError = false
    @Published private(set) var serverState: ServerState = .starting
    @Published private(set) var serverError: String?
    @Published private(set) var entries: [AuditEntry] = []
    @Published private(set) var historyError: String?

    let endpoint = "http://127.0.0.1:43129/mcp"
    let historyURL: URL

    private let credentials = KeychainCredentialStore()
    private let tokenStore = KeychainMCPTokenStore()
    private lazy var client = ASCClient(credentials: credentials)
    private var importedPEM: String?
    private var mcpToken: String?
    private var audit: AuditStore?
    private var serverTask: Task<Void, Never>?
    private var started = false

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        historyURL = support.appendingPathComponent("ASCBridge", isDirectory: true).appendingPathComponent("history.jsonl")
    }

    func start() async {
        guard !started else { return }
        started = true
        // Start the local listener even before an ASC key is imported. Tools will
        // return credentialsMissing until the user saves a valid team key.
        do {
            let store = try AuditStore(fileURL: historyURL)
            audit = store
            let token = try await tokenStore.loadOrCreate()
            mcpToken = token
            let host = MCPHost(service: client, audit: store, token: token)
            serverTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await host.run {
                        await self.serverDidStart()
                    }
                    self.serverState = .failed
                    self.serverError = String(localized: "The MCP server stopped. Restart the app.", bundle: .module, comment: "Error shown if the local MCP server stops unexpectedly.")
                } catch is CancellationError {
                    // Normal process shutdown.
                } catch {
                    self.serverState = .failed
                    self.serverError = String(localized: "Could not start MCP. Check whether another copy of the app is using port 43129, then restart the app.", bundle: .module, comment: "Error shown when the local MCP server cannot start.")
                }
            }
        } catch {
            serverState = .failed
            serverError = String(localized: "Could not prepare MCP history or the connection token. \(error.localizedDescription)", bundle: .module, comment: "Error shown when startup cannot prepare the local MCP history or token. The underlying safe error is included.")
        }
        do {
            if let stored = try await credentials.load() {
                keyID = stored.keyID
                issuerID = stored.issuerID
                hasCredentials = true
            }
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
        await refreshHistory()
    }

    func importKey() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an App Store Connect team key (.p8)", bundle: .module, comment: "Title of the key-file picker.")
        panel.prompt = String(localized: "Choose Key", bundle: .module, comment: "Action button in the key-file picker.")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let bytes = try file.read(upToCount: 65_537) ?? Data()
            guard bytes.count <= 65_536, let pem = String(data: bytes, encoding: .utf8),
                  pem.contains("-----BEGIN PRIVATE KEY-----") else {
                throw BridgeError.invalidInput(String(localized: "Choose a valid .p8 private key downloaded from App Store Connect.", bundle: .module, comment: "Validation error shown when the selected file is not a valid App Store Connect private key."))
            }
            importedPEM = pem
            importedFileName = url.lastPathComponent
            showNotice(String(localized: "File selected. Enter the IDs and save the key to Keychain.", bundle: .module, comment: "Notice shown after the user selects a key file."))
        } catch {
            showNotice(String(localized: "Could not read the .p8 key. Check the file and its permissions.", bundle: .module, comment: "Error shown when the selected key file cannot be read."), isError: true)
        }
    }

    func saveCredentials() async {
        guard let pem = importedPEM else {
            showNotice(String(localized: "Choose a .p8 file first.", bundle: .module, comment: "Error shown when saving before selecting a key file."), isError: true)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let value = TeamCredentials(
                keyID: keyID.trimmingCharacters(in: .whitespacesAndNewlines),
                issuerID: issuerID.trimmingCharacters(in: .whitespacesAndNewlines),
                privateKeyPEM: pem
            )
            try ASCClient.validate(value)
            try await credentials.save(value)
            keyID = value.keyID
            issuerID = value.issuerID
            hasCredentials = true
            importedPEM = nil
            importedFileName = nil
            showNotice(String(localized: "Key saved to Keychain. You can test the connection to Apple.", bundle: .module, comment: "Notice shown after credentials are saved."))
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    func deleteCredentials() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await credentials.delete()
            keyID = ""
            issuerID = ""
            importedPEM = nil
            importedFileName = nil
            hasCredentials = false
            showNotice(String(localized: "Key deleted from Keychain. MCP tools no longer have access to App Store Connect.", bundle: .module, comment: "Notice shown after credentials are deleted."))
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    func testConnection() async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.call(.listApps, arguments: ["limit": .number(1)])
            showNotice(String(localized: "App Store Connect connection is working. The saved key is valid.", bundle: .module, comment: "Notice shown after a successful connection test."))
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    func copyConfiguration() {
        guard let token = mcpToken else { return }
        let configuration = """
        [mcp_servers.asc_bridge]
        url = "\(endpoint)"
        http_headers = { Authorization = "Bearer \(token)" }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration, forType: .string)
        showNotice(String(localized: "Configuration copied. Add it to ~/.codex/config.toml.", bundle: .module, comment: "Notice shown after copying the Codex MCP configuration."))
    }

    func refreshHistory() async {
        guard let audit else { return }
        do {
            entries = try await audit.recentEntries(limit: 500)
            historyError = nil
        } catch {
            historyError = String(localized: "Could not read MCP history.", bundle: .module, comment: "Error shown when the local MCP history cannot be read.")
        }
    }

    func revealHistory() { NSWorkspace.shared.activateFileViewerSelecting([historyURL]) }

    private func serverDidStart() { serverState = .running }

    private func showNotice(_ message: String, isError: Bool = false) {
        notice = message
        noticeIsError = isError
    }
}
