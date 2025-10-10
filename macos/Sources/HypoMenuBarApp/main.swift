#if os(macOS)
import SwiftUI
import AppKit

@main
struct HypoMenuBarApp: App {
    @StateObject private var viewModel = ClipboardHistoryViewModel()

    var body: some Scene {
        MenuBarExtra("Hypo", systemImage: "rectangle.portrait.on.rectangle") {
            MenuBarContentView(viewModel: viewModel)
                .frame(width: 360, height: 480)
                .environmentObject(viewModel)
                .task { await viewModel.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
#endif

// MARK: - ViewModel
@MainActor
class ClipboardHistoryViewModel: ObservableObject {
    @Published var entries: [ClipboardEntry] = []
    @Published var searchText = ""
    @Published var isConnected = false
    
    func start() async {
        // Add some sample entries for demonstration
        entries = [
            ClipboardEntry(content: .text("Hello, World!"), timestamp: Date().addingTimeInterval(-300)),
            ClipboardEntry(content: .text("This is a sample clipboard entry"), timestamp: Date().addingTimeInterval(-600)),
            ClipboardEntry(content: .url(URL(string: "https://example.com")!), timestamp: Date().addingTimeInterval(-900))
        ]
    }
    
    var filteredEntries: [ClipboardEntry] {
        if searchText.isEmpty {
            return entries
        }
        return entries.filter { entry in
            entry.content.title.localizedCaseInsensitiveContains(searchText) ||
            entry.previewText.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    func clearHistory() {
        entries.removeAll()
    }
}

// MARK: - Content View
struct MenuBarContentView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Clipboard History")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button("Clear All") {
                    viewModel.clearHistory()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search clipboard history...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding()
            
            Divider()
            
            // Content
            if viewModel.filteredEntries.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.filteredEntries) { entry in
                            ClipboardEntryRow(entry: entry)
                        }
                    }
                    .padding()
                }
            }
            
            Divider()
            
            // Footer
            HStack {
                ConnectionStatusView(isConnected: viewModel.isConnected)
                Spacer()
                Text("\(viewModel.filteredEntries.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}

// MARK: - Entry Row
struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.content.iconName)
                .foregroundStyle(.primary)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.content.title)
                    .font(.headline)
                    .lineLimit(2)
                
                Text(entry.previewText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                
                Text(entry.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onTapGesture {
            copyToClipboard(entry)
        }
    }
    
    private func copyToClipboard(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        switch entry.content {
        case .text(let text):
            pasteboard.setString(text, forType: .string)
        case .url(let url):
            pasteboard.setString(url.absoluteString, forType: .string)
        case .image(let data):
            pasteboard.setData(data, forType: .png)
        case .file(let data, let _):
            pasteboard.setData(data, forType: .fileURL)
        }
    }
}

// MARK: - Empty State
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            
            Text("No clipboard history")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("Copy some text, images, or files to see them here")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

// MARK: - Connection Status
struct ConnectionStatusView: View {
    let isConnected: Bool
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? .green : .red)
                .frame(width: 8, height: 8)
            
            Text(isConnected ? "Connected" : "Offline")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Models
struct ClipboardEntry: Identifiable, Codable {
    let id = UUID()
    let content: ClipboardContent
    let timestamp: Date
    let previewText: String
    
    init(content: ClipboardContent, timestamp: Date = Date()) {
        self.content = content
        self.timestamp = timestamp
        self.previewText = content.previewText
    }
}

enum ClipboardContent: Codable {
    case text(String)
    case url(URL)
    case image(Data)
    case file(Data, filename: String)
    
    var title: String {
        switch self {
        case .text:
            return "Text"
        case .url:
            return "URL"
        case .image:
            return "Image"
        case .file(_, let filename):
            return "File: \(filename)"
        }
    }
    
    var iconName: String {
        switch self {
        case .text:
            return "text.quote"
        case .url:
            return "link"
        case .image:
            return "photo"
        case .file:
            return "doc"
        }
    }
    
    var previewText: String {
        switch self {
        case .text(let text):
            return String(text.prefix(100))
        case .url(let url):
            return url.absoluteString
        case .image:
            return "Image data"
        case .file(_, let filename):
            return filename
        }
    }
}


#endif
