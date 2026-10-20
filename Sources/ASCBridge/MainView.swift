import BridgeMCP
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var selection: Section? = .connection

    private enum Section: Hashable { case connection, history }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Image(systemName: "app.connected.to.app.below.fill")
                        .font(.system(size: 27)).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ASC Bridge", bundle: .module).font(.headline)
                        Text("Apple ↔ your agent", bundle: .module).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 20)
                List(selection: $selection) {
                    Label { Text("Connection", bundle: .module) } icon: { Image(systemName: "key.horizontal") }
                        .tag(Section.connection)
                    Label { Text("MCP History", bundle: .module) } icon: { Image(systemName: "clock.arrow.circlepath") }
                        .tag(Section.history)
                }
                .listStyle(.sidebar)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    Label { Text(model.serverState.label) } icon: {
                        Image(systemName: model.serverState == .running ? "circle.fill" : "circle")
                    }
                    .font(.caption).foregroundStyle(model.serverState == .running ? .green : .secondary)
                    Text("Running on this Mac", bundle: .module)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } detail: {
            if selection == .history { HistoryView(model: model) }
            else { ConnectionView(model: model) }
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
                    Text("App Store Connect for your agent", bundle: .module)
                        .font(.system(size: 27, weight: .semibold))
                    Text("Give your agent access to app metadata, builds, TestFlight, and reviews.", bundle: .module)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    statusCard(
                        title: String(localized: "Apple Key", bundle: .module, comment: "Status card title for the App Store Connect API key."),
                        value: model.hasCredentials
                            ? String(localized: "Saved in Keychain", bundle: .module, comment: "Status shown when credentials are saved.")
                            : String(localized: "Waiting for a key", bundle: .module, comment: "Status shown when credentials have not been added."),
                        symbol: model.hasCredentials ? "checkmark.shield.fill" : "key.fill",
                        color: model.hasCredentials ? .green : .orange
                    )
                    statusCard(
                        title: String(localized: "MCP Connection", bundle: .module, comment: "Status card title for the local MCP server."),
                        value: model.serverState.label,
                        symbol: "network", color: model.serverState == .running ? .blue : .secondary
                    )
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("App Store Connect team key", bundle: .module).font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                            GridRow {
                                Text("Key ID", bundle: .module).foregroundStyle(.secondary)
                                TextField(text: $model.keyID, prompt: Text(verbatim: "ABC123DE45")) {
                                    Text("Key ID", bundle: .module)
                                }
                                    .labelsHidden().textFieldStyle(.roundedBorder)
                                    .accessibilityLabel(Text("Key ID", bundle: .module))
                            }
                            GridRow {
                                Text("Issuer ID", bundle: .module).foregroundStyle(.secondary)
                                TextField(text: $model.issuerID, prompt: Text("Issuer ID from App Store Connect", bundle: .module)) {
                                    Text("Issuer ID", bundle: .module)
                                }
                                .labelsHidden().textFieldStyle(.roundedBorder)
                                .accessibilityLabel(Text("Issuer ID", bundle: .module))
                            }
                            GridRow {
                                Text("Private Key (.p8)", bundle: .module).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Button { model.importKey() } label: { Text("Choose File…", bundle: .module) }
                                    Text(model.importedFileName ?? (model.hasCredentials
                                        ? String(localized: "Key is already saved", bundle: .module, comment: "Shown when a key is saved and no new key file is selected.")
                                        : String(localized: "No file selected", bundle: .module, comment: "Shown before a key file is selected.")))
                                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        HStack(spacing: 12) {
                            Button { Task { await model.saveCredentials() } } label: {
                                Text("Save to Keychain", bundle: .module)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.importedFileName == nil || model.isBusy)
                            Button { Task { await model.testConnection() } } label: {
                                Text("Test saved key", bundle: .module)
                            }
                            .disabled(!model.hasCredentials || model.isBusy)
                            Spacer()
                            if model.hasCredentials {
                                Button(role: .destructive) { Task { await model.deleteCredentials() } } label: {
                                    Text("Delete Key", bundle: .module)
                                }
                                .disabled(model.isBusy)
                            }
                            if model.isBusy { ProgressView().controlSize(.small) }
                        }
                        Text("Your private key and Apple tokens stay in this app. They are never shared with your agent.", bundle: .module)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Connect your agent with MCP", bundle: .module).font(.headline)
                        Text(model.endpoint).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text("Copy this configuration to ~/.codex/config.toml. It contains a separate MCP token; the Apple key stays in Keychain. For another MCP client, use the same URL and Authorization header.", bundle: .module)
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button { model.copyConfiguration() } label: {
                            Label { Text("Copy Codex configuration", bundle: .module) } icon: { Image(systemName: "doc.on.doc") }
                        }
                        .disabled(model.serverState != .running)
                        Divider()
                        Text("Your agent can manage app metadata, versions, localizations, builds, and TestFlight testing details, and read reviews or post public replies. Changes take effect immediately, with no in-app confirmation. Review replies are visible to customers. Every MCP request appears in History.", bundle: .module)
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                }
                if let error = model.serverError {
                    Label { Text(error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .foregroundStyle(.red).font(.callout)
                }
            }
            .padding(32).frame(maxWidth: 900, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if let message = model.notice {
                Label { Text(message) } icon: {
                    Image(systemName: model.noticeIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                }
                .foregroundStyle(model.noticeIsError ? .red : .green)
                .font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).background(.bar)
            }
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
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
