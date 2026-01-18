Below is a minimal, working SwiftUI UI layer for Muesli that includes:

* **Root flow**: onboarding (permissions) -> new meeting -> live session
* **Permissions sheet** available any time (re-check + request mic + request screen capture)
* **Session view** with:

  * live **system + mic meters**
  * live **transcript** (scrollable)
  * **speaker renaming** that updates historic entries automatically

It also includes a small **backend process manager** that reads JSONL from stdout and feeds it into the UI model.

This UI assumes you have the capture pieces from the previous message (CaptureEngine, ScreenshotScheduler, FramedWriter, AudioSampleExtractor). I include the small changes you need to make so screenshots can emit events and the UI can access levels and meeting start timestamps.

Where this uses ScreenCaptureKit types:

* It lists displays/windows from `SCShareableContent.getExcludingDesktopWindows(...)` and identifies them by `SCDisplay.displayID` and `SCWindow.windowID`. ([Apple Developer][1])
* It creates capture filters using `SCContentFilter(desktopIndependentWindow:)` for a window and `SCContentFilter(display:excludingApplications:exceptingWindows:)` for a display. ([Apple Developer][2])

---

## File layout

Create these files in your macOS SwiftUI app target:

* `MuesliApp.swift`
* `AppModel.swift`
* `BackendProcess.swift`
* `Views/RootView.swift`
* `Views/OnboardingView.swift`
* `Views/NewMeetingView.swift`
* `Views/SessionView.swift`
* `Views/PermissionsSheet.swift`
* `Views/SpeakersSheet.swift`
* `Views/LevelMeter.swift`

---

## 1) MuesliApp.swift

```swift
import SwiftUI

@main
struct MuesliApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
    }
}
```

---

## 2) AppModel.swift

This orchestrates:

* permissions state
* shareable content loading (displays/windows)
* meeting folder creation
* starting/stopping capture + backend
* feeding transcript JSONL into `TranscriptModel`

```swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable {
    case audioOnly = "Audio-only"
    case video = "Video (screenshots)"

    var id: String { rawValue }
}

enum SourceKind: String, CaseIterable, Identifiable {
    case display = "Display"
    case window = "Window"

    var id: String { rawValue }
}

struct MeetingSession {
    let title: String
    let folderURL: URL
    let startedAt: Date
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: - UI state
    @Published var showPermissionsSheet = false
    @Published var isCapturing = false
    @Published var captureMode: CaptureMode = .video
    @Published var sourceKind: SourceKind = .display

    @Published var meetingTitle: String = AppModel.defaultMeetingTitle()
    @Published var currentSession: MeetingSession?

    // MARK: - Permissions
    @Published var micPermission: PermissionState = .notDetermined
    @Published var screenPermissionGranted: Bool = false

    // MARK: - Shareable content
    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var isLoadingShareableContent = false
    @Published var shareableContentError: String?

    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?

    // MARK: - Models
    let transcriptModel = TranscriptModel()

    // MARK: - Capture + backend
    private let captureEngine = CaptureEngine()
    private let screenshotScheduler = ScreenshotScheduler()

    private var backend: BackendProcess?
    private var writer: FramedWriter?

    // You can point this at your demo backend script during development.
    // For a bundled app, consider putting the backend inside the app bundle and referencing it there.
    var backendCommand: [String] = ["/usr/bin/python3", "/ABS/PATH/TO/muesli_backend_demo.py"]

    init() {
        captureEngine.onLevelsUpdated = { [weak self] in
            self?.objectWillChange.send()
        }
        refreshPermissions()
        Task { await loadShareableContent() }
    }

    // MARK: - Convenience for UI
    var systemLevel: Float { captureEngine.systemLevel }
    var micLevel: Float { captureEngine.micLevel }

    var selectedDisplay: SCDisplay? {
        guard let id = selectedDisplayID else { return nil }
        return displays.first { $0.displayID == id }
    }

    var selectedWindow: SCWindow? {
        guard let id = selectedWindowID else { return nil }
        return windows.first { $0.windowID == id }
    }

    var shouldShowOnboarding: Bool {
        // Onboarding if either permission is missing.
        !(screenPermissionGranted && micPermission == .authorised)
    }

    // MARK: - Permissions
    func refreshPermissions() {
        micPermission = Permissions.microphoneState()
        screenPermissionGranted = Permissions.screenCapturePreflight()
    }

    func requestMicPermission() async {
        let ok = await Permissions.requestMicrophone()
        refreshPermissions()
        if !ok {
            showPermissionsSheet = true
        }
    }

    func requestScreenPermission() {
        _ = Permissions.requestScreenCapture()
        // The OS may require the user to toggle in System Settings and sometimes restart the app.
        // We always re-check immediately, and also provide a manual "Re-check" button.
        refreshPermissions()
    }

    // MARK: - Shareable content loading
    func loadShareableContent() async {
        isLoadingShareableContent = true
        shareableContentError = nil
        defer { isLoadingShareableContent = false }

        do {
            let content = try await ScreenCaptureKitHelpers.fetchShareableContent(
                excludingDesktopWindows: true,
                onScreenWindowsOnly: true
            )
            displays = content.displays
            windows = content.windows

            if selectedDisplayID == nil {
                selectedDisplayID = displays.first?.displayID
            }
            if selectedWindowID == nil {
                selectedWindowID = windows.first?.windowID
            }
        } catch {
            shareableContentError = String(describing: error)
        }
    }

    // MARK: - Meeting lifecycle
    func startMeeting() async {
        refreshPermissions()
        if shouldShowOnboarding {
            showPermissionsSheet = true
            return
        }

        guard !isCapturing else { return }

        // Validate capture source selection
        let filter: SCContentFilter
        switch sourceKind {
        case .display:
            guard let display = selectedDisplay else {
                shareableContentError = "No display selected."
                return
            }
            // Capture entire display
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .window:
            guard let window = selectedWindow else {
                shareableContentError = "No window selected."
                return
            }
            // Capture only the specified window
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        // Create meeting folder
        let title = normaliseMeetingTitle(meetingTitle)
        let folderURL = try! createMeetingFolder(title: title)
        let session = MeetingSession(title: title, folderURL: folderURL, startedAt: Date())
        currentSession = session

        // Start backend
        do {
            let backend = try BackendProcess(command: backendCommand)
            backend.onJSONLine = { [weak self] line in
                Task { @MainActor in
                    self?.transcriptModel.ingest(jsonLine: line)
                }
            }
            try backend.start()
            self.backend = backend

            let writer = FramedWriter(stdinHandle: backend.stdin)
            self.writer = writer

            // Send meeting meta
            let meta: [String: Any] = [
                "title": title,
                "start_wall_time": ISO8601DateFormatter().string(from: session.startedAt),
                "sample_rate": 48000,
                "channels": 1
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta)
            writer.send(type: .meetingStart, stream: .system, ptsUs: 0, payload: metaData)

            // Configure optional MP4 recording path
            let recordURL: URL?
            if captureMode == .video {
                recordURL = folderURL.appendingPathComponent("recording.mp4")
            } else {
                recordURL = nil
            }

            // Start capture
            try await captureEngine.startCapture(
                contentFilter: filter,
                writer: writer,
                recordTo: recordURL
            )

            // Start screenshot scheduler only for "video" mode
            if captureMode == .video {
                let screenshotsDir = folderURL.appendingPathComponent("screenshots", isDirectory: true)
                try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

                screenshotScheduler.start(
                    every: 5.0,
                    contentFilter: filter,
                    streamConfig: captureEngine.streamConfigurationForScreenshots(),
                    meetingStartPTSProvider: { [weak self] in self?.captureEngine.meetingStartPTS },
                    outputDir: screenshotsDir
                ) { [weak self] tSec, relativePath in
                    guard let self else { return }
                    let evt: [String: Any] = [
                        "t": tSec,
                        "path": relativePath
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: evt) {
                        // ptsUs is derived from tSec for convenience
                        let ptsUs = Int64(tSec * 1_000_000.0)
                        self.writer?.send(type: .screenshotEvent, stream: .system, ptsUs: ptsUs, payload: data)
                    }
                }
            }

            isCapturing = true
        } catch {
            shareableContentError = "Failed to start backend or capture: \(error)"
            await stopMeeting()
        }
    }

    func stopMeeting() async {
        guard isCapturing else { return }

        screenshotScheduler.stop()
        await captureEngine.stopCapture()

        writer?.send(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
        writer = nil

        backend?.stop()
        backend = nil

        isCapturing = false
        currentSession = nil
    }

    // MARK: - Folder helpers
    static func defaultMeetingTitle() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "\(df.string(from: Date()))-meeting"
    }

    private func normaliseMeetingTitle(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultMeetingTitle() : trimmed
    }

    private func createMeetingFolder(title: String) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muesli", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let folder = base.appendingPathComponent(title, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let metaURL = folder.appendingPathComponent("meta.json")
        let meta: [String: Any] = [
            "title": title,
            "created_at": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
        try data.write(to: metaURL)

        return folder
    }
}

// MARK: - ScreenCaptureKit helpers
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
```

---

## 3) BackendProcess.swift

Reads backend stdout as JSONL and feeds each line into a callback. Also exposes stdin for audio framing.

```swift
import Foundation

final class BackendProcess {

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var buffer = Data()

    var onJSONLine: ((String) -> Void)?

    var stdin: FileHandle { stdinPipe.fileHandleForWriting }

    init(command: [String]) throws {
        guard !command.isEmpty else { throw NSError(domain: "Muesli", code: -1) }

        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty { return }
            self.buffer.append(chunk)

            while true {
                if let range = self.buffer.firstRange(of: Data([0x0A])) { // \n
                    let lineData = self.buffer.subdata(in: 0..<range.lowerBound)
                    self.buffer.removeSubrange(0..<range.upperBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.onJSONLine?(line)
                    }
                } else {
                    break
                }
            }
        }

        try process.run()
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()

        if process.isRunning {
            process.terminate()
        }
    }
}
```

---

## 4) RootView.swift

Decides whether to show onboarding or meeting UI. Also provides a toolbar button for Permissions.

```swift
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.shouldShowOnboarding {
                OnboardingView()
            } else if model.isCapturing {
                SessionView()
            } else {
                NewMeetingView()
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
```

---

## 5) OnboardingView.swift

Polished enough to ship V1: shows status, request buttons, re-check.

```swift
import SwiftUI

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
                    // If still missing permissions, keep them on onboarding and open sheet for more detail.
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
```

---

## 6) NewMeetingView.swift

Lets you set meeting title, choose mode, pick display/window, refresh shareable content, start meeting.

```swift
import SwiftUI
import ScreenCaptureKit

struct NewMeetingView: View {
    @EnvironmentObject var model: AppModel

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
                    ForEach(CaptureMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                Button(model.isLoadingShareableContent ? "Loading…" : "Refresh sources") {
                    Task { await model.loadShareableContent() }
                }
                .disabled(model.isLoadingShareableContent)
            }

            HStack(spacing: 16) {
                Picker("Source type", selection: $model.sourceKind) {
                    ForEach(SourceKind.allCases) { k in
                        Text(k.rawValue).tag(k)
                    }
                }
                .frame(width: 220)

                Spacer()
            }

            GroupBox("Select capture source") {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = model.shareableContentError {
                        Text(err).foregroundStyle(.red)
                    }

                    if model.sourceKind == .display {
                        Picker("Display", selection: $model.selectedDisplayID) {
                            ForEach(model.displays, id: \.displayID) { d in
                                Text("Display \(d.displayID)")
                                    .tag(Optional(d.displayID))
                            }
                        }
                    } else {
                        Picker("Window", selection: $model.selectedWindowID) {
                            ForEach(model.windows, id: \.windowID) { w in
                                let title = w.title ?? "(untitled)"
                                let app = w.owningApplication?.applicationName ?? "(unknown app)"
                                Text("\(app) - \(title)")
                                    .lineLimit(1)
                                    .tag(Optional(w.windowID))
                            }
                        }
                    }
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

            Spacer()

            if model.shouldShowOnboarding {
                Text("Permissions are missing. Use the toolbar Permissions button or onboarding to grant them.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}
```

---

## 7) SessionView.swift

Live meters + transcript with rename and a “Speakers” sheet. Includes Stop.

```swift
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSpeakers = false

    @State private var autoScroll = true

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
                            HStack {
                                Button("Speakers") { showSpeakers = true }
                                Button("Permissions") { model.showPermissionsSheet = true }
                                Spacer()
                                Button("Stop") {
                                    Task { await model.stopMeeting() }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(8)
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
        GroupBox("Live transcript") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.transcriptModel.segments) { seg in
                            TranscriptRow(segment: seg)
                                .id(seg.id)
                        }

                        // Anchor for scroll-to-bottom
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TranscriptRow: View {
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
                        model.transcriptModel.renameSpeaker(id: segment.speakerID, to: proposedName.trimmingCharacters(in: .whitespacesAndNewlines))
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
```

---

## 8) PermissionsSheet.swift

Gives you a re-check panel that can be opened any time.

```swift
import SwiftUI
import AppKit

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
                    // Best-effort deep link. If it fails, the user can open manually.
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
```

---

## 9) SpeakersSheet.swift

Allows editing speaker names centrally. Historic transcript updates automatically because rendering uses a mapping.

```swift
import SwiftUI

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
                            set: { model.transcriptModel.renameSpeaker(id: id, to: $0) }
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
```

---

## 10) LevelMeter.swift

A very simple meter that is good enough for “is audio coming in” verification.

```swift
import SwiftUI

struct LevelMeter: View {
    let label: String
    let level: Float // 0..1

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
```

---

## 11) Small required changes to CaptureEngine to support this UI

Make these changes to your `CaptureEngine` from the previous message:

### A) Add a `private(set)` meeting start timestamp

```swift
private(set) var meetingStartPTS: CMTime?
```

and ensure you assign it when the first audio buffer arrives (you already do, just make it readable).

### B) Inject the writer rather than constructing it internally

Update the signature:

```swift
func startCapture(
    contentFilter: SCContentFilter,
    writer: FramedWriter,
    recordTo url: URL?
) async throws
```

Store `self.writer = writer` and use it for audio frames.

### C) Provide a screenshot stream configuration helper

So the screenshot scheduler can reuse consistent settings:

```swift
func streamConfigurationForScreenshots() -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    // Keep it lightweight. You can set sourceRect here later for region capture.
    c.showsCursor = true
    return c
}
```

---

## Quick “it works” checklist (fast tests)

1. **Onboarding**

   * Launch fresh, deny both permissions, confirm UI stays clear and does not crash.
   * Grant both, hit Re-check, confirm both go green.

2. **Audio meters**

   * Start meeting, play audio from YouTube/Zoom, confirm System meter moves.
   * Speak, confirm Microphone meter moves.

3. **Transcript**

   * With the demo backend, you should see periodic `(demo) audio at …s` messages.
   * Click a speaker label, rename, and confirm historic rows update.

4. **Screenshots** (video mode)

   * Confirm `screenshots/` fills with `t+....png` every 5 seconds.

---

If you want, next I can give you a “region capture” UI (drag-to-select rectangle) that sets `SCStreamConfiguration.sourceRect` correctly per-display coordinates, because that is the part most teams get subtly wrong on multi-display setups.

[1]: https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getexcludingdesktopwindows%28_%3Aonscreenwindowsonly%3Acompletionhandler%3A%29?utm_source=chatgpt.com "getExcludingDesktopWindows (_:onScreenWindowsOnly ..."
[2]: https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init%28desktopindependentwindow%3A%29?utm_source=chatgpt.com "init(desktopIndependentWindow:) | Apple Developer ..."
