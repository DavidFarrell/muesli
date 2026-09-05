import SwiftUI

struct AttachmentsCard: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Selection?
    @State private var hoveredAttachment: UUID?
    private struct Selection: Identifiable {
        let attachment: Attachment
        let folder: URL
        var id: UUID { attachment.id }
    }
    private let columns = [GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 8)]

    var body: some View {
        GroupBox("Attachments") {
            VStack(alignment: .leading, spacing: 8) {
                // The attachment-persistence integration narrows this existing
                // notice to AppModel.attachmentNotice for the selected folder.
                if let notice = model.metadataEditNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.currentAttachments.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 24))
                        Text("Paste images or text").font(.caption)
                        Text("Cmd+V").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.currentAttachments) { attachment in
                            AttachmentThumbnail(attachment: attachment, folder: model.currentSession?.folderURL,
                                isHovered: hoveredAttachment == attachment.id,
                                onTap: {
                                    if let folder = model.currentSession?.folderURL {
                                        selected = Selection(attachment: attachment, folder: folder)
                                    }
                                }, onDelete: { model.deleteAttachment(attachment) })
                                .onHover { hoveredAttachment = $0 ? attachment.id : nil }
                        }
                    }
                    HStack {
                        Spacer()
                        Text("\(model.currentAttachments.count) attachment\(model.currentAttachments.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(8)
        }
        .sheet(item: $selected) { selection in
            AttachmentDetailSheet(attachment: selection.attachment, folder: selection.folder) { selected = nil }
        }
        .onChange(of: model.currentSession?.folderURL) { _, _ in selected = nil }
        .onChange(of: model.currentAttachments.map(\.id)) { _, ids in
            if let selected, !ids.contains(selected.id) { self.selected = nil }
        }
    }
}

private func previewRequest(_ attachment: Attachment, folder: URL?, mode: AttachmentPreviewReader.Mode) -> AttachmentPreviewReader.Request? {
    guard let folder else { return nil }
    return .init(folder: folder, attachmentID: attachment.id, filename: attachment.filename,
                 kind: attachment.type == .image ? .image : .text, mode: mode,
                 sourceSessionID: attachment.sourceSessionID, expectedBytes: attachment.byteCount,
                 expectedSHA256: attachment.sha256)
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    let folder: URL?
    let isHovered: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    @StateObject private var preview = AttachmentPreviewModel()
    private var request: AttachmentPreviewReader.Request? { previewRequest(attachment, folder: folder, mode: .thumbnail) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                Group {
                    switch preview.event {
                    case .loaded(.image(let value)):
                        Image(decorative: value.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    case .loaded(.text): Image(systemName: "doc.text").font(.system(size: 24))
                    case .loading: ProgressView().controlSize(.small)
                    case .pending: Image(systemName: "clock").accessibilityLabel("Preview still loading. Open for details.")
                    case .failed: Image(systemName: "exclamationmark.triangle").accessibilityLabel("Preview unavailable. Open to retry.")
                    }
                }
                .frame(width: 60, height: 60).background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Open attachment preview")
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill").font(.system(size: 10)).foregroundColor(.white)
                        .padding(4).background(Color.red).clipShape(Circle())
                }.buttonStyle(.plain).offset(x: 4, y: -4)
            }
        }
        .onChange(of: request) { _, request in preview.load(request) }
        .onDisappear { preview.stop() }
        .onAppear { preview.load(request) }
    }
}

struct AttachmentDetailSheet: View {
    let attachment: Attachment
    let folder: URL
    let onDismiss: () -> Void
    @StateObject private var preview = AttachmentPreviewModel()
    private var request: AttachmentPreviewReader.Request? { previewRequest(attachment, folder: folder, mode: .detail) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename).font(.headline)
                    Text(formatTimestamp(attachment.timestamp)).font(.caption).foregroundStyle(.secondary)
                    if attachment.sha256 == nil { Text("Legacy attachment: no saved fingerprint.").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Done", action: onDismiss).keyboardShortcut(.escape)
            }.padding()
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onChange(of: request, initial: true) { _, request in preview.load(request) }
        .onDisappear { preview.stop() }
    }
    @ViewBuilder private var content: some View {
        switch preview.event {
        case .loading:
            ProgressView("Loading preview…")
        case .pending:
            VStack(spacing: 12) {
                Text("The preview is still loading. Its original file operation remains active.")
                Button("Check again") { preview.retry() }
            }.padding()
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(message).multilineTextAlignment(.center)
                Button("Retry") { preview.retry() }
            }.padding()
        case .loaded(.image(let value)):
            VStack {
                Image(decorative: value.image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding()
                Text("Preview limited to 2048 pixels; original file is unchanged.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom)
            }
        case .loaded(.text(let text)):
            ScrollView {
                Text(text).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        }
    }
    private func formatTimestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? min(Double(Int.max / 2), max(0, seconds)) : 0
        let hours = Int(value) / 3600, minutes = (Int(value) % 3600) / 60, secs = Int(value) % 60
        return hours > 0 ? String(format: "%d:%02d:%02d into meeting", hours, minutes, secs)
            : String(format: "%d:%02d into meeting", minutes, secs)
    }
}
