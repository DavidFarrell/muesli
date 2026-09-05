import SwiftUI

// MARK: - Speakers Sheet

struct SpeakersSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var transcript: TranscriptModel
    @Environment(\.dismiss) var dismiss
    @FocusState private var focusedSpeakerID: String?

    var body: some View {
        let speakerIDs = allSpeakerIDs()
        VStack(alignment: .leading, spacing: 14) {
            Text("Speakers")
                .font(.title2).bold()

            Text("Names apply to this speaker in this source and stream.")
                .foregroundStyle(.secondary)

            List {
                ForEach(speakerIDs, id: \.self) { id in
                    HStack {
                        Text(transcript.speakerLabel(for: id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 210, alignment: .leading)

                        TextField("Name", text: Binding(
                            get: { transcript.displayName(for: id) },
                            set: { model.renameSpeaker(id: id, to: $0) }
                        ))
                        .focused($focusedSpeakerID, equals: id)
                        .onKeyPress(keys: [.init("\t")], phases: .down) { keyPress in
                            let moved = moveFocus(
                                from: id,
                                in: speakerIDs,
                                backwards: keyPress.modifiers.contains(.shift)
                            )
                            return moved ? .handled : .ignored
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 420)
    }

    private func moveFocus(from id: String, in ids: [String], backwards: Bool) -> Bool {
        guard let current = ids.firstIndex(of: id) else { return false }
        let target = backwards ? (current - 1) : (current + 1)
        guard target >= 0, target < ids.count else { return false }
        focusedSpeakerID = ids[target]
        return true
    }

    private func allSpeakerIDs() -> [String] {
        let ids = Set(transcript.segments.map(\.speakerKey))
        return ids.sorted()
    }
}
