import SwiftUI
import AppKit

// MARK: - Meeting Viewer

struct MeetingViewer: View {
    @EnvironmentObject var model: AppModel
    let meeting: MeetingHistoryItem
    @State private var showSpeakers = false
    @State private var autoScroll = true
    @State private var copyIconName = "doc.on.clipboard"
    @State private var showRenameSheet = false
    @State private var renameTitle = ""
    @State private var isIdentifyingSpeakers = false
    @State private var identificationProgress: SpeakerIdentifier.Progress?
    @State private var identificationError: String?
    @State private var proposedMappings: [SpeakerIdentifier.SpeakerMapping] = []
    @State private var showMappingSheet = false
    @State private var identificationTask: Task<Void, Never>?
    @State private var isRediarizing = false
    @State private var rediarizeProgress: BatchRediarizer.Progress?
    @State private var rediarizeError: String?
    @State private var pendingRediarizeResult: BatchRediarizer.Result?
    @State private var showRediarizeConfirm = false
    @State private var rediarizeTask: Task<Void, Never>?
    @State private var rediarizeStream: BatchRediarizer.Stream = .system

    var body: some View {
        VStack(spacing: 12) {
            header

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Viewer") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Auto-scroll transcript", isOn: $autoScroll)
                            Button("Speakers") { showSpeakers = true }
                        }
                        .padding(8)
                    }

                    GroupBox("Speaker ID") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Batch re-diarization")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                rerunSpeakerSegmentation()
                            } label: {
                                Label("Rerun speaker segmentation", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canRediarize)

                            Picker("Stream", selection: $rediarizeStream) {
                                Text("System").tag(BatchRediarizer.Stream.system)
                                Text("Mic").tag(BatchRediarizer.Stream.mic)
                                Text("System + Mic").tag(BatchRediarizer.Stream.both)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)

                            if isRediarizing {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(rediarizeProgressText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Button("Cancel") {
                                    cancelRediarization()
                                }
                                .buttonStyle(.bordered)
                            }

                            if let rediarizeError {
                                Text(rediarizeError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            Divider()

                            Text("Speaker naming")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                identifySpeakers()
                            } label: {
                                Label("Identify speakers", systemImage: "person.text.rectangle")
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canIdentifySpeakers)

                            if isIdentifyingSpeakers {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(progressText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Button("Cancel") {
                                    cancelSpeakerIdentification()
                                }
                                .buttonStyle(.bordered)
                            }

                            if let message = model.speakerIdStatusMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if let identificationError {
                                Text(identificationError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(8)
                    }

                    Spacer()
                }
                .frame(width: 260)

                transcriptPane(autoScroll: autoScroll)
            }
        }
        .padding(16)
        .sheet(isPresented: $showSpeakers) {
            SpeakersSheet()
        }
        .sheet(isPresented: $showMappingSheet) {
            SpeakerMappingSheet(
                mappings: proposedMappings,
                onConfirm: { mappings in
                    model.applySpeakerMappings(mappings, for: meeting)
                    showMappingSheet = false
                },
                onCancel: {
                    showMappingSheet = false
                }
            )
        }
        .alert("Replace transcript?", isPresented: $showRediarizeConfirm) {
            Button("Replace", role: .destructive) {
                if let result = pendingRediarizeResult {
                    model.applyBatchRediarization(result, for: meeting)
                }
                pendingRediarizeResult = nil
                showRediarizeConfirm = false
            }
            Button("Cancel", role: .cancel) {
                pendingRediarizeResult = nil
                showRediarizeConfirm = false
            }
        } message: {
            Text("Found \(pendingRediarizeResult?.speakers.count ?? 0) speakers. Replace transcript?")
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameMeetingSheet(
                title: $renameTitle,
                onCancel: { showRenameSheet = false },
                onSave: {
                    model.renameMeeting(meeting, to: renameTitle)
                    showRenameSheet = false
                }
            )
        }
        .onDisappear {
            identificationTask?.cancel()
            identificationTask = nil
            rediarizeTask?.cancel()
            rediarizeTask = nil
        }
    }

    private var header: some View {
        HStack {
            Button("Back") {
                model.closeMeetingViewer()
            }
            .buttonStyle(.link)

            VStack(alignment: .leading) {
                Text(meeting.title)
                    .font(.title2).bold()
                Text("\(formatDuration(meeting.durationSeconds)) • \(meeting.segmentCount) segments")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    renameTitle = meeting.title
                    showRenameSheet = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button {
                    model.resumeMeeting(meeting)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .disabled(model.isCapturing || meeting.status == .recording)
                .help("Resume this meeting")

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(model.transcriptModel.asPlainText(), forType: .string)
                    copyIconName = "checkmark.circle.fill"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copyIconName = "doc.on.clipboard"
                    }
                } label: {
                    Image(systemName: copyIconName)
                }
                .buttonStyle(.borderless)
                .help("Copy transcript")

                Button {
                    model.exportTranscriptFiles(for: meeting)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .help("Export transcript")
            }
        }
    }

    private func transcriptPane(autoScroll: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.transcriptModel.segments.filter { !$0.isPartial }) { segment in
                        TranscriptRow(segment: segment)
                            .id(segment.id)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .background(.thinMaterial)
            .cornerRadius(12)
            .onChange(of: model.transcriptModel.segments.count) { _ in
                guard autoScroll, let last = model.transcriptModel.segments.last else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%dh %dm", hrs, mins)
        }
        if mins > 0 {
            return String(format: "%dm %ds", mins, secs)
        }
        return "\(secs)s"
    }

    private var canIdentifySpeakers: Bool {
        if isIdentifyingSpeakers || isRediarizing {
            return false
        }
        switch model.speakerIdStatus {
        case .ready, .unknown:
            return true
        case .ollamaNotRunning, .modelMissing, .error:
            return false
        }
    }

    private var canRediarize: Bool {
        if isRediarizing || isIdentifyingSpeakers {
            return false
        }
        if meeting.status == .recording || model.isCapturing {
            return false
        }
        guard model.backendFolderURL != nil, model.backendPythonExists else {
            return false
        }
        return true
    }

    private var progressText: String {
        switch identificationProgress {
        case .extractingFrames:
            return "Extracting frames..."
        case .analyzing:
            return "Analyzing with Ollama..."
        case .complete:
            return "Complete"
        case nil:
            return "Identifying..."
        }
    }

    private var rediarizeProgressText: String {
        switch rediarizeProgress {
        case .preparing:
            return "Preparing audio..."
        case .transcribing:
            return "Transcribing audio..."
        case .diarizing:
            return "Identifying speakers..."
        case .merging:
            return "Finalizing..."
        case .complete:
            return "Complete"
        case nil:
            return "Re-processing..."
        }
    }

    private func rerunSpeakerSegmentation() {
        guard !isRediarizing else { return }

        rediarizeError = nil
        isRediarizing = true
        rediarizeProgress = .preparing

        rediarizeTask = Task {
            do {
                try Task.checkCancellation()
                let result = try await model.runBatchRediarization(
                    for: meeting,
                    stream: rediarizeStream,
                    progressHandler: { progress in
                        Task { @MainActor in
                            rediarizeProgress = progress
                        }
                    }
                )
                try Task.checkCancellation()
                await MainActor.run {
                    pendingRediarizeResult = result
                    isRediarizing = false
                    rediarizeProgress = nil
                    showRediarizeConfirm = true
                }
            } catch is CancellationError {
                await MainActor.run {
                    isRediarizing = false
                    rediarizeProgress = nil
                }
            } catch {
                await MainActor.run {
                    isRediarizing = false
                    rediarizeProgress = nil
                    rediarizeError = "Reprocess failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func cancelRediarization() {
        rediarizeTask?.cancel()
        rediarizeTask = nil
    }

    private func identifySpeakers() {
        guard !isIdentifyingSpeakers else { return }

        identificationError = nil
        isIdentifyingSpeakers = true
        identificationProgress = nil

        let transcript = transcriptForIdentification()
        let speakerIds = speakerIdsForIdentification()
        let screenshots = loadScreenshots(for: meeting)

        identificationTask = Task {
            do {
                try Task.checkCancellation()
                let identifier = SpeakerIdentifier()
                let result = try await identifier.identifySpeakers(
                    screenshots: screenshots,
                    transcript: transcript,
                    speakerIds: speakerIds,
                    progressHandler: { progress in
                        Task { @MainActor in
                            identificationProgress = progress
                        }
                    }
                )
                try Task.checkCancellation()
                await MainActor.run {
                    proposedMappings = result.mappings
                    isIdentifyingSpeakers = false
                    identificationProgress = nil
                    showMappingSheet = true
                }
            } catch is CancellationError {
                await MainActor.run {
                    isIdentifyingSpeakers = false
                    identificationProgress = nil
                }
            } catch {
                await MainActor.run {
                    isIdentifyingSpeakers = false
                    identificationProgress = nil
                    if let urlError = error as? URLError, urlError.code == .timedOut {
                        identificationError = "Speaker ID timed out after 30 seconds. Try again."
                    } else {
                        identificationError = "Speaker ID failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func cancelSpeakerIdentification() {
        identificationTask?.cancel()
        identificationTask = nil
    }

    private func loadScreenshots(for meeting: MeetingHistoryItem) -> [URL] {
        let folder = meeting.folderURL.appendingPathComponent("screenshots", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        let imageURLs = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "png" || ext == "jpg" || ext == "jpeg"
        }
        return imageURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func speakerIdsForIdentification() -> [String] {
        var ids = Set<String>()
        for segment in model.transcriptModel.segments where !segment.isPartial {
            ids.insert(segment.speakerID)
        }
        return ids.sorted()
    }

    private func transcriptForIdentification() -> String {
        model.transcriptModel.segments
            .filter { !$0.isPartial }
            .map { segment in
                let stream = segment.stream == "unknown" ? "" : "[\(segment.stream)] "
                return "\(stream)t=\(String(format: "%.2f", segment.t0))s \(segment.speakerID): \(segment.text)"
            }
            .joined(separator: "\n")
    }
}

// MARK: - Speaker Mapping Sheet

struct SpeakerMappingSheet: View {
    let mappings: [SpeakerIdentifier.SpeakerMapping]
    let onConfirm: ([SpeakerIdentifier.SpeakerMapping]) -> Void
    let onCancel: () -> Void

    @State private var workingMappings: [SpeakerIdentifier.SpeakerMapping]

    init(
        mappings: [SpeakerIdentifier.SpeakerMapping],
        onConfirm: @escaping ([SpeakerIdentifier.SpeakerMapping]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mappings = mappings
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _workingMappings = State(initialValue: mappings.sorted { $0.speakerId < $1.speakerId })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speaker mapping")
                .font(.title2).bold()

            Text("Review and edit names before applying them to the transcript.")
                .foregroundStyle(.secondary)

            List {
                ForEach(workingMappings.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Text(workingMappings[index].speakerId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)

                        TextField("Name", text: Binding(
                            get: { workingMappings[index].name },
                            set: { workingMappings[index].name = $0 }
                        ))

                        Text(confidenceText(for: workingMappings[index].confidence))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                Button("Apply") { onConfirm(workingMappings) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 420)
    }

    private func confidenceText(for confidence: Double) -> String {
        let clamped = max(0.0, min(1.0, confidence))
        let percent = Int((clamped * 100.0).rounded())
        return "\(percent)%"
    }
}
