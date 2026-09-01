import SwiftUI
import HypoCore

/// One history entry, laid out like Android's card: a type icon and an origin
/// badge above the preview, with the time on the right. Tapping copies it back
/// to the clipboard, which is what the card does there too.
struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let isLocal: Bool
    let onCopy: () -> Void
    let onOpenDetail: () -> Void

    var body: some View {
        // A tap gesture rather than wrapping the row in a Button: the preview
        // control is itself a Button, and SwiftUI does not reliably deliver
        // taps to a button nested inside another one — the row swallowed them,
        // so the preview could be seen but not opened.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: typeSymbol)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                originBadge

                Spacer(minLength: 8)

                Text(entry.timestamp, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Only when there is more to see than the row shows, the
                // way Android decides it: images and files always have
                // more, text only when the preview had to cut it.
                if hasMoreToShow {
                    Button(action: onOpenDetail) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview")
                    .accessibilityIdentifier("Preview-\(entry.id.uuidString)")
                }
            }

            Text(entry.content.listDescription)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
    }

    private var originBadge: some View {
        HStack(spacing: 4) {
            if entry.isEncrypted {
                Image(systemName: "lock.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }
            // Cloud only. LAN gets no icon, matching Android and macOS: the
            // common case should not be decorated.
            if entry.transportOrigin == .cloud {
                Image(systemName: "icloud")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Text(entry.originDeviceName ?? String(entry.deviceId.prefix(8)))
                .font(.caption2)
                .foregroundStyle(isLocal ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isLocal ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemBackground),
            in: Capsule()
        )
    }

    private var hasMoreToShow: Bool {
        switch entry.content {
        case .image, .file:
            return true
        case .text(let text):
            return text != entry.content.previewDescription || text.count > 120
        case .link:
            return false
        }
    }

    private var typeSymbol: String {
        switch entry.content {
        case .text: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}
