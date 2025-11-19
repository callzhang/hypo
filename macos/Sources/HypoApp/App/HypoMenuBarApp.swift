#if canImport(SwiftUI)
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

public struct HypoMenuBarApp: App {
    @StateObject private var viewModel: ClipboardHistoryViewModel
    @State private var monitor: ClipboardMonitor?

    public init() {
        let initMsg = "🚀 [HypoMenuBarApp] Initializing app\n"
        print(initMsg)
        try? initMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        // Create shared dependencies
        let historyStore = HistoryStore()
        let server = LanWebSocketServer()
        let provider = DefaultTransportProvider(server: server)
        
        // Create transport manager with history store for incoming clipboard handling
        let transportManager = TransportManager(
            provider: provider,
            webSocketServer: server,
            historyStore: historyStore
        )
        
        let viewModel = ClipboardHistoryViewModel(
            store: historyStore,
            transportManager: transportManager
        )
        
        let beforeSetMsg = "🚀 [HypoMenuBarApp] About to call setHistoryViewModel\n"
        print(beforeSetMsg)
        try? beforeSetMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        transportManager.setHistoryViewModel(viewModel)
        
        let afterSetMsg = "🚀 [HypoMenuBarApp] setHistoryViewModel completed\n"
        print(afterSetMsg)
        try? afterSetMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some Scene {
        MenuBarExtra("📋", systemImage: "doc.on.clipboard.fill") {
            MenuBarContentView(viewModel: viewModel)
                .frame(width: 360, height: 480)
                .environmentObject(viewModel)
                .preferredColorScheme(viewModel.appearancePreference.colorScheme)
                .onAppear {
                    // CRITICAL: Ensure setHistoryViewModel is called when view appears
                    // This is the most reliable place since SwiftUI might not call our custom init()
                    if let transportManager = viewModel.transportManager {
                        let initMsg = "🚀 [HypoMenuBarApp] .onAppear: Ensuring setHistoryViewModel is called\n"
                        print(initMsg)
                        try? initMsg.appendToFile(path: "/tmp/hypo_debug.log")
                        transportManager.setHistoryViewModel(viewModel)
                    }
                    setupMonitor()
                }
                .task {
                    // Also call it from .task as backup
                    if let transportManager = viewModel.transportManager {
                        let taskMsg = "🚀 [HypoMenuBarApp] .task: Ensuring setHistoryViewModel is called\n"
                        print(taskMsg)
                        try? taskMsg.appendToFile(path: "/tmp/hypo_debug.log")
                        transportManager.setHistoryViewModel(viewModel)
                    }
                    await viewModel.start()
                }
                .onOpenURL { url in
                    Task { await viewModel.handleDeepLink(url) }
                }
        }
        .menuBarExtraStyle(.window)
    }

    private func setupMonitor() {
        guard monitor == nil else { return }
        let deviceIdentity = DeviceIdentity()
        let monitor = ClipboardMonitor(
            deviceId: deviceIdentity.deviceId,
            deviceName: deviceIdentity.deviceName
        )
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
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 12) {
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
        .background(.ultraThinMaterial)
        .opacity(isVisible ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
        .onAppear {
            isVisible = true
            configureWindowBlur()
        }
        .onDisappear {
            isVisible = false
        }
    }
    
    private func configureWindowBlur() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Find the MenuBarExtra window
            for window in NSApplication.shared.windows {
                if window.isVisible && 
                   (window.styleMask.contains(.borderless) || window.title.isEmpty) &&
                   window.frame.width < 500 && window.frame.height < 600 {
                    
                    // Configure window for native blurred modal appearance
                    window.backgroundColor = .clear
                    window.isOpaque = false
                    window.hasShadow = true
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    
                    // Set up visual effect view as the window's background
                    if let contentView = window.contentView {
                        // Check if visual effect view already exists
                        var visualEffect: NSVisualEffectView?
                        for subview in contentView.subviews {
                            if let effectView = subview as? NSVisualEffectView {
                                visualEffect = effectView
                                break
                            }
                        }
                        
                        // Create visual effect view if it doesn't exist
                        if visualEffect == nil {
                            visualEffect = NSVisualEffectView()
                            visualEffect?.material = .hudWindow
                            visualEffect?.blendingMode = .behindWindow
                            visualEffect?.state = .active
                            visualEffect?.frame = contentView.bounds
                            visualEffect?.autoresizingMask = [.width, .height]
                            
                            // Insert at the very bottom, behind all content
                            contentView.addSubview(visualEffect!, positioned: .below, relativeTo: nil)
                        } else {
                            // Update existing one
                            visualEffect?.frame = contentView.bounds
                        }
                        
                        // Ensure content view and all subviews are transparent
                        contentView.wantsLayer = true
                        contentView.layer?.backgroundColor = NSColor.clear.cgColor
                        contentView.layer?.isOpaque = false
                        
                        // Make all SwiftUI hosting views transparent
                        for subview in contentView.subviews {
                            if String(describing: type(of: subview)).contains("HostingView") || 
                               String(describing: type(of: subview)).contains("NSHostingView") {
                                subview.wantsLayer = true
                                subview.layer?.backgroundColor = NSColor.clear.cgColor
                                subview.layer?.isOpaque = false
                            }
                        }
                    }
                    break
                }
            }
        }
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
                ClipboardCard(entry: entry, localDeviceId: viewModel.localDeviceId)
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
    let localDeviceId: String
    
    private var originName: String {
        entry.originDisplayName(localDeviceId: localDeviceId)
    }
    
    private var isLocal: Bool {
        entry.isLocal(localDeviceId: localDeviceId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: entry.content.iconName)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.content.title)
                            .font(.headline)
                        // Origin badge
                        Text(originName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(isLocal ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.2))
                            )
                            .foregroundStyle(isLocal ? .blue : .secondary)
                    }
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
    
    private var originName: String {
        entry.originDisplayName(localDeviceId: viewModel.localDeviceId)
    }
    
    private var isLocal: Bool {
        entry.isLocal(localDeviceId: viewModel.localDeviceId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Image(systemName: entry.content.iconName)
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.content.title)
                            .font(.headline)
                        // Origin badge
                        Text(originName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(isLocal ? Color.blue.opacity(0.2) : Color.secondary.opacity(0.2))
                            )
                            .foregroundStyle(isLocal ? .blue : .secondary)
                    }
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
    
    private var versionString: String {
        // Get the app bundle - when running as .app, Bundle.main should be the app bundle
        let bundle = Bundle.main
        
        // Debug: log bundle info
        print("📦 [SettingsSectionView] Bundle path: \(bundle.bundlePath)")
        print("📦 [SettingsSectionView] Bundle identifier: \(bundle.bundleIdentifier ?? "nil")")
        print("📦 [SettingsSectionView] Info dictionary keys: \(bundle.infoDictionary?.keys.sorted() ?? [])")
        
        if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = bundle.infoDictionary?["CFBundleVersion"] as? String {
            print("📦 [SettingsSectionView] Found version: \(version), build: \(build)")
            return "Version \(version) (Build \(build))"
        } else if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String {
            print("📦 [SettingsSectionView] Found version only: \(version)")
            return "Version \(version)"
        } else if let build = bundle.infoDictionary?["CFBundleVersion"] as? String {
            print("📦 [SettingsSectionView] Found build only: \(build)")
            return "Build \(build)"
        } else {
            // Fallback: use Info.plist values directly
            print("📦 [SettingsSectionView] No version found in bundle, using fallback")
            return "Version 1.0.0"
        }
    }

    var body: some View {
        ScrollView {
            Form {
                Section("Connection") {
                    HStack {
                        Toggle("Allow cloud relay fallback", isOn: Binding(
                            get: { viewModel.allowsCloudFallback },
                            set: { viewModel.setAllowsCloudFallback($0) }
                        ))
                        Spacer()
                        // Connection Status Icon - inline with toggle
                        Image(systemName: connectionStatusIconName(for: viewModel.connectionState))
                            .foregroundColor(connectionStatusIconColor(for: viewModel.connectionState))
                            .font(.system(size: 14, weight: .medium))
                            .help(connectionStatusTooltip(for: viewModel.connectionState))
                    }
                }
                
                Section("Security") {
                    Toggle("Plain Text Mode (Debug)", isOn: Binding(
                        get: { viewModel.plainTextModeEnabled },
                        set: { viewModel.plainTextModeEnabled = $0 }
                    ))
                    Text("⚠️ Send clipboard without encryption. Less secure, for debugging only.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hypo Clipboard")
                            .font(.headline)
                        Text(versionString)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .formStyle(.grouped)
        }
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
    
    private func connectionStatusIconName(for state: ConnectionState) -> String {
        switch state {
        case .idle:
            return "wifi.slash"
        case .connectingLan, .connectingCloud:
            return "arrow.triangle.2.circlepath"
        case .connectedLan:
            return "wifi"
        case .connectedCloud:
            return "cloud.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private func connectionStatusIconColor(for state: ConnectionState) -> Color {
        switch state {
        case .idle:
            return .gray
        case .connectingLan, .connectingCloud:
            return .orange
        case .connectedLan:
            return .green
        case .connectedCloud:
            return .blue
        case .error:
            return .red
        }
    }
    
    private func connectionStatusTooltip(for state: ConnectionState) -> String {
        switch state {
        case .idle:
            return "Server Offline"
        case .connectingLan:
            return "Connecting via LAN..."
        case .connectedLan:
            return "Connected via LAN"
        case .connectingCloud:
            return "Connecting via Cloud..."
        case .connectedCloud:
            return "Connected via Cloud"
        case .error:
            return "Connection Error"
        }
    }
}

private struct PairDeviceSheet: View {
    @ObservedObject var viewModel: ClipboardHistoryViewModel
    @Binding var isPresented: Bool
    @StateObject private var remoteViewModel: RemotePairingViewModel
    @State private var hasStarted = false

    init(viewModel: ClipboardHistoryViewModel, isPresented: Binding<Bool>) {
        self._viewModel = ObservedObject(initialValue: viewModel)
        self._isPresented = isPresented
        _remoteViewModel = StateObject(wrappedValue: viewModel.makeRemotePairingViewModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair New Device")
                .font(.title2.bold())

            statusSection

            content

            Divider()
            
            HStack {
                Button("Close") { 
                    isPresented = false 
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isComplete {
                    Button("Done") { 
                        isPresented = false 
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 350, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled()
        .onAppear { startIfNeeded() }
        .onDisappear {
            remoteViewModel.reset()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Text(remoteViewModel.statusMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
        if let countdown = remoteViewModel.countdownText {
            Text(countdown)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        remoteContent
    }

    private var isComplete: Bool {
        if case .completed = remoteViewModel.state { return true }
        return false
    }

    @ViewBuilder
    private var remoteContent: some View {
        switch remoteViewModel.state {
        case .idle, .requestingCode:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .displaying(let code, _), .awaitingChallenge(let code, _):
            VStack(spacing: 16) {
                Text("Pairing Code")
                    .font(.headline)
                Text(code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(12)
                Text("Enter this code on your Android device")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .completing:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .completed:
            successView
        case .failed(let message):
            failureView(message: message)
        }
    }

    @ViewBuilder
    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Pairing complete")
                .font(.title3)
                .bold()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func failureView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text(message)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func startIfNeeded(force: Bool = false) {
        let params = viewModel.pairingParameters()
        if force || !hasStarted {
            remoteViewModel.start(service: params.service, port: params.port, relayHint: params.relayHint)
        }
        hasStarted = true
    }
}

private struct ConnectionStatusView: View {
    let state: ConnectionState
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.system(size: 14, weight: .medium))
            Text(statusText)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(iconColor.opacity(0.1))
        .cornerRadius(8)
    }
    
    private var iconName: String {
        switch state {
        case .idle:
            return "wifi.slash"
        case .connectingLan, .connectingCloud:
            return "arrow.triangle.2.circlepath"
        case .connectedLan:
            return "wifi"
        case .connectedCloud:
            return "cloud.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var iconColor: Color {
        switch state {
        case .idle:
            return .gray
        case .connectingLan, .connectingCloud:
            return .orange
        case .connectedLan:
            return .green
        case .connectedCloud:
            return .blue
        case .error:
            return .red
        }
    }
    
    private var statusText: String {
        switch state {
        case .idle:
            return "Offline"
        case .connectingLan:
            return "Connecting (LAN)..."
        case .connectedLan:
            return "Connected (LAN)"
        case .connectingCloud:
            return "Connecting (Cloud)..."
        case .connectedCloud:
            return "Connected (Cloud)"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

#endif
