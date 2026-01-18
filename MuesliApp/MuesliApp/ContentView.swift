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

// MARK: - App Model

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

enum BackendPythonError: Error {
    case venvOutside
    case venvMissing
    case venvNotExecutable

    var message: String {
        switch self {
        case .venvOutside:
            return "Backend venv points outside the backend folder. Recreate it with " +
                "/opt/homebrew/bin/python3.12 -m venv --copies .venv and install deps with pip."
        case .venvMissing:
            return "Backend venv not found. Run /opt/homebrew/bin/python3.12 -m venv --copies .venv and install deps with pip."
        case .venvNotExecutable:
            return "Backend venv python exists but is not executable. Recreate it with " +
                "/opt/homebrew/bin/python3.12 -m venv --copies .venv and install deps with pip."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    private let captureSampleRate = 48000
    private let captureChannels = 1

    @Published var showPermissionsSheet = false
    @Published var isCapturing = false
    @Published var captureMode: CaptureMode = .video
    @Published var sourceKind: SourceKind = .display
    @Published var transcribeSystem = true
    @Published var transcribeMic = true

    @Published var meetingTitle: String = AppModel.defaultMeetingTitle()
    @Published var currentSession: MeetingSession?

    @Published var micPermission: PermissionState = .notDetermined
    @Published var screenPermissionGranted: Bool = false

    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var isLoadingShareableContent = false
    @Published var shareableContentError: String?

    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedInputDeviceID: UInt32 = 0 {
        didSet {
            if selectedInputDeviceID != 0 {
                _ = AudioDeviceManager.setDefaultInputDevice(selectedInputDeviceID)
            }
        }
    }
    @Published var backendLogTail: [String] = []

    let transcriptModel = TranscriptModel()

    private let captureEngine = CaptureEngine()
    private let screenshotScheduler = ScreenshotScheduler()
    private let backendLogTailLimit = 200

    private var backend: BackendProcess?
    private var writer: FramedWriter?
    private var backendLogHandle: FileHandle?
    private var backendLogURL: URL?
    private var backendAccessURL: URL?
    private let backendBookmarkKey = "MuesliBackendBookmark"
    private let defaultBackendProjectRoot = URL(fileURLWithPath: "/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only")
    private var transcriptCancellable: AnyCancellable?

    @Published var backendFolderURL: URL?
    @Published var backendFolderError: String?

    var backendFolderPath: String {
        backendFolderURL?.path ?? "(not selected)"
    }
    var backendPythonCandidatePath: String? {
        backendFolderURL?.appendingPathComponent(".venv/bin/python").path
    }
    var backendPythonExists: Bool {
        guard let path = backendPythonCandidatePath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
    var appSupportPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "-"
    }
    var isSandboxed: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let entitlement = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        return (entitlement as? Bool) == true
    }

    init() {
        captureEngine.onLevelsUpdated = { [weak self] in
            self?.objectWillChange.send()
        }
        transcriptCancellable = transcriptModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        refreshPermissions()
        loadInputDevices()
        loadBackendBookmark()
        validateBackendFolder()
        Task { await loadShareableContent() }
    }

    var systemLevel: Float { captureEngine.systemLevel }
    var micLevel: Float { captureEngine.micLevel }
    var debugSystemBuffers: Int { captureEngine.debugSystemBuffers }
    var debugMicBuffers: Int { captureEngine.debugMicBuffers }
    var debugSystemFrames: Int { captureEngine.debugSystemFrames }
    var debugMicFrames: Int { captureEngine.debugMicFrames }
    var debugSystemPTS: Double { captureEngine.debugSystemPTS }
    var debugMicPTS: Double { captureEngine.debugMicPTS }
    var debugSystemFormat: String { captureEngine.debugSystemFormat }
    var debugMicFormat: String { captureEngine.debugMicFormat }
    var debugSystemErrorMessage: String { captureEngine.debugSystemErrorMessage }
    var debugMicErrorMessage: String { captureEngine.debugMicErrorMessage }
    var debugAudioErrors: Int { captureEngine.debugAudioErrors }
    var debugMicErrors: Int { captureEngine.debugMicErrors }
    var backendLogPath: String? { backendLogURL?.path }
    var debugSummary: String {
        let tail = backendLogTail.suffix(50).joined(separator: "\n")
        return """
        System buffers: \(debugSystemBuffers) frames: \(debugSystemFrames)
        System PTS: \(String(format: "%.3f", debugSystemPTS))
        System format: \(debugSystemFormat)
        System errors: \(debugAudioErrors)
        System last error: \(debugSystemErrorMessage)
        Mic buffers: \(debugMicBuffers) frames: \(debugMicFrames)
        Mic PTS: \(String(format: "%.3f", debugMicPTS))
        Mic format: \(debugMicFormat)
        Mic errors: \(debugMicErrors)
        Mic last error: \(debugMicErrorMessage)
        App Support: \(appSupportPath)
        Backend folder: \(backendFolderPath)
        Backend log: \(backendLogPath ?? "-")
        Backend python: \(backendPythonCandidatePath ?? "-") exists=\(backendPythonExists)
        Sandboxed: \(isSandboxed)
        Backend log tail:
        \(tail)
        """
    }

    private func resolveBackendPython(for root: URL) -> Result<String, BackendPythonError> {
        let venvPythonURL = root.appendingPathComponent(".venv/bin/python")
        if FileManager.default.fileExists(atPath: venvPythonURL.path) {
            #if DEBUG
            return .success(venvPythonURL.path)
            #else
            if FileManager.default.isExecutableFile(atPath: venvPythonURL.path) {
                return .success(venvPythonURL.path)
            }
            return .failure(.venvNotExecutable)
            #endif
        }
        return .failure(.venvMissing)
    }

    private func loadBackendBookmark() {
        backendFolderError = nil
        guard let data = UserDefaults.standard.data(forKey: backendBookmarkKey) else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            bookmarkDataIsStale: &stale
        ) {
            backendFolderURL = url
            if stale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(refreshed, forKey: backendBookmarkKey)
            }
        }
    }

    private func validateBackendFolder() {
        guard let url = backendFolderURL else {
            backendFolderError = "Select the backend folder."
            return
        }
        let pythonPath = url.appendingPathComponent(".venv/bin/python").path
        #if DEBUG
        if FileManager.default.fileExists(atPath: pythonPath) {
            backendFolderError = nil
            return
        }
        backendFolderError = "Backend venv not found. Run /opt/homebrew/bin/python3.12 -m venv --copies .venv and install deps with pip."
        #else
        if FileManager.default.isExecutableFile(atPath: pythonPath) {
            backendFolderError = nil
            return
        }
        if FileManager.default.fileExists(atPath: pythonPath) {
            backendFolderError = "Backend venv python is not executable. Recreate it with /opt/homebrew/bin/python3.12 -m venv --copies .venv and install deps with pip."
            return
        }
        backendFolderError = "Backend venv not found. Run /opt/homebrew/bin/python3.12 -m venv --copies .venv and install deps with pip."
        #endif
    }

    @MainActor
    func chooseBackendFolder() {
        backendFolderError = nil
        shareableContentError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultBackendProjectRoot.deletingLastPathComponent()
        panel.message = "Select the fast_mac_transcribe_diarise_local_models_only folder."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(data, forKey: backendBookmarkKey)
                backendFolderURL = url
                validateBackendFolder()
            } catch {
                backendFolderError = "Failed to save backend folder bookmark: \(error)"
            }
        }
    }

    private func startBackendAccess(for url: URL) -> Bool {
        guard backendAccessURL == nil else { return true }
        if url.startAccessingSecurityScopedResource() {
            backendAccessURL = url
            return true
        }
        return false
    }

    private func stopBackendAccess() {
        if let url = backendAccessURL {
            url.stopAccessingSecurityScopedResource()
        }
        backendAccessURL = nil
    }

    private func resetBackendLog(in folderURL: URL) {
        backendLogTail.removeAll()
        let logURL = folderURL.appendingPathComponent("backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        backendLogURL = logURL
        backendLogHandle = try? FileHandle(forWritingTo: logURL)
    }

    private func closeBackendLog() {
        if let handle = backendLogHandle {
            try? handle.close()
        }
        backendLogHandle = nil
    }

    private func appendBackendLog(_ line: String, toTail: Bool) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        if let data = (trimmed + "\n").data(using: .utf8) {
            backendLogHandle?.write(data)
        }
        guard toTail else { return }
        backendLogTail.append(trimmed)
        if backendLogTail.count > backendLogTailLimit {
            backendLogTail.removeFirst(backendLogTail.count - backendLogTailLimit)
        }
    }

    private func handleBackendJSONLine(_ line: String) {
        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = obj["type"] as? String {
            if type == "error" {
                let message = (obj["message"] as? String) ?? line
                appendBackendLog("[error] \(message)", toTail: true)
            } else if type == "status" {
                var parts: [String] = []
                if let message = obj["message"] as? String {
                    parts.append(message)
                }
                if let stream = obj["stream"] as? String {
                    parts.append("stream=\(stream)")
                }
                if let turns = obj["turns"] as? Int {
                    parts.append("turns=\(turns)")
                }
                if let duration = obj["duration"] as? Double {
                    parts.append(String(format: "duration=%.2fs", duration))
                }
                let text = parts.isEmpty ? line : parts.joined(separator: " ")
                appendBackendLog("[status] \(text)", toTail: true)
            }
        }
        transcriptModel.ingest(jsonLine: line)
    }

    var selectedDisplay: SCDisplay? {
        guard let id = selectedDisplayID else { return nil }
        return displays.first { $0.displayID == id }
    }

    var selectedWindow: SCWindow? {
        guard let id = selectedWindowID else { return nil }
        return windows.first { $0.windowID == id }
    }

    var shouldShowOnboarding: Bool {
        !(screenPermissionGranted && micPermission == .authorised)
    }

    func refreshPermissions() {
        micPermission = Permissions.microphoneState()
        screenPermissionGranted = Permissions.screenCapturePreflight()
        Task { await updateScreenPermissionFromShareableContent() }
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
        refreshPermissions()
    }

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
            screenPermissionGranted = true

            if selectedDisplayID == nil {
                selectedDisplayID = displays.first?.displayID
            }
            if selectedWindowID == nil {
                selectedWindowID = windows.first?.windowID
            }
        } catch {
            shareableContentError = String(describing: error)
            screenPermissionGranted = false
        }
    }

    func loadInputDevices() {
        inputDevices = AudioDeviceManager.inputDevices()
        if selectedInputDeviceID == 0 {
            let defaultID = AudioDeviceManager.defaultInputDeviceID()
            selectedInputDeviceID = defaultID ?? inputDevices.first?.id ?? 0
        }
    }

    private func updateScreenPermissionFromShareableContent() async {
        do {
            _ = try await ScreenCaptureKitHelpers.fetchShareableContent(
                excludingDesktopWindows: true,
                onScreenWindowsOnly: true
            )
            screenPermissionGranted = true
        } catch {
            screenPermissionGranted = false
        }
    }

    func startMeeting() async {
        refreshPermissions()
        backendFolderError = nil
        shareableContentError = nil
        if shouldShowOnboarding {
            showPermissionsSheet = true
            return
        }

        guard !isCapturing else { return }

        guard transcribeSystem || transcribeMic else {
            shareableContentError = "Select at least one transcription source."
            return
        }

        guard let backendProjectRoot = backendFolderURL else {
            shareableContentError = "Select the backend folder before starting."
            return
        }

        let filter: SCContentFilter
        switch sourceKind {
        case .display:
            guard let display = selectedDisplay else {
                shareableContentError = "No display selected."
                return
            }
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .window:
            guard let window = selectedWindow else {
                shareableContentError = "No window selected."
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let title = normaliseMeetingTitle(meetingTitle)
        let folderURL: URL
        do {
            folderURL = try createMeetingFolder(title: title)
        } catch {
            shareableContentError = "Failed to create meeting folder: \(error)"
            return
        }

        let session = MeetingSession(title: title, folderURL: folderURL, startedAt: Date())
        currentSession = session

        do {
            let audioDir = folderURL.appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            resetBackendLog(in: folderURL)

            if selectedInputDeviceID != 0 {
                _ = AudioDeviceManager.setDefaultInputDevice(selectedInputDeviceID)
            }

            guard startBackendAccess(for: backendProjectRoot) else {
                shareableContentError = "Backend folder access denied. Re-select the folder."
                closeBackendLog()
                currentSession = nil
                return
            }

            let writer: FramedWriter
            switch resolveBackendPython(for: backendProjectRoot) {
            case .success(let backendPython):
                if !FileManager.default.fileExists(atPath: backendPython) {
                    let message = "Backend python not found at \(backendPython)."
                    shareableContentError = message
                    backendFolderError = message
                    closeBackendLog()
                    stopBackendAccess()
                    currentSession = nil
                    return
                }
                let transcribeStream: String
                if transcribeSystem && transcribeMic {
                    transcribeStream = "both"
                } else if transcribeSystem {
                    transcribeStream = "system"
                } else {
                    transcribeStream = "mic"
                }

                var command = [
                    backendPython,
                    "-m",
                    "diarise_transcribe.muesli_backend",
                    "--emit-meters",
                    "--transcribe-stream",
                    transcribeStream,
                    "--output-dir",
                    audioDir.path
                ]
                #if DEBUG
                command.append(contentsOf: ["--verbose", "--live-interval", "5", "--live-min-seconds", "5"])
                #endif
                let baseEnv = ProcessInfo.processInfo.environment
                let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                let mergedPath: String
                if let existingPath = baseEnv["PATH"], !existingPath.isEmpty {
                    mergedPath = "\(defaultPath):\(existingPath)"
                } else {
                    mergedPath = defaultPath
                }
                let backendEnv = [
                    "PYTHONPATH": backendProjectRoot.appendingPathComponent("src").path,
                    "PATH": mergedPath
                ]
                let backend = try BackendProcess(
                    command: command,
                    workingDirectory: backendProjectRoot,
                    environment: backendEnv
                )
                appendBackendLog("Backend folder: \(backendProjectRoot.path)", toTail: true)
                appendBackendLog("PATH: \(mergedPath)", toTail: true)
                appendBackendLog("Command: \(command.joined(separator: " "))", toTail: true)
                backend.onExit = { [weak self] status in
                    Task { @MainActor in
                        self?.appendBackendLog("Backend exited with status \(status)", toTail: true)
                    }
                }
                backend.onStdoutLine = { [weak self] line in
                    Task { @MainActor in
                        self?.handleBackendJSONLine(line)
                    }
                }
                backend.onStderrLine = { [weak self] line in
                    Task { @MainActor in
                        self?.appendBackendLog("[stderr] \(line)", toTail: true)
                    }
                }
                try backend.start()
                self.backend = backend
                let createdWriter = FramedWriter(stdinHandle: backend.stdin)
                self.writer = createdWriter
                writer = createdWriter

            case .failure(let error):
                shareableContentError = error.message
                backendFolderError = error.message
                appendBackendLog("Backend start blocked: \(error.message)", toTail: true)
                closeBackendLog()
                stopBackendAccess()
                currentSession = nil
                return
            }

            let meta: [String: Any] = [
                "protocol_version": 1,
                "sample_format": "s16le",
                "title": title,
                "start_wall_time": ISO8601DateFormatter().string(from: session.startedAt),
                "sample_rate": captureSampleRate,
                "channels": captureChannels
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta)
            writer.send(type: .meetingStart, stream: .system, ptsUs: 0, payload: metaData)
            appendBackendLog("Sent meeting_start", toTail: true)

            let recordURL: URL?
            if captureMode == .video {
                recordURL = folderURL.appendingPathComponent("recording.mp4")
            } else {
                recordURL = nil
            }

            try await captureEngine.startCapture(
                contentFilter: filter,
                writer: writer,
                recordTo: recordURL
            )

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
                        let ptsUs = Int64(tSec * 1_000_000.0)
                        self.writer?.send(type: .screenshotEvent, stream: .system, ptsUs: ptsUs, payload: data)
                    }
                }
            }

            isCapturing = true
        } catch {
            let pythonPath = backendPythonCandidatePath ?? "(unknown)"
            let nsError = error as NSError
            let details = "domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)"
            shareableContentError = "Failed to start backend or capture: \(error). Python: \(pythonPath) exists=\(backendPythonExists) sandboxed=\(isSandboxed) \(details)"
            appendBackendLog("Start failure: \(shareableContentError ?? "\(error)")", toTail: true)
            closeBackendLog()
            stopBackendAccess()
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
        closeBackendLog()
        stopBackendAccess()

        isCapturing = false
        currentSession = nil
    }

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

// MARK: - Root View

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

            GroupBox("Select capture source") {
                VStack(alignment: .leading, spacing: 12) {
                    if let err = model.shareableContentError {
                        Text(err).foregroundStyle(.red)
                    }

                    if model.sourceKind == .display {
                        Picker("Display", selection: $model.selectedDisplayID) {
                            ForEach(model.displays, id: \.displayID) { display in
                                Text("Display \(display.displayID)")
                                    .tag(Optional(display.displayID))
                            }
                        }
                    } else {
                        Picker("Window", selection: $model.selectedWindowID) {
                            ForEach(model.windows, id: \.windowID) { window in
                                let title = window.title ?? "(untitled)"
                                let app = window.owningApplication?.applicationName ?? "(unknown app)"
                                Text("\(app) - \(title)")
                                    .lineLimit(1)
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

            Spacer()

            if model.shouldShowOnboarding {
                Text("Permissions are missing. Use the toolbar Permissions button or onboarding to grant them.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }
}

// MARK: - Session

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSpeakers = false
    @State private var autoScroll = true
    @State private var showDebug = false
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
        GroupBox("Live transcript") {
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
                        model.transcriptModel.renameSpeaker(id: segment.speakerID, to: trimmed)
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

// MARK: - Transcript Model

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let speakerID: String
    let stream: String
    let t0: Double
    let t1: Double?
    let text: String
    let isPartial: Bool
}

@MainActor
final class TranscriptModel: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var speakerNames: [String: String] = [:]
    @Published var lastTranscriptAt: Date?
    @Published var lastTranscriptText: String = ""

    func displayName(for speakerID: String) -> String {
        speakerNames[speakerID] ?? speakerID
    }

    func renameSpeaker(id: String, to name: String) {
        speakerNames[id] = name
    }

    func ingest(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return
        }

        switch type {
        case "segment":
            let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
            let stream = (obj["stream"] as? String) ?? "unknown"
            let t0 = (obj["t0"] as? Double) ?? 0
            let t1 = obj["t1"] as? Double
            let text = (obj["text"] as? String) ?? ""
            let segment = TranscriptSegment(
                speakerID: speakerID,
                stream: stream,
                t0: t0,
                t1: t1,
                text: text,
                isPartial: false
            )
            segments.removeAll { $0.isPartial }
            segments.append(segment)
            lastTranscriptAt = Date()
            if !text.isEmpty {
                lastTranscriptText = text
            }

        case "partial":
            let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
            let stream = (obj["stream"] as? String) ?? "unknown"
            let t0 = (obj["t0"] as? Double) ?? 0
            let text = (obj["text"] as? String) ?? ""
            let segment = TranscriptSegment(
                speakerID: speakerID,
                stream: stream,
                t0: t0,
                t1: nil,
                text: text,
                isPartial: true
            )
            if let idx = segments.lastIndex(where: { $0.isPartial }) {
                segments[idx] = segment
            } else {
                segments.append(segment)
            }
            lastTranscriptAt = Date()
            if !text.isEmpty {
                lastTranscriptText = text
            }

        case "speakers":
            if let known = obj["known"] as? [[String: Any]] {
                for entry in known {
                    if let speakerID = entry["speaker_id"] as? String {
                        let name = (entry["name"] as? String) ?? speakerID
                        speakerNames[speakerID] = name
                    }
                }
            }

        default:
            return
        }
    }
}

// MARK: - Backend Process

final class BackendProcess {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let workingDirectory: URL?
    private let environment: [String: String]?

    private var buffer = Data()
    private var stderrBuffer = Data()

    var onJSONLine: ((String) -> Void)?
    var onStdoutLine: ((String) -> Void)?
    var onStderrLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    var stdin: FileHandle { stdinPipe.fileHandleForWriting }

    init(command: [String], workingDirectory: URL? = nil, environment: [String: String]? = nil) throws {
        guard !command.isEmpty else {
            throw NSError(domain: "Muesli", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty command"])
        }

        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        self.workingDirectory = workingDirectory
        self.environment = environment

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self.buffer.append(chunk)

            while true {
                if let range = self.buffer.firstRange(of: Data([0x0A])) {
                    let lineData = self.buffer.subdata(in: 0..<range.lowerBound)
                    self.buffer.removeSubrange(0..<range.upperBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.onStdoutLine?(line)
                        self.onJSONLine?(line)
                    }
                } else {
                    break
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self.stderrBuffer.append(chunk)

            while true {
                if let range = self.stderrBuffer.firstRange(of: Data([0x0A])) {
                    let lineData = self.stderrBuffer.subdata(in: 0..<range.lowerBound)
                    self.stderrBuffer.removeSubrange(0..<range.upperBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.onStderrLine?(line)
                    }
                } else {
                    break
                }
            }
        }

        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                env[key] = value
            }
            process.environment = env
        }

        process.terminationHandler = { [weak self] proc in
            self?.onExit?(proc.terminationStatus)
        }

        try process.run()
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()

        if process.isRunning {
            process.terminate()
        }
    }
}

// MARK: - Framed Writer

enum StreamID: UInt8 {
    case system = 0
    case mic = 1
}

enum MsgType: UInt8 {
    case audio = 1
    case screenshotEvent = 2
    case meetingStart = 3
    case meetingStop = 4
}

final class FramedWriter {
    private let handle: FileHandle
    private let writeQueue = DispatchQueue(label: "muesli.framed-writer")

    init(stdinHandle: FileHandle) {
        self.handle = stdinHandle
    }

    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        writeQueue.async {
            var header = Data()
            header.append(type.rawValue)
            header.append(stream.rawValue)

            var pts = ptsUs.littleEndian
            header.append(Data(bytes: &pts, count: 8))

            var len = UInt32(payload.count).littleEndian
            header.append(Data(bytes: &len, count: 4))

            do {
                try self.handle.write(contentsOf: header)
                try self.handle.write(contentsOf: payload)
            } catch {
                return
            }
        }
    }
}

// MARK: - Audio Extraction

enum AudioExtractError: Error {
    case missingFormat
    case unsupportedFormat
    case failedToGetBufferList(OSStatus)
}

struct PCMChunk {
    let pts: CMTime
    let data: Data
    let frameCount: Int
}

final class AudioSampleExtractor {
    func extractInt16Mono(from sampleBuffer: CMSampleBuffer) throws -> PCMChunk {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioExtractError.missingFormat
        }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            throw AudioExtractError.missingFormat
        }
        let asbd = asbdPtr.pointee

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 0,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        if status != noErr {
            throw AudioExtractError.failedToGetBufferList(status)
        }

        let dataPointer = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let pts = sampleBuffer.presentationTimeStamp
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        let bufferCount = Int(dataPointer.count)
        if bufferCount < 1 {
            throw AudioExtractError.unsupportedFormat
        }

        var mono = [Float](repeating: 0, count: frames)
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let channelsPerFrame = Int(asbd.mChannelsPerFrame)

        for b in 0..<bufferCount {
            guard let mData = dataPointer[b].mData else { continue }
            let byteSize = Int(dataPointer[b].mDataByteSize)

            if isFloat && bitsPerChannel == 32 {
                let sampleCount = byteSize / MemoryLayout<Float>.size
                let floats = mData.bindMemory(to: Float.self, capacity: sampleCount)
                if isInterleaved && channelsPerFrame > 1 {
                    let framesAvailable = sampleCount / channelsPerFrame
                    let count = min(frames, framesAvailable)
                    for i in 0..<count {
                        var sum: Float = 0
                        let base = i * channelsPerFrame
                        for ch in 0..<channelsPerFrame {
                            sum += floats[base + ch]
                        }
                        mono[i] += sum / Float(channelsPerFrame)
                    }
                } else {
                    let count = min(frames, sampleCount)
                    for i in 0..<count {
                        mono[i] += floats[i]
                    }
                }
            } else if isSignedInt && bitsPerChannel == 16 {
                let sampleCount = byteSize / MemoryLayout<Int16>.size
                let ints = mData.bindMemory(to: Int16.self, capacity: sampleCount)
                if isInterleaved && channelsPerFrame > 1 {
                    let framesAvailable = sampleCount / channelsPerFrame
                    let count = min(frames, framesAvailable)
                    for i in 0..<count {
                        var sum: Float = 0
                        let base = i * channelsPerFrame
                        for ch in 0..<channelsPerFrame {
                            sum += Float(ints[base + ch]) / 32768.0
                        }
                        mono[i] += sum / Float(channelsPerFrame)
                    }
                } else {
                    let count = min(frames, sampleCount)
                    for i in 0..<count {
                        mono[i] += Float(ints[i]) / 32768.0
                    }
                }
            } else if isSignedInt && bitsPerChannel == 32 {
                let sampleCount = byteSize / MemoryLayout<Int32>.size
                let ints = mData.bindMemory(to: Int32.self, capacity: sampleCount)
                if isInterleaved && channelsPerFrame > 1 {
                    let framesAvailable = sampleCount / channelsPerFrame
                    let count = min(frames, framesAvailable)
                    for i in 0..<count {
                        var sum: Float = 0
                        let base = i * channelsPerFrame
                        for ch in 0..<channelsPerFrame {
                            sum += Float(ints[base + ch]) / 2147483648.0
                        }
                        mono[i] += sum / Float(channelsPerFrame)
                    }
                } else {
                    let count = min(frames, sampleCount)
                    for i in 0..<count {
                        mono[i] += Float(ints[i]) / 2147483648.0
                    }
                }
            } else {
                throw AudioExtractError.unsupportedFormat
            }
        }

        let denom = Float(bufferCount)
        var out = Data(count: frames * MemoryLayout<Int16>.size)

        out.withUnsafeMutableBytes { rawBuf in
            let outPtr = rawBuf.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let v = mono[i] / max(1, denom)
                let clamped = max(-1.0, min(1.0, v))
                outPtr[i] = Int16(clamped * 32767.0)
            }
        }

        return PCMChunk(pts: pts, data: out, frameCount: frames)
    }
}

// MARK: - Capture Engine

@MainActor
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sampleRate = 48000
    private let channelCount = 1

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let recordingDelegate = RecordingDelegate()

    private let extractor = AudioSampleExtractor()

    private(set) var meetingStartPTS: CMTime?
    private var writer: FramedWriter?

    var systemLevel: Float = 0
    var micLevel: Float = 0

    var debugSystemBuffers: Int = 0
    var debugMicBuffers: Int = 0
    var debugSystemFrames: Int = 0
    var debugMicFrames: Int = 0
    var debugSystemPTS: Double = 0
    var debugMicPTS: Double = 0
    var debugSystemFormat: String = "-"
    var debugMicFormat: String = "-"
    var debugSystemErrorMessage: String = "-"
    var debugMicErrorMessage: String = "-"
    var debugAudioErrors: Int = 0
    var debugMicErrors: Int = 0

    var onLevelsUpdated: (() -> Void)?

    func startCapture(
        contentFilter: SCContentFilter,
        writer: FramedWriter,
        recordTo url: URL?
    ) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = channelCount
        config.excludesCurrentProcessAudio = true

        if #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }

        let stream = SCStream(filter: contentFilter, configuration: config, delegate: self)
        self.stream = stream

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.system"))
        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.mic"))
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "muesli.video.drop"))

        self.writer = writer

        if #available(macOS 15.0, *), let recordURL = url {
            let roConfig = SCRecordingOutputConfiguration()
            roConfig.outputURL = recordURL
            roConfig.outputFileType = .mp4
            let ro = SCRecordingOutput(configuration: roConfig, delegate: recordingDelegate)
            try stream.addRecordingOutput(ro)
            self.recordingOutput = ro
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func stopCapture() async {
        guard let stream else { return }

        await withCheckedContinuation { cont in
            stream.stopCapture { _ in cont.resume() }
        }

        self.stream = nil
        self.recordingOutput = nil
        self.writer = nil
        self.meetingStartPTS = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            return
        }
        guard sampleBuffer.isValid else { return }

        do {
            let pcm = try extractor.extractInt16Mono(from: sampleBuffer)

            if meetingStartPTS == nil {
                meetingStartPTS = pcm.pts
            }
            guard let start = meetingStartPTS else { return }

            let delta = CMTimeSubtract(pcm.pts, start)
            let seconds = CMTimeGetSeconds(delta)
            let ptsUs = Int64(seconds * 1_000_000.0)

            let level = rmsLevelInt16(pcm.data)
            let ptsSeconds = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
            let formatInfo = formatString(from: sampleBuffer) ?? "-"

            DispatchQueue.main.async {
                if type == .audio {
                    self.systemLevel = level
                    self.debugSystemBuffers += 1
                    self.debugSystemFrames = pcm.frameCount
                    self.debugSystemPTS = ptsSeconds
                    self.debugSystemFormat = formatInfo
                } else if #available(macOS 15.0, *), type == .microphone {
                    self.micLevel = level
                    self.debugMicBuffers += 1
                    self.debugMicFrames = pcm.frameCount
                    self.debugMicPTS = ptsSeconds
                    self.debugMicFormat = formatInfo
                }
                self.onLevelsUpdated?()
            }

            if type == .screen {
                return
            } else if type == .audio {
                writer?.send(type: .audio, stream: .system, ptsUs: ptsUs, payload: pcm.data)
            } else if #available(macOS 15.0, *), type == .microphone {
                writer?.send(type: .audio, stream: .mic, ptsUs: ptsUs, payload: pcm.data)
            }
        } catch {
            let formatInfo = formatString(from: sampleBuffer) ?? "-"
            let errorMessage = describeError(error)
            DispatchQueue.main.async {
                if type == .audio {
                    self.debugAudioErrors += 1
                    self.debugSystemFormat = formatInfo
                    self.debugSystemErrorMessage = errorMessage
                } else if #available(macOS 15.0, *), type == .microphone {
                    self.debugMicErrors += 1
                    self.debugMicFormat = formatInfo
                    self.debugMicErrorMessage = errorMessage
                }
            }
            return
        }
    }

    func streamConfigurationForScreenshots() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.showsCursor = true
        return c
    }

    private func rmsLevelInt16(_ data: Data) -> Float {
        let count = data.count / 2
        if count == 0 { return 0 }

        var sumSquares: Double = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Double(p[i]) / 32768.0
                sumSquares += v * v
            }
        }
        let rms = sqrt(sumSquares / Double(count))
        return Float(min(1.0, rms))
    }

    private func formatString(from sampleBuffer: CMSampleBuffer) -> String? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let rate = Int(asbd.mSampleRate)
        let channels = asbd.mChannelsPerFrame
        let bits = asbd.mBitsPerChannel
        let formatID = fourCC(asbd.mFormatID)
        let flags = String(format: "0x%08X", asbd.mFormatFlags)
        return "id=\(formatID) sr=\(rate) ch=\(channels) bits=\(bits) flags=\(flags)"
    }

    private func describeError(_ error: Error) -> String {
        if let audioError = error as? AudioExtractError {
            switch audioError {
            case .missingFormat:
                return "missing_format"
            case .unsupportedFormat:
                return "unsupported_format"
            case .failedToGetBufferList(let status):
                return "buffer_list_error=\(status)"
            }
        }
        return String(describing: error)
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return bytes.map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
    }
}

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {}

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
