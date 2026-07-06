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

/// Single source of truth for the input-device policy.
///
/// `followSystem` adopts whatever macOS makes the default input (the launch
/// default). `pinned` holds one specific device, identified by its STABLE UID,
/// and survives the OS moving the default underneath us. A pin resets back to
/// `followSystem` only on the three reset conditions: the user re-picks a
/// different device, the pinned device disappears, or the user explicitly
/// selects "System default".
enum InputSelection: Equatable {
    case followSystem
    case pinned(uid: String)

    var logDescription: String {
        switch self {
        case .followSystem: return "follow"
        case .pinned(let uid): return "pinned(\(uid))"
        }
    }
}

/// Output-device policy. Mirrors `InputSelection`. The recording path is
/// device-independent (system audio is captured via ScreenCaptureKit), so this
/// governs the user-facing chosen playback device and the VPIO/built-in-speaker
/// echo-cancellation decision, not what gets recorded.
enum OutputSelection: Equatable {
    case followSystem
    case pinned(uid: String)

    var logDescription: String {
        switch self {
        case .followSystem: return "follow"
        case .pinned(let uid): return "pinned(\(uid))"
        }
    }
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
    // Source of truth for the input-device policy. `selectedInputDeviceID` is a
    // DERIVED display mirror for the picker (0 == "System default" / following).
    @Published private(set) var inputSelection: InputSelection = .followSystem
    @Published var selectedInputDeviceID: UInt32 = 0
    @Published var outputDevices: [AudioDevice] = []
    @Published private(set) var outputSelection: OutputSelection = .followSystem
    @Published var selectedOutputDeviceID: UInt32 = 0
    @Published var aecMode: AECMode = .auto {
        didSet {
            UserDefaults.standard.set(aecMode.rawValue, forKey: aecModeKey)
            // A mode change is a fresh chance for VPIO; restart so it takes effect.
            micVoiceProcessingDowngraded = false
            if isCapturing {
                enqueueMicLifecycle("aec-change") { await $0.restartMeetingMicEngineForInputSwitch() }
            }
        }
    }
    @Published var isPreviewingLevels = false
    @Published private(set) var isStartingMeeting = false

    // Per-buffer-accurate mic level/debug state. NOT @Published - the startup
    // health check and watchdog need these exact on every buffer, but the UI
    // must not invalidate at buffer rate. `meters` is the throttled display
    // mirror views actually observe (audit A1).
    private var micLevel: Float = 0
    private var debugMicBuffers: Int = 0
    private var debugMicFrames: Int = 0
    private var debugMicPTS: Double = 0
    private var debugMicFormat: String = "-"
    private var debugMicErrorMessage: String = "-"
    private var debugMicErrors: Int = 0
    let meters = AudioMetersModel()

    let transcriptModel = TranscriptModel()
    @Published var currentAttachments: [Attachment] = []

    private let captureEngine = CaptureEngine()
    // `any MicCapturing` rather than `MicEngine?`: this can hold either the
    // AVAudioEngine-backed MicEngine or CaptureSessionMicEngine, chosen per
    // start by `makeMicEngine` (see shouldUseCaptureSessionEngine).
    private var micEngine: (any MicCapturing)?
    private var previewMicEngine: (any MicCapturing)?
    private var isPreviewCaptureRunning = false
    private var previewLifecycleTask: Task<Void, Never>?
    // Single serializer for ALL mic engine start/stop/restart operations so two
    // device events can't interleave at an await suspension and orphan the engine
    // (audit D2/D8). Plus a monotonic generation token as belt-and-braces against
    // any stray start completing into a superseded generation.
    private var micLifecycleTask: Task<Void, Never>?
    private var micEngineGeneration: Int = 0
    // The device the running engine is actually bound to / started on. The
    // restart decision compares the DESIRED device to this, not a bare ID delta
    // on the display mirror (audit D1/D3).
    private var micEngineBoundDeviceID: UInt32 = 0
    // Which engine KIND the running engine actually is - kept in lockstep
    // with micEngineBoundDeviceID everywhere that's set/cleared. Needed
    // because the same device id can require a different engine as the
    // system default moves away from / back onto a pinned device (audit: 5
    // Jul 2026 incident - an id-only restart compare left AVAudioEngine
    // bound to a route it could no longer capture; see
    // shouldRestartForSelection).
    private var micEngineUsesCaptureSession: Bool = false
    // Same idea, for the start-screen preview engine (audit A2/D preview
    // parity: previously the preview had no bound-device bookkeeping at all,
    // so a device swap while sat on the start screen never re-resolved it).
    private var previewMicEngineBoundDeviceID: UInt32 = 0
    private var previewMicEngineUsesCaptureSession: Bool = false
    private var micStartupHealthTask: Task<Void, Never>?
    private var micFramesWatchdogTask: Task<Void, Never>?
    private let micWatchdogIntervalNs: UInt64 = 2_000_000_000
    private let micStallThresholdSeconds: Double = 4.0
    private var lastMicAudioAt: Date?
    private var micFrameCount: Int = 0
    private var micStartTime: Date?
    // When the current engine's start() call succeeded - distinct from
    // micStartTime (set on first frame). This is what lets the watchdog catch
    // an engine that never delivers frame one at all (audit: 5 Jul 2026
    // mic-dead-after-device-switch incident, MacBook Pro mic pinned=true but
    // zero frames ever, invisible to the old frames-only watchdog).
    private var micEngineStartedAt: Date?
    // Shared recovery-ladder state (see requestMicRecovery). Reset to 0 when a
    // frame actually arrives or the user hits Refresh; incremented once per
    // recovery attempt regardless of which caller (watchdog or health check)
    // triggered it.
    private var micNoAudioRecoveryAttempts: Int = 0
    // Debounces requestMicRecovery so the watchdog and the startup health
    // check can't both fire a rebuild for the same stall.
    private var micRecoveryPending = false
    // Set once the ladder gives up (attempt 3+ with nothing to fall back to,
    // or attempt 4+). Stops the watchdog re-detecting the same dead stall
    // every tick and re-logging/re-attempting for the rest of the meeting.
    // Cleared only where the ladder itself resets (see resetMicRecoveryLadder).
    private var micRecoveryParked = false
    // Effective VPIO state the current meeting-mic start requested, and whether a
    // VPIO->plain downgrade has already fired this generation (gates it to once).
    private var micVoiceProcessingRequested = false
    private var micVoiceProcessingDowngraded = false
    private let screenshotScheduler = ScreenshotScheduler()
    private let backendLogTailLimit = 200

    // Owns the mic hot path (level compute + FramedWriter delivery) off
    // MainActor entirely - see MicAudioForwarder's doc comment (2026-07-06
    // livelock fix, item 1). `micOutputEnabled`/`pendingMicAudio` used to
    // live on AppModel directly; both now live inside the forwarder.
    private let micAudioForwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
    // Owns backend.log file writes + the copy-debug ring buffer off
    // MainActor (2026-07-06 livelock fix, item 5). `nonisolated(unsafe)`:
    // BackendLogWriter is internally serialized on its own private queue
    // (see its doc comment), so it is genuinely safe to call from any
    // isolation domain, incl. `AudioLog.sink`'s arbitrary-queue closure -
    // that is the entire point of moving it off MainActor.
    private nonisolated(unsafe) let backendLogWriter = BackendLogWriter(ringBufferLimit: 200)
    // Detects (and logs) a wedged main thread from entirely off-main code -
    // see its doc comment (2026-07-06 livelock fix, item 2). Assigned in
    // init() since it depends on `backendLogWriter`/`micAudioForwarder`.
    private let mainActorStarvationWatchdog: MainActorStarvationWatchdog
    // Cheap storm tripwire - see its doc comment (2026-07-06 livelock fix,
    // item 7). Assigned in init() for the same reason.
    private let stormTripwire: RunLoopStormTripwire

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
    private let aecModeKey = "aecMode"
    private let inputSelectionModeKey = "inputSelectionMode"
    private let inputSelectionUIDKey = "inputSelectionUID"
    private let outputSelectionModeKey = "outputSelectionMode"
    private let outputSelectionUIDKey = "outputSelectionUID"
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
        mainActorStarvationWatchdog = MainActorStarvationWatchdog(
            logWriter: backendLogWriter, forwarder: micAudioForwarder
        )
        stormTripwire = RunLoopStormTripwire(logWriter: backendLogWriter)

        if let stored = UserDefaults.standard.string(forKey: aecModeKey),
           let mode = AECMode(rawValue: stored) {
            aecMode = mode
        }

        // Mirror the unified audio log into the backend-log writer's ring
        // buffer so the failure timeline is visible without Console. The
        // sink fires on arbitrary queues (CoreAudio listeners, mic-engine
        // actors, a MainActor heartbeat every ~2s) - it must NOT hop to
        // MainActor to do this (audit: 2026-07-06 livelock - the old
        // `Task { @MainActor in appendBackendLog }` here fed an
        // AppModel-wide invalidation drumbeat with zero live UI readers).
        // `backendLogWriter` is internally queue-serialized, so calling into
        // it directly from any thread is safe.
        AudioLog.sink = { [weak self] line in
            self?.backendLogWriter.append("[audio] \(line)", toTail: true)
        }

        // Safe only now: every stored property (including stormTripwire
        // itself) is assigned by this point, so this escaping closure can
        // capture `self`.
        stormTripwire.setContextProvider { [weak self] in
            guard let self else {
                return RunLoopStormTripwire.Context(
                    activeScreen: "-", transcriptRows: 0, historyCount: 0, meterPublishCount: 0
                )
            }
            return RunLoopStormTripwire.Context(
                activeScreen: String(describing: self.activeScreen),
                transcriptRows: self.transcriptModel.segments.count,
                historyCount: self.meetingHistory.count,
                meterPublishCount: self.meters.publishCount
            )
        }
        mainActorStarvationWatchdog.start()
        stormTripwire.start()

        // Restore the persisted device policy (a pin survives relaunch by UID).
        inputSelection = Self.persistedSelection(
            modeKey: inputSelectionModeKey, uidKey: inputSelectionUIDKey
        ).map(InputSelection.pinned) ?? .followSystem
        outputSelection = Self.persistedSelection(
            modeKey: outputSelectionModeKey, uidKey: outputSelectionUIDKey
        ).map(OutputSelection.pinned) ?? .followSystem

        captureEngine.metersModel = meters
        captureEngine.onStreamStopped = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.appendBackendLog("System audio capture stopped: \(error.localizedDescription)", toTail: true)
            }
        }
        AudioDeviceManager.observeInputDeviceChanges { [weak self] in
            AudioLog.event("listener.input.fired", ["snap": AudioDeviceManager.snapshot()])
            self?.loadInputDevices()
        }
        AudioDeviceManager.observeOutputDeviceChanges { [weak self] in
            AudioLog.event("listener.output.fired", ["snap": AudioDeviceManager.snapshot()])
            Task { @MainActor in self?.handleOutputDeviceChange() }
        }
        refreshPermissions()
        loadInputDevices()
        loadOutputDevices()
        loadBackendBookmark()
        validateBackendFolder()
        migrateLegacyMeetingsIfNeeded()
        recoverOrphanedMeetingsIfNeeded()
        loadMeetingHistory()
        Task { await loadShareableContent() }

        Task.detached(priority: .background) { [weak self] in
            let removed = TempTranscriptCleanup.sweep(temporaryDirectory: FileManager.default.temporaryDirectory)
            guard removed > 0 else { return }
            await MainActor.run {
                self?.appendBackendLog(
                    "Cleaned up \(removed) stale transcript temp folder(s) from previous launches.",
                    toTail: false
                )
            }
        }
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
        let tail = backendLogWriter.tailSnapshot(limit: 50).joined(separator: "\n")
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
        let logURL = folderURL.appendingPathComponent("backend.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        backendLogURL = logURL
        backendLogHandle = try? FileHandle(forWritingTo: logURL)
        backendLogWriter.reset(handle: backendLogHandle)
    }

    private func closeBackendLog() {
        backendLogWriter.close()
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
            appendBackendLog("Failed to flush \(label): \(error.localizedDescription)", toTail: true)
        }
    }

    /// The actual file write + ring-buffer append happen on
    /// `backendLogWriter`'s own queue, off MainActor (2026-07-06 livelock
    /// fix, item 5) - this call itself is fire-and-forget from here.
    private func appendBackendLog(_ line: String, toTail: Bool, handle: FileHandle? = nil) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        backendLogWriter.append(trimmed, toTail: toTail, handle: handle)
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

    /// Mirrors the current internal mic level/debug state into the throttled
    /// `meters` display model. Call after any mutation of the internal vars
    /// above (per-buffer callers get coalesced automatically by `meters`).
    /// One-shot callers (reset/stop/restart) pass `force: true` - a dropped
    /// publish there is never retried, so it must bypass the throttle.
    private func publishMicMeters(force: Bool = false) {
        meters.updateMic(
            level: micLevel,
            buffers: debugMicBuffers,
            frames: debugMicFrames,
            pts: debugMicPTS,
            format: debugMicFormat,
            force: force
        )
    }

    /// Mic error/status changes aren't per-buffer-rate; publish immediately.
    private func publishMicError() {
        meters.setMicError(message: debugMicErrorMessage, errorCount: debugMicErrors)
    }

    private func resetMicDebugState() {
        micLevel = 0
        debugMicBuffers = 0
        debugMicFrames = 0
        debugMicPTS = 0
        debugMicFormat = "-"
        debugMicErrorMessage = "-"
        debugMicErrors = 0
        micFrameCount = 0
        lastMicAudioAt = nil
        publishMicMeters(force: true)
        publishMicError()
    }

    /// MainActor-side bookkeeping for a mic buffer that `MicAudioForwarder`
    /// already delivered (level computed, sent to the backend or queued)
    /// entirely off MainActor - see the forwarder's doc comment for why (the
    /// 2026-07-06 livelock fix, item 1). This method only ever handles
    /// metering + recovery-ladder bookkeeping; it can lag behind the actual
    /// audio delivery under a MainActor storm without the audio pipeline
    /// itself being affected. `result.isFirstFrame` alone is a complete
    /// replacement for the old
    /// `lastMicAudioAt == nil || micNoAudioRecoveryAttempts > 0 ||
    /// micRecoveryParked` reset condition: any successful recovery attempt
    /// rebuilds the engine into a new generation, so its first delivered
    /// frame is always the generation's first frame too.
    private func onMicAudioDelivered(_ result: MicAudioForwarder.DeliveryResult, generation: Int) {
        guard generation == micEngineGeneration else { return }
        guard transcribeMic else { return }

        // A frame actually arriving is the ladder's success signal - not
        // just on the first frame of a generation, but also whenever a
        // recovery attempt is in flight or the ladder has parked. The
        // `.giveUp` step parks WITHOUT rebuilding the engine (see
        // `requestMicRecovery`), so a stall that resolves on its own on the
        // SAME generation never produces `isFirstFrame`; without this OR,
        // `micRecoveryParked`/the persistent mic alert would never clear
        // even though audio is flowing again (review-gate finding on the
        // 2026-07-06 livelock fix).
        let shouldResetRecovery = result.isFirstFrame || micNoAudioRecoveryAttempts > 0 || micRecoveryParked
        if shouldResetRecovery {
            resetMicRecoveryLadder()
        }
        if result.isFirstFrame {
            if let startedAt = micEngineStartedAt {
                AudioLog.event("mic.first-frame", ["msSinceStart": Int(Date().timeIntervalSince(startedAt) * 1000)])
            }
        }
        if result.isResumptionAfterGap {
            AudioLog.event("mic.resumed-after-gap", ["generation": generation])
        }

        micLevel = result.level
        debugMicBuffers += 1
        debugMicFrames = result.frameSampleCount
        debugMicPTS = result.elapsedSeconds
        // Liveness signals for UI/logging convenience. The frames watchdog's
        // actual STALL DETECTION reads `micAudioForwarder.snapshot()`
        // directly instead (ground truth, updated even when this MainActor
        // hop is delayed) - see `startMicFramesWatchdog`.
        lastMicAudioAt = Date()
        micFrameCount += 1
        debugMicFormat = "s16le sr=\(micOutputSampleRate) ch=\(micOutputChannels)"
        publishMicMeters()
    }

    private func handlePreviewMicAudio(_ data: Data) {
        micLevel = rmsLevelInt16(data)
        publishMicMeters()
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

    /// Serialize ALL mic engine start/stop/restart work through one chained task
    /// so two device events cannot interleave at an await and orphan the engine
    /// (audit D2/D8). Fire-and-forget; ordering is preserved. NEVER call this
    /// from within an op already running on this chain - that self-awaits and
    /// deadlocks; call `restartMeetingMicEngineForInputSwitch()` directly there.
    private func enqueueMicLifecycle(_ reason: String, _ op: @escaping @MainActor (AppModel) async -> Void) {
        let previous = micLifecycleTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            AudioLog.event("lifecycle.run", ["reason": reason])
            await op(self)
        }
        micLifecycleTask = task
    }

    // MARK: Selection persistence

    private static func persistedSelection(modeKey: String, uidKey: String) -> String? {
        guard UserDefaults.standard.string(forKey: modeKey) == "pinned",
              let uid = UserDefaults.standard.string(forKey: uidKey), !uid.isEmpty else {
            return nil
        }
        return uid
    }

    private func persistInputSelection() {
        switch inputSelection {
        case .followSystem:
            UserDefaults.standard.set("follow", forKey: inputSelectionModeKey)
            UserDefaults.standard.removeObject(forKey: inputSelectionUIDKey)
        case .pinned(let uid):
            UserDefaults.standard.set("pinned", forKey: inputSelectionModeKey)
            UserDefaults.standard.set(uid, forKey: inputSelectionUIDKey)
        }
    }

    private func persistOutputSelection() {
        switch outputSelection {
        case .followSystem:
            UserDefaults.standard.set("follow", forKey: outputSelectionModeKey)
            UserDefaults.standard.removeObject(forKey: outputSelectionUIDKey)
        case .pinned(let uid):
            UserDefaults.standard.set("pinned", forKey: outputSelectionModeKey)
            UserDefaults.standard.set(uid, forKey: outputSelectionUIDKey)
        }
    }

    private func setInputSelection(_ newValue: InputSelection) {
        guard inputSelection != newValue else { return }
        inputSelection = newValue
        persistInputSelection()
    }

    private func setOutputSelection(_ newValue: OutputSelection) {
        guard outputSelection != newValue else { return }
        outputSelection = newValue
        persistOutputSelection()
    }

    // MARK: Resolution

    /// The device the input engine should currently be on, per policy. In follow
    /// mode this is the live OS default; in pinned mode it's the pinned UID
    /// re-resolved to its current id, falling back to follow (RESET #2) if the
    /// pinned device has disappeared.
    private func resolvedInputDeviceID() -> (id: UInt32, pinned: Bool) {
        switch inputSelection {
        case .followSystem:
            return (AudioDeviceManager.defaultInputDeviceID() ?? 0, false)
        case .pinned(let uid):
            if let id = AudioDeviceManager.deviceID(forUID: uid) {
                return (id, true)
            }
            setInputSelection(.followSystem)
            AudioLog.event("resolve.pin-vanished", ["uid": uid])
            return (AudioDeviceManager.defaultInputDeviceID() ?? 0, false)
        }
    }

    /// One decision point for which mic-capture engine to instantiate. Always
    /// logs the choice (and why) so a support log tail proves which path a
    /// given start actually took.
    private func makeMicEngine(usesCaptureSession: Bool, context: String, resolvedID: UInt32, pinned: Bool) -> any MicCapturing {
        if usesCaptureSession {
            AudioLog.event("engine.select", [
                "engine": "capturesession", "context": context, "resolvedID": resolvedID
            ])
            return CaptureSessionMicEngine()
        }
        AudioLog.event("engine.select", [
            "engine": "avaudioengine", "context": context, "resolvedID": resolvedID, "pinned": pinned
        ])
        return MicEngine()
    }

    private func inputDeviceName(for id: UInt32) -> String {
        if let name = inputDevices.first(where: { $0.id == id })?.name {
            return name
        }
        return AudioDeviceManager.name(for: id) ?? "Device \(id)"
    }

    func loadOutputDevices() {
        outputDevices = AudioDeviceManager.outputDevices()
        switch outputSelection {
        case .followSystem:
            selectedOutputDeviceID = 0
        case .pinned(let uid):
            if let id = AudioDeviceManager.deviceID(forUID: uid),
               outputDevices.contains(where: { $0.id == id }) {
                selectedOutputDeviceID = id
            } else {
                setOutputSelection(.followSystem)
                selectedOutputDeviceID = 0
            }
        }
    }

    // MARK: User picks

    /// `id == 0` is the "System default" sentinel row (RESET #3 -> resume follow).
    func selectInputDevice(_ id: UInt32) {
        if id == 0 {
            guard inputSelection != .followSystem else { return }
            AudioLog.event("user.pick.input", ["choice": "system-default"])
            setInputSelection(.followSystem)
        } else {
            guard let uid = inputDevices.first(where: { $0.id == id })?.uid else { return }
            if case .pinned(let current) = inputSelection, current == uid { return }
            AudioLog.event("user.pick.input", [
                "toID": id, "toUID": uid, "toName": inputDeviceName(for: id)
            ])
            setInputSelection(.pinned(uid: uid))
        }
        applyInputSelectionChange()
    }

    func selectOutputDevice(_ id: UInt32) {
        if id == 0 {
            guard outputSelection != .followSystem else { return }
            AudioLog.event("user.pick.output", ["choice": "system-default"])
            setOutputSelection(.followSystem)
        } else {
            guard let uid = outputDevices.first(where: { $0.id == id })?.uid else { return }
            if case .pinned(let current) = outputSelection, current == uid { return }
            AudioLog.event("user.pick.output", ["toID": id, "toUID": uid])
            setOutputSelection(.pinned(uid: uid))
            // A manual output pin is the user choosing the playback device; make
            // it the system default output so playback actually moves there.
            _ = AudioDeviceManager.setDefaultOutputDevice(id)
        }
        loadOutputDevices()
        // An output change is a fresh chance for VPIO; let the engine re-evaluate.
        if isCapturing {
            micVoiceProcessingDowngraded = false
            enqueueMicLifecycle("output-pick") { await $0.restartMeetingMicEngineForInputSwitch() }
        }
    }

    /// Apply an input policy change: re-resolve + (if capturing) restart the
    /// meeting engine when the device actually differs, else refresh the preview.
    private func applyInputSelectionChange() {
        micVoiceProcessingDowngraded = false
        // A manual device pick is fresh user intent - same rationale as
        // Refresh. But requestMicRecovery's own fallback step calls
        // selectInputDevice(0) internally, setting micRecoveryPending = true
        // just before doing so precisely so this reset doesn't stomp on its
        // in-flight bookkeeping (the alert it just set, the attempt count) -
        // only reset when nothing is already pending.
        if !micRecoveryPending {
            resetMicRecoveryLadder()
        }
        loadInputDevices()   // refreshes the mirror + enqueues a restart if the device changed
        if !isCapturing, previewMicEngine != nil {
            enqueueMicLifecycle("input-pick-preview") { await $0.restartPreviewMicEngineForInputSwitch() }
        }
    }

    private func startHomeLevelPreviewNow() async {
        guard !isCapturing else { return }
        guard !isStartingMeeting else { return }
        // A meeting that just stopped is still tearing down (capture engine,
        // mic engine, backend) until isFinalizing clears - starting the
        // preview capture concurrently would race that teardown. See the
        // `finalizeStoppedMeeting` defer for the matching restart-kick once
        // finalizing completes (item 4, 2026-07-06 livelock fix).
        guard !isFinalizing else {
            isPreviewingLevels = false
            return
        }
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
            let (resolvedID, pinned) = resolvedInputDeviceID()
            previewMicEngineBoundDeviceID = resolvedID
            let usesCaptureSession = shouldUseCaptureSessionEngine(
                resolvedID: resolvedID, pinned: pinned, liveDefaultInputID: AudioDeviceManager.defaultInputDeviceID() ?? 0
            )
            previewMicEngineUsesCaptureSession = usesCaptureSession
            do {
                try await attemptPreviewMicEngineStart(usesCaptureSession: usesCaptureSession, resolvedID: resolvedID, pinned: pinned)
            } catch is CaptureSessionMicEngineError where usesCaptureSession {
                // Same fallback as the meeting engine - see startMeetingMicEngine.
                AudioLog.event("engine.select.capturesession-fallback", ["context": "preview", "resolvedID": resolvedID])
                previewMicEngineUsesCaptureSession = false
                do {
                    try await attemptPreviewMicEngineStart(usesCaptureSession: false, resolvedID: resolvedID, pinned: pinned)
                } catch {
                    handlePreviewMicStartFailure(error)
                }
            } catch {
                handlePreviewMicStartFailure(error)
            }
        }

        isPreviewingLevels = isPreviewCaptureRunning || (previewMicEngine != nil)
    }

    /// One start attempt for the start-screen preview mic engine - the
    /// preview's analogue of `attemptMeetingMicEngineStart`. Assigns
    /// `previewMicEngine` up front (a concurrent guard elsewhere expects a
    /// non-nil engine while starting) and clears it back to nil if it throws.
    private func attemptPreviewMicEngineStart(usesCaptureSession: Bool, resolvedID: UInt32, pinned: Bool) async throws {
        let engine = makeMicEngine(usesCaptureSession: usesCaptureSession, context: "preview", resolvedID: resolvedID, pinned: pinned)
        previewMicEngine = engine
        do {
            try await engine.start(
                // CaptureSessionMicEngine has no VPIO equivalent - never request it there.
                enableVoiceProcessing: usesCaptureSession ? false : shouldEnableVoiceProcessing(),
                preferredInputDeviceID: resolvedID == 0 ? nil : resolvedID,
                pinned: pinned,
                onConfigurationChange: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        AudioLog.event("preview.engine.configchange", ["snap": AudioDeviceManager.snapshot()])
                        // Same re-resolve the meeting engine's hook does;
                        // loadInputDevices() restarts the preview itself
                        // if the resolved device actually moved.
                        self.loadInputDevices()
                    }
                }
            ) { [weak self] data in
                Task { @MainActor in
                    self?.handlePreviewMicAudio(data)
                }
            }
        } catch {
            previewMicEngine = nil
            throw error
        }

        guard !isCapturing, !isStartingMeeting, isStartScreenActive else {
            await engine.stop()
            previewMicEngine = nil
            previewMicEngineBoundDeviceID = 0
            previewMicEngineUsesCaptureSession = false
            isPreviewingLevels = isPreviewCaptureRunning
            return
        }
    }

    private func handlePreviewMicStartFailure(_ error: Error) {
        previewMicEngineBoundDeviceID = 0
        previewMicEngineUsesCaptureSession = false
        debugMicErrors += 1
        debugMicErrorMessage = "mic_preview_start_failed: \(error.localizedDescription)"
        publishMicError()
    }

    private func stopHomeLevelPreviewNow() async {
        if let engine = previewMicEngine {
            await engine.stop()
            previewMicEngine = nil
            previewMicEngineBoundDeviceID = 0
            previewMicEngineUsesCaptureSession = false
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
        publishMicMeters(force: true)
        meters.updateSystem(
            level: captureEngine.systemLevel,
            buffers: captureEngine.debugSystemBuffers,
            frames: captureEngine.debugSystemFrames,
            pts: captureEngine.debugSystemPTS,
            format: captureEngine.debugSystemFormat,
            force: true
        )
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

    private func shouldEnableVoiceProcessing() -> Bool {
        let outputIsBuiltIn = AudioDeviceManager.defaultOutputDeviceID().map(AudioDeviceManager.isBuiltInSpeaker) ?? false
        return shouldRequestVoiceProcessing(mode: aecMode, outputIsBuiltInSpeaker: outputIsBuiltIn)
    }

    private func startMeetingMicEngine() async {
        guard transcribeMic else {
            micEngine = nil
            micEngineStartedAt = nil
            await micAudioForwarder.stop()
            cancelMicStartupHealthCheck()
            return
        }

        micEngineGeneration += 1
        let generation = micEngineGeneration

        // Re-resolve the device at the moment of start so a steal that happened
        // between the trigger and here is honoured. A pinned device binds
        // unconditionally; follow mode lets the engine track the default.
        let (resolvedID, pinned) = resolvedInputDeviceID()
        micEngineBoundDeviceID = resolvedID
        let usesCaptureSession = shouldUseCaptureSessionEngine(
            resolvedID: resolvedID, pinned: pinned, liveDefaultInputID: AudioDeviceManager.defaultInputDeviceID() ?? 0
        )
        micEngineUsesCaptureSession = usesCaptureSession

        do {
            try await attemptMeetingMicEngineStart(
                usesCaptureSession: usesCaptureSession, resolvedID: resolvedID, pinned: pinned, generation: generation
            )
        } catch is CaptureSessionMicEngineError where usesCaptureSession {
            // The capture-session engine could not even start (e.g. the CoreAudio
            // UID -> AVCaptureDevice mapping did not hold on this hardware - the
            // one unverified assumption in that path). Degrade to AVAudioEngine
            // for the SAME device rather than a hard dead end: at worst this
            // reproduces the OLD silent-zero-frames failure mode, which the
            // watchdog + recovery ladder already rescue (MicRecoveryLadder) -
            // a capture session that throws on every attempt would otherwise
            // leave a broken pin permanently dead, surviving even Refresh.
            AudioLog.event("engine.select.capturesession-fallback", ["gen": generation, "resolvedID": resolvedID])
            micEngineUsesCaptureSession = false
            do {
                try await attemptMeetingMicEngineStart(
                    usesCaptureSession: false, resolvedID: resolvedID, pinned: pinned, generation: generation
                )
            } catch {
                await handleMeetingMicEngineStartFailure(error)
            }
        } catch {
            await handleMeetingMicEngineStartFailure(error)
        }
    }

    /// One start attempt for the meeting mic engine: builds the engine for the
    /// given choice, starts it, and on success runs the usual post-start
    /// bookkeeping (generation/isFinalizing guards, micEngine assignment,
    /// health check). Throws without touching `micEngine` on failure - the
    /// caller decides how to react (VPIO retry, capture-session fallback, or
    /// surfacing the failure).
    private func attemptMeetingMicEngineStart(
        usesCaptureSession: Bool, resolvedID: UInt32, pinned: Bool, generation: Int
    ) async throws {
        let engine = makeMicEngine(usesCaptureSession: usesCaptureSession, context: "meeting", resolvedID: resolvedID, pinned: pinned)

        // Effective VPIO drops to off once a downgrade has fired this
        // generation, and unconditionally for the capture-session path (it
        // has no VPIO equivalent - see CaptureSessionMicEngine's header).
        let enableVPIO = usesCaptureSession ? false : (shouldEnableVoiceProcessing() && !micVoiceProcessingDowngraded)
        micVoiceProcessingRequested = enableVPIO

        AudioLog.event("engine.start.begin", [
            "gen": generation, "vpio": enableVPIO, "pinned": pinned, "resolvedID": resolvedID, "captureSession": usesCaptureSession
        ])

        // Arm the forwarder's new generation BEFORE the tap can possibly
        // fire, so audio delivery (level compute + FramedWriter.send) never
        // depends on MainActor being free - see MicAudioForwarder's doc
        // comment (2026-07-06 livelock fix, item 1). This also closes the
        // narrow startup race the old MainActor-side `pendingMicAudio`
        // mechanism only papered over: no buffer can arrive before its
        // generation is recognised.
        await micAudioForwarder.beginGeneration(generation, writer: writer)

        try await engine.start(
            enableVoiceProcessing: enableVPIO,
            preferredInputDeviceID: resolvedID == 0 ? nil : resolvedID,
            pinned: pinned,
            onConfigurationChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    AudioLog.event("engine.configchange", ["snap": AudioDeviceManager.snapshot()])
                    // Re-resolve under the new route; restarts only if the
                    // device the engine should be on actually moved.
                    self.loadInputDevices()
                }
            }
        ) { [weak self] data in
            guard let self else { return }
            // Deliver directly to the forwarder - NOT `Task { @MainActor in
            // ... }` - so this never needs a live UI thread. Only a
            // throttled subset of deliveries (see the forwarder's gating)
            // hops to MainActor afterwards, purely for metering/recovery-
            // ladder bookkeeping.
            Task {
                guard let result = await self.micAudioForwarder.deliver(data, generation: generation) else { return }
                await self.onMicAudioDelivered(result, generation: generation)
            }
        }
        // Serialization should prevent overlap, but bail if a newer start
        // superseded this one before it completed (audit D2 belt-and-braces).
        guard generation == micEngineGeneration else {
            AudioLog.event("engine.start.superseded", ["gen": generation, "current": micEngineGeneration])
            await engine.stop()
            return
        }
        // A stop() that ran concurrently with this start (e.g. a recovery
        // rebuild in flight when the user hit Stop) must not have this
        // start assign a live engine after the meeting has ended - stop
        // what we just started and leave micEngine untouched instead.
        guard !isFinalizing else {
            AudioLog.event("engine.start.superseded-by-stop", ["gen": generation])
            await engine.stop()
            return
        }
        micEngine = engine
        micEngineStartedAt = Date()
        await micAudioForwarder.setOutputEnabled(true)
        debugMicErrorMessage = "-"
        publishMicError()
        if isCapturing {
            scheduleMicStartupHealthCheck()
        }
    }

    private func handleMeetingMicEngineStartFailure(_ error: Error) async {
        // A VPIO-format failure is not a hard failure: downgrade to plain
        // capture once and restart rather than leaving the mic dead.
        if let micEngineError = error as? MicEngineError,
           case .invalidInputFormat(_, _, _, let vpioRequested) = micEngineError,
           vpioRequested, !micVoiceProcessingDowngraded {
            micVoiceProcessingDowngraded = true
            appendBackendLog("Echo cancellation could not start on this audio route; continuing without it.", toTail: true)
            AudioLog.event("engine.start.vpio-downgrade-retry")
            // The start threw, so nothing was assigned/needs teardown - just
            // retry the start (downgraded flag now forces VPIO off). NB this
            // path runs at first-start too, BEFORE isCapturing is set, so it
            // must not route through restartMeetingMicEngineForInputSwitch
            // (which guards on isCapturing and would no-op here).
            await startMeetingMicEngine()
            return
        }
        await handleMicStartFailure(error)
    }

    private func handleMicStartFailure(_ error: Error) async {
        micEngine = nil
        micEngineStartedAt = nil
        micEngineBoundDeviceID = 0
        micEngineUsesCaptureSession = false
        await micAudioForwarder.stop()
        cancelMicStartupHealthCheck()
        debugMicErrors += 1
        debugMicErrorMessage = "mic_start_failed: \(error.localizedDescription)"
        publishMicError()
        // The red debugMicErrorMessage line takes precedence in SessionView,
        // but a stale "reconnecting..." alert must not be left to resurface
        // after a later successful start, before the first frame arrives.
        meters.clearMicAlert()
        AudioLog.error("engine.start.fail.surfaced", ["error": String(describing: error)])
        appendBackendLog("Mic engine failed to start: \(error.localizedDescription)", toTail: true)
    }

    /// Stop-then-start the meeting mic engine. MUST run on the mic lifecycle
    /// serializer (via `enqueueMicLifecycle`) - never spawn it in a bare Task.
    private func restartMeetingMicEngineForInputSwitch() async {
        guard isCapturing else { return }
        guard transcribeMic else { return }
        // A stop in progress poisons any queued/in-flight restart - the
        // belt-and-braces check in startMeetingMicEngine also catches a
        // restart that was already past this guard when stop began.
        guard !isFinalizing else { return }

        // A restart supersedes any pending startup health check (audit D15).
        cancelMicStartupHealthCheck()
        AudioLog.event("engine.restart.begin", ["boundID": micEngineBoundDeviceID])

        if let engine = micEngine {
            await engine.stop()
            micEngine = nil
        }
        micEngineBoundDeviceID = 0
        micEngineUsesCaptureSession = false
        micEngineStartedAt = nil

        // The upcoming startMeetingMicEngine() call re-arms the forwarder
        // for a fresh generation (see beginGeneration), but stop it
        // explicitly here too so forwarding halts the instant the engine
        // does, rather than lingering until the new generation is armed.
        await micAudioForwarder.stop()
        micLevel = 0
        debugMicBuffers = 0
        debugMicFrames = 0
        debugMicPTS = 0
        lastMicAudioAt = nil
        publishMicMeters(force: true)
        await startMeetingMicEngine()
        AudioLog.event("engine.restart.end", ["boundID": micEngineBoundDeviceID])
    }

    private func restartPreviewMicEngineForInputSwitch() async {
        await runPreviewLifecycleOperation { model in
            if let engine = model.previewMicEngine {
                await engine.stop()
                model.previewMicEngine = nil
                model.previewMicEngineBoundDeviceID = 0
                model.previewMicEngineUsesCaptureSession = false
            }
            await model.startHomeLevelPreviewNow()
        }
    }

    private func cancelMicStartupHealthCheck() {
        micStartupHealthTask?.cancel()
        micStartupHealthTask = nil
    }

    /// Continuous frames-flowing watchdog for the whole meeting (the startup
    /// health check is one-shot and can't catch a mic that dies mid-meeting -
    /// audit D9). Logs a heartbeat every interval and force-restarts on a stall
    /// once frames have actually been flowing. This is the recovery for the
    /// silent-dead-mic-on-device-change symptom.
    private func startMicFramesWatchdog() {
        stopMicFramesWatchdog()
        micFramesWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.micWatchdogIntervalNs ?? 2_000_000_000)
                guard let self else { return }
                guard !Task.isCancelled else { return }
                guard self.isCapturing, self.transcribeMic else { continue }

                // Ground truth from the forwarder, NOT the MainActor mirrors
                // (`lastMicAudioAt`/`micFrameCount`) - those can lag behind
                // reality under exactly the MainActor storm this watchdog
                // needs to stay correct through (2026-07-06 livelock fix,
                // item 1). A delayed mirror must never read as "mic stopped"
                // when the forwarder is still delivering fine off-actor.
                let snap = await self.micAudioForwarder.snapshot()
                let reference = snap.lastFrameAt ?? self.micStartTime
                let since = reference.map { Date().timeIntervalSince($0) }
                AudioLog.event("heartbeat", [
                    "frames": snap.frameCount,
                    "sinceLastFrameMs": since.map { Int($0 * 1000) } ?? -1,
                    "micLevel": String(format: "%.3f", self.micLevel),
                    "engineAlive": self.micEngine != nil,
                    "boundID": self.micEngineBoundDeviceID,
                    "snap": AudioDeviceManager.snapshot()
                ])

                guard self.micEngine != nil else { continue }
                // Once the ladder has given up, stop re-detecting the same
                // dead stall every tick - that would re-log heartbeat.STALL
                // and re-announce "attempting recovery" for the rest of the
                // meeting even though requestMicRecovery itself would no-op.
                guard !self.micRecoveryParked else { continue }
                if let last = snap.lastFrameAt {
                    // Delivered-then-stopped: frames were flowing and died.
                    guard Date().timeIntervalSince(last) > self.micStallThresholdSeconds else { continue }
                    AudioLog.error("heartbeat.STALL", [
                        "sinceLastFrameMs": Int(Date().timeIntervalSince(last) * 1000),
                        "snap": AudioDeviceManager.snapshot()
                    ])
                    self.appendBackendLog("Mic stopped delivering audio - restarting capture.", toTail: true)
                    self.requestMicRecovery(reason: "watchdog-stall")
                } else if let startedAt = self.micEngineStartedAt,
                          Date().timeIntervalSince(startedAt) > self.micStallThresholdSeconds {
                    // Never-delivered-at-all: lastFrameAt only arms after a
                    // first frame, so an engine that never delivers frame one
                    // was previously invisible here (the 5 Jul 2026 incident -
                    // engine.start.ok pinned=true but zero frames, ever).
                    AudioLog.error("heartbeat.STALL.no-first-frame", [
                        "sinceStartMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                        "snap": AudioDeviceManager.snapshot()
                    ])
                    self.appendBackendLog("Mic never delivered audio after switching input - attempting recovery.", toTail: true)
                    self.requestMicRecovery(reason: "watchdog-no-first-frame")
                }
            }
        }
    }

    private func stopMicFramesWatchdog() {
        micFramesWatchdogTask?.cancel()
        micFramesWatchdogTask = nil
    }

    /// True when the input is pinned to a specific device that is not
    /// currently the live system default - i.e. there is somewhere sensible to
    /// fall back to. Re-resolved fresh each call rather than cached, since the
    /// OS default can move independently of our pin.
    private func isPinnedAwayFromSystemDefaultInput() -> Bool {
        guard case .pinned(let uid) = inputSelection else { return false }
        guard let pinnedID = AudioDeviceManager.deviceID(forUID: uid) else { return false }
        let defaultID = AudioDeviceManager.defaultInputDeviceID() ?? 0
        return defaultID != 0 && pinnedID != defaultID
    }

    /// Single shared entry point for automatic mic-dead recovery. Called by
    /// both frames-watchdog stall paths (delivered-then-stopped and
    /// never-delivered) and the startup health check's no-VPIO no-audio
    /// branch, which previously just logged and gave up (audit: the 5 Jul
    /// 2026 incident - a pinned device switch left the tap silently dead with
    /// no recovery until the user manually switched back). `micRecoveryPending`
    /// is the debounce: it stops the watchdog and the health check racing each
    /// other into a double rebuild for the same stall.
    private func requestMicRecovery(reason: String) {
        guard !micRecoveryPending else { return }
        guard !micRecoveryParked else { return }
        guard isCapturing, transcribeMic else { return }
        guard !isFinalizing else { return }

        micNoAudioRecoveryAttempts += 1
        let attempt = micNoAudioRecoveryAttempts
        let pinnedAway = isPinnedAwayFromSystemDefaultInput()
        let step = MicRecoveryLadder.step(forAttempt: attempt, isPinnedAwayFromDefault: pinnedAway)
        AudioLog.event("mic.recovery", ["reason": reason, "attempt": attempt, "step": String(describing: step)])

        switch step {
        case .rebuild:
            meters.setMicAlert("Mic stopped delivering audio - reconnecting...")
            micRecoveryPending = true
            enqueueMicLifecycle(reason) { model in
                await model.restartMeetingMicEngineForInputSwitch()
                model.micRecoveryPending = false
            }
        case .fallbackToSystemDefault:
            var deviceName = "the pinned input"
            if case .pinned(let uid) = inputSelection, let id = AudioDeviceManager.deviceID(forUID: uid) {
                deviceName = inputDeviceName(for: id)
            }
            let message = "No audio from \(deviceName) - switched back to the system default input"
            appendBackendLog(message, toTail: true)
            meters.setMicAlert(message)
            micRecoveryPending = true
            // The normal UI pathway: updates the picker AND, since the
            // resolved device now differs from the dead-bound one, enqueues
            // the rebuild itself via loadInputDevices - a second explicit
            // restart here would just be a redundant extra rebuild.
            selectInputDevice(0)
            enqueueMicLifecycle(reason) { model in
                model.micRecoveryPending = false
            }
        case .giveUp:
            meters.setMicAlert("Microphone is not delivering audio. Try Refresh or pick a different input.")
            micRecoveryParked = true
        }
    }

    /// Resets all recovery-ladder bookkeeping in lockstep. Called wherever a
    /// fresh success or a fresh user intent invalidates the old state: a
    /// frame arriving, Refresh, a manual device pick, or the meeting stopping.
    private func resetMicRecoveryLadder() {
        micNoAudioRecoveryAttempts = 0
        micRecoveryPending = false
        micRecoveryParked = false
        meters.clearMicAlert()
    }

    /// User-triggered recovery (the Refresh button). Re-enumerates devices AND
    /// force-restarts a dead/stale meeting engine even when the resolved device
    /// id has not changed - the old Refresh only restarted on an id delta and so
    /// could not rescue a dead-but-present mic (audit D3).
    func refreshMicrophones() {
        AudioLog.event("user.refresh", ["snap": AudioDeviceManager.snapshot()])
        loadInputDevices()
        loadOutputDevices()

        guard isCapturing else {
            // Not in a meeting: this is the fix for "Refresh does nothing" on
            // the start screen (audit A3) - re-enumerating devices alone never
            // touched the preview engine driving the meters, so a dead/stale
            // preview meter had nothing to bring it back except a manual
            // device pick. No `previewMicEngine != nil` gate here on purpose:
            // the dead-preview case a user actually hits is the engine having
            // FAILED to start and been nilled (mic_preview_start_failed), and
            // restartPreviewMicEngineForInputSwitch already handles a nil
            // engine fine (skips the stop, goes straight to
            // startHomeLevelPreviewNow, which has its own guards).
            if isStartScreenActive {
                enqueueMicLifecycle("refresh-preview") { await $0.restartPreviewMicEngineForInputSwitch() }
            }
            return
        }
        guard transcribeMic else { return }
        let stale = lastMicAudioAt.map { Date().timeIntervalSince($0) > micStallThresholdSeconds } ?? true
        if micEngine == nil || debugMicBuffers == 0 || stale {
            AudioLog.event("user.refresh.force-restart", [
                "engineAlive": micEngine != nil, "buffers": debugMicBuffers
            ])
            micVoiceProcessingDowngraded = false
            // A manual refresh is a fresh user intent - the ladder starts over.
            resetMicRecoveryLadder()
            enqueueMicLifecycle("refresh") { await $0.restartMeetingMicEngineForInputSwitch() }
        }
    }

    /// Runs `refreshMicrophones()` and waits for whatever lifecycle work it
    /// enqueued (a meeting-engine restart, a preview restart, or nothing) so
    /// the Refresh button can show feedback tied to real completion rather
    /// than a guessed delay.
    func refreshMicrophonesAwaitingCompletion() async {
        refreshMicrophones()
        await micLifecycleTask?.value
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

            // A VPIO route that delivered no audio is the silent-failure case:
            // downgrade once to plain capture and health-check that too. The
            // restart reschedules the health check itself on success.
            if micVoiceProcessingRequested && !micVoiceProcessingDowngraded {
                micVoiceProcessingDowngraded = true
                appendBackendLog("Echo cancellation could not start on this audio route; continuing without it.", toTail: true)
                AudioLog.event("healthcheck.no-audio.vpio-downgrade")
                enqueueMicLifecycle("vpio-downgrade") { await $0.restartMeetingMicEngineForInputSwitch() }
                return
            }

            // Plain capture with no audio is a genuine mic problem, not VPIO -
            // route into the shared recovery ladder instead of logging and
            // giving up (this was the dead end in the 5 Jul 2026 incident).
            AudioLog.error("healthcheck.no-audio")
            appendBackendLog("Mic health check: still no audio.", toTail: true)
            requestMicRecovery(reason: "healthcheck-no-audio")
        }
    }

    @MainActor
    private func handleOutputDeviceChange() {
        // Honour the output policy: a pin re-asserts itself if the OS moved the
        // default output away from it; a vanished pin resets to follow.
        if case .pinned(let uid) = outputSelection {
            if let id = AudioDeviceManager.deviceID(forUID: uid) {
                if AudioDeviceManager.defaultOutputDeviceID() != id {
                    _ = AudioDeviceManager.setDefaultOutputDevice(id)
                    AudioLog.event("output.reassert-pin", ["uid": uid, "id": id])
                }
            } else {
                setOutputSelection(.followSystem)
                AudioLog.event("output.pin-vanished", ["uid": uid])
            }
        }
        loadOutputDevices()

        // No active mic generation means nothing to re-evaluate; the next start
        // resets the downgrade flag itself.
        guard isCapturing, transcribeMic else { return }

        // An output change is a fresh chance for VPIO, in any mode.
        micVoiceProcessingDowngraded = false

        // Only Auto's decision depends on the output route; manual On/Off keep
        // their decision (the reset above still lets a later restart retry VPIO).
        guard aecMode == .auto else { return }
        guard shouldEnableVoiceProcessing() != micVoiceProcessingRequested else { return }

        enqueueMicLifecycle("output-change") { await $0.restartMeetingMicEngineForInputSwitch() }
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
            .appendingPathComponent(TempTranscriptCleanup.stagingDirectoryName, isDirectory: true)
        let tempFolder = tempBase.appendingPathComponent("\(session.title)-\(UUID().uuidString)")
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

        let previousID = selectedInputDeviceID
        let (desiredID, pinned) = resolvedInputDeviceID()

        // The picker mirror: 0 == "System default" row when following; the pinned
        // device id otherwise.
        selectedInputDeviceID = pinned ? desiredID : 0

        let liveDefaultInputID = AudioDeviceManager.defaultInputDeviceID() ?? 0
        let desiredUsesCaptureSession = shouldUseCaptureSessionEngine(
            resolvedID: desiredID, pinned: pinned, liveDefaultInputID: liveDefaultInputID
        )

        // Restart only when capturing and EITHER the device the engine SHOULD
        // be on differs from what it's actually bound to, OR the bound device
        // is unchanged but now needs a different ENGINE KIND. The kind case
        // is liveness/identity aware in the same spirit as the id-only check
        // it replaces (audit D1/D3: a follow-mode steal moves `desiredID` off
        // `micEngineBoundDeviceID`), but closes a gap that check left open
        // (audit: 5 Jul 2026 incident) - pinned==default at start picks
        // AVAudioEngine; the default then moves elsewhere; `desiredID` is
        // UNCHANGED (still the pinned device) so an id-only compare never
        // restarted, leaving AVAudioEngine bound to a route it can no longer
        // capture. See `shouldRestartForSelection`.
        let willRestart = isCapturing && transcribeMic && !isFinalizing
            && shouldRestartForSelection(
                desiredID: desiredID, boundID: micEngineBoundDeviceID,
                desiredUsesCaptureSession: desiredUsesCaptureSession, currentUsesCaptureSession: micEngineUsesCaptureSession
            )
        // Same liveness check for the start-screen preview engine (audit A2
        // preview parity) - only meaningful when there's no meeting running
        // and a preview engine actually exists to be stale.
        let willRestartPreview = !isCapturing && previewMicEngine != nil
            && shouldRestartForSelection(
                desiredID: desiredID, boundID: previewMicEngineBoundDeviceID,
                desiredUsesCaptureSession: desiredUsesCaptureSession, currentUsesCaptureSession: previewMicEngineUsesCaptureSession
            )

        AudioLog.event("resolve.input", [
            "mode": inputSelection.logDescription,
            "previousID": previousID,
            "desiredID": desiredID,
            "boundID": micEngineBoundDeviceID,
            "pinned": pinned,
            "isCapturing": isCapturing,
            "willRestart": willRestart,
            "willRestartPreview": willRestartPreview,
            "desiredCaptureSession": desiredUsesCaptureSession,
            "boundCaptureSession": micEngineUsesCaptureSession,
            "snap": AudioDeviceManager.snapshot()
        ])

        if willRestart {
            micVoiceProcessingDowngraded = false
            enqueueMicLifecycle("input-resolve") { await $0.restartMeetingMicEngineForInputSwitch() }
        } else if willRestartPreview {
            enqueueMicLifecycle("input-resolve-preview") { await $0.restartPreviewMicEngineForInputSwitch() }
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
        // The choke point for BOTH the fresh-start (public startMeeting()) and
        // resume (resumeMeeting -> here directly) paths. stopMeeting() clears
        // isCapturing and flips activeScreen back to .start well before its
        // async finalization finishes (isFinalizing stays true until then),
        // so the start screen's Resume button can otherwise be tapped mid-stop
        // - without this guard a fresh engine start could race the still-
        // draining stop and end up unassigned (see startMeetingMicEngine's
        // superseded-by-stop check) while this function carries on regardless,
        // starting the health check/watchdog against a mic that never bound.
        guard !isFinalizing else {
            AudioLog.event("start.blocked-finalizing")
            return
        }
        isStartingMeeting = true
        defer { isStartingMeeting = false }
        cancelMicStartupHealthCheck()
        micVoiceProcessingDowngraded = false
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
                await teardownFailedMeetingStart(session: session, wasResume: meeting != nil, priorMetadata: metadata)
                return
            }

            let writer: FramedWriter
            switch resolveBackendPython(for: backendProjectRoot) {
            case .success(let backendPython):
                if !FileManager.default.fileExists(atPath: backendPython) {
                    let message = "Backend python not found at \(backendPython)."
                    shareableContentError = message
                    backendFolderError = message
                    await teardownFailedMeetingStart(session: session, wasResume: meeting != nil, priorMetadata: metadata)
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
                command.append("--live-asr-only")
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
                await teardownFailedMeetingStart(session: session, wasResume: meeting != nil, priorMetadata: metadata)
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
            // Mic-side flushing is now handled inline by
            // `micAudioForwarder.setOutputEnabled(true)` at the moment the
            // engine started (see attemptMeetingMicEngineStart) - there is
            // no separate mic flush step here any more.

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
            startMicFramesWatchdog()
        } catch {
            let pythonPath = backendPythonCandidatePath ?? "(unknown)"
            let nsError = error as NSError
            let details = "domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)"
            shareableContentError = "Failed to start backend or capture: \(error). Python: \(pythonPath) exists=\(backendPythonExists) sandboxed=\(isSandboxed) \(details)"
            appendBackendLog("Start failure: \(shareableContentError ?? "\(error)")", toTail: true)
            await teardownFailedMeetingStart(session: session, wasResume: meeting != nil, priorMetadata: metadata)
        }
    }

    /// Explicit teardown for a startMeeting() attempt that threw partway
    /// through. Only some prefix of the happy path above may have actually
    /// run by the time the throw happened - backend log/transcript-events log
    /// always have (they're the first statements in the do block), but the
    /// backend process, writer, mic engine and system capture may or may not
    /// have started depending on where the failure occurred. Previously the
    /// catch called `stopMeeting()`, which no-ops on its `guard isCapturing`
    /// since isCapturing is never set true before this catch runs - so
    /// whatever had already started (backend process, writer, capture engine,
    /// mic engine, log handles) leaked until the next Start (2026-07-04
    /// review, GPT-5 finding). Every step below is nil-safe/idempotent so it's
    /// harmless to run regardless of how far the failed attempt got; this
    /// hard-kills the backend rather than waiting for a graceful exit since
    /// there is no meeting transcript to finalize.
    private func teardownFailedMeetingStart(
        session: MeetingSession,
        wasResume: Bool,
        priorMetadata: MeetingMetadata?
    ) async {
        cancelMicStartupHealthCheck()
        stopMicFramesWatchdog()
        screenshotScheduler.stop()
        await captureEngine.stopCapture()

        enqueueMicLifecycle("start-failure-cleanup") { model in
            if let engine = model.micEngine {
                await engine.stop()
            }
            model.micEngine = nil
            model.micEngineStartedAt = nil
            model.micEngineBoundDeviceID = 0
            model.micEngineUsesCaptureSession = false
        }
        await micLifecycleTask?.value
        await micAudioForwarder.stop()
        micStartTime = nil
        resetMicRecoveryLadder()

        backend?.stop()
        backend = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        writer = nil

        closeBackendLog()
        closeTranscriptEventsLog()
        stopBackendAccess()

        rollBackFailedMeetingMetadata(for: session, wasResume: wasResume, priorMetadata: priorMetadata)

        clearAttachments()
        currentSession = nil
    }

    /// Undoes whatever createInitialMeetingMetadata/appendResumeSessionMetadata
    /// wrote to meeting.json before the failure - both run early in the do
    /// block, well before any of the throwing steps that follow, so by the
    /// time a start attempt lands in the catch the on-disk status may already
    /// be the mid-write `.recording` value with nothing to ever flip it back.
    /// Left alone, that permanently disables Resume and rediarize for the
    /// folder (both gate on `status == .recording` in MeetingViewer) until
    /// someone hand-edits the file (2026-07 gate finding). Every write here is
    /// `try?` and safe to call even when the corresponding metadata write
    /// never actually happened - idempotent against the "threw before
    /// touching meeting.json" case.
    private func rollBackFailedMeetingMetadata(
        for session: MeetingSession,
        wasResume: Bool,
        priorMetadata: MeetingMetadata?
    ) {
        if wasResume {
            // appendResumeSessionMetadata (if it got that far) flipped status
            // to .recording and appended a new, now-phantom session entry.
            // Restore exactly what was on disk before this attempt touched
            // it - the meeting must be exactly as resumable/rediarizable as
            // it was before Resume was tapped.
            guard let priorMetadata else { return }
            try? writeMeetingMetadata(priorMetadata, to: session.folderURL)
            return
        }
        // Fresh start: there was no prior metadata to restore. If
        // createInitialMeetingMetadata got far enough to write status =
        // .recording, mark it .completed instead - an empty/failed meeting,
        // but no longer bricked. If the write never happened, there's
        // nothing to fix here (buildMeetingHistoryItem's legacy fallback
        // already defaults a folder with no meeting.json to .completed).
        guard var metadata = try? readMeetingMetadata(from: session.folderURL) else { return }
        guard metadata.status == .recording else { return }
        metadata.status = .completed
        metadata.updatedAt = Date()
        try? writeMeetingMetadata(metadata, to: session.folderURL)
    }

    func stopMeeting() async {
        guard isCapturing else { return }

        isFinalizing = true
        cancelMicStartupHealthCheck()
        stopMicFramesWatchdog()
        micEngineBoundDeviceID = 0
        micEngineUsesCaptureSession = false

        // Drain any in-flight/queued mic lifecycle op before reading micEngine
        // below. Without this, a suspended restart (which already nilled
        // micEngine and is awaiting a new engine's start) can complete AFTER
        // this function has already read micEngine as nil, skipped the stop,
        // and torn down - then assign a live engine into a meeting that has
        // already ended (orphan engine holding the mic). isFinalizing (set
        // above) makes any newly-queued op a no-op, and the belt-and-braces
        // check in startMeetingMicEngine stops an already-in-flight start's
        // engine instead of assigning it once this awaits through.
        await micLifecycleTask?.value

        screenshotScheduler.stop()
        await captureEngine.stopCapture()
        if let engine = micEngine {
            await engine.stop()
        }
        micEngine = nil
        micEngineStartedAt = nil
        await micAudioForwarder.stop()
        micStartTime = nil
        resetMicRecoveryLadder()

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
            // Ordered after any writes still queued on the writer's own
            // serial queue - see BackendLogWriter.close's doc comment for
            // why this must not be a bare `handle.close()` here.
            backendLogWriter.close()
            stopBackendAccess(for: backendAccessURL)
            isFinalizing = false
            // The home-level preview was blocked from (re)starting while
            // isFinalizing (see startHomeLevelPreviewNow's guard, item 4) -
            // if the user is still sitting on the start screen, kick it back
            // on now rather than leaving it dead until they navigate away
            // and back or hit Refresh.
            if isStartScreenActive, !isCapturing {
                Task { await self.startHomeLevelPreview() }
            }
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
        backendLogWriter.synchronize(label: "backend log")

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

    /// Single entry point for renaming a meeting on disk. Trims/validates the
    /// title, writes it to meeting.json, then updates every in-memory mirror
    /// that applies (meetingHistory row, the active .viewing screen, and the
    /// live session/meetingTitle if this is the current recording). Throws
    /// on validation or I/O failure instead of swallowing it, so callers can
    /// revert their optimistic UI and show the user what went wrong.
    @discardableResult
    func renameMeeting(folderURL: URL, to newTitle: String) throws -> String {
        let trimmed: String
        do {
            trimmed = try MeetingRenamer.rename(folderURL: folderURL, to: newTitle)
        } catch {
            appendBackendLog("Failed to rename meeting at \(folderURL.lastPathComponent): \(error.localizedDescription)", toTail: true)
            throw error
        }

        if let idx = meetingHistory.firstIndex(where: { $0.folderURL == folderURL }) {
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
            if case .viewing(let current) = activeScreen, current.id == existing.id {
                activeScreen = .viewing(updatedItem)
            }
        }

        if let session = currentSession, session.folderURL == folderURL {
            currentSession = MeetingSession(title: trimmed, folderURL: session.folderURL, startedAt: session.startedAt)
            meetingTitle = trimmed
        }

        return trimmed
    }

    @discardableResult
    func renameMeeting(_ item: MeetingHistoryItem, to newTitle: String) throws -> String {
        try renameMeeting(folderURL: item.folderURL, to: newTitle)
    }

    @discardableResult
    func renameCurrentMeeting(to newTitle: String) throws -> String {
        guard let session = currentSession else { throw MeetingRenameError.noActiveSession }
        return try renameMeeting(folderURL: session.folderURL, to: newTitle)
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

    /// Finalizes any meeting left at `status: recording` with no live
    /// session - i.e. the app crashed or was force-quit mid-meeting (see
    /// engineer-notes/incident-2026-07-06-mainthread-livelock.md, where a
    /// 54-minute main-thread livelock led to a SIGKILL and the meeting was
    /// never finalized despite the audio underneath being completely
    /// healthy). Called from `init()`, before any meeting could possibly be
    /// live in THIS process, so a `.recording` `meeting.json` found here is
    /// unconditionally orphaned. Resume stays disabled for the recovered
    /// meeting - it's `.completed` now, which is the point: the recording is
    /// over and its audio should be usable in-app (viewer, rediarize,
    /// export) rather than permanently locked out.
    private func recoverOrphanedMeetingsIfNeeded() {
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
            guard let metadata = try? readMeetingMetadata(from: folderURL),
                  OrphanedMeetingRecovery.needsRecovery(metadata) else { continue }

            let wavDuration = wavDurationSeconds(for: folderURL, metadata: metadata)
            let fallbackEnd = latestModificationDate(for: folderURL) ?? metadata.updatedAt
            let fallbackDuration = max(0, fallbackEnd.timeIntervalSince(metadata.createdAt))
            let recovered = OrphanedMeetingRecovery.finalize(
                metadata,
                wavDurationSeconds: wavDuration,
                fallbackDurationSeconds: fallbackDuration,
                now: Date()
            )
            do {
                try writeMeetingMetadata(recovered, to: folderURL)
                appendBackendLog(
                    "Recovered orphaned meeting '\(recovered.title)' left mid-recording (likely a crash or " +
                    "force-quit) - marked completed, duration=\(String(format: "%.1f", recovered.durationSeconds))s.",
                    toTail: true
                )
            } catch {
                appendBackendLog(
                    "Failed to recover orphaned meeting \(folderURL.lastPathComponent): \(error.localizedDescription)",
                    toTail: true
                )
            }
        }
    }

    /// The longer of the mic/system wav durations, read via `AVAudioFile` -
    /// `nil` if neither wav exists or is readable, so the caller can fall
    /// back to an mtime-based estimate.
    private func wavDurationSeconds(for folderURL: URL, metadata: MeetingMetadata) -> Double? {
        let audioFolderName = metadata.sessions.last?.audioFolder ?? findAudioFolderName(in: folderURL) ?? "audio"
        let audioDir = folderURL.appendingPathComponent(audioFolderName, isDirectory: true)
        var longest: Double?
        for name in ["mic.wav", "system.wav"] {
            let url = audioDir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let file = try? AVAudioFile(forReading: url),
                  file.fileFormat.sampleRate > 0 else { continue }
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            guard seconds.isFinite else { continue }
            longest = max(longest ?? 0, seconds)
        }
        return longest
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
