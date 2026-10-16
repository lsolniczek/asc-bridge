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
                        Text("Historia MCP").font(.system(size: 27, weight: .semibold))
                        Text("Ostatnie 500 wywołań. Pełna historia jest zapisana na tym Macu.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.revealHistory() } label: { Image(systemName: "folder") }
                        .help("Pokaż plik historii w Finderze")
                    Button { Task { await model.refreshHistory() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Odśwież historię")
                }
                TextField("Szukaj narzędzia, metody lub wyniku", text: $search).textFieldStyle(.roundedBorder)
                if let error = model.historyError {
                    Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                }
            }
            .padding(24)
            Divider()
            if model.entries.isEmpty {
                ContentUnavailableView("Historia jest pusta", systemImage: "clock.arrow.circlepath",
                    description: Text("Podłącz agenta. Tutaj pojawią się wywołania narzędzi, błędy i pozostałe żądania MCP."))
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
                        ContentUnavailableView("Wybierz wywołanie", systemImage: "text.alignleft",
                            description: Text("Zobaczysz parametry, czas wykonania i wynik."))
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
                    if let duration = entry.durationMS { Text("\(Int(duration)) ms") }
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
                Label(statusLabel(entry.status), systemImage: statusSymbol(entry.status)).foregroundStyle(statusColor(entry.status))
                LabeledContent("Czas", value: entry.startedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Metoda", value: entry.method)
                if let requestID = entry.requestID { LabeledContent("ID żądania", value: requestID) }
                if let duration = entry.durationMS { LabeledContent("Czas wykonania", value: "\(Int(duration)) ms") }
                if entry.status == "pending" {
                    Text("Brak zapisanego zakończenia. Wywołanie może być w toku lub zostało przerwane. Przed powtórzeniem zmiany sprawdź stan w ASC.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let summary = entry.summary {
                    Divider()
                    Text("Wynik").font(.subheadline.weight(.semibold))
                    Text(summary).font(.callout).textSelection(.enabled)
                }
                Divider()
                Text("Parametry").font(.subheadline.weight(.semibold))
                Text((try? entry.parameters?.encodedString(pretty: true)) ?? "Brak parametrów")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
    }
}

private func statusLabel(_ status: String) -> String {
    switch status {
    case "success": "Wykonano"
    case "error": "Błąd"
    case "rejected": "Odrzucono"
    default: "W toku / brak zakończenia"
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
