import SwiftUI
import HypoCore

public struct HistoryListView: View {
    @ObservedObject private var viewModel: HistoryListViewModel

    public init(viewModel: HistoryListViewModel) {
        self.viewModel = viewModel
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
            .task { await viewModel.load() }
        }
    }
}
