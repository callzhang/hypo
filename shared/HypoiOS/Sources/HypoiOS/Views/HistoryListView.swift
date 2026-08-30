import SwiftUI
import HypoCore

public struct HistoryListView: View {
    @ObservedObject private var viewModel: HistoryListViewModel

    public init(viewModel: HistoryListViewModel) {
        self.viewModel = viewModel
    }

    /// Says what became of the last send. Entries are written to local history
    /// either way, so without this a send that reached nobody would look
    /// exactly like one that worked.
    private var sendStatusMessage: String? {
        switch viewModel.lastSendOutcome {
        case .none:
            return nil
        case .notConfigured:
            return "Not connected yet"
        case .noPairedDevices:
            return "No paired devices — pair one first"
        case .sent(let count):
            return "Sent to \(count) device\(count == 1 ? "" : "s")"
        case .allFailed(let count):
            return "Could not reach \(count) device\(count == 1 ? "" : "s")"
        case .partial(let sent, let failed):
            return "Sent to \(sent), failed for \(failed)"
        }
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.visibleEntries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.content.previewDescription)
                            .lineLimit(2)
                        Text(entry.originDeviceName ?? entry.deviceId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await viewModel.remove(id: entry.id) }
                        }
                        Button(entry.isPinned ? "Unpin" : "Pin") {
                            Task { await viewModel.togglePin(id: entry.id) }
                        }
                    }
                }
            }
            .overlay {
                if viewModel.visibleEntries.isEmpty {
                    ContentUnavailableView(
                        viewModel.searchText.isEmpty ? "No history yet" : "No matches",
                        systemImage: viewModel.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass"
                    )
                }
            }
            .searchable(text: $viewModel.searchText)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        Task { await viewModel.clearAll() }
                    }
                    .disabled(viewModel.entries.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if let message = sendStatusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // The system paste button is the only way to read the
                    // clipboard on iOS without interrupting the user with a
                    // permission prompt, so sending starts here rather than
                    // from a poll the way Android does it. Its label is drawn
                    // by the system and cannot be changed, so the caption below
                    // has to carry the meaning.
                    PasteButton { text in
                        Task { await viewModel.sendText(text) }
                    }
                    Text("Send what you copied to your other devices")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .task { await viewModel.load() }
        }
    }
}
