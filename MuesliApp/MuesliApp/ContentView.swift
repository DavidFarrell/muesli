import SwiftUI
import Darwin
import CoreAudio
import Combine
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AppKit
import AudioToolbox
import Security

// MARK: - Root View

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.shouldShowOnboarding {
                OnboardingView()
            } else {
                switch model.activeScreen {
                case .start:
                    NewMeetingView()
                case .session:
                    SessionView()
                case .viewing(let item):
                    MeetingViewer(meeting: item)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Permissions") { model.showPermissionsSheet = true }
            }
        }
        .sheet(isPresented: $model.showPermissionsSheet) {
            PermissionsSheet()
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Muesli")
                .font(.largeTitle).bold()

            Text("""
Muesli needs:
- Screen recording permission (to capture system audio and screenshots)
- Microphone permission (to capture your voice)
""")

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    statusDot(ok: model.screenPermissionGranted)
                    Text("Screen recording")
                    Spacer()
                    Button("Request") { model.requestScreenPermission() }
                }

                HStack {
                    statusDot(ok: model.micPermission == .authorised)
                    Text("Microphone")
                    Spacer()
                    Button("Request") {
                        Task { await model.requestMicPermission() }
                    }
                }
            }
            .padding()
            .background(.thinMaterial)
            .cornerRadius(10)

            HStack {
                Button("Re-check") { model.refreshPermissions() }
                Spacer()
                Button("Continue") {
                    model.refreshPermissions()
                    if model.shouldShowOnboarding {
                        model.showPermissionsSheet = true
                    }
                }
                .keyboardShortcut(.defaultAction)
            }

            Spacer()

            Text("Tip: You can open the Permissions panel at any time from the toolbar.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    @ViewBuilder
    private func statusDot(ok: Bool) -> some View {
        Circle()
            .frame(width: 10, height: 10)
            .foregroundStyle(ok ? .green : .red)
            .accessibilityLabel(ok ? "Granted" : "Not granted")
    }
}

// MARK: - New Meeting

struct NewMeetingView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAllMeetings = false
    @State private var pendingDelete: MeetingHistoryItem?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New meeting")
                .font(.largeTitle).bold()

            HStack(spacing: 12) {
                Text("Title")
                    .frame(width: 60, alignment: .leading)
                TextField("yyyy-MM-dd-meeting", text: $model.meetingTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                Spacer()
            }

            HStack(spacing: 16) {
                Picker("Mode", selection: $model.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                Button(model.isLoadingShareableContent ? "Loading..." : "Refresh sources") {
                    Task { await model.loadShareableContent() }
                }
                .disabled(model.isLoadingShareableContent)
            }

            HStack(spacing: 16) {
                Picker("Source type", selection: $model.sourceKind) {
                    ForEach(SourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .frame(width: 220)

                Spacer()
            }
            if model.sourceKind == .window {
                Text("Window capture may only include that app's audio. Use Display to capture full system audio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Select capture source") {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = model.shareableContentError {
                        Text(err).foregroundStyle(.red)
                    }

                    if model.sourceKind == .display {
                        Picker("Display", selection: $model.selectedDisplayID) {
                            ForEach(model.displays, id: \.displayID) { display in
                                HStack(spacing: 10) {
                                    if let cgImage = model.displayThumbnails[display.displayID] {
                                        Image(decorative: cgImage, scale: 1.0)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 80, height: 45)
                                            .cornerRadius(4)
                                    }
                                    Text("Display \(display.displayID)")
                                }
                                .tag(Optional(display.displayID))
                            }
                        }
                    } else {
                        Picker("Window", selection: $model.selectedWindowID) {
                            ForEach(model.windows, id: \.windowID) { window in
                                let title = window.title ?? "(untitled)"
                                let app = window.owningApplication?.applicationName ?? "(unknown app)"
                                HStack(spacing: 10) {
                                    if let cgImage = model.windowThumbnails[window.windowID] {
                                        Image(decorative: cgImage, scale: 1.0)
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 80, height: 45)
                                            .cornerRadius(4)
                                    }
                                    Text("\(app) - \(title)")
                                        .lineLimit(1)
                                }
                                .tag(Optional(window.windowID))
                            }
                        }
                    }
                }
                .padding(8)
            }

            GroupBox("Microphone") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Input", selection: Binding(
                        get: { model.selectedInputDeviceID },
                        set: { model.selectedInputDeviceID = $0 }
                    )) {
                        ForEach(model.inputDevices, id: \.id) { device in
                            Text(device.name)
                                .tag(device.id)
                        }
                    }

                    Button("Refresh microphones") {
                        model.loadInputDevices()
                    }
                    .buttonStyle(.link)

                    Text("Changing the mic uses the system default input. Restart the meeting to apply.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Backend") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.backendFolderPath)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let pythonPath = model.backendPythonCandidatePath {
                        Text("Python: \(pythonPath)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text("App Support: \(model.appSupportPath)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Sandboxed: \(model.isSandboxed ? "Yes" : "No")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let err = model.backendFolderError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button("Select backend folder") {
                        model.chooseBackendFolder()
                    }
                    .buttonStyle(.bordered)

                    Text("Select the fast_mac_transcribe_diarise_local_models_only folder.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox("Transcription sources") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("System audio", isOn: $model.transcribeSystem)
                        .disabled(!model.transcribeMic)
                    Toggle("Microphone", isOn: $model.transcribeMic)
                        .disabled(!model.transcribeSystem)
                    Text("At least one source must be selected.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Start meeting") {
                    Task { await model.startMeeting() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.shouldShowOnboarding)
            }

            GroupBox("Recent meetings") {
                if model.meetingHistory.isEmpty {
                    Text("No meetings yet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleMeetings) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Button {
                                    model.openMeeting(item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text("\(formatDuration(item.durationSeconds)) • \(item.segmentCount) segments")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button {
                                    pendingDelete = item
                                    showDeleteConfirm = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }

                        if model.meetingHistory.count > maxVisibleMeetings {
                            Button(showAllMeetings ? "Show less" : "Show more") {
                                showAllMeetings.toggle()
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            if model.shouldShowOnboarding {
                Text("Permissions are missing. Use the toolbar Permissions button or onboarding to grant them.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .alert("Delete meeting?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let item = pendingDelete {
                    model.deleteMeeting(item)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This will move the meeting folder to the Trash.")
        }
    }

    private var maxVisibleMeetings: Int { 8 }

    private var visibleMeetings: [MeetingHistoryItem] {
        if showAllMeetings {
            return model.meetingHistory
        }
        return Array(model.meetingHistory.prefix(maxVisibleMeetings))
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
}

// MARK: - Meeting Viewer

struct MeetingViewer: View {
    @EnvironmentObject var model: AppModel
    let meeting: MeetingHistoryItem
    @State private var showSpeakers = false
    @State private var autoScroll = true
    @State private var copyIconName = "doc.on.clipboard"

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
}

// MARK: - Session

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSpeakers = false
    @State private var autoScroll = true
    @State private var showDebug = false
    @State private var copyIconName = "doc.on.clipboard"
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
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.currentSession?.title ?? "Meeting")
                    .font(.title2).bold()
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
                    LazyVStack(alignment: .leading, spacing: 10) {
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

struct TranscriptRow: View {
    @EnvironmentObject var model: AppModel
    let segment: TranscriptSegment
    @State private var showRename = false
    @State private var proposedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(model.transcriptModel.displayName(for: segment.speakerID)) {
                    proposedName = model.transcriptModel.displayName(for: segment.speakerID)
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

                Text(String(format: "t=%.2fs", segment.t0))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(segment.text)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(.thinMaterial)
        .cornerRadius(10)
        .sheet(isPresented: $showRename) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename speaker")
                    .font(.headline)

                Text("Speaker ID: \(segment.speakerID)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Name", text: $proposedName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel") { showRename = false }
                    Button("Save") {
                        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                        model.renameSpeaker(id: segment.speakerID, to: trimmed)
                        showRename = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 420)
        }
    }
}

// MARK: - Permissions Sheet

struct PermissionsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions")
                .font(.title2).bold()

            Text("""
Screen recording is required for capturing system audio and screenshots.
Microphone is required for capturing your voice.
""")
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    dot(ok: model.screenPermissionGranted)
                    Text("Screen recording")
                    Spacer()
                    Button("Request") { model.requestScreenPermission() }
                }

                HStack {
                    dot(ok: model.micPermission == .authorised)
                    Text("Microphone")
                    Spacer()
                    Button("Request") {
                        Task { await model.requestMicPermission() }
                    }
                }
            }
            .padding()
            .background(.thinMaterial)
            .cornerRadius(10)

            HStack {
                Button("Re-check") { model.refreshPermissions() }

                Spacer()

                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("If capture still fails after granting permission, quit and re-open Muesli.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 520)
        .onAppear { model.refreshPermissions() }
    }

    @ViewBuilder
    private func dot(ok: Bool) -> some View {
        Circle()
            .frame(width: 10, height: 10)
            .foregroundStyle(ok ? .green : .red)
    }
}

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
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(0.65))
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, level)))))
                }
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Permissions

enum PermissionState {
    case authorised
    case denied
    case notDetermined
}

struct Permissions {
    static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorised
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func screenCapturePreflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

// MARK: - Screenshot Scheduler

final class ScreenshotScheduler {
    private var timer: DispatchSourceTimer?
    private let ciContext = CIContext()

    func start(
        every intervalSeconds: Double,
        contentFilter: SCContentFilter,
        streamConfig: SCStreamConfiguration,
        meetingStartPTSProvider: @escaping () -> CMTime?,
        outputDir: URL,
        onScreenshotEvent: @escaping (_ tSeconds: Double, _ relativePath: String) -> Void
    ) {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "muesli.screenshots"))
        t.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            SCScreenshotManager.captureSampleBuffer(contentFilter: contentFilter, configuration: streamConfig) { sb, err in
                guard err == nil, let sb else { return }
                guard let startPTS = meetingStartPTSProvider() else { return }

                let pts = sb.presentationTimeStamp
                let delta = CMTimeSubtract(pts, startPTS)
                let tSec = max(0, CMTimeGetSeconds(delta))

                guard let imgBuf = CMSampleBufferGetImageBuffer(sb) else { return }
                let ci = CIImage(cvImageBuffer: imgBuf)
                guard let cg = self.ciContext.createCGImage(ci, from: ci.extent) else { return }

                let name = String(format: "t+%010.3f.png", tSec)
                let fileURL = outputDir.appendingPathComponent(name)
                self.writePNG(cgImage: cg, to: fileURL)

                onScreenshotEvent(tSec, "screenshots/\(name)")
            }
        }
        self.timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func writePNG(cgImage: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }
}

// MARK: - ScreenCaptureKit Helpers

enum ScreenCaptureKitHelpers {
    static func fetchShareableContent(excludingDesktopWindows: Bool, onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { cont in
            SCShareableContent.getExcludingDesktopWindows(excludingDesktopWindows, onScreenWindowsOnly: onScreenWindowsOnly) { content, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let content {
                    cont.resume(returning: content)
                } else {
                    cont.resume(throwing: NSError(domain: "Muesli", code: -1, userInfo: [NSLocalizedDescriptionKey: "No shareable content returned"]))
                }
            }
        }
    }
}

// MARK: - Audio Devices

struct AudioDevice: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

enum AudioDeviceManager {
    static func inputDevices() -> [AudioDevice] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        var devices: [AudioDevice] = []
        for id in deviceIDs {
            guard hasInputChannels(id) else { continue }
            let name = deviceName(id) ?? "Unknown"
            devices.append(AudioDevice(id: id, name: name))
        }

        return devices.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func defaultInputDeviceID() -> UInt32? {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(0)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &deviceID)
        if status != noErr {
            return nil
        }
        return deviceID
    }

    static func setDefaultInputDevice(_ id: UInt32) -> Bool {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(id)
        let dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectSetPropertyData(systemObject, &address, 0, nil, dataSize, &deviceID)
        return status == noErr
    }

    private static func deviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &name)
        if status != noErr {
            return nil
        }
        return name as String
    }

    private static func hasInputChannels(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) != noErr {
            return false
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let audioBufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, audioBufferList) != noErr {
            return false
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channelCount > 0
    }
}
