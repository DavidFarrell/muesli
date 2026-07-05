import SwiftUI

// MARK: - Inline Editable Title

/// Click-to-edit title used by SessionView (the live session header) and
/// MeetingViewer (the meeting viewer header). Tapping the title, or setting
/// `isEditing` externally (e.g. from a pencil button), swaps it for a
/// TextField; Enter/blur commits, Esc cancels. On commit failure the title
/// reverts to `title` (the caller's own state didn't change, since the
/// underlying write failed) and an inline error is shown beneath it.
struct InlineEditableTitle: View {
    let title: String
    var font: Font = .title2.bold()
    @Binding var isEditing: Bool
    /// Returns an error message to display, or nil on success.
    let onCommit: (String) -> String?

    @State private var pendingTitle = ""
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isEditing {
                TextField("Title", text: $pendingTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(font)
                    .focused($isFocused)
                    .onAppear {
                        pendingTitle = title
                        errorMessage = nil
                        DispatchQueue.main.async {
                            isFocused = true
                        }
                    }
                    .onSubmit {
                        commit()
                    }
                    .onChange(of: isFocused) { _, focused in
                        guard !focused else { return }
                        commit()
                    }
                    .onExitCommand {
                        cancel()
                    }
            } else {
                Text(title)
                    .font(font)
                    .onTapGesture {
                        isEditing = true
                    }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func commit() {
        guard isEditing else { return }
        let trimmed = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        guard !trimmed.isEmpty, trimmed != title else { return }
        errorMessage = onCommit(trimmed)
    }

    private func cancel() {
        guard isEditing else { return }
        isEditing = false
    }
}
