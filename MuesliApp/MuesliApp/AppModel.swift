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

enum SpeakerIdStatus: Equatable {
    case unknown
    case ready
    case ollamaNotRunning
    case modelMissing(String)
    case error(String)
}

enum AppScreen {
    case start
    case session
    case viewing(MeetingHistoryItem)
}

@MainActor
final class AppModel: ObservableObject {
    private let captureSampleRate = 16000
    private let captureChannels = 1
    private let micOutputSampleRate = 16000
    private let micOutputChannels = 1

    @Published var showPermissionsSheet = false
    @Published var isCapturing = false
    @Published var isFinalizing = false
    @Published var captureMode: CaptureMode = .video
    @Published var sourceKind: SourceKind = .display
    @Published var transcribeSystem = true
    @Published var transcribeMic = true

    @Published var meetingTitle: String = AppModel.defaultMeetingTitle()
    @Published var currentSession: MeetingSession?
    @Published var tempTranscriptFolderPath: String?

    @Published var micPermission: PermissionState = .notDetermined
    @Published var screenPermissionGranted: Bool = false

    @Published var displays: [SCDisplay] = []
    @Published var windows: [SCWindow] = []
    @Published var displayThumbnails: [CGDirectDisplayID: CGImage] = [:]
    @Published var windowThumbnails: [CGWindowID: CGImage] = [:]
    @Published var isLoadingShareableContent = false
    @Published var shareableContentError: String?

    @Published var selectedDisplayID: CGDirectDisplayID?
    @Published var selectedWindowID: CGWindowID?
    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedInputDeviceID: UInt32 = 0
    @Published var backendLogTail: [String] = []
    @Published var micLevel: Float = 0
    @Published var isPreviewingLevels = false
    @Published private(set) var isStartingMeeting = false
    @Published private(set) var isSwitchingInputDevice = false
    @Published var debugMicBuffers: Int = 0
    @Published var debugMicFrames: Int = 0
    @Published var debugMicPTS: Double = 0
    @Published var debugMicFormat: String = "-"
    @Published var debugMicErrorMessage: String = "-"
    @Published var debugMicErrors: Int = 0

    let transcriptModel = TranscriptModel()
    @Published var currentAttachments: [Attachment] = []

    private let captureEngine = CaptureEngine()
    private var micEngine: MicEngine?
    private var previewMicEngine: MicEngine?
    private var isPreviewCaptureRunning = false
    private var previewLifecycleTask: Task<Void, Never>?
    private var inputDeviceSelectionTask: Task<Void, Never>?
    private var micStartupHealthTask: Task<Void, Never>?
    private var micStartTime: Date?
    private var micOutputEnabled = false
    private var micStartupRecoveryAttempts = 0
    private let maxMicStartupRecoveryAttempts = 1
    private var pendingMicAudio: [PendingAudio] = []
    private let maxPendingMicAudio = 200
    private let screenshotScheduler = ScreenshotScheduler()
    private let backendLogTailLimit = 200

    private var backend: BackendProcess?
    private var writer: FramedWriter?
    private var backendLogHandle: FileHandle?
    private var backendLogURL: URL?
    private var transcriptEventsHandle: FileHandle?
    private var transcriptEventsURL: URL?
    private var currentTranscriptEventsStartOffset: UInt64 = 0
    private var backendAccessURL: URL?
    private var stdoutTask: Task<Void, Never>?
    private let backendBookmarkKey = "MuesliBackendBookmark"
    private var defaultBackendProjectRoot: URL? {
        if let envPath = ProcessInfo.processInfo.environment["MUESLI_BACKEND_ROOT"],
           !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        #if DEBUG
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidate = cwd.appendingPathComponent("backend/fast_mac_transcribe_diarise_local_models_only")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        #endif
        return nil
    }
    private var transcriptCancellable: AnyCancellable?

    @Published var backendFolderURL: URL?
    @Published var backendFolderError: String?
    @Published var meetingHistory: [MeetingHistoryItem] = []
    @Published var activeScreen: AppScreen = .start
    @Published var speakerIdStatus: SpeakerIdStatus = .unknown

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
    var speakerIdStatusMessage: String? {
        switch speakerIdStatus {
        case .unknown:
            return nil
        case .ready:
            return nil
        case .ollamaNotRunning:
            return "Ollama is not running. Start `ollama serve`."
        case .modelMissing(let name):
            return "Model missing: \(name). Run `ollama pull \(name)`."
        case .error(let message):
            return "Speaker ID error: \(message)"
        }
    }

    init() {
        captureEngine.onLevelsUpdated = { [weak self] in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        transcriptCancellable = transcriptModel.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        AudioDeviceManager.observeInputDeviceChanges { [weak self] in
            self?.loadInputDevices()
        }
        refreshPermissions()
        loadInputDevices()
        loadBackendBookmark()
        validateBackendFolder()
        migrateLegacyMeetingsIfNeeded()
        loadMeetingHistory()
        Task { await loadShareableContent() }
    }

    var systemLevel: Float { captureEngine.systemLevel }
    var debugSystemBuffers: Int { captureEngine.debugSystemBuffers }
    var debugSystemFrames: Int { captureEngine.debugSystemFrames }
    var debugSystemPTS: Double { captureEngine.debugSystemPTS }
    var debugSystemFormat: String { captureEngine.debugSystemFormat }
    var debugSystemErrorMessage: String { captureEngine.debugSystemErrorMessage }
    var debugAudioErrors: Int { captureEngine.debugAudioErrors }
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
        Transcript temp folder: \(tempTranscriptFolderPath ?? "-")
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
        if let defaultBackendProjectRoot {
            panel.directoryURL = defaultBackendProjectRoot.deletingLastPathComponent()
        }
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

    private func stopBackendAccess(for url: URL?) {
        url?.stopAccessingSecurityScopedResource()
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

    private func resetTranscriptEventsLog(in folderURL: URL, append: Bool) {
        let logURL = folderURL.appendingPathComponent("transcript_events.jsonl")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        transcriptEventsURL = logURL
        if let handle = try? FileHandle(forWritingTo: logURL) {
            if append {
                currentTranscriptEventsStartOffset = (try? handle.seekToEnd()) ?? 0
            } else {
                try? handle.truncate(atOffset: 0)
                currentTranscriptEventsStartOffset = 0
            }
            transcriptEventsHandle = handle
        } else {
            currentTranscriptEventsStartOffset = 0
        }
    }

    private func loadTranscriptFromDisk(in folderURL: URL) {
        let transcriptURL = folderURL.appendingPathComponent("transcript.jsonl")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return }
        guard let data = try? Data(contentsOf: transcriptURL),
              let content = String(data: data, encoding: .utf8) else {
            return
        }
        for line in content.split(whereSeparator: \.isNewline) {
            transcriptModel.ingest(jsonLine: String(line))
        }
    }

    private func closeTranscriptEventsLog() {
        if let handle = transcriptEventsHandle {
            try? handle.close()
        }
        transcriptEventsHandle = nil
        currentTranscriptEventsStartOffset = 0
    }

    private func closeHandle(_ handle: FileHandle?) {
        if let handle {
            try? handle.close()
        }
    }

    private func appendBackendLogTail(_ line: String) {
        backendLogTail.append(line)
        if backendLogTail.count > backendLogTailLimit {
            backendLogTail.removeFirst(backendLogTail.count - backendLogTailLimit)
        }
    }

    private func writeDataToHandle(_ data: Data, handle: FileHandle?) -> Error? {
        guard let handle else { return nil }
        do {
            try handle.write(contentsOf: data)
            return nil
        } catch {
            return error
        }
    }

    private func synchronizeHandle(_ handle: FileHandle?, label: String) {
        guard let handle else { return }
        do {
            try handle.synchronize()
        } catch {
            appendBackendLogTail("Failed to flush \(label): \(error.localizedDescription)")
        }
    }

    private func appendBackendLog(_ line: String, toTail: Bool, handle: FileHandle? = nil) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        if let data = (trimmed + "\n").data(using: .utf8) {
            if let error = writeDataToHandle(data, handle: handle ?? backendLogHandle), toTail {
                appendBackendLogTail("[backend.log write failed] \(error.localizedDescription)")
            }
        }
        guard toTail else { return }
        appendBackendLogTail(trimmed)
    }

    private func handleBackendWriteError(_ error: Error) {
        guard isCapturing else { return }
        let message = "Backend connection lost: \(error.localizedDescription)"
        shareableContentError = message
        appendBackendLog(message, toTail: true)
        Task { await stopMeeting() }
    }

    private func handleBackendJSONLine(
        _ line: String,
        transcriptEventsHandle: FileHandle?,
        backendLogHandle: FileHandle?,
        ingestIntoLiveTranscript: Bool
    ) {
        if let data = (line + "\n").data(using: .utf8) {
            if let error = writeDataToHandle(data, handle: transcriptEventsHandle) {
                appendBackendLog(
                    "Failed to append transcript event: \(error.localizedDescription)",
                    toTail: ingestIntoLiveTranscript,
                    handle: backendLogHandle
                )
            }
        }
        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = obj["type"] as? String {
            if type == "error" {
                let message = (obj["message"] as? String) ?? line
                appendBackendLog("[error] \(message)", toTail: ingestIntoLiveTranscript, handle: backendLogHandle)
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
                appendBackendLog("[status] \(text)", toTail: ingestIntoLiveTranscript, handle: backendLogHandle)
            }
        }
        if ingestIntoLiveTranscript {
            transcriptModel.ingest(jsonLine: line)
        }
    }

    private func resetMicDebugState() {
        micLevel = 0
        debugMicBuffers = 0
        debugMicFrames = 0
        debugMicPTS = 0
        debugMicFormat = "-"
        debugMicErrorMessage = "-"
        debugMicErrors = 0
    }

    private func handleMicAudio(_ data: Data) {
        guard transcribeMic, writer != nil else { return }
        let now = Date()
        if micStartTime == nil {
            micStartTime = now
        }
        let elapsed = now.timeIntervalSince(micStartTime ?? now)
        let ptsUs = Int64(elapsed * 1_000_000.0)

        micLevel = rmsLevelInt16(data)
        debugMicBuffers += 1
        debugMicFrames = data.count / 2
        debugMicPTS = elapsed
        debugMicFormat = "s16le sr=\(micOutputSampleRate) ch=\(micOutputChannels)"

        let payload = data
        if micOutputEnabled {
            writer?.send(type: .audio, stream: .mic, ptsUs: ptsUs, payload: payload)
        } else {
            pendingMicAudio.append(PendingAudio(
                ptsUs: ptsUs,
                payload: payload,
                sampleRate: micOutputSampleRate,
                channels: micOutputChannels
            ))
            if pendingMicAudio.count > maxPendingMicAudio {
                pendingMicAudio.removeFirst(pendingMicAudio.count - maxPendingMicAudio)
            }
        }
    }

    private func handlePreviewMicAudio(_ data: Data) {
        micLevel = rmsLevelInt16(data)
    }

    private var isStartScreenActive: Bool {
        if case .start = activeScreen { return true }
        return false
    }

    private func runPreviewLifecycleOperation(
        _ operation: @escaping @MainActor (AppModel) async -> Void
    ) async {
        let previousTask = previewLifecycleTask
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            await operation(self)
        }
        previewLifecycleTask = task
        await task.value
    }

    private func queueInputDeviceSelectionChange(to newValue: UInt32, updateSystemDefault: Bool) {
        let previousTask = inputDeviceSelectionTask
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            await Task.yield()
            guard let self else { return }
            await self.applyInputDeviceSelectionChange(
                to: newValue,
                updateSystemDefault: updateSystemDefault
            )
        }
        inputDeviceSelectionTask = task
    }

    private func applyInputDeviceSelectionChange(
        to newValue: UInt32,
        updateSystemDefault: Bool
    ) async {
        guard newValue != 0 else { return }
        guard selectedInputDeviceID == newValue else { return }

        isSwitchingInputDevice = true
        defer { isSwitchingInputDevice = false }

        if updateSystemDefault {
            guard AudioDeviceManager.setDefaultInputDevice(newValue) else {
                debugMicErrors += 1
                debugMicErrorMessage = "mic_device_switch_failed"
                loadInputDevices()
                appendBackendLog("Failed to switch microphone to \(inputDeviceName(for: newValue)).", toTail: true)
                return
            }

            await waitForDefaultInputDevice(newValue, timeoutSeconds: 1.0)
            appendBackendLog("Microphone switched to \(inputDeviceName(for: newValue)).", toTail: isCapturing)
        } else {
            appendBackendLog(
                "Microphone followed system default: \(inputDeviceName(for: newValue)).",
                toTail: isCapturing
            )
        }

        if isCapturing {
            await restartMeetingMicEngineForInputSwitch()
        } else if previewMicEngine != nil {
            await restartPreviewMicEngineForInputSwitch()
        }
    }

    private func waitForDefaultInputDevice(_ id: UInt32, timeoutSeconds: Double) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if AudioDeviceManager.defaultInputDeviceID() == id {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func inputDeviceName(for id: UInt32) -> String {
        if let name = inputDevices.first(where: { $0.id == id })?.name {
            return name
        }
        return "Device \(id)"
    }

    func selectInputDevice(_ id: UInt32) {
        guard id != 0 else { return }
        guard id != selectedInputDeviceID else { return }
        selectedInputDeviceID = id
        let selectedID = id
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.selectedInputDeviceID == selectedID else { return }
            self.queueInputDeviceSelectionChange(to: selectedID, updateSystemDefault: true)
        }
    }

    private func startHomeLevelPreviewNow() async {
        guard !isCapturing else { return }
        guard !isStartingMeeting else { return }
        guard !shouldShowOnboarding else {
            isPreviewingLevels = false
            return
        }
        guard isStartScreenActive else {
            isPreviewingLevels = false
            return
        }

        if !isPreviewCaptureRunning {
            guard let display = selectedDisplay ?? displays.first else {
                isPreviewingLevels = previewMicEngine != nil
                return
            }
            let audioFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            do {
                try await captureEngine.startCapture(contentFilter: audioFilter, writer: nil, recordTo: nil)
                guard !isCapturing, !isStartingMeeting, isStartScreenActive else {
                    await captureEngine.stopCapture()
                    isPreviewCaptureRunning = false
                    isPreviewingLevels = false
                    return
                }
                captureEngine.setAudioOutputEnabled(false)
                isPreviewCaptureRunning = true
            } catch {
                shareableContentError = "Failed to start system audio preview: \(error.localizedDescription)"
            }
        }

        if previewMicEngine == nil {
            let engine = MicEngine()
            previewMicEngine = engine
            do {
                try await engine.start(preferredInputDeviceID: selectedInputDeviceID == 0 ? nil : selectedInputDeviceID) { [weak self] data in
                    Task { @MainActor in
                        self?.handlePreviewMicAudio(data)
                    }
                }
                guard !isCapturing, !isStartingMeeting, isStartScreenActive else {
                    await engine.stop()
                    previewMicEngine = nil
                    isPreviewingLevels = isPreviewCaptureRunning
                    return
                }
            } catch {
                previewMicEngine = nil
                debugMicErrors += 1
                debugMicErrorMessage = "mic_preview_start_failed: \(error.localizedDescription)"
            }
        }

        isPreviewingLevels = isPreviewCaptureRunning || (previewMicEngine != nil)
    }

    private func stopHomeLevelPreviewNow() async {
        if let engine = previewMicEngine {
            await engine.stop()
            previewMicEngine = nil
        }

        if isCapturing {
            // Never stop captureEngine here during a live meeting.
            isPreviewCaptureRunning = false
            isPreviewingLevels = false
            return
        }

        if isPreviewCaptureRunning {
            await captureEngine.stopCapture()
            isPreviewCaptureRunning = false
        }

        isPreviewingLevels = false
        micLevel = 0
        captureEngine.systemLevel = 0
        objectWillChange.send()
    }

    func startHomeLevelPreview() async {
        await runPreviewLifecycleOperation { model in
            await model.startHomeLevelPreviewNow()
        }
    }

    func stopHomeLevelPreview() async {
        await runPreviewLifecycleOperation { model in
            await model.stopHomeLevelPreviewNow()
        }
    }

    func refreshHomeLevelPreview() async {
        await runPreviewLifecycleOperation { model in
            await model.stopHomeLevelPreviewNow()
            await model.startHomeLevelPreviewNow()
        }
    }

    private func startMeetingMicEngine() async {
        guard transcribeMic else {
            micEngine = nil
            micOutputEnabled = false
            cancelMicStartupHealthCheck()
            return
        }

        let engine = MicEngine()
        micEngine = engine

        do {
            try await engine.start(preferredInputDeviceID: selectedInputDeviceID == 0 ? nil : selectedInputDeviceID) { [weak self] data in
                Task { @MainActor in
                    self?.handleMicAudio(data)
                }
            }
            micOutputEnabled = true
            debugMicErrorMessage = "-"
            if isCapturing {
                scheduleMicStartupHealthCheck()
            }
        } catch {
            micEngine = nil
            micOutputEnabled = false
            cancelMicStartupHealthCheck()
            debugMicErrors += 1
            debugMicErrorMessage = "mic_start_failed: \(error.localizedDescription)"
            appendBackendLog("Mic engine failed to start: \(error.localizedDescription)", toTail: true)
        }
    }

    private func restartMeetingMicEngineForInputSwitch() async {
        guard isCapturing else { return }
        guard transcribeMic else { return }

        if let engine = micEngine {
            await engine.stop()
            micEngine = nil
        }

        pendingMicAudio.removeAll()
        micOutputEnabled = false
        micLevel = 0
        debugMicBuffers = 0
        debugMicFrames = 0
        debugMicPTS = 0
        await startMeetingMicEngine()
    }

    private func restartPreviewMicEngineForInputSwitch() async {
        await runPreviewLifecycleOperation { model in
            if let engine = model.previewMicEngine {
                await engine.stop()
                model.previewMicEngine = nil
            }
            await model.startHomeLevelPreviewNow()
        }
    }

    private func flushPendingMicAudio() {
        guard micOutputEnabled, !pendingMicAudio.isEmpty else { return }
        let pending = pendingMicAudio
        pendingMicAudio.removeAll()
        for item in pending {
            writer?.send(type: .audio, stream: .mic, ptsUs: item.ptsUs, payload: item.payload)
        }
    }

    private func cancelMicStartupHealthCheck() {
        micStartupHealthTask?.cancel()
        micStartupHealthTask = nil
    }

    private func scheduleMicStartupHealthCheck() {
        cancelMicStartupHealthCheck()
        guard transcribeMic else { return }

        micStartupHealthTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard isCapturing else { return }
            guard transcribeMic else { return }
            guard micEngine != nil else { return }
            guard debugMicBuffers == 0 else { return }

            guard micStartupRecoveryAttempts < maxMicStartupRecoveryAttempts else {
                appendBackendLog("Mic health check: still no audio after automatic retry.", toTail: true)
                return
            }

            micStartupRecoveryAttempts += 1
            appendBackendLog("Mic health check: no audio detected after start; restarting microphone capture.", toTail: true)
            await restartMeetingMicEngineForInputSwitch()
            scheduleMicStartupHealthCheck()
        }
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

    private func buildTranscriptJSONL(from segments: [TranscriptSegment]) -> String {
        segments
            .filter { !$0.isPartial }
            .compactMap { seg -> String? in
                let payload: [String: Any] = [
                    "speaker_id": seg.speakerID,
                    "stream": seg.stream,
                    "t0": seg.t0,
                    "t1": seg.t1 ?? seg.t0,
                    "text": seg.text
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let line = String(data: data, encoding: .utf8) {
                    return line
                }
                return nil
            }
            .joined(separator: "\n")
    }

    private func writeTranscriptData(
        _ data: Data?,
        to url: URL,
        encodeFailure: String,
        writeFailure: String,
        logToTail: Bool = true,
        logHandle: FileHandle? = nil
    ) {
        guard let data else {
            appendBackendLog(encodeFailure, toTail: logToTail, handle: logHandle)
            return
        }
        do {
            try data.write(to: url)
        } catch {
            appendBackendLog(
                "\(writeFailure): \(error.localizedDescription)",
                toTail: logToTail,
                handle: logHandle
            )
        }
    }

    private func saveTranscriptFiles(
        for session: MeetingSession,
        segments: [TranscriptSegment],
        text: String,
        logToTail: Bool = true,
        logHandle: FileHandle? = nil
    ) {
        let jsonlURL = session.folderURL.appendingPathComponent("transcript.jsonl")
        let txtURL = session.folderURL.appendingPathComponent("transcript.txt")

        let jsonlString = buildTranscriptJSONL(from: segments)
        let textString = text

        let jsonlData = jsonlString.data(using: .utf8)
        let textData = textString.data(using: .utf8)

        writeTranscriptData(
            jsonlData,
            to: jsonlURL,
            encodeFailure: "Failed to encode transcript JSONL.",
            writeFailure: "Failed to save transcript JSONL",
            logToTail: logToTail,
            logHandle: logHandle
        )
        writeTranscriptData(
            textData,
            to: txtURL,
            encodeFailure: "Failed to encode transcript text.",
            writeFailure: "Failed to save transcript text",
            logToTail: logToTail,
            logHandle: logHandle
        )

        let tempBase = FileManager.default.temporaryDirectory
        let tempFolder = tempBase.appendingPathComponent("Muesli-\(session.title)-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
            if let jsonlData {
                try jsonlData.write(to: tempFolder.appendingPathComponent("transcript.jsonl"))
            }
            if let textData {
                try textData.write(to: tempFolder.appendingPathComponent("transcript.txt"))
            }
            if logToTail {
                tempTranscriptFolderPath = tempFolder.path
            }
            appendBackendLog("Transcript temp folder: \(tempFolder.path)", toTail: logToTail, handle: logHandle)
        } catch {
            appendBackendLog(
                "Failed to save transcript temp copy: \(error.localizedDescription)",
                toTail: logToTail,
                handle: logHandle
            )
        }
    }

    private func linesFromTranscriptEvents(
        in folderURL: URL,
        startingAt offset: UInt64
    ) -> [String] {
        let eventsURL = folderURL.appendingPathComponent("transcript_events.jsonl")
        guard let data = try? Data(contentsOf: eventsURL) else { return [] }
        let start = Int(min(offset, UInt64(data.count)))
        let slice = data.subdata(in: start..<data.count)
        guard let content = String(data: slice, encoding: .utf8) else { return [] }
        return content.split(whereSeparator: \.isNewline).map(String.init)
    }

    func exportTranscriptFiles() {
        guard let session = currentSession else {
            appendBackendLog("Export failed: no active session.", toTail: true)
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.title)-transcript.txt"
        panel.prompt = "Export"
        panel.message = "Export transcript as .txt (JSONL will be written alongside)."

        if panel.runModal() == .OK, let url = panel.url {
            let jsonlURL = url.deletingPathExtension().appendingPathExtension("jsonl")
            let targetDir = url.deletingLastPathComponent()

            let textString = transcriptModel.asPlainText()
            let textData = textString.data(using: .utf8)
            writeTranscriptData(
                textData,
                to: url,
                encodeFailure: "Failed to encode exported transcript text.",
                writeFailure: "Failed to export transcript text"
            )

            let jsonlString = buildTranscriptJSONL(from: transcriptModel.segments)
            let jsonlData = jsonlString.data(using: .utf8)
            writeTranscriptData(
                jsonlData,
                to: jsonlURL,
                encodeFailure: "Failed to encode exported transcript JSONL.",
                writeFailure: "Failed to export transcript JSONL"
            )

            appendBackendLog("Transcript exported to \(targetDir.path).", toTail: true)
        }
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
            windows = sortWindows(content.windows)
            screenPermissionGranted = true

            if selectedDisplayID == nil {
                selectedDisplayID = displays.first?.displayID
            }
            if selectedWindowID == nil {
                selectedWindowID = windows.first?.windowID
            }

            // Capture thumbnails in background - don't block the UI
            Task { @MainActor in
                await captureThumbnails()
            }

            if isStartScreenActive && !isCapturing {
                await refreshHomeLevelPreview()
            }
        } catch {
            shareableContentError = String(describing: error)
            screenPermissionGranted = false
        }
    }

    private func sortWindows(_ items: [SCWindow]) -> [SCWindow] {
        items.sorted { lhs, rhs in
            let lhsApp = lhs.owningApplication?.applicationName ?? ""
            let rhsApp = rhs.owningApplication?.applicationName ?? ""
            let appOrder = lhsApp.localizedCaseInsensitiveCompare(rhsApp)
            if appOrder != .orderedSame {
                return appOrder == .orderedAscending
            }
            let lhsTitle = lhs.title ?? ""
            let rhsTitle = rhs.title ?? ""
            let titleOrder = lhsTitle.localizedCaseInsensitiveCompare(rhsTitle)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.windowID < rhs.windowID
        }
    }

    func loadInputDevices() {
        let available = AudioDeviceManager.inputDevices()
        inputDevices = available

        let availableIDs = Set(available.map(\.id))
        let defaultID = AudioDeviceManager.defaultInputDeviceID()
        let previousSelection = selectedInputDeviceID
        let resolvedSelection: UInt32

        if availableIDs.contains(selectedInputDeviceID) {
            resolvedSelection = selectedInputDeviceID
        } else if let defaultID, availableIDs.contains(defaultID) {
            resolvedSelection = defaultID
        } else {
            resolvedSelection = available.first?.id ?? 0
        }

        if selectedInputDeviceID != resolvedSelection {
            selectedInputDeviceID = resolvedSelection
        }

        guard resolvedSelection != 0 else { return }
        guard previousSelection != 0 else { return }
        guard previousSelection != resolvedSelection else { return }
        guard !isSwitchingInputDevice else { return }
        guard isCapturing else { return }

        let selectedID = resolvedSelection
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.selectedInputDeviceID == selectedID else { return }
            self.queueInputDeviceSelectionChange(to: selectedID, updateSystemDefault: false)
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

    @MainActor
    func refreshSpeakerIdStatus(modelName: String = "gemma3:27b") async {
        speakerIdStatus = await SpeakerIdentifier.checkAvailability(modelName: modelName)
    }

    @MainActor
    private func captureThumbnails() async {
        displayThumbnails.removeAll()
        windowThumbnails.removeAll()

        let thumbnailSize = CGSize(width: 160, height: 90)

        for display in displays {
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            if let image = await captureThumbnail(for: filter),
               let thumbnail = resizeImage(image, to: thumbnailSize) {
                displayThumbnails[display.displayID] = thumbnail
            }
        }

        for window in windows {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            if let image = await captureThumbnail(for: filter),
               let thumbnail = resizeImage(image, to: thumbnailSize) {
                windowThumbnails[window.windowID] = thumbnail
            }
        }
    }

    @MainActor
    private func captureThumbnail(for filter: SCContentFilter) async -> CGImage? {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Use a timeout to prevent hanging if a window capture never returns
        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config) { sampleBuffer, error in
                        guard error == nil,
                              let sampleBuffer,
                              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let ciImage = CIImage(cvImageBuffer: imageBuffer)
                        let context = CIContext()
                        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)
                        continuation.resume(returning: cgImage)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            // Return first result (either the capture or timeout)
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func resizeImage(_ image: CGImage, to maxSize: CGSize) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        if width == 0 || height == 0 {
            return nil
        }

        let widthRatio = maxSize.width / width
        let heightRatio = maxSize.height / height
        let ratio = min(widthRatio, heightRatio)

        let newWidth = Int(width * ratio)
        let newHeight = Int(height * ratio)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        return context.makeImage()
    }

    func startMeeting() async {
        guard !isStartingMeeting else { return }
        await startMeeting(resuming: nil, metadata: nil, timestampOffset: 0)
        if !isCapturing, case .start = activeScreen {
            await startHomeLevelPreview()
        }
    }

    private func startMeeting(
        resuming meeting: MeetingHistoryItem?,
        metadata: MeetingMetadata?,
        timestampOffset: Double
    ) async {
        guard !isStartingMeeting else { return }
        isStartingMeeting = true
        defer { isStartingMeeting = false }
        cancelMicStartupHealthCheck()
        micStartupRecoveryAttempts = 0
        await stopHomeLevelPreview()
        refreshMeetingTitleForDateRollover()
        refreshPermissions()
        loadInputDevices()
        backendFolderError = nil
        shareableContentError = nil
        tempTranscriptFolderPath = nil
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

        // Always use a display filter for audio capture (system-wide audio)
        // Use selectedDisplay if available, otherwise fall back to first display
        let displayForAudio = selectedDisplay ?? displays.first
        guard let audioDisplay = displayForAudio else {
            shareableContentError = "No display available for audio capture."
            return
        }
        let audioFilter = SCContentFilter(display: audioDisplay, excludingApplications: [], exceptingWindows: [])

        // Screenshot filter can be display or window based on user selection
        let screenshotFilter: SCContentFilter
        if captureMode == .audioOnly {
            // Audio-only mode doesn't use screenshots, but we still need a valid filter
            screenshotFilter = audioFilter
        } else {
            switch sourceKind {
            case .display:
                guard let display = selectedDisplay else {
                    shareableContentError = "No display selected."
                    return
                }
                screenshotFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            case .window:
                guard let window = selectedWindow else {
                    shareableContentError = "No window selected."
                    return
                }
                screenshotFilter = SCContentFilter(desktopIndependentWindow: window)
            }
        }

        var title = normaliseMeetingTitle(meetingTitle)
        let folderURL: URL
        let audioDir: URL
        var sessionID = 1
        if let meeting {
            do {
                let prepared = try prepareResumeSession(for: meeting)
                folderURL = meeting.folderURL
                audioDir = prepared.audioFolderURL
                sessionID = prepared.sessionID
            } catch {
                shareableContentError = "Failed to prepare resume session: \(error)"
                return
            }
        } else {
            if let autoTitle = autoNumberedMeetingTitle(from: meetingTitle) {
                meetingTitle = autoTitle
                title = normaliseMeetingTitle(autoTitle)
            }
            do {
                folderURL = try createMeetingFolder(title: title)
                audioDir = folderURL.appendingPathComponent("audio", isDirectory: true)
                try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            } catch {
                shareableContentError = "Failed to create meeting folder: \(error)"
                return
            }
        }

        let session = MeetingSession(title: title, folderURL: folderURL, startedAt: Date())
        currentSession = session
        transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
        if let metadata {
            transcriptModel.speakerNames = metadata.speakerNames
        }
        if meeting != nil {
            loadTranscriptFromDisk(in: folderURL)
            loadAttachments(from: folderURL)
        } else {
            clearAttachments()
        }
        if timestampOffset > 0 {
            transcriptModel.timestampOffset = timestampOffset
        }

        do {
            resetBackendLog(in: folderURL)
            resetTranscriptEventsLog(in: folderURL, append: meeting != nil)
            if meeting == nil {
                try createInitialMeetingMetadata(for: session, audioFolderName: audioDir.lastPathComponent)
            } else if let metadata {
                try appendResumeSessionMetadata(metadata, for: session, sessionID: sessionID, audioFolderName: audioDir.lastPathComponent)
            }

            guard startBackendAccess(for: backendProjectRoot) else {
                shareableContentError = "Backend folder access denied. Re-select the folder."
                closeBackendLog()
                closeTranscriptEventsLog()
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
                    closeTranscriptEventsLog()
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
                command.append("--keep-wav")
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
                let sessionFolderURL = folderURL
                let sessionLogHandle = backendLogHandle
                let sessionEventsHandle = transcriptEventsHandle
                appendBackendLog("Backend folder: \(backendProjectRoot.path)", toTail: true)
                appendBackendLog("PATH: \(mergedPath)", toTail: true)
                appendBackendLog("Command: \(command.joined(separator: " "))", toTail: true)
                backend.onExit = { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        let isActiveSession = self.isCapturing && self.currentSession?.folderURL == sessionFolderURL
                        self.appendBackendLog(
                            "Backend exited with status \(status)",
                            toTail: isActiveSession,
                            handle: sessionLogHandle
                        )
                    }
                }
                backend.onStderrLine = { [weak self] line in
                    Task { @MainActor in
                        guard let self else { return }
                        let isActiveSession = self.isCapturing && self.currentSession?.folderURL == sessionFolderURL
                        self.appendBackendLog(
                            "[stderr] \(line)",
                            toTail: isActiveSession,
                            handle: sessionLogHandle
                        )
                    }
                }
                try backend.start()
                self.backend = backend
                stdoutTask?.cancel()
                stdoutTask = Task { @MainActor in
                    for await line in backend.stdoutLines {
                        let isActiveSession = self.isCapturing && self.currentSession?.folderURL == sessionFolderURL
                        self.handleBackendJSONLine(
                            line,
                            transcriptEventsHandle: sessionEventsHandle,
                            backendLogHandle: sessionLogHandle,
                            ingestIntoLiveTranscript: isActiveSession
                        )
                    }
                }
                let createdWriter = FramedWriter(stdinHandle: backend.stdin)
                createdWriter.onWriteError = { [weak self] error in
                    Task { @MainActor in
                        self?.handleBackendWriteError(error)
                    }
                }
                self.writer = createdWriter
                writer = createdWriter

            case .failure(let error):
                shareableContentError = error.message
                backendFolderError = error.message
                appendBackendLog("Backend start blocked: \(error.message)", toTail: true)
                closeBackendLog()
                closeTranscriptEventsLog()
                stopBackendAccess()
                currentSession = nil
                return
            }

            let recordURL: URL?
            if captureMode == .video {
                recordURL = folderURL.appendingPathComponent("recording.mp4")
            } else {
                recordURL = nil
            }

            try await captureEngine.startCapture(
                contentFilter: audioFilter,
                writer: writer,
                recordTo: recordURL
            )

            resetMicDebugState()
            pendingMicAudio.removeAll()
            micOutputEnabled = false
            micStartTime = Date()
            await startMeetingMicEngine()

            let formats = await captureEngine.waitForAudioFormats(timeoutSeconds: 2.0)
            let systemSampleRate = formats.systemSampleRate ?? captureSampleRate
            let systemChannels = formats.systemChannels ?? captureChannels
            let micSampleRate = micOutputSampleRate
            let micChannels = micOutputChannels

            if formats.systemSampleRate == nil {
                appendBackendLog("System audio format not detected; using requested settings.", toTail: true)
            } else if systemSampleRate != captureSampleRate || systemChannels != captureChannels {
                appendBackendLog("System audio: requested \(captureSampleRate)Hz/\(captureChannels)ch, got \(systemSampleRate)Hz/\(systemChannels)ch.", toTail: true)
            }

            let meta: [String: Any] = [
                "protocol_version": 1,
                "sample_format": "s16le",
                "title": title,
                "start_wall_time": ISO8601DateFormatter().string(from: session.startedAt),
                "sample_rate": captureSampleRate,
                "channels": captureChannels,
                "system_sample_rate": systemSampleRate,
                "system_channels": systemChannels,
                "mic_sample_rate": micSampleRate,
                "mic_channels": micChannels
            ]
            let metaData = try JSONSerialization.data(withJSONObject: meta)
            writer.send(type: .meetingStart, stream: .system, ptsUs: 0, payload: metaData)
            appendBackendLog("Sent meeting_start", toTail: true)
            updateMeetingMetadataStreams(
                for: session,
                systemSampleRate: systemSampleRate,
                systemChannels: systemChannels,
                micSampleRate: micSampleRate,
                micChannels: micChannels
            )
            captureEngine.setAudioOutputEnabled(true)
            flushPendingMicAudio()

            if captureMode == .video {
                let screenshotsDir = folderURL.appendingPathComponent("screenshots", isDirectory: true)
                try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

                screenshotScheduler.start(
                    every: 5.0,
                    contentFilter: screenshotFilter,
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
            activeScreen = .session
            scheduleMicStartupHealthCheck()
        } catch {
            let pythonPath = backendPythonCandidatePath ?? "(unknown)"
            let nsError = error as NSError
            let details = "domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)"
            shareableContentError = "Failed to start backend or capture: \(error). Python: \(pythonPath) exists=\(backendPythonExists) sandboxed=\(isSandboxed) \(details)"
            appendBackendLog("Start failure: \(shareableContentError ?? "\(error)")", toTail: true)
            closeBackendLog()
            closeTranscriptEventsLog()
            stopBackendAccess()
            await stopMeeting()
        }
    }

    func stopMeeting() async {
        guard isCapturing else { return }

        isFinalizing = true
        cancelMicStartupHealthCheck()
        micStartupRecoveryAttempts = 0

        screenshotScheduler.stop()
        await captureEngine.stopCapture()
        if let engine = micEngine {
            await engine.stop()
        }
        micEngine = nil
        micOutputEnabled = false
        pendingMicAudio.removeAll()
        micStartTime = nil

        writer?.send(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
        writer?.closeStdinAfterDraining()

        let stoppingSession = currentSession
        let stoppingBackend = backend
        let stoppingStdoutTask = stdoutTask
        let stoppingBackendLogHandle = backendLogHandle
        let stoppingTranscriptEventsHandle = transcriptEventsHandle
        let stoppingBackendAccessURL = backendAccessURL
        let stoppingTranscriptEventsStartOffset = currentTranscriptEventsStartOffset
        let stoppingTranscriptSegments = transcriptModel.segments.filter { !$0.isPartial }
        let stoppingSpeakerNames = transcriptModel.speakerNames
        let stoppingTimestampOffset = transcriptModel.timestampOffset

        writer = nil
        backend = nil
        stdoutTask = nil
        backendLogHandle = nil
        backendLogURL = nil
        transcriptEventsHandle = nil
        transcriptEventsURL = nil
        backendAccessURL = nil
        currentTranscriptEventsStartOffset = 0
        clearAttachments()

        isCapturing = false
        currentSession = nil
        activeScreen = .start

        guard let stoppingSession else {
            closeHandle(stoppingTranscriptEventsHandle)
            closeHandle(stoppingBackendLogHandle)
            stopBackendAccess(for: stoppingBackendAccessURL)
            isFinalizing = false
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.finalizeStoppedMeeting(
                session: stoppingSession,
                backend: stoppingBackend,
                stdoutTask: stoppingStdoutTask,
                backendLogHandle: stoppingBackendLogHandle,
                transcriptEventsHandle: stoppingTranscriptEventsHandle,
                backendAccessURL: stoppingBackendAccessURL,
                transcriptEventsStartOffset: stoppingTranscriptEventsStartOffset,
                transcriptSegmentsSnapshot: stoppingTranscriptSegments,
                speakerNamesSnapshot: stoppingSpeakerNames,
                timestampOffsetSnapshot: stoppingTimestampOffset
            )
        }
    }

    private func finalizeStoppedMeeting(
        session: MeetingSession,
        backend: BackendProcess?,
        stdoutTask: Task<Void, Never>?,
        backendLogHandle: FileHandle?,
        transcriptEventsHandle: FileHandle?,
        backendAccessURL: URL?,
        transcriptEventsStartOffset: UInt64,
        transcriptSegmentsSnapshot: [TranscriptSegment],
        speakerNamesSnapshot: [String: String],
        timestampOffsetSnapshot: Double
    ) async {
        defer {
            closeHandle(transcriptEventsHandle)
            closeHandle(backendLogHandle)
            stopBackendAccess(for: backendAccessURL)
            isFinalizing = false
        }

        let exitStatus = await backend?.waitForExit(timeoutSeconds: 120)
        if exitStatus == nil {
            appendBackendLog(
                "Backend did not exit after stop; terminating.",
                toTail: false,
                handle: backendLogHandle
            )
            backend?.terminate()
        }
        backend?.cleanup()
        await waitForStdoutDrain(task: stdoutTask, timeoutSeconds: 2.0)
        synchronizeHandle(transcriptEventsHandle, label: "transcript events log")
        synchronizeHandle(backendLogHandle, label: "backend log")

        let model = TranscriptModel()
        model.timestampOffset = timestampOffsetSnapshot
        model.segments = transcriptSegmentsSnapshot
        model.speakerNames = speakerNamesSnapshot
        for line in linesFromTranscriptEvents(in: session.folderURL, startingAt: transcriptEventsStartOffset) {
            model.ingest(jsonLine: line)
        }

        let finalizedSegments = model.segments.filter { !$0.isPartial }
        saveTranscriptFiles(
            for: session,
            segments: finalizedSegments,
            text: model.asPlainText(),
            logToTail: false,
            logHandle: backendLogHandle
        )
        finalizeMeetingMetadata(for: session, finalizedSegments: finalizedSegments)
        if let updatedItem = buildMeetingHistoryItem(for: session.folderURL),
           let idx = meetingHistory.firstIndex(where: { $0.folderURL == session.folderURL }) {
            meetingHistory[idx] = updatedItem
        } else if let updatedItem = buildMeetingHistoryItem(for: session.folderURL) {
            meetingHistory.insert(updatedItem, at: 0)
        }
    }

    private func waitForStdoutDrain(task: Task<Void, Never>?, timeoutSeconds: Double) async {
        guard let task else { return }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                } catch {
                    return false
                }
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        if !finished {
            task.cancel()
        }
    }

    static func defaultMeetingTitle() -> String {
        defaultMeetingTitle(for: Date(), number: 1)
    }

    func refreshMeetingTitleForDateRollover(now: Date = Date()) {
        guard !isCapturing else { return }
        guard let parsed = parseAutoMeetingTitle(meetingTitle) else { return }
        let todayPrefix = Self.meetingDatePrefix(for: now)
        guard parsed.datePrefix != todayPrefix else { return }
        meetingTitle = Self.defaultMeetingTitle(for: now, number: nextMeetingNumber(for: todayPrefix))
    }

    private static func meetingDatePrefix(for date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy_MM_dd"
        return df.string(from: date)
    }

    private static func defaultMeetingTitle(for date: Date, number: Int) -> String {
        "\(meetingDatePrefix(for: date)) - Meeting \(number) - "
    }

    private func parseAutoMeetingTitle(_ title: String) -> (datePrefix: String, number: Int)? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: " - Meeting ")
        guard parts.count >= 2 else { return nil }
        let datePrefix = parts[0]
        guard isDatePrefix(datePrefix) else { return nil }

        let remainder = parts[1]
        var digits = ""
        var index = remainder.startIndex
        while index < remainder.endIndex, remainder[index].isNumber {
            digits.append(remainder[index])
            index = remainder.index(after: index)
        }
        guard let number = Int(digits), number > 0 else { return nil }

        let tail = remainder[index...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty, tail != "-" {
            return nil
        }
        return (datePrefix: datePrefix, number: number)
    }

    private func isDatePrefix(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let chars = Array(value)
        guard chars[4] == "_", chars[7] == "_" else { return false }
        for (idx, ch) in chars.enumerated() where idx != 4 && idx != 7 {
            guard ch.isNumber else { return false }
        }
        return true
    }

    private func parseMeetingNumber(in title: String, datePrefix: String) -> Int? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(datePrefix) - Meeting "
        guard trimmed.hasPrefix(prefix) else { return nil }
        let remainder = trimmed.dropFirst(prefix.count)
        var digits = ""
        for ch in remainder {
            if ch.isNumber {
                digits.append(ch)
            } else {
                break
            }
        }
        guard let number = Int(digits) else { return nil }
        return number
    }

    private func nextMeetingNumber(for datePrefix: String) -> Int {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muesli", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)

        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 1
        }

        var maxNumber = 0
        for folderURL in folders {
            let resourceValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }
            let title = (try? readMeetingMetadata(from: folderURL).title) ?? folderURL.lastPathComponent
            if let number = parseMeetingNumber(in: title, datePrefix: datePrefix) {
                maxNumber = max(maxNumber, number)
            }
        }

        return maxNumber + 1
    }

    private func autoNumberedMeetingTitle(from proposed: String) -> String? {
        guard let parsed = parseAutoMeetingTitle(proposed) else { return nil }
        let next = nextMeetingNumber(for: parsed.datePrefix)
        return "\(parsed.datePrefix) - Meeting \(next) - "
    }

    private func normaliseMeetingTitle(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
        let filtered = trimmed.components(separatedBy: allowed.inverted).joined()
        let collapsed = filtered.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return collapsed.isEmpty ? Self.defaultMeetingTitle() : collapsed
    }

    private func createMeetingFolder(title: String) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muesli", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        var folder = base.appendingPathComponent(title, isDirectory: true)
        var index = 1
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = base.appendingPathComponent("\(title)-\(String(format: "%02d", index))", isDirectory: true)
            index += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        return folder
    }

    private func meetingMetadataURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent("meeting.json")
    }

    private func readMeetingMetadata(from folderURL: URL) throws -> MeetingMetadata {
        let data = try Data(contentsOf: meetingMetadataURL(for: folderURL))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingMetadata.self, from: data)
    }

    private func writeMeetingMetadata(_ metadata: MeetingMetadata, to folderURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: meetingMetadataURL(for: folderURL), options: [.atomic])
    }

    private func createInitialMeetingMetadata(for session: MeetingSession, audioFolderName: String) throws {
        let streams: [String: MeetingStreamInfo] = [
            "system": MeetingStreamInfo(sampleRate: nil, channels: nil),
            "mic": MeetingStreamInfo(sampleRate: nil, channels: nil)
        ]
        let now = session.startedAt
        let metadata = MeetingMetadata(
            version: 1,
            title: session.title,
            createdAt: now,
            updatedAt: now,
            durationSeconds: 0,
            lastTimestamp: 0,
            status: .recording,
            sessions: [
                MeetingSessionMetadata(
                    sessionID: 1,
                    startedAt: now,
                    endedAt: nil,
                    audioFolder: audioFolderName,
                    streams: streams
                )
            ],
            segmentCount: 0,
            speakerNames: [:]
        )
        try writeMeetingMetadata(metadata, to: session.folderURL)
    }

    private func appendResumeSessionMetadata(
        _ metadata: MeetingMetadata,
        for session: MeetingSession,
        sessionID: Int,
        audioFolderName: String
    ) throws {
        var updated = metadata
        updated.status = .recording
        updated.updatedAt = session.startedAt
        let streams: [String: MeetingStreamInfo] = [
            "system": MeetingStreamInfo(sampleRate: nil, channels: nil),
            "mic": MeetingStreamInfo(sampleRate: nil, channels: nil)
        ]
        let newSession = MeetingSessionMetadata(
            sessionID: sessionID,
            startedAt: session.startedAt,
            endedAt: nil,
            audioFolder: audioFolderName,
            streams: streams
        )
        updated.sessions.append(newSession)
        try writeMeetingMetadata(updated, to: session.folderURL)
    }

    private func finalizeMeetingMetadata(
        for session: MeetingSession,
        finalizedSegments: [TranscriptSegment]
    ) {
        do {
            var metadata = try readMeetingMetadata(from: session.folderURL)
            let lastTimestamp = max(
                metadata.lastTimestamp,
                finalizedSegments.map { $0.t1 ?? $0.t0 }.max() ?? 0
            )
            let segmentCount = max(metadata.segmentCount, finalizedSegments.count)
            let durationFromStart = Date().timeIntervalSince(metadata.createdAt)
            let durationSeconds = max(metadata.durationSeconds, lastTimestamp, durationFromStart)

            metadata.updatedAt = Date()
            metadata.durationSeconds = durationSeconds
            metadata.lastTimestamp = lastTimestamp
            metadata.segmentCount = segmentCount
            metadata.status = .completed
            if let lastIndex = metadata.sessions.indices.last {
                var lastSession = metadata.sessions[lastIndex]
                if lastSession.endedAt == nil {
                    lastSession = MeetingSessionMetadata(
                        sessionID: lastSession.sessionID,
                        startedAt: lastSession.startedAt,
                        endedAt: Date(),
                        audioFolder: lastSession.audioFolder,
                        streams: lastSession.streams
                    )
                    metadata.sessions[lastIndex] = lastSession
                }
            }
            try writeMeetingMetadata(metadata, to: session.folderURL)
        } catch {
            appendBackendLog("Failed to update meeting.json: \(error.localizedDescription)", toTail: true)
        }
    }

    func renameSpeaker(id: String, to name: String) {
        transcriptModel.renameSpeaker(id: id, to: name)
        if let session = currentSession {
            persistSpeakerNames(to: session.folderURL)
        } else if case .viewing(let item) = activeScreen {
            persistSpeakerNames(to: item.folderURL)
        }
    }

    // MARK: - Attachments

    private func attachmentsFolderURL(for session: MeetingSession) -> URL {
        session.folderURL.appendingPathComponent("attachments", isDirectory: true)
    }

    private func attachmentsManifestURL(for session: MeetingSession) -> URL {
        session.folderURL.appendingPathComponent("attachments.json")
    }

    private func meetingElapsedSeconds() -> Double {
        guard let session = currentSession else { return 0 }
        return Date().timeIntervalSince(session.startedAt)
    }

    private func formatTimestampFilename(_ seconds: Double, extension ext: String) -> String {
        // Format: t+0000005.123.png (7 digits for seconds, 3 for milliseconds)
        let wholeSec = Int(seconds)
        let millis = Int((seconds - Double(wholeSec)) * 1000)
        return String(format: "t+%07d.%03d.%@", wholeSec, millis, ext)
    }

    func saveImageAttachment(_ image: NSImage) {
        guard let session = currentSession else { return }

        let attachmentsDir = attachmentsFolderURL(for: session)
        do {
            try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        } catch {
            appendBackendLog("Failed to create attachments folder: \(error.localizedDescription)", toTail: true)
            return
        }

        let elapsed = meetingElapsedSeconds()
        let filename = formatTimestampFilename(elapsed, extension: "png")
        let fileURL = attachmentsDir.appendingPathComponent(filename)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            appendBackendLog("Failed to convert image to PNG", toTail: true)
            return
        }

        do {
            try pngData.write(to: fileURL)
            let attachment = Attachment(type: .image, timestamp: elapsed, filename: filename)
            currentAttachments.append(attachment)
            saveAttachmentsManifest(for: session)
            appendBackendLog("Saved image attachment: \(filename)", toTail: true)
        } catch {
            appendBackendLog("Failed to save image attachment: \(error.localizedDescription)", toTail: true)
        }
    }

    func saveTextAttachment(_ text: String) {
        guard let session = currentSession else { return }

        let attachmentsDir = attachmentsFolderURL(for: session)
        do {
            try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        } catch {
            appendBackendLog("Failed to create attachments folder: \(error.localizedDescription)", toTail: true)
            return
        }

        let elapsed = meetingElapsedSeconds()
        let filename = formatTimestampFilename(elapsed, extension: "txt")
        let fileURL = attachmentsDir.appendingPathComponent(filename)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            let attachment = Attachment(type: .text, timestamp: elapsed, filename: filename)
            currentAttachments.append(attachment)
            saveAttachmentsManifest(for: session)
            appendBackendLog("Saved text attachment: \(filename)", toTail: true)
        } catch {
            appendBackendLog("Failed to save text attachment: \(error.localizedDescription)", toTail: true)
        }
    }

    func deleteAttachment(_ attachment: Attachment) {
        guard let session = currentSession else { return }

        let attachmentsDir = attachmentsFolderURL(for: session)
        let fileURL = attachmentsDir.appendingPathComponent(attachment.filename)

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            currentAttachments.removeAll { $0.id == attachment.id }
            saveAttachmentsManifest(for: session)
            appendBackendLog("Deleted attachment: \(attachment.filename)", toTail: true)
        } catch {
            appendBackendLog("Failed to delete attachment: \(error.localizedDescription)", toTail: true)
        }
    }

    func attachmentFileURL(for attachment: Attachment) -> URL? {
        guard let session = currentSession else { return nil }
        return attachmentsFolderURL(for: session).appendingPathComponent(attachment.filename)
    }

    private func saveAttachmentsManifest(for session: MeetingSession) {
        let manifest = AttachmentsManifest(attachments: currentAttachments)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(manifest)
            try data.write(to: attachmentsManifestURL(for: session), options: [.atomic])
        } catch {
            appendBackendLog("Failed to save attachments manifest: \(error.localizedDescription)", toTail: true)
        }
    }

    private func loadAttachments(from folderURL: URL) {
        currentAttachments = []
        let manifestURL = folderURL.appendingPathComponent("attachments.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }

        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(AttachmentsManifest.self, from: data)
            currentAttachments = manifest.attachments
        } catch {
            appendBackendLog("Failed to load attachments manifest: \(error.localizedDescription)", toTail: true)
        }
    }

    private func clearAttachments() {
        currentAttachments = []
    }

    func applySpeakerMappings(_ mappings: [SpeakerIdentifier.SpeakerMapping], for meeting: MeetingHistoryItem) {
        var didUpdate = false
        let segmentIds = Set(transcriptModel.segments.map { $0.speakerID })
        let hasSystemSegments = segmentIds.contains { $0.lowercased().hasPrefix("system:") }
        let hasMicSegments = segmentIds.contains { $0.lowercased().hasPrefix("mic:") }
        for mapping in mappings {
            let rawId = mapping.speakerId.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmed = mapping.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawId.isEmpty, !trimmed.isEmpty else { continue }

            let suffix = ":\(rawId)"
            var targets = Set<String>()
            for key in transcriptModel.speakerNames.keys where key.hasSuffix(suffix) || key == rawId {
                targets.insert(key)
            }
            for id in segmentIds where id.hasSuffix(suffix) || id == rawId {
                targets.insert(id)
            }
            if transcriptModel.speakerNames[rawId] != nil {
                targets.insert(rawId)
            }
            if targets.isEmpty {
                let parts = rawId.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    let prefix = String(parts[0]).lowercased()
                    let base = String(parts[1])
                    if prefix == "system", !hasSystemSegments, hasMicSegments {
                        let alt = "mic:\(base)"
                        if segmentIds.contains(alt) || transcriptModel.speakerNames[alt] != nil {
                            targets.insert(alt)
                        }
                    } else if prefix == "mic", !hasMicSegments, hasSystemSegments {
                        let alt = "system:\(base)"
                        if segmentIds.contains(alt) || transcriptModel.speakerNames[alt] != nil {
                            targets.insert(alt)
                        }
                    }
                }
            }
            guard !targets.isEmpty else { continue }
            for target in targets {
                transcriptModel.renameSpeaker(id: target, to: trimmed)
                didUpdate = true
            }
        }
        guard didUpdate else { return }
        persistSpeakerNames(to: meeting.folderURL)
    }

    func runBatchRediarization(
        for meeting: MeetingHistoryItem,
        stream: BatchRediarizer.Stream,
        progressHandler: @escaping (BatchRediarizer.Progress) -> Void
    ) async throws -> BatchRediarizer.Result {
        guard let backendProjectRoot = backendFolderURL else {
            throw NSError(
                domain: "Muesli",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Select the backend folder before reprocessing."]
            )
        }
        guard startBackendAccess(for: backendProjectRoot) else {
            throw NSError(
                domain: "Muesli",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Backend folder access denied. Re-select the folder."]
            )
        }
        defer { stopBackendAccess() }

        switch resolveBackendPython(for: backendProjectRoot) {
        case .failure(let error):
            throw NSError(
                domain: "Muesli",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: error.message]
            )
        case .success(let backendPython):
            let rediarizer = BatchRediarizer()
            return try await rediarizer.run(
                meetingDirectory: meeting.folderURL,
                backendPython: backendPython,
                backendRoot: backendProjectRoot,
                stream: stream,
                progressHandler: progressHandler
            )
        }
    }

    func applyBatchRediarization(_ result: BatchRediarizer.Result, for meeting: MeetingHistoryItem) {
        let segments = result.turns.map { turn in
            TranscriptSegment(
                speakerID: turn.speakerId,
                stream: turn.stream,
                t0: turn.t0,
                t1: turn.t1,
                text: turn.text,
                isPartial: false
            )
        }
        let sorted = segments.sorted { $0.t0 < $1.t0 }

        transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
        transcriptModel.segments = sorted
        transcriptModel.speakerNames = [:]
        if let last = sorted.last, !last.text.isEmpty {
            transcriptModel.lastTranscriptText = last.text
            transcriptModel.lastTranscriptAt = Date()
        }

        writeTranscriptFiles(for: meeting.folderURL, segments: sorted)
        updateMeetingMetadataAfterRediarization(
            folderURL: meeting.folderURL,
            segmentCount: sorted.count,
            lastTimestamp: sorted.map { $0.t1 ?? $0.t0 }.max() ?? 0,
            durationSeconds: result.duration
        )

        if let updatedItem = buildMeetingHistoryItem(for: meeting.folderURL) {
            if let idx = meetingHistory.firstIndex(where: { $0.id == meeting.id }) {
                meetingHistory[idx] = updatedItem
            } else {
                meetingHistory.insert(updatedItem, at: 0)
            }
            if case .viewing(let current) = activeScreen, current.id == meeting.id {
                activeScreen = .viewing(updatedItem)
            }
        }
    }

    func renameMeeting(_ item: MeetingHistoryItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            var metadata = try readMeetingMetadata(from: item.folderURL)
            metadata.title = trimmed
            metadata.updatedAt = Date()
            try writeMeetingMetadata(metadata, to: item.folderURL)

            let updatedItem = MeetingHistoryItem(
                id: item.id,
                folderURL: item.folderURL,
                title: trimmed,
                createdAt: item.createdAt,
                durationSeconds: item.durationSeconds,
                segmentCount: item.segmentCount,
                status: item.status
            )
            if let idx = meetingHistory.firstIndex(where: { $0.id == item.id }) {
                meetingHistory[idx] = updatedItem
            }
            if case .viewing(let current) = activeScreen, current.id == item.id {
                activeScreen = .viewing(updatedItem)
            }
        } catch {
            appendBackendLog("Failed to rename meeting \(item.id): \(error.localizedDescription)", toTail: true)
        }
    }

    func renameCurrentMeeting(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = currentSession else { return }

        do {
            var metadata = try readMeetingMetadata(from: session.folderURL)
            metadata.title = trimmed
            metadata.updatedAt = Date()
            try writeMeetingMetadata(metadata, to: session.folderURL)

            let updatedSession = MeetingSession(
                title: trimmed,
                folderURL: session.folderURL,
                startedAt: session.startedAt
            )
            currentSession = updatedSession
            meetingTitle = trimmed

            if let idx = meetingHistory.firstIndex(where: { $0.folderURL == session.folderURL }) {
                let existing = meetingHistory[idx]
                let updatedItem = MeetingHistoryItem(
                    id: existing.id,
                    folderURL: existing.folderURL,
                    title: trimmed,
                    createdAt: existing.createdAt,
                    durationSeconds: existing.durationSeconds,
                    segmentCount: existing.segmentCount,
                    status: existing.status
                )
                meetingHistory[idx] = updatedItem
            }
        } catch {
            appendBackendLog("Failed to rename active meeting: \(error.localizedDescription)", toTail: true)
        }
    }

    private func persistSpeakerNames(to folderURL: URL) {
        do {
            var metadata = try readMeetingMetadata(from: folderURL)
            metadata.speakerNames = transcriptModel.speakerNames
            metadata.updatedAt = Date()
            try writeMeetingMetadata(metadata, to: folderURL)
        } catch {
            appendBackendLog("Failed to persist speaker names: \(error.localizedDescription)", toTail: true)
        }
    }

    private func writeTranscriptFiles(for folderURL: URL, segments: [TranscriptSegment]) {
        let jsonlURL = folderURL.appendingPathComponent("transcript.jsonl")
        let txtURL = folderURL.appendingPathComponent("transcript.txt")

        let jsonlString = buildTranscriptJSONL(from: segments)
        let textString = transcriptModel.asPlainText()
        let jsonlData = jsonlString.data(using: .utf8)
        let textData = textString.data(using: .utf8)

        writeTranscriptData(
            jsonlData,
            to: jsonlURL,
            encodeFailure: "Failed to encode transcript JSONL.",
            writeFailure: "Failed to write transcript JSONL"
        )
        writeTranscriptData(
            textData,
            to: txtURL,
            encodeFailure: "Failed to encode transcript text.",
            writeFailure: "Failed to write transcript text"
        )
    }

    private func updateMeetingMetadataAfterRediarization(
        folderURL: URL,
        segmentCount: Int,
        lastTimestamp: Double,
        durationSeconds: Double
    ) {
        do {
            var metadata = try readMeetingMetadata(from: folderURL)
            metadata.updatedAt = Date()
            metadata.segmentCount = segmentCount
            metadata.lastTimestamp = max(metadata.lastTimestamp, lastTimestamp)
            metadata.durationSeconds = max(metadata.durationSeconds, durationSeconds, lastTimestamp)
            metadata.speakerNames = [:]
            metadata.status = .completed
            try writeMeetingMetadata(metadata, to: folderURL)
        } catch {
            appendBackendLog("Failed to update meeting.json after reprocess: \(error.localizedDescription)", toTail: true)
        }
    }

    private func updateMeetingMetadataStreams(
        for session: MeetingSession,
        systemSampleRate: Int,
        systemChannels: Int,
        micSampleRate: Int,
        micChannels: Int
    ) {
        do {
            var metadata = try readMeetingMetadata(from: session.folderURL)
            if let lastIndex = metadata.sessions.indices.last {
                let streams: [String: MeetingStreamInfo] = [
                    "system": MeetingStreamInfo(sampleRate: systemSampleRate, channels: systemChannels),
                    "mic": MeetingStreamInfo(sampleRate: micSampleRate, channels: micChannels)
                ]
                let lastSession = metadata.sessions[lastIndex]
                metadata.sessions[lastIndex] = MeetingSessionMetadata(
                    sessionID: lastSession.sessionID,
                    startedAt: lastSession.startedAt,
                    endedAt: lastSession.endedAt,
                    audioFolder: lastSession.audioFolder,
                    streams: streams
                )
                metadata.updatedAt = Date()
                try writeMeetingMetadata(metadata, to: session.folderURL)
            }
        } catch {
            appendBackendLog("Failed to update meeting stream formats: \(error.localizedDescription)", toTail: true)
        }
    }

    private func prepareResumeSession(for meeting: MeetingHistoryItem) throws -> (metadata: MeetingMetadata, sessionID: Int, audioFolderURL: URL) {
        let metadata = try readMeetingMetadata(from: meeting.folderURL)
        let nextSessionID = (metadata.sessions.map(\.sessionID).max() ?? 0) + 1
        let folderName = "audio-session-\(nextSessionID)"
        let audioURL = meeting.folderURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: audioURL, withIntermediateDirectories: true)
        return (metadata, nextSessionID, audioURL)
    }

    private func migrateLegacyMeetingsIfNeeded() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muesli", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for folderURL in folders {
            let resourceValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }
            let metadataURL = meetingMetadataURL(for: folderURL)
            guard !FileManager.default.fileExists(atPath: metadataURL.path) else { continue }

            if let metadata = buildLegacyMeetingMetadata(for: folderURL) {
                do {
                    try writeMeetingMetadata(metadata, to: folderURL)
                } catch {
                    appendBackendLog("Failed to migrate meeting.json for \(folderURL.lastPathComponent): \(error.localizedDescription)", toTail: true)
                }
            }
        }
    }

    private func loadMeetingHistory() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muesli", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            meetingHistory = []
            return
        }

        var items: [MeetingHistoryItem] = []
        for folderURL in folders {
            let resourceValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }
            if let item = buildMeetingHistoryItem(for: folderURL) {
                items.append(item)
            }
        }
        meetingHistory = items.sorted { $0.createdAt > $1.createdAt }
    }

    private func buildMeetingHistoryItem(for folderURL: URL) -> MeetingHistoryItem? {
        if let metadata = try? readMeetingMetadata(from: folderURL) {
            return MeetingHistoryItem(
                id: folderURL.lastPathComponent,
                folderURL: folderURL,
                title: metadata.title,
                createdAt: metadata.createdAt,
                durationSeconds: metadata.durationSeconds,
                segmentCount: metadata.segmentCount,
                status: metadata.status
            )
        }

        let createdAt = creationDate(for: folderURL) ?? Date()
        let updatedAt = latestModificationDate(for: folderURL) ?? createdAt
        let durationSeconds = max(0, updatedAt.timeIntervalSince(createdAt))
        let title = legacyMeetingTitle(for: folderURL)
        let segmentStats = parseSegmentStats(
            from: folderURL.appendingPathComponent("transcript.jsonl"),
            expectsTypeField: false
        )

        return MeetingHistoryItem(
            id: folderURL.lastPathComponent,
            folderURL: folderURL,
            title: title,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            segmentCount: segmentStats.count,
            status: .completed
        )
    }

    func deleteMeeting(_ item: MeetingHistoryItem) {
        if isCapturing, let session = currentSession, session.folderURL == item.folderURL {
            appendBackendLog("Delete blocked: meeting is currently recording.", toTail: true)
            return
        }
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: item.folderURL, resultingItemURL: &trashedURL)
            meetingHistory.removeAll { $0.id == item.id }
            if case .viewing(let current) = activeScreen, current.id == item.id {
                closeMeetingViewer()
            }
        } catch {
            appendBackendLog("Failed to delete meeting \(item.id): \(error.localizedDescription)", toTail: true)
        }
    }

    func openMeeting(_ item: MeetingHistoryItem) {
        loadTranscriptForViewer(from: item.folderURL)
        activeScreen = .viewing(item)
        Task { await refreshSpeakerIdStatus() }
    }

    func resumeMeeting(_ item: MeetingHistoryItem) {
        do {
            let metadata = try readMeetingMetadata(from: item.folderURL)
            meetingTitle = item.title
            Task { await startMeeting(resuming: item, metadata: metadata, timestampOffset: metadata.lastTimestamp) }
        } catch {
            appendBackendLog("Failed to resume meeting \(item.id): \(error.localizedDescription)", toTail: true)
        }
    }

    func closeMeetingViewer() {
        activeScreen = .start
        clearViewerTranscript()
    }

    func exportTranscriptFiles(for meeting: MeetingHistoryItem) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(meeting.title)-transcript.txt"
        panel.prompt = "Export"
        panel.message = "Export transcript as .txt (JSONL will be written alongside)."

        if panel.runModal() == .OK, let url = panel.url {
            let jsonlURL = url.deletingPathExtension().appendingPathExtension("jsonl")

            let transcriptURL = meeting.folderURL.appendingPathComponent("transcript.jsonl")
            let jsonlData: Data?
            if FileManager.default.fileExists(atPath: transcriptURL.path),
               let diskData = try? Data(contentsOf: transcriptURL) {
                jsonlData = diskData
            } else {
                let jsonlString = buildTranscriptJSONL(from: transcriptModel.segments)
                jsonlData = jsonlString.data(using: .utf8)
            }
            writeTranscriptData(
                jsonlData,
                to: jsonlURL,
                encodeFailure: "Failed to encode exported transcript JSONL.",
                writeFailure: "Failed to export transcript JSONL"
            )

            let textString = transcriptModel.asPlainText()
            let textData = textString.data(using: .utf8)
            writeTranscriptData(
                textData,
                to: url,
                encodeFailure: "Failed to encode exported transcript text.",
                writeFailure: "Failed to export transcript text"
            )
        }
    }

    private func loadTranscriptForViewer(from folderURL: URL) {
        transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
        let transcriptURL = folderURL.appendingPathComponent("transcript.jsonl")
        if FileManager.default.fileExists(atPath: transcriptURL.path) {
            if let data = try? Data(contentsOf: transcriptURL),
               let content = String(data: data, encoding: .utf8) {
                for line in content.split(separator: "\n") {
                    transcriptModel.ingest(jsonLine: String(line))
                }
            }
        } else {
            appendBackendLog("Transcript not found for viewer: \(transcriptURL.path)", toTail: true)
        }

        do {
            let metadata = try readMeetingMetadata(from: folderURL)
            transcriptModel.speakerNames = metadata.speakerNames
        } catch {
            appendBackendLog("Failed to load speaker names: \(error.localizedDescription)", toTail: true)
        }
    }

    private func clearViewerTranscript() {
        transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
    }

    private func buildLegacyMeetingMetadata(for folderURL: URL) -> MeetingMetadata? {
        let title = legacyMeetingTitle(for: folderURL)
        let createdAt = creationDate(for: folderURL) ?? Date()
        let updatedAt = latestModificationDate(for: folderURL) ?? createdAt
        let audioFolderName = findAudioFolderName(in: folderURL) ?? "audio"

        let transcriptURL = folderURL.appendingPathComponent("transcript.jsonl")
        let eventsURL = folderURL.appendingPathComponent("transcript_events.jsonl")

        var segmentCount = 0
        var lastTimestamp = 0.0
        var speakerNames: [String: String] = [:]

        if FileManager.default.fileExists(atPath: transcriptURL.path) {
            let stats = parseSegmentStats(from: transcriptURL, expectsTypeField: false)
            segmentCount = stats.count
            lastTimestamp = stats.lastTimestamp
        } else if FileManager.default.fileExists(atPath: eventsURL.path) {
            let stats = parseSegmentStats(from: eventsURL, expectsTypeField: true)
            segmentCount = stats.count
            lastTimestamp = stats.lastTimestamp
            speakerNames = stats.speakerNames
        }

        let durationSeconds = max(lastTimestamp, updatedAt.timeIntervalSince(createdAt))
        let streams: [String: MeetingStreamInfo] = [
            "system": MeetingStreamInfo(sampleRate: nil, channels: nil),
            "mic": MeetingStreamInfo(sampleRate: nil, channels: nil)
        ]

        let session = MeetingSessionMetadata(
            sessionID: 1,
            startedAt: createdAt,
            endedAt: updatedAt,
            audioFolder: audioFolderName,
            streams: streams
        )

        return MeetingMetadata(
            version: 1,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            durationSeconds: durationSeconds,
            lastTimestamp: lastTimestamp,
            status: .completed,
            sessions: [session],
            segmentCount: segmentCount,
            speakerNames: speakerNames
        )
    }

    private func legacyMeetingTitle(for folderURL: URL) -> String {
        let metaURL = folderURL.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = obj["title"] as? String,
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return folderURL.lastPathComponent
    }

    private func creationDate(for url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.creationDate] as? Date
    }

    private func latestModificationDate(for folderURL: URL) -> Date? {
        let candidates = [
            folderURL.appendingPathComponent("transcript.jsonl"),
            folderURL.appendingPathComponent("transcript.txt"),
            folderURL.appendingPathComponent("transcript_events.jsonl"),
            folderURL.appendingPathComponent("backend.log"),
            folderURL.appendingPathComponent("recording.mp4")
        ]
        var latest: Date?
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let date = attrs?[.modificationDate] as? Date {
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }
        return latest
    }

    private func findAudioFolderName(in folderURL: URL) -> String? {
        let audioURL = folderURL.appendingPathComponent("audio", isDirectory: true)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            return "audio"
        }

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true, entry.lastPathComponent.lowercased().hasPrefix("audio") {
                    return entry.lastPathComponent
                }
            }
        }
        return nil
    }

    private func parseSegmentStats(from url: URL, expectsTypeField: Bool) -> (count: Int, lastTimestamp: Double, speakerNames: [String: String]) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return (0, 0, [:])
        }

        var count = 0
        var lastTimestamp = 0.0
        var speakerNames: [String: String] = [:]

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if expectsTypeField {
                guard let type = obj["type"] as? String else { continue }
                if type == "speakers", let known = obj["known"] as? [[String: Any]] {
                    for entry in known {
                        if let speakerID = entry["speaker_id"] as? String {
                            let name = (entry["name"] as? String) ?? speakerID
                            speakerNames[speakerID] = name
                        }
                    }
                }
                guard type == "segment" else { continue }
            }

            guard let t0 = obj["t0"] as? Double else { continue }
            let t1 = obj["t1"] as? Double
            count += 1
            let end = t1 ?? t0
            if end > lastTimestamp {
                lastTimestamp = end
            }
        }

        return (count, lastTimestamp, speakerNames)
    }
}
