import SwiftUI
import HypoCore

/// The app's root screen, laid out like Android's: one row holding the search
/// field, a connection status icon and a settings button, then the list.
///
/// No title and no clear-all button — Android has neither, and a large
/// navigation title costs a third of the screen to say what the app already is.
public struct HistoryListView: View {
    @ObservedObject private var viewModel: HistoryListViewModel
    @ObservedObject private var transportManager: TransportManager
    private let onOpenSettings: () -> Void

    public init(
        viewModel: HistoryListViewModel,
        transportManager: TransportManager,
        onOpenSettings: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.transportManager = transportManager
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                searchField

                // Status, not a control — the same non-interactive icon
                // Android shows in this position.
                connectionIcon
                    .frame(width: 44, height: 44)
                    .accessibilityIdentifier("ConnectionStatus")
                    .accessibilityLabel(connectionDescription)

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            list
        }
        .safeAreaInset(edge: .bottom) {
            if let message = sendStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
        .task { await viewModel.load() }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $viewModel.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }

    private var list: some View {
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
        .listStyle(.plain)
        .overlay {
            if viewModel.visibleEntries.isEmpty {
                ContentUnavailableView(
                    viewModel.searchText.isEmpty ? "No history yet" : "No matches",
                    systemImage: viewModel.searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass"
                )
            }
        }
    }

    /// Mirrors Android's ConnectionStatusIcon: Wifi on LAN, Cloud on relay,
    /// a spinner while connecting, CloudOff when there is nothing.
    private var connectionIcon: some View {
        Image(systemName: connectionSymbol)
            .foregroundStyle(connectionTint)
    }

    private var connectionSymbol: String {
        switch transportManager.connectionState {
        case .connectedLan: return "wifi"
        case .connectedCloud: return "icloud.fill"
        case .connectingLan, .connectingCloud: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.arrow.triangle.2.circlepath"
        case .disconnected: return "icloud.slash"
        }
    }

    private var connectionTint: Color {
        switch transportManager.connectionState {
        case .connectedLan: return .primary
        case .connectedCloud: return .accentColor
        case .error: return .orange
        case .connectingLan, .connectingCloud, .disconnected: return .secondary
        }
    }

    private var connectionDescription: String {
        switch transportManager.connectionState {
        case .disconnected: return "Disconnected"
        case .connectingLan: return "Connecting over LAN"
        case .connectedLan: return "Connected over LAN"
        case .connectingCloud: return "Connecting to relay"
        case .connectedCloud: return "Connected via relay"
        case .error(let message): return message
        }
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
}
