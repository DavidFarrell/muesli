import SwiftUI
import AppKit

// MARK: - Session

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSpeakers = false
    @State private var autoScroll = true
    @State private var showDebug = false
    @State private var copyIconName = "doc.on.clipboard"
    @State private var showRenameSheet = false
    @State private var renameTitle = ""
    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        VStack(spacing: 12) {
            header

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Audio levels") {
                        VStack(alignment: .leading, spacing: 10) {
                            LevelMeter(label: "System", level: model.systemLevel)
                            LevelMeter(label: "Microphone", level: model.micLevel)
                            Text("If a meter is flat at 0, your capture is not receiving that stream.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }

                    GroupBox("Controls") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Auto-scroll transcript", isOn: $autoScroll)
                            Toggle("Show debug panel", isOn: $showDebug)
                            HStack {
                                Button("Speakers") { showSpeakers = true }
                                Spacer()
                                Button(model.isFinalizing ? "Finalizing..." : "Stop") {
                                    Task { await model.stopMeeting() }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isFinalizing)
                            }
                            if model.isFinalizing {
                                Text("Finalizing transcript...")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                    }

                    if showDebug {
                        GroupBox("Debug") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Button("Copy debug") {
                                        let pasteboard = NSPasteboard.general
                                        pasteboard.clearContents()
                                        pasteboard.setString(model.debugSummary, forType: .string)
                                    }
                                    .buttonStyle(.bordered)

                                    Spacer()
                                }
                                Text("System buffers: \(model.debugSystemBuffers) frames: \(model.debugSystemFrames)")
                                Text("System PTS: \(String(format: "%.3f", model.debugSystemPTS))")
                                Text("System format: \(model.debugSystemFormat)")
                                Text("System errors: \(model.debugAudioErrors)")
                                Text("System last error: \(model.debugSystemErrorMessage)")
                                Divider()
                                Text("Mic buffers: \(model.debugMicBuffers) frames: \(model.debugMicFrames)")
                                Text("Mic PTS: \(String(format: "%.3f", model.debugMicPTS))")
                                Text("Mic format: \(model.debugMicFormat)")
                                Text("Mic errors: \(model.debugMicErrors)")
                                Text("Mic last error: \(model.debugMicErrorMessage)")
                                Divider()
                                Text("Transcript segments: \(model.transcriptModel.segments.count)")
                                if let last = model.transcriptModel.lastTranscriptAt {
                                    Text("Last transcript: \(timeFormatter.string(from: last))")
                                }
                                if !model.transcriptModel.lastTranscriptText.isEmpty {
                                    let snippet = model.transcriptModel.lastTranscriptText.prefix(120)
                                    Text("Last text: \(snippet)")
                                }
                                Divider()
                                Text("Backend folder: \(model.backendFolderPath)")
                                Text("Backend log: \(model.backendLogPath ?? "-")")
                                if let tempPath = model.tempTranscriptFolderPath {
                                    Text("Transcript temp folder: \(tempPath)")
                                }
                                if !model.backendLogTail.isEmpty {
                                    ScrollView {
                                        Text(model.backendLogTail.joined(separator: "\n"))
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxHeight: 120)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                        }
                    }

                    Spacer()
                }
                .frame(width: 360)

                transcriptPane(autoScroll: autoScroll)
            }
        }
        .padding(16)
        .sheet(isPresented: $showSpeakers) {
            SpeakersSheet()
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameMeetingSheet(
                title: $renameTitle,
                onCancel: { showRenameSheet = false },
                onSave: {
                    model.renameCurrentMeeting(to: renameTitle)
                    showRenameSheet = false
                }
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Button {
                    renameTitle = model.currentSession?.title ?? ""
                    showRenameSheet = true
                } label: {
                    Text(model.currentSession?.title ?? "Meeting")
                        .font(.title2).bold()
                }
                .buttonStyle(.plain)
                if let folder = model.currentSession?.folderURL.path {
                    Text(folder)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
    }

    private func transcriptPane(autoScroll: Bool) -> some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.transcriptModel.segments) { seg in
                            TranscriptRow(segment: seg)
                                .id(seg.id)
                        }

                        Color.clear.frame(height: 1).id("BOTTOM")
                    }
                    .padding(8)
                }
                .onChange(of: model.transcriptModel.segments.count) { _, _ in
                    guard autoScroll else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                    }
                }
            }
        }
        label: {
            HStack {
                Text("Live transcript")
                Spacer()
                Button {
                    let text = model.transcriptModel.asPlainText()
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    copyIconName = "checkmark"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copyIconName = "doc.on.clipboard"
                    }
                } label: {
                    Image(systemName: copyIconName)
                }
                .help("Copy transcript")

                Button {
                    model.exportTranscriptFiles()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Export transcript")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Level Meter

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).frame(width: 90, alignment: .leading)
                Text(String(format: "%.2f", level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)

                    let width = max(0.0, min(1.0, CGFloat(level))) * geo.size.width
                    RoundedRectangle(cornerRadius: 6)
                        .fill(level < 0.6 ? .green : (level < 0.85 ? .yellow : .red))
                        .frame(width: width)
                }
            }
            .frame(height: 12)
        }
    }
}
