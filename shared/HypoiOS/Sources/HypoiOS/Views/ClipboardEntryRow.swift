import SwiftUI
import HypoCore

/// One history entry, laid out like Android's card: a type icon and an origin
/// badge above the preview, with the time on the right. Tapping copies it back
/// to the clipboard, which is what the card does there too.
struct ClipboardEntryRow: View {
    let entry: ClipboardEntry
    let isLocal: Bool
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
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
                }

                Text(entry.content.previewDescription)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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

    private var typeSymbol: String {
        switch entry.content {
        case .text: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}
