import SwiftUI
import AppKit

struct AttachmentsCard: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedAttachment: Attachment?
    @State private var hoveredAttachment: Attachment?

    private let columns = [
        GridItem(.adaptive(minimum: 60, maximum: 80), spacing: 8)
    ]

    var body: some View {
        GroupBox("Attachments") {
            VStack(alignment: .leading, spacing: 8) {
                if model.currentAttachments.isEmpty {
                    emptyState
                } else {
                    attachmentsGrid
                }

                if !model.currentAttachments.isEmpty {
                    footer
                }
            }
            .padding(8)
        }
        .sheet(item: $selectedAttachment) { attachment in
            AttachmentDetailSheet(attachment: attachment) {
                selectedAttachment = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("Paste images or text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Cmd+V")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var attachmentsGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(model.currentAttachments) { attachment in
                AttachmentThumbnail(
                    attachment: attachment,
                    isHovered: hoveredAttachment?.id == attachment.id,
                    onTap: { selectedAttachment = attachment },
                    onDelete: { model.deleteAttachment(attachment) }
                )
                .onHover { isHovered in
                    hoveredAttachment = isHovered ? attachment : nil
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("\(model.currentAttachments.count) attachment\(model.currentAttachments.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: Attachment
    let isHovered: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                thumbnailContent
                    .frame(width: 60, height: 60)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.red)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        switch attachment.type {
        case .image:
            if let url = model.attachmentFileURL(for: attachment),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        case .text:
            Image(systemName: "doc.text")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
    }
}

struct AttachmentDetailSheet: View {
    let attachment: Attachment
    let onDismiss: () -> Void

    @EnvironmentObject var model: AppModel
    @State private var textContent: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            contentArea
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            if attachment.type == .text {
                loadTextContent()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.headline)
                Text(formatTimestamp(attachment.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.escape)
        }
        .padding()
    }

    @ViewBuilder
    private var contentArea: some View {
        switch attachment.type {
        case .image:
            imageContent
        case .text:
            textContentView
        }
    }

    private var imageContent: some View {
        Group {
            if let url = model.attachmentFileURL(for: attachment),
               let nsImage = NSImage(contentsOf: url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                }
            } else {
                ContentUnavailableView("Image not found", systemImage: "photo")
            }
        }
    }

    private var textContentView: some View {
        ScrollView {
            Text(textContent)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }

    private func loadTextContent() {
        guard let url = model.attachmentFileURL(for: attachment) else {
            textContent = "(Unable to load file)"
            return
        }
        do {
            textContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            textContent = "(Error loading text: \(error.localizedDescription))"
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d into meeting", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d into meeting", minutes, secs)
        }
    }
}
