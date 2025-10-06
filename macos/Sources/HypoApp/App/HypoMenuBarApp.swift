#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@main
struct HypoMenuBarApp: App {
    @StateObject private var viewModel = ClipboardHistoryViewModel()
    @State private var monitor: ClipboardMonitor?

    var body: some Scene {
        MenuBarExtra("Hypo", systemImage: "rectangle.portrait.on.rectangle") {
            MenuBarContentView(viewModel: viewModel)
                .frame(width: 360, height: 480)
                .environmentObject(viewModel)
                .preferredColorScheme(viewModel.appearancePreference.colorScheme)
                .task { await viewModel.start() }
                .onOpenURL { url in
                    Task { await viewModel.handleDeepLink(url) }
                }
                .onAppear(perform: setupMonitor)
        }
        .menuBarExtraStyle(.window)
    }

    private func setupMonitor() {
        guard monitor == nil else { return }
        let monitor = ClipboardMonitor()
        monitor.delegate = viewModel
        monitor.start()
        self.monitor = monitor
    }
}

private enum MenuSection: String, CaseIterable, Identifiable {
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .history: return "clock"
        case .settings: return "gear"
        }
    }
}

private struct MenuBarContentView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @State private var selectedSection: MenuSection = .history
    @State private var search = ""

    var body: some View {
        VStack(spacing: 12) {
            LatestClipboardView(entry: viewModel.latestItem, viewModel: viewModel)

            Picker("Section", selection: $selectedSection) {
                ForEach(MenuSection.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Menu sections")

            switch selectedSection {
            case .history:
                HistorySectionView(viewModel: viewModel, search: $search)
            case .settings:
                SettingsSectionView(viewModel: viewModel)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        )
    }
}

private struct LatestClipboardView: View {
    let entry: ClipboardEntry?
    @ObservedObject var viewModel: ClipboardHistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Latest", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if let entry {
                    Button {
                        viewModel.copyToPasteboard(entry)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy latest clipboard item")
                }
            }

            if let entry {
                ClipboardCard(entry: entry)
            } else {
                Text("Clipboard history will appear here once you copy something.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry?.accessibilityDescription() ?? "No clipboard content yet")
    }
}

private struct HistorySectionView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @Binding var search: String

    private var filteredItems: [ClipboardEntry] {
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            return viewModel.items
        }
        return viewModel.items.filter { $0.matches(query: search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search clipboard history")
                Button {
                    viewModel.clearHistory()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.items.isEmpty)
                .help("Clear clipboard history")
            }

            if filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No clipboard items")
                        .font(.headline)
                    Text(search.isEmpty ? "Copy something to get started." : "Try adjusting your search query.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredItems) { item in
                            ClipboardRow(entry: item, viewModel: viewModel)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(item.isPinned ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                        }
                    }
                }
            }
        }
    }
}

private struct ClipboardCard: View {
    let entry: ClipboardEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: entry.content.iconName)
                    .foregroundStyle(.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.content.title)
                        .font(.headline)
                    Text(entry.previewText)
                        .lineLimit(3)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(entry.timestamp.formatted(date: .numeric, time: .standard))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityDescription())
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    @ObservedObject var viewModel: ClipboardHistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Image(systemName: entry.content.iconName)
                    .foregroundStyle(.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.content.title)
                        .font(.headline)
                    Text(entry.previewText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.timestamp, style: .time)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if entry.isPinned {
                        Label("Pinned", systemImage: "pin.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
        }
        .contextMenu {
            Button("Copy") { viewModel.copyToPasteboard(entry) }
            Button(entry.isPinned ? "Unpin" : "Pin") { viewModel.togglePin(entry) }
            Button("Delete", role: .destructive) {
                Task { await viewModel.remove(id: entry.id) }
            }
        }
        .onTapGesture { viewModel.copyToPasteboard(entry) }
        .onDrag {
            if let provider = viewModel.itemProvider(for: entry) {
                return provider
            }
            return NSItemProvider(object: entry.previewText as NSString)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilityDescription())
    }
}

private struct SettingsSectionView: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @State private var isPresentingPairing = false

    var body: some View {
        Form {
            Section("Connection") {
                Toggle(isOn: Binding(
                    get: { viewModel.transportPreference == .lanFirst },
                    set: { viewModel.updateTransportPreference($0 ? .lanFirst : .cloudOnly) }
                )) {
                    Text("Prefer local network connections")
                }
                Toggle("Allow cloud relay fallback", isOn: Binding(
                    get: { viewModel.allowsCloudFallback },
                    set: { viewModel.setAllowsCloudFallback($0) }
                ))
            }

            Section("History") {
                Slider(value: Binding(
                    get: { Double(viewModel.historyLimit) },
                    set: { viewModel.updateHistoryLimit(Int($0)) }
                ), in: 20...500, step: 10) {
                    Text("History size")
                }
                HStack {
                    Text("Current limit")
                    Spacer()
                    Text("\(viewModel.historyLimit)")
                }
                Toggle("Auto-delete after a delay", isOn: Binding(
                    get: { viewModel.autoDeleteAfterHours > 0 },
                    set: { newValue in
                        let hours = newValue ? max(viewModel.autoDeleteAfterHours, 6) : 0
                        viewModel.setAutoDelete(hours: hours)
                    }
                ))
                if viewModel.autoDeleteAfterHours > 0 {
                    Stepper(value: Binding(
                        get: { viewModel.autoDeleteAfterHours },
                        set: { viewModel.setAutoDelete(hours: $0) }
                    ), in: 1...72, step: 1) {
                        Text("Delete after \(viewModel.autoDeleteAfterHours) hour(s)")
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { viewModel.appearancePreference },
                    set: { viewModel.updateAppearance($0) }
                )) {
                    ForEach(ClipboardHistoryViewModel.AppearancePreference.allCases) { appearance in
                        Text(appearanceTitle(for: appearance)).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Security") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current encryption key")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(viewModel.encryptionKeySummary)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contextMenu {
                            Button("Copy") { viewModel.copyEncryptionKeyToPasteboard() }
                            Button("Regenerate", role: .destructive) { viewModel.regenerateEncryptionKey() }
                        }
                }
                HStack {
                    Button("Copy key") { viewModel.copyEncryptionKeyToPasteboard() }
                    Button("Regenerate key", role: .destructive) { viewModel.regenerateEncryptionKey() }
                }
            }

            Section("Paired devices") {
                if viewModel.pairedDevices.isEmpty {
                    Text("No devices paired yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.pairedDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.platform)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Last seen \(device.lastSeen.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(device.isOnline ? Color.green : Color.gray)
                                .frame(width: 10, height: 10)
                                .accessibilityLabel(device.isOnline ? "Online" : "Offline")
                            Button(role: .destructive) {
                                viewModel.removePairedDevice(device)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Remove device")
                        }
                    }
                }
                Button("Pair new device") { isPresentingPairing = true }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $isPresentingPairing) {
            PairDeviceSheet(viewModel: viewModel, isPresented: $isPresentingPairing)
        }
    }

    private func appearanceTitle(for appearance: ClipboardHistoryViewModel.AppearancePreference) -> String {
        switch appearance {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

private struct PairDeviceSheet: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @Binding var isPresented: Bool
    @State private var deviceName: String = ""
    @State private var selectedPlatform: DevicePlatform = .android

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair New Device")
                .font(.title2.bold())

            TextField("Device name", text: $deviceName)
                .textFieldStyle(.roundedBorder)

            Picker("Platform", selection: $selectedPlatform) {
                ForEach(DevicePlatform.allCases) { platform in
                    Text(platform.displayName).tag(platform)
                }
            }
            .pickerStyle(.segmented)

            Spacer()

            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Pair") {
                    let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewModel.pairDevice(name: trimmedName, platform: selectedPlatform.displayName)
                    isPresented = false
                }
                .disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360, height: 240)
    }
}

private enum DevicePlatform: String, CaseIterable, Identifiable {
    case android
    case macos
    case windows

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .android: return "Android"
        case .macos: return "macOS"
        case .windows: return "Windows"
        }
    }
}
#endif
