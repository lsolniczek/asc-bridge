import BridgeMCP
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var selection: Section = .connection

    private enum Section: Hashable { case connection, history }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "app.connected.to.app.below.fill")
                        .font(.system(size: 27)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ASC Bridge").font(.headline)
                        Text("Apple ↔ Twój agent").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 20)
                List(selection: $selection) {
                    Label("Połączenie", systemImage: "key.horizontal").tag(Section.connection)
                    Label("Historia MCP", systemImage: "clock.arrow.circlepath").tag(Section.history)
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    Label(model.serverState.label, systemImage: model.serverState == .running ? "circle.fill" : "circle")
                        .font(.caption).foregroundStyle(model.serverState == .running ? .green : .secondary)
                    Text("Działa na tym Macu")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            switch selection {
            case .connection: ConnectionView(model: model)
            case .history: HistoryView(model: model)
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshHistory()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

struct ConnectionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("App Store Connect dla Twojego agenta")
                        .font(.system(size: 27, weight: .semibold))
                    Text("Dodaj klucz zespołu. Agent otrzyma narzędzia do wersji i tekstów w App Store.")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    statusCard(title: "Klucz Apple", value: model.hasCredentials ? "Zapisany w Keychain" : "Czeka na dodanie",
                               symbol: model.hasCredentials ? "checkmark.shield.fill" : "key.fill",
                               color: model.hasCredentials ? .green : .orange)
                    statusCard(title: "Połączenie MCP", value: model.serverState.label,
                               symbol: "network", color: model.serverState == .running ? .blue : .secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Klucz zespołu").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            GridRow {
                                Text("Key ID").foregroundStyle(.secondary)
                                TextField("ABC123DE45", text: $model.keyID).textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Issuer ID").foregroundStyle(.secondary)
                                TextField("Identyfikator wystawcy z ASC", text: $model.issuerID).textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Klucz .p8").foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Button("Wybierz plik…", action: model.importKey)
                                    Text(model.importedFileName ?? (model.hasCredentials ? "Klucz jest już zapisany" : "Nie wybrano pliku"))
                                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Zapisz w Keychain") { Task { await model.saveCredentials() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.importedFileName == nil || model.isBusy)
                            Button("Testuj zapisany klucz") { Task { await model.testConnection() } }
                                .disabled(!model.hasCredentials || model.isBusy)
                            Spacer()
                            if model.hasCredentials {
                                Button("Usuń klucz", role: .destructive) { Task { await model.deleteCredentials() } }
                                    .disabled(model.isBusy)
                            }
                            if model.isBusy { ProgressView().controlSize(.small) }
                        }
                        Text("Klucz prywatny i tokeny Apple pozostają w aplikacji. Nie są przekazywane agentowi.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Podłącz agenta przez MCP").font(.headline)
                        Text(model.endpoint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text("Skopiuj konfigurację do ~/.codex/config.toml. Zawiera osobny token MCP; klucz Apple pozostaje w Keychain. W innym kliencie MCP użyj tego samego adresu i nagłówka Authorization.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { model.copyConfiguration() } label: {
                            Label("Skopiuj konfigurację Codexa", systemImage: "doc.on.doc")
                        }
                        .disabled(model.serverState != .running)
                        Divider()
                        Text("Agent może tworzyć wersje oraz dodawać i zmieniać opisy, „Co nowego” i tekst promocyjny. Zmiany wykonują się od razu. Wszystkie wywołania MCP zobaczysz w historii.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                }
                if let message = model.notice {
                    Label(message, systemImage: model.noticeIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.noticeIsError ? .red : .green)
                        .font(.callout).textSelection(.enabled)
                }
                if let error = model.serverError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
            }
            .padding(32).frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func statusCard(title: String, value: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.weight(.medium))
            }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }
}
