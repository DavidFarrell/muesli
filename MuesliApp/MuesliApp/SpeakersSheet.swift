import SwiftUI

// MARK: - Speakers Sheet

struct SpeakersSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speakers")
                .font(.title2).bold()

            Text("Renaming here updates all transcript lines immediately.")
                .foregroundStyle(.secondary)

            List {
                ForEach(allSpeakerIDs(), id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)

                        TextField("Name", text: Binding(
                            get: { model.transcriptModel.displayName(for: id) },
                            set: { model.renameSpeaker(id: id, to: $0) }
                        ))
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

    private func allSpeakerIDs() -> [String] {
        var ids = Set(model.transcriptModel.speakerNames.keys)
        for s in model.transcriptModel.segments {
            ids.insert(s.speakerID)
        }
        return ids.sorted()
    }
}
