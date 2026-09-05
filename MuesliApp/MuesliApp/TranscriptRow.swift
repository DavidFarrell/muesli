import SwiftUI

struct TranscriptRow: View {
    let segment: TranscriptSegment
    let displayName: String
    let onRename: (String) -> Void
    @State private var showRename = false
    @State private var proposedName = ""

    private var isMic: Bool {
        segment.stream == "mic"
    }

    var body: some View {
        HStack {
            if isMic { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button(displayName) {
                        proposedName = displayName
                        showRename = true
                    }
                    .buttonStyle(.link)

                    if segment.stream != "unknown" {
                        Text(segment.stream.capitalized)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.thinMaterial)
                            .cornerRadius(6)
                    }

                    if let source = segment.sourceSessionID {
                        Text("Source \(source)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160)
                            .help("Source/session: \(source)")
                    }

                    Text(String(format: "t=%.2fs", segment.t0))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                Text(segment.text)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(isMic ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            .cornerRadius(10)
            .frame(maxWidth: .infinity, alignment: isMic ? .trailing : .leading)
            .sheet(isPresented: $showRename) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rename speaker")
                        .font(.headline)

                    Text(segment.speakerIdentity.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Name", text: $proposedName)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Spacer()
                        Button("Cancel") { showRename = false }
                        Button("Save") {
                            let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                            onRename(trimmed)
                            showRename = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
                .frame(width: 420)
            }

            if !isMic { Spacer(minLength: 60) }
        }
    }
}
