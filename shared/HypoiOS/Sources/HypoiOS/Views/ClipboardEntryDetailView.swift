import SwiftUI
import HypoCore

/// The full contents of one history entry, the way Android's detail sheet
/// shows them.
///
/// The row can only ever show a preview — three lines of text, or a line
/// describing an image. Anything longer is cut off with no way to read the
/// rest, which for a clipboard app is the part you actually wanted.
struct ClipboardEntryDetailView: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metadata
                    Divider()
                    content
                }
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if let imageFile {
                            // A file URL, so the share sheet offers Save to
                            // Photos and Open With — Android's two buttons.
                            ShareLink(item: imageFile)
                        } else if let shareable {
                            ShareLink(item: shareable)
                        }
                        Button {
                            onCopy()
                            didCopy = true
                        } label: {
                            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                        .disabled(didCopy)
                    }
                }
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("From", value: entry.originDeviceName ?? entry.deviceId)
            LabeledContent("When", value: entry.timestamp.formatted(date: .abbreviated, time: .shortened))
            if let size = sizeDescription {
                LabeledContent("Size", value: size)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.content {
        case .text(let text):
            // Selectable, because reading it is often not the point — taking
            // part of it is.
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .link(let url):
            VStack(alignment: .leading, spacing: 12) {
                Text(url.absoluteString)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Link("Open link", destination: url)
            }
        case .image(let metadata):
            if let data = metadata.data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                // The bytes live with the entry; without them there is nothing
                // to draw, and saying so beats an empty box.
                Text("The image is no longer stored on this device.")
                    .foregroundStyle(.secondary)
            }
        case .file(let metadata):
            VStack(alignment: .leading, spacing: 8) {
                Label(metadata.fileName, systemImage: "doc")
                Text(metadata.uti)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        switch entry.content {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file(let metadata): return metadata.fileName
        }
    }

    private var sizeDescription: String? {
        switch entry.content {
        case .image(let metadata):
            let pixels = "\(Int(metadata.pixelSize.width))×\(Int(metadata.pixelSize.height))"
            return "\(pixels), \(byteCount(metadata.byteSize))"
        case .file(let metadata):
            return byteCount(metadata.byteSize)
        case .text(let text):
            return "\(text.count) characters"
        case .link:
            return nil
        }
    }

    /// What can be handed to the share sheet, which is iOS's answer to
    /// Android's "Open with…" and its save-to-Photos button at once.
    private var shareable: String? {
        switch entry.content {
        case .text(let text): return text
        case .link(let url): return url.absoluteString
        case .image, .file: return nil
        }
    }

    /// The image written somewhere the share sheet can reach it.
    ///
    /// ShareLink needs a URL for the sheet to offer Save to Photos; handing it
    /// raw Data only offers to share the bytes.
    private var imageFile: URL? {
        guard case .image(let metadata) = entry.content, let data = metadata.data else { return nil }
        let ext = metadata.format.isEmpty ? "png" : metadata.format
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hypo-\(entry.id.uuidString)")
            .appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
