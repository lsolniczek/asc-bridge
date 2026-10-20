import BridgeMCP
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var selection: UUID?
    @State private var search = ""

    private var filteredEntries: [AuditEntry] {
        guard !search.isEmpty else { return model.entries }
        return model.entries.filter {
            [$0.method, $0.toolName ?? "", $0.summary ?? ""].joined(separator: " ")
                .localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MCP History", bundle: .module).font(.system(size: 27, weight: .semibold))
                        Text("Showing the last 500 calls. Full history is saved on this Mac.", bundle: .module)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.revealHistory() } label: { Image(systemName: "folder") }
                        .help(Text("Show history file in Finder", bundle: .module))
                    Button { Task { await model.refreshHistory() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(Text("Refresh history", bundle: .module))
                }
                TextField(text: $search, prompt: Text("Search tools, methods, or results", bundle: .module)) {
                    Text("Search tools, methods, or results", bundle: .module)
                }
                .textFieldStyle(.roundedBorder)
                if let error = model.historyError {
                    Label { Text(error) } icon: { Image(systemName: "exclamationmark.circle") }
                        .font(.callout).foregroundStyle(.red)
                }
            }
            .padding(24)
            Divider()
            if model.entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "No history yet", bundle: .module, comment: "Empty-state title shown before any MCP requests are recorded."),
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Connect an agent to see tool calls, errors, and other MCP requests here.", bundle: .module)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(filteredEntries) { entry in
                            HistoryRow(entry: entry).tag(entry.id)
                        }
                    }
                    .frame(minWidth: 260, idealWidth: 340)
                    if let entry = model.entries.first(where: { $0.id == selection }) {
                        HistoryDetail(entry: entry).frame(minWidth: 260, maxWidth: .infinity)
                    } else {
                        ContentUnavailableView(
                            String(localized: "Select a request", bundle: .module, comment: "Empty-state title shown until a history entry is selected."),
                            systemImage: "text.alignleft",
                            description: Text("View its parameters, duration, and result.", bundle: .module)
                        )
                        .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: AuditEntry
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol(entry.status)).foregroundStyle(statusColor(entry.status)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.toolName ?? entry.method).font(.system(.callout, design: .monospaced)).lineLimit(1)
                HStack {
                    Text(entry.startedAt, format: .dateTime.day().month().hour().minute().second())
                    Spacer()
                    if let duration = entry.durationMS {
                        Text(String(localized: "\(Int(duration)) ms", bundle: .module, comment: "Elapsed time in milliseconds, shown in a history row."))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct HistoryDetail: View {
    let entry: AuditEntry
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(entry.toolName ?? entry.method).font(.headline).textSelection(.enabled)
                Label { Text(statusLabel(entry.status)) } icon: {
                    Image(systemName: statusSymbol(entry.status))
                }
                .foregroundStyle(statusColor(entry.status))
                LabeledContent {
                    Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                } label: { Text("Time", bundle: .module) }
                LabeledContent {
                    Text(entry.method)
                } label: { Text("Method", bundle: .module) }
                if let requestID = entry.requestID {
                    LabeledContent { Text(requestID) } label: { Text("Request ID", bundle: .module) }
                }
                if let duration = entry.durationMS {
                    LabeledContent {
                        Text(String(localized: "\(Int(duration)) ms", bundle: .module, comment: "Elapsed time in milliseconds, shown in request details."))
                    } label: { Text("Duration", bundle: .module) }
                }
                if entry.status == "pending" {
                    Text("No completion was recorded. The request may still be running or may have been interrupted. Check its status in App Store Connect before repeating a change.", bundle: .module)
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let summary = entry.summary {
                    Divider()
                    Text("Result", bundle: .module).font(.subheadline.weight(.semibold))
                    Text(summary).font(.callout).textSelection(.enabled)
                }
                Divider()
                Text("Parameters", bundle: .module).font(.subheadline.weight(.semibold))
                Text((try? entry.parameters?.encodedString(pretty: true)) ?? String(localized: "No parameters", bundle: .module, comment: "Shown when a history request has no recorded parameters."))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
    }
}

private func statusLabel(_ status: String) -> String {
    switch status {
    case "success": String(localized: "Completed", bundle: .module, comment: "MCP request status label.")
    case "error": String(localized: "Error", bundle: .module, comment: "MCP request status label.")
    case "rejected": String(localized: "Rejected", bundle: .module, comment: "MCP request status label.")
    default: String(localized: "Pending or incomplete", bundle: .module, comment: "MCP request status label for a request without a recorded completion.")
    }
}

private func statusSymbol(_ status: String) -> String {
    switch status {
    case "success": "checkmark.circle.fill"
    case "error", "rejected": "exclamationmark.circle.fill"
    default: "clock"
    }
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "success": .green
    case "error", "rejected": .red
    default: .orange
    }
}
