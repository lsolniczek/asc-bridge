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
            case .starting: "Uruchamianie"
            case .running: "MCP działa lokalnie"
            case .failed: "MCP niedostępne"
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
                    self.serverError = "Serwer MCP został zatrzymany. Uruchom aplikację ponownie."
                } catch is CancellationError {
                    // Normal process shutdown.
                } catch {
                    self.serverState = .failed
                    self.serverError = "Nie można uruchomić MCP. Sprawdź, czy inna kopia aplikacji nie używa portu 43129, i uruchom aplikację ponownie."
                }
            }
        } catch {
            serverState = .failed
            serverError = "Nie można przygotować historii lub tokenu połączenia MCP. \(error.localizedDescription)"
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
        panel.title = "Wybierz klucz zespołu App Store Connect (.p8)"
        panel.prompt = "Wybierz klucz"
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
                throw BridgeError.invalidInput("Wybierz poprawny klucz prywatny .p8 pobrany z App Store Connect.")
            }
            importedPEM = pem
            importedFileName = url.lastPathComponent
            showNotice("Plik wybrany. Uzupełnij identyfikatory i zapisz klucz w Keychain.")
        } catch {
            showNotice("Nie można wczytać klucza .p8. Sprawdź plik i jego uprawnienia.", isError: true)
        }
    }

    func saveCredentials() async {
        guard let pem = importedPEM else {
            showNotice("Najpierw wybierz plik .p8.", isError: true)
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
            showNotice("Klucz zapisany w Keychain. Możesz przetestować połączenie z Apple.")
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
            showNotice("Klucz usunięty z Keychain. Narzędzia MCP nie mają już dostępu do ASC.")
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    func testConnection() async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.call(.listApps, arguments: ["limit": .number(1)])
            showNotice("Połączenie z App Store Connect działa. Zapisany klucz jest poprawny.")
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
        showNotice("Konfiguracja skopiowana. Dodaj ją do pliku ~/.codex/config.toml.")
    }

    func refreshHistory() async {
        guard let audit else { return }
        do {
            entries = try await audit.recentEntries(limit: 500)
            historyError = nil
        } catch {
            historyError = "Nie można odczytać historii MCP."
        }
    }

    func revealHistory() { NSWorkspace.shared.activateFileViewerSelecting([historyURL]) }

    private func serverDidStart() { serverState = .running }

    private func showNotice(_ message: String, isError: Bool = false) {
        notice = message
        noticeIsError = isError
    }
}
