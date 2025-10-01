#if canImport(SwiftUI)
import SwiftUI

@main
struct HypoMenuBarApp: App {
    @StateObject private var viewModel = ClipboardHistoryViewModel()

    var body: some Scene {
        MenuBarExtra("Hypo", systemImage: "rectangle.portrait.on.rectangle") {
            HistoryListView(viewModel: viewModel)
                .frame(width: 320, height: 420)
                .environmentObject(viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct HistoryListView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @State private var search = ""

    var filteredItems: [ClipboardEntry] {
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return viewModel.items
        }
        return viewModel.items.filter { $0.matches(query: search) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button(action: viewModel.clearHistory) {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("Clear clipboard history")
                .disabled(viewModel.items.isEmpty)
            }

            List(filteredItems) { item in
                ClipboardRow(item: item)
            }
            .listStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.start()
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardEntry

    var subtitle: String {
        switch item.content {
        case .text(let value):
            return value
        case .link(let url):
            return url.absoluteString
        case .image(let metadata):
            return "Image (\(metadata.pixelSize.width)x\(metadata.pixelSize.height))"
        case .file(let metadata):
            return "File · \(metadata.fileName)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: item.content.iconName)
                Text(item.content.title)
                    .font(.headline)
                Spacer()
                Text(item.timestamp.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Text(subtitle)
                .font(.subheadline)
                .lineLimit(2)
        }
    }
}
#endif
