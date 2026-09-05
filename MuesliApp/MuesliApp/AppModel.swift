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
    private var meetingSavePublication = MeetingSavePublicationGate()
    @Published private var meetingSaveNotices: [String: String] = [:]
    var meetingSaveNotice: String? {
        meetingSaveNotices.isEmpty ? nil : meetingSaveNotices.keys.sorted().compactMap { meetingSaveNotices[$0] }.joined(separator: "\n")
    }
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
            micHealth.resetRecoveryBudget()
            previewMicHealth.resetRecoveryBudget()
            if isCapturing {
                enqueueMicLifecycle("aec-change") { await $0.restartMeetingMicEngineForInputSwitch() }
            } else if isStartScreenActive {
                previewVoiceProcessingDowngraded = false
                enqueueMicLifecycle("aec-change-preview") { await $0.restartPreviewMicEngineForInputSwitch() }
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
    @Published private var attachmentNotices: [String: String] = [:]
    private var attachmentNoticeOwners: [String: UUID] = [:]
    private var attachmentEditID: UUID?
    var attachmentNotice: String? { currentSession.flatMap { attachmentNotices[$0.folderURL.path] } }

    private let captureEngine = CaptureEngine()
    // `any MicCapturing` rather than `MicEngine?`: this can hold either the
    // AVAudioEngine-backed MicEngine or CaptureSessionMicEngine, chosen per
    // start by `makeMicEngine` (see shouldUseCaptureSessionEngine).
    private var micEngine: (any MicCapturing)?
    private var previewMicEngine: (any MicCapturing)?
    private var isPreviewCaptureRunning = false
    private var previewLifecycleTask: Task<Void, Never>?
    private var pendingPreviewOperation: (@MainActor (AppModel) async -> Void)?
    // Single serializer for ALL mic engine start/stop/restart operations so two
    // device events can't interleave at an await suspension and orphan the engine
    // (audit D2/D8). Plus a monotonic generation token as belt-and-braces against
    // any stray start completing into a superseded generation.
    private var micLifecycleTask: Task<Void, Never>?
    private var pendingMicOperation: (@MainActor (AppModel) async -> Void)?
    private var pendingMicReason = ""
    private let micOperationOwner = CaptureOperationOwner()
    private var micHealth = CaptureSourceHealth()
    private var previewMicHealth = CaptureSourceHealth()
    private var previewMicForwarder: MicAudioForwarder?
    private var previewVoiceProcessingDowngraded = false
    private var previewVoiceProcessingRequested = false
    private var systemRecoveryPending = false
    private var observedMicProblems = 0
    private var observedPreviewMicProblems = 0
    private var lastRetiredMicIngress: MicAudioIngress.Snapshot?
    private var lastRetiredPreviewMicIngress: MicAudioIngress.Snapshot?
    private var lastResolvedInputConfiguration: String?
    private var lastObservedOutputDeviceID: UInt32?
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
    private var micAudioIngress: MicAudioIngress?
    private var previewMicAudioIngress: MicAudioIngress?
    private var previewMicGeneration = 0
    private let micAudioForwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
    // Owns backend.log file writes + the copy-debug ring buffer off
    // MainActor. The writer explicitly opts out of default MainActor
    // isolation and confines its mutable state to its own serial queue.
    private nonisolated let backendLogWriter = BackendLogWriter(ringBufferLimit: 200)
    // Detects (and logs) a wedged main thread from entirely off-main code -
    // see its doc comment (2026-07-06 livelock fix, item 2). Assigned in
    // init() since it depends on `backendLogWriter`.
    private let mainActorStarvationWatchdog: MainActorStarvationWatchdog

    private var backend: BackendProcess?
    private var writer: FramedWriter?
    private var sourceRecorder: LocalAudioRecorder?
    private var currentMeetingAccess: MeetingFileAccess?
    private let meetingStartPreparation = MeetingStartPreparationOwner()
    private var sourceTimeline: CaptureTimeline?
    private var sessionArtifactStore: SessionArtifactStore?
    private var isPreparingResume = false
    private var inferenceFailure: String?
    // Backend-readiness handshake state (2026-07-16 RCA rec #3 - backend
    // wedged pre-read-loop, meeting presented as recording, 26 minutes lost).
    // The gate opens when the child acknowledges MSG_MEETING_START with a
    // meeting_started status; until then no audio is forwarded to the pipe
    // (mic buffers in MicAudioForwarder's pending ring, system audio in
    // CaptureEngine's) and the meeting is not presented as recording.
    private let backendStartupGate = BackendStartupGate()
    private let backendAdmission = BackendAdmissionOwner()
    private let batchRediarizer = BatchRediarizer()
    // 10s: the pre-read-loop cost is the module import chain (numpy/
    // soundfile/parakeet_mlx pulling in MLX/Metal), a few seconds on a cold
    // start - and most of it overlaps the capture/mic startup that runs
    // between spawn and the handshake wait. 10s is a comfortable multiple of
    // the worst healthy start while still turning the incident's silent
    // 26-minute loss into a ~10-second visible failure.
    private let backendReadinessTimeoutSeconds: Double = 10.0
    // Backpressure detector state (2026-07-16 RCA rec #2): flips when the
    // FramedWriter's queue has work but writes stop completing (backend
    // alive-but-not-reading; a blocked pipe write never throws, so
    // onWriteError can't see this). Checked each frames-watchdog tick.
    private var backendWriteStalled = false
    private var backendStallLogTicks = 0
    private var backendLogHandle: FileHandle?
    private var backendLogURL: URL?
    private var transcriptEventsURL: URL?
    private var currentTranscriptEventsStartOffset: UInt64 = 0
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
    @Published private var metadataEditNotices: [String: String] = [:]
    private var metadataEditNoticeOwners: [String: UUID] = [:]
    @Published private var catalogNotice: String?
    private var pendingDeletes: [String: UUID] = [:]
    var metadataEditNotice: String? {
        let notices = metadataEditNotices.keys.sorted().compactMap { metadataEditNotices[$0] } + attachmentNotices.keys.sorted().compactMap { attachmentNotices[$0] } + [catalogNotice].compactMap { $0 }
        return notices.isEmpty ? nil : notices.joined(separator: "\n")
    }
    private lazy var metadataEdits = MeetingMetadataEdits { [weak self] event in
        self?.publishMetadataEdit(event)
    }
    private lazy var meetingCatalog = MeetingCatalogController { [weak self] event in
        guard let self else { return }
        switch event {
        case .committed(let snapshot):
            let unresolved = Set(snapshot.unresolved.map { $0.standardizedFileURL.path })
            let retained = self.meetingHistory.filter { unresolved.contains($0.folderURL.standardizedFileURL.path) }
            self.meetingHistory = (snapshot.items + retained).sorted { $0.createdAt > $1.createdAt }
            self.catalogNotice = snapshot.problems.isEmpty ? nil : "Some meetings could not be read. Their files are preserved. " + snapshot.problems.joined(separator: "\n")
        case .discarded:
            self.catalogNotice = nil
        case .pending:
            self.catalogNotice = "Meeting history is still being read. The original disk operation remains active."
        case .failed(let message):
            self.catalogNotice = "Meeting history could not be read: \(message)"
        }
    }

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
            logWriter: backendLogWriter
        )

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

        // Sample UI context only when the watchdog's one outstanding echo
        // executes. A stall report uses the last successful sample and its age.
        mainActorStarvationWatchdog.setContextProvider { [weak self] in
            guard let self else { return nil }
            return MainActorStarvationWatchdog.Context(
                activeScreen: String(describing: self.activeScreen),
                transcriptRows: self.transcriptModel.segments.count,
                historyCount: self.meetingHistory.count,
                meterPublishCount: self.meters.publishCount
            )
        }
        mainActorStarvationWatchdog.start()

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
                if let self, !self.isCapturing { self.isPreviewCaptureRunning = false }
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
    private var diagnosticSourceID: String?
    private var diagnosticRuntimeIdentity: ObservedRuntimeIdentity?
    var debugSummary: String {
        BuildDiagnostic.summary(runtime: diagnosticRuntimeIdentity, counters: [
            "system_buffers": debugSystemBuffers, "system_frames": debugSystemFrames,
            "system_errors": debugAudioErrors, "mic_buffers": debugMicBuffers,
            "mic_frames": debugMicFrames, "mic_errors": debugMicErrors
        ], sandboxed: isSandboxed)
    }

    /// Checks the file's POSIX mode bits directly. `FileManager.isExecutableFile`
    /// (access(2) with X_OK) is sandbox-filtered and returns false for files under a
    /// security-scoped user-selected folder even though spawning them works fine.
    static func hasExecutePermissionBits(atPath path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attrs[.posixPermissions] as? NSNumber else {
            return false
        }
        return permissions.uint16Value & 0o111 != 0
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
        if FileManager.default.fileExists(atPath: pythonPath) {
            if Self.hasExecutePermissionBits(atPath: pythonPath) {
                backendFolderError = nil
            } else {
                backendFolderError = "Backend venv python is not executable. Recreate it with /opt/homebrew/bin/python3.12 -m venv --copies .venv and install deps with pip."
            }
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

    private func closeBackendLog() {
        backendLogWriter.close()
        backendLogHandle = nil
    }

    private func closeTranscriptEventsLog() {
        transcriptEventsURL = nil
        currentTranscriptEventsStartOffset = 0
    }

    private func closeHandle(_ handle: FileHandle?) {
        if let handle { backendLogWriter.close(handle: handle) }
    }

    /// The actual file write + ring-buffer append happen on
    /// `backendLogWriter`'s own queue, off MainActor (2026-07-06 livelock
    /// fix, item 5) - this call itself is fire-and-forget from here.
    private func appendBackendLog(_ line: String, toTail: Bool, handle: FileHandle? = nil) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        backendLogWriter.append(trimmed, toTail: toTail, handle: handle)
    }

    private func reportInferenceFailure(_ message: String) {
        inferenceFailure = message
        shareableContentError = "Live transcription unavailable. Audio is being saved locally. " + message
        appendBackendLog(shareableContentError ?? message, toTail: true)
        meters.setBackendAlert( "Live transcription unavailable; source audio continues recording.")
    }

    private func handleBackendWriteError(_ error: Error) {
        guard sourceRecorder != nil else { return }
        reportInferenceFailure(error.localizedDescription)
    }

    private func handleBackendJSONLine(
        _ line: String,
        backendLogHandle: FileHandle?,
        ingestIntoLiveTranscript: Bool,
        sessionFolderURL: URL? = nil
    ) {
        // Authoritative data is already journaled by the reader. UI
        // consumption is a disposable projection and never owns its file.
        if let data = line.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = obj["type"] as? String {
            if type == "runtime_identity", let sessionFolderURL,
               currentSession?.folderURL == sessionFolderURL,
               let sourceID = diagnosticSourceID {
                diagnosticRuntimeIdentity = ObservedRuntimeIdentity.event(line, sourceSessionID: sourceID)
            } else if type == "error" {
                let message = (obj["message"] as? String) ?? line
                appendBackendLog("[error] \(message)", toTail: ingestIntoLiveTranscript, handle: backendLogHandle)
            } else if type == "status" {
                // The readiness handshake's other half (2026-07-16 RCA rec
                // #3): the backend emits meeting_started immediately after
                // opening its stream writers in response to MSG_MEETING_START
                // - the proof that the child's read loop is alive and the
                // WAV/PCM files exist. Gated on the session folder so a
                // late line from a previous meeting's stdout task can never
                // open a new meeting's gate. NB this must NOT be gated on
                // ingestIntoLiveTranscript: that flag requires isCapturing,
                // which is deliberately still false while startMeeting waits
                // on this very acknowledgment.
                if (obj["message"] as? String) == "meeting_started",
                   let sessionFolderURL,
                   currentSession?.folderURL == sessionFolderURL {
                    backendStartupGate.markReady()
                }
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
        guard !micHealth.invalidated else { return }
        _ = micHealth.progress(frames: result.totalFrameCount, generation: generation)
        debugMicErrorMessage = "-"
        publishMicError()

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
        debugMicBuffers = result.totalFrameCount
        debugMicFrames = result.frameSampleCount
        debugMicPTS = result.elapsedSeconds
        // Liveness signals for UI/logging convenience. The frames watchdog's
        // actual STALL DETECTION reads `micAudioForwarder.snapshot()`
        // directly instead (ground truth, updated even when this MainActor
        // hop is delayed) - see `startMicFramesWatchdog`.
        lastMicAudioAt = Date()
        micFrameCount = result.totalFrameCount
        debugMicFormat = "s16le sr=\(micOutputSampleRate) ch=\(micOutputChannels)"
        publishMicMeters()
    }

    private func handlePreviewMicAudio(_ result: MicAudioForwarder.DeliveryResult) {
        guard !previewMicHealth.invalidated else { return }
        _ = previewMicHealth.progress(frames: result.totalFrameCount, generation: previewMicGeneration)
        debugMicErrorMessage = "-"
        publishMicError()
        meters.clearMicAlert()
        micLevel = result.level
        publishMicMeters()
    }

    private var isStartScreenActive: Bool {
        if case .start = activeScreen { return true }
        return false
    }

    private var wantsHomeLevelPreview: Bool {
        CapturePreviewPolicy.wantsPreview(isCapturing: isCapturing, isStarting: isStartingMeeting,
                                         isFinalizing: isFinalizing, isStartScreenActive: isStartScreenActive,
                                         onboarding: shouldShowOnboarding)
    }

    private func runPreviewLifecycleOperation(
        _ operation: @escaping @MainActor (AppModel) async -> Void
    ) async {
        pendingPreviewOperation = operation
        if previewLifecycleTask == nil {
            previewLifecycleTask = Task { @MainActor [weak self] in
                guard let self else { return }
                while let operation = pendingPreviewOperation {
                    pendingPreviewOperation = nil
                    // Meeting start/stop/navigation wins over a delayed start
                    // notification that replaced a pending preview teardown.
                    if wantsHomeLevelPreview { await operation(self) }
                    else { await stopHomeLevelPreviewNow() }
                }
                previewLifecycleTask = nil
            }
        }
        await previewLifecycleTask?.value
    }

    /// One worker resolves the latest desired microphone route after each
    /// native operation. Bursts replace pending intent instead of accumulating
    /// one Task per notification. Do not call recursively from its operation.

    private func enqueueMicLifecycle(_ reason: String, _ op: @escaping @MainActor (AppModel) async -> Void) {
        pendingMicOperation = op
        pendingMicReason = reason
        guard micLifecycleTask == nil else { return }
        micLifecycleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while let operation = pendingMicOperation {
                let reason = pendingMicReason
                pendingMicOperation = nil
                AudioLog.event("lifecycle.run", ["reason": reason])
                await operation(self)
            }
            micRecoveryPending = false
            micLifecycleTask = nil
        }
    }

    private func invalidateMicrophone(generation: Int, preview: Bool) {
        if preview {
            guard generation == previewMicGeneration, previewMicHealth.invalidate(generation: generation) else { return }
            enqueueMicLifecycle("preview-configuration-invalidated") { await $0.restartPreviewMicEngineForInputSwitch() }
        } else {
            guard generation == micEngineGeneration, micHealth.invalidate(generation: generation) else { return }
            enqueueMicLifecycle("configuration-invalidated") { await $0.restartMeetingMicEngineForInputSwitch() }
        }
    }

    private func startNativeMicrophone(_ engine: any MicCapturing, ingress: MicAudioIngress,
                                      generation: Int, voiceProcessing: Bool, resolvedID: UInt32,
                                      pinned: Bool, preview: Bool) async throws {
        let access = preview ? nil : currentMeetingAccess
        let problem = ingress.problemCallback()
        let invalidation = CaptureInvalidationMailbox(onInvalidated: {
            problem(.unknown(generation: generation, message: "The native microphone configuration was invalidated."))
        }) { [weak self] in
            self?.invalidateMicrophone(generation: generation, preview: preview)
        }
        let changed = invalidation.callback()
        try await micOperationOwner.perform(onFailure: { error in
            problem(.unknown(generation: generation, message: "Microphone start failed: \(error.localizedDescription)"))
        }, operation: {
            defer { withExtendedLifetime(access) {} }
            try await engine.start(generation: generation, enableVoiceProcessing: voiceProcessing,
                                   preferredInputDeviceID: resolvedID == 0 ? nil : resolvedID,
                                   pinned: pinned, onConfigurationChange: changed,
                                   onCaptureProblem: ingress.problemCallback(), onAudioData: ingress.callback())
        }, cleanupIfAbandoned: {
            defer { withExtendedLifetime(access) {} }
            await engine.stop()
            await ingress.finish()
        })
    }

    @discardableResult
    private func stopNativeMicrophone(_ engine: any MicCapturing, ingress: MicAudioIngress?, preview: Bool) async -> Bool {
        let access = preview ? nil : currentMeetingAccess
        let generation = preview ? previewMicGeneration : micEngineGeneration
        let problem = ingress?.problemCallback()
        do {
            try await micOperationOwner.perform(onFailure: { error in
                problem?(.unknown(generation: generation, message: "Microphone stop failed: \(error.localizedDescription)"))
            }) {
                defer { withExtendedLifetime(access) {} }
                await engine.stop()
                await ingress?.finish()
            }
            return true
        } catch {
            if let failure = error as? CaptureOperationOwner.Failure, case .busy = failure { return false }
            let message = error.localizedDescription
            if preview { previewMicHealth.fail(message, quarantined: true) }
            else { micHealth.fail(message, quarantined: true) }
            meters.setMicAlert(message)
            return false
        }
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
        micHealth.resetRecoveryBudget()
        previewMicHealth.resetRecoveryBudget()
        loadOutputDevices()
        // An output change is a fresh chance for VPIO; let the engine re-evaluate.
        if isCapturing {
            micVoiceProcessingDowngraded = false
            enqueueMicLifecycle("output-pick") { await $0.restartMeetingMicEngineForInputSwitch() }
        } else if isStartScreenActive {
            previewVoiceProcessingDowngraded = false
            enqueueMicLifecycle("output-pick-preview") { await $0.restartPreviewMicEngineForInputSwitch() }
        }
    }

    /// Apply an input policy change: re-resolve + (if capturing) restart the
    /// meeting engine when the device actually differs, else refresh the preview.
    private func applyInputSelectionChange() {
        micHealth.resetRecoveryBudget()
        previewMicHealth.resetRecoveryBudget()
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
        startMicFramesWatchdog()
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
            if let display = selectedDisplay ?? displays.first {
            let audioFilter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            do {
                try await captureEngine.startCapture(contentFilter: audioFilter, writer: nil, recordTo: nil)
                guard wantsHomeLevelPreview else {
                    if captureEngine.isPreviewSource { _ = await captureEngine.stopCapture() }
                    isPreviewCaptureRunning = false
                    isPreviewingLevels = false
                    return
                }
                await captureEngine.setAudioOutputEnabled(false)
                isPreviewCaptureRunning = true
            } catch {
                shareableContentError = "Failed to start system audio preview: \(error.localizedDescription)"
            }
            } else {
                shareableContentError = "System audio preview needs an available display."
            }
        }

        guard wantsHomeLevelPreview else { await stopHomeLevelPreviewNow(); return }
        if previewMicEngine == nil, micOperationOwner.isBusy {
            previewMicHealth.fail("The previous microphone operation is still owned by macOS.", quarantined: true)
        }
        if previewMicEngine == nil, previewMicHealth.phase != .failed, !micOperationOwner.isBusy {
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
        previewMicGeneration += 1
        let generation = previewMicGeneration
        let forwarder = MicAudioForwarder(sampleRate: 16000, channels: 1)
        previewMicForwarder = forwarder
        previewMicHealth.begin(generation: generation)
        previewVoiceProcessingRequested = !usesCaptureSession && shouldEnableVoiceProcessing() && !previewVoiceProcessingDowngraded
        await forwarder.beginMeeting()
        await forwarder.beginGeneration(generation, writer: nil)
        let display = MicDeliveryDisplayMailbox { [weak self] result in
            guard let self, self.previewMicGeneration == generation, self.isStartScreenActive else { return }
            self.handlePreviewMicAudio(result)
        }
        observedPreviewMicProblems = 0
        let ingress = MicAudioIngress.forwarding(to: forwarder, display: display,
                                               onProblem: await forwarder.captureFailureHandler())
        previewMicAudioIngress = ingress
        do {
            try await startNativeMicrophone(engine, ingress: ingress, generation: generation,
                                            voiceProcessing: previewVoiceProcessingRequested,
                                            resolvedID: resolvedID, pinned: pinned, preview: true)
        } catch {
            await previewMicAudioIngress?.finish()
            lastRetiredPreviewMicIngress = previewMicAudioIngress?.snapshot() ?? lastRetiredPreviewMicIngress
            previewMicAudioIngress = nil
            previewMicGeneration += 1
            previewMicEngine = nil
            throw error
        }

        guard wantsHomeLevelPreview else {
            guard await stopNativeMicrophone(engine, ingress: previewMicAudioIngress, preview: true) else { return }
            await previewMicAudioIngress?.finish()
            lastRetiredPreviewMicIngress = previewMicAudioIngress?.snapshot() ?? lastRetiredPreviewMicIngress
            previewMicAudioIngress = nil
            previewMicGeneration += 1
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
        if previewVoiceProcessingRequested && !previewVoiceProcessingDowngraded && !(error is CaptureOperationOwner.Failure) {
            previewVoiceProcessingDowngraded = true
        }
        previewMicHealth.fail(error.localizedDescription, retryable: micPermission == .authorised,
                              quarantined: error is CaptureOperationOwner.Failure)
        meters.setMicAlert(previewMicHealth.message ?? "Microphone unavailable")
        publishMicError()
    }

    private func stopHomeLevelPreviewNow() async {
        if let engine = previewMicEngine,
           await stopNativeMicrophone(engine, ingress: previewMicAudioIngress, preview: true) {
            await previewMicAudioIngress?.finish()
            lastRetiredPreviewMicIngress = previewMicAudioIngress?.snapshot() ?? lastRetiredPreviewMicIngress
            previewMicAudioIngress = nil
            previewMicForwarder = nil
            previewMicGeneration += 1
            previewMicEngine = nil
            previewMicEngineBoundDeviceID = 0
            previewMicEngineUsesCaptureSession = false
        }

        if isCapturing {
            if captureEngine.isPreviewSource { _ = await captureEngine.stopCapture() }
            isPreviewCaptureRunning = false
            isPreviewingLevels = false
            return
        }

        // Source identity protects a recording started while preview teardown awaited macOS.
        if captureEngine.isPreviewSource { _ = await captureEngine.stopCapture() }
        isPreviewCaptureRunning = false

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
        startMicFramesWatchdog()
        guard transcribeMic else {
            micEngine = nil
            micEngineStartedAt = nil
            await micAudioIngress?.finish()
            lastRetiredMicIngress = micAudioIngress?.snapshot() ?? lastRetiredMicIngress
            micAudioIngress = nil
            await micAudioForwarder.stop()
            cancelMicStartupHealthCheck()
            return
        }

        guard !micOperationOwner.isBusy else {
            micHealth.fail("The previous microphone operation is still owned by macOS.", quarantined: true)
            sourceRecorder?.reportFailure(stream: .mic, message: "The requested microphone could not start while a previous operation was still running.")
            return
        }
        guard micHealth.phase != .failed else {
            sourceRecorder?.reportFailure(stream: .mic, message: micHealth.message ?? "The requested microphone is unavailable.")
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
            micEngineGeneration += 1
            let fallbackGeneration = micEngineGeneration
            do {
                try await attemptMeetingMicEngineStart(
                    usesCaptureSession: false, resolvedID: resolvedID, pinned: pinned, generation: fallbackGeneration
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
        await micAudioIngress?.finish()
        await micAudioForwarder.beginGeneration(generation, writer: sourceRecorder, outputEnabled: sourceRecorder != nil)
        let display = MicDeliveryDisplayMailbox { [weak self] result in
            self?.onMicAudioDelivered(result, generation: generation)
        }
        observedMicProblems = 0
        let reportProblem = await micAudioForwarder.captureFailureHandler()
        let recorder = sourceRecorder
        let timeline = sourceTimeline
        let ingress = MicAudioIngress.forwarding(to: micAudioForwarder, display: display, onRejected: { packet, reason in
            guard let timeline else { return }
            recorder?.reportLoss(stream: .mic, ptsUs: timeline.relativeMicroseconds(packet.captureTimeUs),
                                 frames: Int64(packet.outputFrameCount), reason: reason.rawValue)
        }, onProblem: reportProblem)
        micAudioIngress = ingress

        micHealth.begin(generation: generation)
        try await startNativeMicrophone(engine, ingress: ingress, generation: generation,
                                        voiceProcessing: enableVPIO, resolvedID: resolvedID, pinned: pinned, preview: false)
        // Serialization should prevent overlap, but bail if a newer start
        // superseded this one before it completed (audit D2 belt-and-braces).
        guard generation == micEngineGeneration else {
            AudioLog.event("engine.start.superseded", ["gen": generation, "current": micEngineGeneration])
            _ = await stopNativeMicrophone(engine, ingress: ingress, preview: false)
            return
        }
        // A stop() that ran concurrently with this start (e.g. a recovery
        // rebuild in flight when the user hit Stop) must not have this
        // start assign a live engine after the meeting has ended - stop
        // what we just started and leave micEngine untouched instead.
        guard !isFinalizing else {
            AudioLog.event("engine.start.superseded-by-stop", ["gen": generation])
            _ = await stopNativeMicrophone(engine, ingress: ingress, preview: false)
            return
        }
        micEngine = engine
        micEngineStartedAt = Date()
        // Only open the pipe once the backend has acknowledged
        // MSG_MEETING_START (2026-07-16 RCA §9 startup-ordering defect: mic
        // forwarding used to be enabled here unconditionally, before
        // meeting_start was even sent, so frames could reach a backend whose
        // writers didn't exist - and, in the incident, pile into a pipe
        // nobody read). At FIRST start the gate is still closed: frames
        // buffer in the forwarder's pending ring and startMeeting flushes
        // them via setOutputEnabled(true) the moment meeting_started
        // arrives. On mid-meeting engine rebuilds the gate is already open,
        // so this enables immediately - exactly the old timing.
        if sourceRecorder != nil {
            await micAudioForwarder.setOutputEnabled(true)
        }
        if isCapturing {
            scheduleMicStartupHealthCheck()
        }
    }

    private func handleMeetingMicEngineStartFailure(_ error: Error) async {
        // A VPIO-format failure is not a hard failure: downgrade to plain
        // capture once and restart rather than leaving the mic dead.
        if micVoiceProcessingRequested, !micVoiceProcessingDowngraded,
           !(error is CaptureOperationOwner.Failure), micPermission == .authorised {
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
        await micAudioIngress?.finish()
        lastRetiredMicIngress = micAudioIngress?.snapshot() ?? lastRetiredMicIngress
        micAudioIngress = nil
        await micAudioForwarder.stop()
        cancelMicStartupHealthCheck()
        debugMicErrors += 1
        debugMicErrorMessage = "mic_start_failed: \(error.localizedDescription)"
        publishMicError()
        // The red debugMicErrorMessage line takes precedence in SessionView,
        // but a stale "reconnecting..." alert must not be left to resurface
        // after a later successful start, before the first frame arrives.
        micHealth.fail(error.localizedDescription, retryable: micPermission == .authorised,
                       quarantined: error is CaptureOperationOwner.Failure)
        meters.setMicAlert(micHealth.message ?? "Microphone unavailable")
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
            guard await stopNativeMicrophone(engine, ingress: micAudioIngress, preview: false) else { return }
            micEngine = nil
        }
        micEngineBoundDeviceID = 0
        micEngineUsesCaptureSession = false
        micEngineStartedAt = nil

        // The upcoming startMeetingMicEngine() call re-arms the forwarder
        // for a fresh generation (see beginGeneration), but stop it
        // explicitly here too so forwarding halts the instant the engine
        // does, rather than lingering until the new generation is armed.
        await micAudioIngress?.finish()
        lastRetiredMicIngress = micAudioIngress?.snapshot() ?? lastRetiredMicIngress
        micAudioIngress = nil
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
                guard await model.stopNativeMicrophone(engine, ingress: model.previewMicAudioIngress, preview: true) else { return }
                await model.previewMicAudioIngress?.finish()
                model.lastRetiredPreviewMicIngress = model.previewMicAudioIngress?.snapshot() ?? model.lastRetiredPreviewMicIngress
                model.previewMicAudioIngress = nil
                model.previewMicGeneration += 1
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
        guard micFramesWatchdogTask == nil else { return }
        micFramesWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                guard !isFinalizing else { continue }
                if isCapturing { checkBackendWriteBacklog() }
                let preview = !isCapturing && !isStartingMeeting && isStartScreenActive && !shouldShowOnboarding
                guard isCapturing || preview else { continue }

                let recoverSystem = captureEngine.supervise(allowRecovery: !systemRecoveryPending)
                if preview, captureEngine.health.phase == .healthy { isPreviewCaptureRunning = true }
                if recoverSystem, !systemRecoveryPending, let requestToken = captureEngine.requestToken {
                    systemRecoveryPending = true
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { systemRecoveryPending = false }
                        guard captureEngine.requestToken == requestToken else { return }
                        _ = await captureEngine.restartCapture(expectedRequest: requestToken)
                        if preview, !isCapturing, !isStartingMeeting, !isFinalizing, isStartScreenActive {
                            isPreviewCaptureRunning = captureEngine.isPreviewSource && captureEngine.hasNativeSource
                        }
                    }
                }

                if preview {
                    observeMicrophoneProblems(preview: true)
                    if previewMicHealth.phase == .quarantined, !micOperationOwner.isBusy {
                        previewMicHealth.fail("The previous microphone operation has finished.")
                    }
                    if let forwarder = previewMicForwarder {
                        let snapshot = await forwarder.snapshot()
                        if previewMicHealth.progress(frames: snapshot.frameCount, generation: snapshot.generation,
                                                      at: snapshot.lastFrameAt ?? Date()) {
                            debugMicErrorMessage = "-"
                            publishMicError()
                            meters.clearMicAlert()
                        }
                    }
                    if previewMicHealth.shouldRecover(requireContinuousCallbacks: true, canStartRecovery: !micOperationOwner.isBusy) {
                        if previewVoiceProcessingRequested { previewVoiceProcessingDowngraded = true }
                        meters.setMicAlert("Reconnecting microphone preview…")
                        enqueueMicLifecycle("preview-health-recovery") { await $0.restartPreviewMicEngineForInputSwitch() }
                    }
                    if previewMicHealth.phase == .failed { meters.setMicAlert(previewMicHealth.message ?? "Microphone preview is unavailable.") }
                } else if transcribeMic {
                    observeMicrophoneProblems(preview: false)
                    if micHealth.phase == .quarantined, !micOperationOwner.isBusy {
                        micHealth.fail("The previous microphone operation has finished.")
                    }
                    let snapshot = await micAudioForwarder.snapshot()
                    if micHealth.progress(frames: snapshot.frameCount, generation: snapshot.generation,
                                           at: snapshot.lastFrameAt ?? Date()) {
                        resetMicRecoveryLadder()
                        debugMicErrorMessage = "-"
                        publishMicError()
                    }
                    if micHealth.shouldRecover(requireContinuousCallbacks: true, canStartRecovery: !micOperationOwner.isBusy) {
                        if micVoiceProcessingRequested { micVoiceProcessingDowngraded = true }
                        meters.setMicAlert("Reconnecting microphone…")
                        enqueueMicLifecycle("meeting-health-recovery") { await $0.restartMeetingMicEngineForInputSwitch() }
                    }
                    if micHealth.phase == .failed { meters.setMicAlert(micHealth.message ?? "Microphone is unavailable.") }
                }
            }
        }
    }

    private func observeMicrophoneProblems(preview: Bool) {
        guard let snapshot = (preview ? previewMicAudioIngress : micAudioIngress)?.snapshot(),
              let problem = snapshot.latestSourceProblem else { return }
        if preview {
            guard snapshot.sourceProblemCount > observedPreviewMicProblems, problem.generation == previewMicGeneration else { return }
            observedPreviewMicProblems = snapshot.sourceProblemCount
            previewMicHealth.fail(problem.message)
        } else {
            guard snapshot.sourceProblemCount > observedMicProblems, problem.generation == micEngineGeneration else { return }
            observedMicProblems = snapshot.sourceProblemCount
            micHealth.fail(problem.message)
        }
        debugMicErrorMessage = problem.message
        publishMicError()
        meters.setMicAlert(problem.message)
    }

    private func stopMicFramesWatchdog() {
        micFramesWatchdogTask?.cancel()
        micFramesWatchdogTask = nil
        micHealth.reset()
    }

    /// The writequeue-backpressure detector (2026-07-16 RCA rec #2), run
    /// once per frames-watchdog tick. The signature it catches: the backend
    /// is alive but not reading its stdin, so the pipe fills, writes BLOCK
    /// (never throw - `onWriteError` is structurally blind to this), and in
    /// the incident 26 minutes of audio vanished behind healthy-looking
    /// meters. Mid-meeting this deliberately does NOT stop the meeting: the
    /// user may prefer to keep talking and rely on a parallel recorder, so
    /// it surfaces an unmissable persistent alert instead, and the stop path
    /// (see stopMeeting) uses the flag to bypass the drain and escalate.
    private func checkBackendWriteBacklog() {
        guard isCapturing, !isFinalizing else { return }
        if let status = sourceRecorder?.status(), let error = status.error {
            let message = "Audio preservation problem: " + error
            if shareableContentError != message {
                shareableContentError = message
                appendBackendLog(message, toTail: true)
            }
            meters.setBackendAlert(message)
        }
        guard let writer else { return }
        let snapshot = writer.backlogSnapshot()
        if snapshot.isStalled, !backendWriteStalled {
            backendWriteStalled = true
            reportInferenceFailure("The transcription process stopped consuming control messages.")
        }
    }

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
        guard isCapturing, transcribeMic, !isFinalizing else { return }
        micHealth.fail("Microphone needs recovery (\(reason)).")
        meters.setMicAlert("Reconnecting microphone…")
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
        Task { @MainActor [weak self] in _ = await self?.refreshMicrophonesAwaitingCompletion() }
    }

    func refreshMicrophonesAwaitingCompletion() async -> AudioRefreshResult {
        AudioLog.event("user.refresh", ["snap": AudioDeviceManager.snapshot()])
        loadInputDevices()
        loadOutputDevices()
        guard !isFinalizing, !isStartingMeeting else { return AudioRefreshResult(microphone: .failed, system: .failed) }
        let preview = !isCapturing && isStartScreenActive
        if preview {
            observeMicrophoneProblems(preview: true)
            previewMicHealth.observeExpectedProgress()
        } else if transcribeMic {
            observeMicrophoneProblems(preview: false)
            micHealth.observeExpectedProgress()
        }
        _ = captureEngine.supervise(allowRecovery: false)
        if preview {
            previewMicHealth.resetRecoveryBudget()
            previewVoiceProcessingDowngraded = false
            captureEngine.resetRecoveryBudget()
            await refreshHomeLevelPreview()
        } else if isCapturing {
            if transcribeMic, micHealth.phase != .healthy {
                micHealth.resetRecoveryBudget()
                micVoiceProcessingDowngraded = false
                enqueueMicLifecycle("user-refresh-microphone") { await $0.restartMeetingMicEngineForInputSwitch() }
            }
            if captureEngine.health.phase != .healthy {
                captureEngine.resetRecoveryBudget()
                _ = await captureEngine.restartCapture()
            }
            await micLifecycleTask?.value
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            let microphone = preview ? previewMicHealth.phase : micHealth.phase
            _ = captureEngine.supervise(allowRecovery: false)
            if (microphone == .healthy || (!preview && !transcribeMic)), captureEngine.health.phase == .healthy { break }
            if microphone == .failed || microphone == .quarantined { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        func outcome(_ phase: CaptureSourceHealth.Phase) -> AudioRefreshResult.Outcome {
            switch phase {
            case .healthy: return .healthy
            case .failed, .quarantined: return .failed
            default: return .unverified
            }
        }
        return AudioRefreshResult(microphone: (!preview && !transcribeMic) ? .notRequested : outcome(preview ? previewMicHealth.phase : micHealth.phase),
                                  system: outcome(captureEngine.health.phase))
    }

    private func scheduleMicStartupHealthCheck() {
        cancelMicStartupHealthCheck()
        startMicFramesWatchdog()
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

        let outputID = AudioDeviceManager.defaultOutputDeviceID()
        guard outputID != lastObservedOutputDeviceID else { return }
        lastObservedOutputDeviceID = outputID
        micHealth.resetRecoveryBudget()
        previewMicHealth.resetRecoveryBudget()
        micVoiceProcessingDowngraded = false
        previewVoiceProcessingDowngraded = false
        if isCapturing, transcribeMic {
            enqueueMicLifecycle("output-change") { await $0.restartMeetingMicEngineForInputSwitch() }
        } else if isStartScreenActive {
            enqueueMicLifecycle("output-change-preview") { await $0.restartPreviewMicEngineForInputSwitch() }
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

    @Published var transcriptExportNotice: String?
    private let transcriptExportOwner = TranscriptExportOwner()
    private var transcriptExportID: UUID?

    func exportTranscriptFiles() {
        guard let session = currentSession else {
            transcriptExportNotice = "Open a saved meeting to export its transcript."
            return
        }
        presentTranscriptExport(sourceDirectory: session.folderURL, title: session.title)
    }

    private func presentTranscriptExport(sourceDirectory: URL, title: String) {
        guard transcriptExportID == nil else {
            transcriptExportNotice = "The original transcript export is still running. Its result will appear here."
            return
        }
        if currentSession?.folderURL == sourceDirectory, isCapturing || isFinalizing {
            transcriptExportNotice = "Stop and finish saving this meeting before exporting its transcript."
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export transcript folder"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "\(title)-transcript"
        panel.prompt = "Export"
        panel.message = "Create a new folder containing transcript.txt and transcript.jsonl. Existing folders are never replaced."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        beginTranscriptExport(sourceDirectory: sourceDirectory, destinationDirectory: destination)
    }

    /// The selected URLs are immutable; late completion never reads a different
    /// viewer's model. Every actual outcome is visible outside the backend log.
    private func beginTranscriptExport(sourceDirectory: URL, destinationDirectory: URL) {
        let id = UUID()
        transcriptExportID = id
        transcriptExportNotice = "Exporting the selected meeting's saved transcript…"
        do {
            let attempt = try transcriptExportOwner.start(sourceDirectory: sourceDirectory,
                destinationDirectory: destinationDirectory, onCompletion: { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.transcriptExportID == id else { return }
                        self.transcriptExportID = nil
                        switch result {
                        case .success(let receipt):
                            self.transcriptExportNotice = "Exported transcript folder “\(receipt.directory.lastPathComponent)”."
                        case .failure(let error): self.transcriptExportNotice = error.localizedDescription
                        }
                    }
                })
            Task { @MainActor [weak self] in
                let outcome = await attempt.wait(timeoutSeconds: 5)
                guard let self, self.transcriptExportID == id else { return }
                switch outcome {
                case .timedOut, .cancelled:
                    self.transcriptExportNotice = "The transcript export is still pending. Its original operation remains active; the actual result will appear here."
                case .completed: break // Only the original callback publishes once.
                }
            }
        } catch {
            transcriptExportID = nil
            transcriptExportNotice = error.localizedDescription
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

        let configuration = "\(desiredID):\(pinned):\(desiredUsesCaptureSession)"
        if lastResolvedInputConfiguration != configuration {
            lastResolvedInputConfiguration = configuration
            micHealth.resetRecoveryBudget()
            previewMicHealth.resetRecoveryBudget()
        }

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
        let willRestartPreview = !isCapturing && !isStartingMeeting && !isFinalizing
            && isStartScreenActive && !shouldShowOnboarding
            && ((previewMicEngine == nil && previewMicHealth.phase != .failed) || shouldRestartForSelection(
                desiredID: desiredID, boundID: previewMicEngineBoundDeviceID,
                desiredUsesCaptureSession: desiredUsesCaptureSession, currentUsesCaptureSession: previewMicEngineUsesCaptureSession
            ))

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
        await startMeeting(resuming: nil)
        if !isCapturing, case .start = activeScreen {
            await startHomeLevelPreview()
        }
    }

    private func startMeeting(resuming meeting: MeetingHistoryItem?) async {
        meetingCatalog.invalidate()
        guard !isStartingMeeting else { return }
        guard !meetingStartPreparation.isBusy else {
            shareableContentError = "The previous start is still preparing or closing its files. Try again after that operation returns."
            return
        }
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

        // Fresh handshake + backpressure state for this attempt (2026-07-16
        // RCA recs #2/#3). The gate MUST be closed before the mic engine can
        // start - attemptMeetingMicEngineStart checks it to decide whether
        // audio may flow to the pipe yet. Deliberately AFTER every early
        // return above (gate advisory): resetting before the `!isCapturing`
        // guard would close the gate under a still-active meeting, silently
        // re-buffering its mic forwarding on the next engine rebuild.
        backendStartupGate.reset()
        backendWriteStalled = false
        backendStallLogTicks = 0
        meters.clearBackendAlert()

        let backendProjectRoot = backendFolderURL

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

        let request = MeetingStartPreparationOwner.Request(
            title: normaliseMeetingTitle(meetingTitle),
            automaticDatePrefix: parseAutoMeetingTitle(meetingTitle) == nil ? nil : Self.meetingDatePrefix(for: Date()),
            resumeFolder: meeting?.folderURL,
            video: captureMode == .video)
        let prepared: MeetingStartPreparationOwner.Prepared
        switch await meetingStartPreparation.prepare(request, timeoutSeconds: 8) {
        case .ready(let value): prepared = value
        case .failed(let message):
            shareableContentError = "Could not prepare meeting files: \(message)"
            return
        case .timedOut:
            shareableContentError = "Preparing meeting files took too long. The original operation still owns its files; another start will wait for its cleanup."
            return
        case .cancelled:
            shareableContentError = "Meeting start was cancelled. Its file preparation will close before another start is allowed."
            return
        case .busy:
            shareableContentError = "The previous meeting preparation is still closing its files."
            return
        }
        let title = prepared.title
        let folderURL = prepared.folderURL
        let audioDir = prepared.audioDirectory
        let metadata = prepared.priorMetadata
        let timestampOffset = prepared.timestampOffset
        let sourceID = prepared.sourceID
        diagnosticSourceID = sourceID
        diagnosticRuntimeIdentity = nil
        let recorder = prepared.recorder
        let captureTimeline = prepared.timeline
        let session = MeetingSession(title: title, folderURL: folderURL, startedAt: prepared.startedAt)
        meetingTitle = title
        meetingCatalog.protect(folderURL)
        currentSession = session
        sourceRecorder = recorder
        currentMeetingAccess = prepared.access
        sessionArtifactStore = prepared.artifacts
        sourceTimeline = captureTimeline
        inferenceFailure = nil
        backendLogURL = prepared.logURL
        backendLogHandle = prepared.logHandle
        backendLogWriter.reset(handle: prepared.logHandle, access: prepared.access)
        transcriptEventsURL = prepared.eventsURL
        currentTranscriptEventsStartOffset = 0
        transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
        transcriptModel.speakerNames = metadata?.speakerNames ?? [:]
        if let data = prepared.transcriptData, let content = String(data: data, encoding: .utf8) {
            for line in content.split(whereSeparator: \.isNewline) {
                transcriptModel.ingest(jsonLine: String(line))
            }
        }
        clearAttachments()
        if let data = prepared.attachmentsData {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do { currentAttachments = try decoder.decode(AttachmentsManifest.self, from: data).attachments }
            catch { appendBackendLog("Failed to decode saved attachments: \(error.localizedDescription)", toTail: true) }
        }
        transcriptModel.timestampOffset = timestampOffset
        // The source and session now exist. Stop must be available during
        // native setup and the bounded inference admission that follows.
        isCapturing = true
        activeScreen = .session
        let sessionEventsURL = prepared.eventsURL

        do {
            try Task.checkCancellation()
            let recordURL: URL?
            if let artifacts = prepared.artifacts {
                captureEngine.recoveryRecordingURLProvider = { [artifacts] in artifacts.nextVideoURL() }
                captureEngine.onRecordingOutputCreated = { [artifacts] in artifacts.retainRecording($0) }
                guard let url = artifacts.nextVideoURL() else {
                    throw NSError(domain: "Muesli", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Could not reserve a new video segment"])
                }
                recordURL = url
            } else {
                captureEngine.recoveryRecordingURLProvider = nil
                captureEngine.onRecordingOutputCreated = nil
                recordURL = nil
            }

            sourceTimeline = captureTimeline
            await micAudioForwarder.beginMeeting(epoch: captureTimeline)
            guard isCurrentSource(recorder, eventsURL: sessionEventsURL) else { return }
            try await captureEngine.startCapture(
                contentFilter: audioFilter,
                writer: recorder,
                recordTo: recordURL,
                timeline: captureTimeline,
                audioOutputEnabled: true, meetingAccess: prepared.access
            )
            guard isCurrentSource(recorder, eventsURL: sessionEventsURL) else { return }

            resetMicDebugState()
            micStartTime = Date()
            await startMeetingMicEngine()
            guard isCurrentSource(recorder, eventsURL: sessionEventsURL) else { return }

            let formats = await captureEngine.waitForAudioFormats(timeoutSeconds: 2.0)
            guard isCurrentSource(recorder, eventsURL: sessionEventsURL) else { return }
            let systemSampleRate = 16_000
            let systemChannels = 1
            let micSampleRate = micOutputSampleRate
            let micChannels = micOutputChannels

            if formats.systemSampleRate == nil {
                appendBackendLog("System audio format not detected; using requested settings.", toTail: true)
            } else if systemSampleRate != captureSampleRate || systemChannels != captureChannels {
                appendBackendLog("System audio: requested \(captureSampleRate)Hz/\(captureChannels)ch, got \(systemSampleRate)Hz/\(systemChannels)ch.", toTail: true)
            }

            if let backendProjectRoot {
                do {
                    try await launchLiveInference(backendProjectRoot: backendProjectRoot, audioDir: audioDir,
                                                  folderURL: folderURL, recorder: recorder, eventsURL: sessionEventsURL)
                } catch {
                    guard isCurrentSource(recorder, eventsURL: sessionEventsURL) else { return }
                    reportInferenceFailure(error.localizedDescription)
                }
            } else {
                reportInferenceFailure("No local transcription backend is configured.")
            }
            guard isCurrentSource(recorder, eventsURL: sessionEventsURL) else { return }

            let meta: [String: Any] = [
                "protocol_version": 1,
                "source_session_id": sourceID,
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
            writer?.send(type: .meetingStart, stream: .system, ptsUs: 0, payload: metaData)
            appendBackendLog("Sent meeting_start", toTail: true)
            // Readiness describes inference only. Capture already writes to
            // the app-owned source store and must continue during this wait.
            if let sessionBackend = backend {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let readiness = await self.backendStartupGate.waitUntilReady(
                        timeoutSeconds: self.backendReadinessTimeoutSeconds,
                        isProcessAlive: { sessionBackend.isRunning })
                    guard self.sourceRecorder === recorder else { return }
                    if readiness != .ready {
                        self.reportInferenceFailure("The transcription process did not become ready.")
                    }
                }
            }

            if let artifacts = sessionArtifactStore {
                let request = ScreenshotScheduler.NativeRequest(filter: screenshotFilter,
                    configuration: captureEngine.streamConfigurationForScreenshots())
                // The sink belongs to this attempt. Source assets still persist
                // when inference is absent or its UI projection is cancelled.
                let eventWriter = writer
                screenshotScheduler.start(every: 5, store: artifacts, request: request.capture) { event in
                    if let data = try? JSONEncoder().encode(event) {
                        eventWriter?.send(type: .screenshotEvent, stream: .system,
                            ptsUs: Int64(event.t * 1_000_000), payload: data)
                    }
                }
            }

            scheduleMicStartupHealthCheck()
            startMicFramesWatchdog()
        } catch {
            // Stop owns teardown once it retires this source. A late startup
            // continuation must not touch its files or a subsequent meeting.
            guard isCurrentSource(recorder, eventsURL: sessionEventsURL) else { return }
            isFinalizing = true
            defer { isFinalizing = false; isCapturing = false; activeScreen = .start }
            let pythonPath = backendPythonCandidatePath ?? "(unknown)"
            let nsError = error as NSError
            let details = "domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)"
            shareableContentError = "Failed to start backend or capture: \(error). Python: \(pythonPath) sandboxed=\(isSandboxed) \(details)"
            appendBackendLog("Start failure: \(shareableContentError ?? "\(error)")", toTail: true)
            await teardownFailedMeetingStart(session: session, wasResume: meeting != nil, priorMetadata: metadata)
        }
    }

    private func isCurrentSource(_ recorder: LocalAudioRecorder, eventsURL: URL) -> Bool {
        isCapturing && !isFinalizing && sourceRecorder === recorder && transcriptEventsURL == eventsURL
    }

    /// Live inference may be absent or fail; source recording has a separate owner.
    private func launchLiveInference(backendProjectRoot: URL, audioDir: URL, folderURL: URL,
                                     recorder: LocalAudioRecorder, eventsURL: URL) async throws {
        let transcribeStream = transcribeSystem && transcribeMic ? "both" : (transcribeSystem ? "system" : "mic")
        let sessionLogHandle = backendLogHandle
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.transcriptEventsURL == eventsURL else { return }
                let active = self.isCurrentSource(recorder, eventsURL: eventsURL)
                if active { self.reportInferenceFailure("The transcription process exited (status \(status)).") }
                self.appendBackendLog("Backend exited with status \(status)", toTail: active, handle: sessionLogHandle)
            }
        }
        let onStderr: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor [weak self] in
                guard let self, self.transcriptEventsURL == eventsURL else { return }
                self.appendBackendLog("[stderr] \(line)",
                    toTail: self.isCurrentSource(recorder, eventsURL: eventsURL), handle: sessionLogHandle)
            }
        }
        let attempt = try backendAdmission.start(protecting: folderURL, timeoutSeconds: 8) {
            try BackendLaunchConfiguration.scoped(root: backendProjectRoot) { python in
                var command = [python, "-m", "diarise_transcribe.muesli_backend", "--emit-meters",
                    "--transcribe-stream", transcribeStream, "--output-dir", audioDir.path,
                    "--keep-wav", "--source-recording", "--live-asr-only", "--meeting-lease-required"]
                #if DEBUG
                command.append(contentsOf: ["--verbose", "--live-interval", "5", "--live-min-seconds", "5"])
                #endif
                let backend = try BackendProcess(command: command, workingDirectory: backendProjectRoot,
                    environment: BatchRediarizer.backendEnvironment(root: backendProjectRoot), eventJournalURL: eventsURL)
                backend.onExit = onExit
                backend.onStderrLine = onStderr
                return backend
            }
        }
        let outcome = await attempt.waitUntilReady()
        guard isCurrentSource(recorder, eventsURL: eventsURL), !Task.isCancelled else {
            attempt.cancel()
            throw CancellationError()
        }
        switch outcome {
        case .ready: break
        case .failed(let message): throw BackendAdmissionOwner.Failure(message: message)
        case .timedOut, .cancelled: throw BackendAdmissionOwner.Failure.retired
        }
        // No await between the current-source fence, claim and UI publication.
        let resources = try attempt.claim()
        let backend = resources.backend
        let createdWriter = resources.writer
        self.backend = backend
        self.writer = createdWriter
        currentTranscriptEventsStartOffset = backend.stdoutStatus().journalStartOffset
        createdWriter.onWriteError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.transcriptEventsURL == eventsURL else { return }
                self.handleBackendWriteError(error)
            }
        }
        stdoutTask?.cancel()
        stdoutTask = Task { @MainActor in
            for await line in backend.stdoutLines {
                guard !Task.isCancelled else { break }
                self.handleBackendJSONLine(line, backendLogHandle: sessionLogHandle,
                    ingestIntoLiveTranscript: self.isCurrentSource(recorder, eventsURL: eventsURL),
                    sessionFolderURL: folderURL)
            }
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
        let stoppingAccess = currentMeetingAccess
        defer { currentMeetingAccess = nil; withExtendedLifetime(stoppingAccess) {} }
        let stoppingArtifacts = takeSessionArtifactStore()
        cancelMicStartupHealthCheck()
        stopMicFramesWatchdog()
        screenshotScheduler.stop()
        let systemStopped = await captureEngine.stopCapture()
        if systemStopped { stoppingArtifacts?.markCaptureStopped(atHostUs: CaptureTimeline.hostNowMicroseconds()) }

        enqueueMicLifecycle("start-failure-cleanup") { model in
            if let engine = model.micEngine {
                _ = await model.stopNativeMicrophone(engine, ingress: model.micAudioIngress, preview: false)
            }
            model.micEngine = nil
            model.micEngineStartedAt = nil
            model.micEngineBoundDeviceID = 0
            model.micEngineUsesCaptureSession = false
        }
        await micLifecycleTask?.value
        await micAudioIngress?.finish()
        lastRetiredMicIngress = micAudioIngress?.snapshot() ?? lastRetiredMicIngress
        micAudioIngress = nil
        await micAudioForwarder.stop()
        await micAudioForwarder.endMeeting()
        let hadSourceRecorder = sourceRecorder != nil
        let sourceResult = await sourceRecorder?.finish()
        let artifactResult = await stoppingArtifacts?.finish(timeoutSeconds: 5)
        sourceRecorder = nil
        sourceTimeline = nil
        micStartTime = nil
        resetMicRecoveryLadder()

        // Stdin closing belongs to the writer's queue exclusively (round-2
        // gate blocker) - close it via the barrier before stop()'s teardown.
        // In this failed-start path audio never flowed (the readiness gate
        // was still closed), so the queue holds at most the small
        // meeting_start control frame and the barrier resolves immediately;
        // the bound is defensive.
        if let failedWriter = writer {
            _ = await failedWriter.closeStdinAndWait(timeoutSeconds: 2)
        }
        // stop() SIGTERMs, but the child this teardown most needs to kill is
        // one wedged pre-read-loop (2026-07-16 RCA) - which may ignore
        // SIGTERM. Escalate to SIGKILL after a short grace, detached so the
        // teardown itself stays fast; killing the child also closes the
        // pipe's read end, unblocking any FramedWriter write stuck on a full
        // pipe (RCA rec #6).
        let failedBackend = backend
        backend?.stop()
        backend = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        writer = nil
        backendStartupGate.reset()
        backendWriteStalled = false
        meters.clearBackendAlert()
        if let failedBackend {
            Task.detached {
                if await failedBackend.waitForExit(timeoutSeconds: 5) == nil {
                    failedBackend.forceKill()
                }
            }
        }

        closeBackendLog()
        closeTranscriptEventsLog()

        if hadSourceRecorder {
            // Source capture may have succeeded before another source failed.
            // Keep this session indexed so preserved material is recoverable.
            await finalizeMeetingMetadata(for: session, finalizedSegments: [], sourceManifest: sourceResult,
                                    artifactResult: artifactResult, incomplete: true, access: stoppingAccess)
        } else {
            // Preserve the prepared session index even if no recorder reached
            // this defensive path. The owned finalizer reports missing sources.
            await finalizeMeetingMetadata(for: session, finalizedSegments: [], incomplete: true, access: stoppingAccess)
        }

        clearAttachments()
        currentSession = nil
    }

    func stopMeeting() async {
        guard isCapturing, !isFinalizing else { return }
        let stoppingAccess = currentMeetingAccess

        isFinalizing = true
        // Retire edit admission before any suspension. The retained finalizer
        // carries accepted names even if their preceding disk edit fails.
        let acceptedSpeakerNames = currentSession.map { retireMetadataEdits(in: $0.folderURL) } ?? [:]
        let stoppingArtifacts = takeSessionArtifactStore()
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
        let systemStopped = await captureEngine.stopCapture()
        if systemStopped { stoppingArtifacts?.markCaptureStopped(atHostUs: CaptureTimeline.hostNowMicroseconds()) }
        if let engine = micEngine {
            _ = await stopNativeMicrophone(engine, ingress: micAudioIngress, preview: false)
        }
        micEngine = nil
        micEngineStartedAt = nil
        await micAudioIngress?.finish()
        lastRetiredMicIngress = micAudioIngress?.snapshot() ?? lastRetiredMicIngress
        micAudioIngress = nil
        await micAudioForwarder.stop()
        await micAudioForwarder.endMeeting()
        let sourceResult = await sourceRecorder?.finish()
        let artifactResult = await stoppingArtifacts?.finish(timeoutSeconds: 5)
        sourceRecorder = nil
        sourceTimeline = nil
        micStartTime = nil
        resetMicRecoveryLadder()

        // Stop-path hardening (2026-07-16 RCA rec #6). meetingStop and the
        // close both go through the writer's serial queue - against a
        // wedged (alive-but-not-reading) child they queue behind the
        // blocked write and never arrive, and the finalize wait below is
        // what escalates (its no-progress check re-measures LIVE, so this
        // at-stop snapshot is diagnostic only - deliberately NOT the stale
        // backendWriteStalled latch, which can outlive a recovery by a
        // watchdog tick; gate BLOCKER 4). meetingStop is sent even when
        // stalled: it is a control frame, and if the child recovers during
        // finalize it should still stop cleanly.
        let backendStalledAtStop = writer?.isBacklogStalled() ?? false
        writer?.send(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
        if backendStalledAtStop {
            let snap = writer?.backlogSnapshot()
            AudioLog.error("writequeue.stalled-at-stop", [
                "outstandingFrames": snap?.outstandingFrames ?? -1,
                "outstandingBytes": snap?.outstandingBytes ?? -1,
                "droppedFrames": snap?.droppedFrames ?? -1
            ])
            appendBackendLog("Backend write queue stalled at stop; new sends rejected, close queued.", toTail: true)
            // Same queued close as the healthy path, plus reject any
            // further sends with accounting.
            writer?.forceCloseStdin()
        } else {
            writer?.closeStdinAfterDraining()
        }
        backendStartupGate.reset()
        backendWriteStalled = false
        backendStallLogTicks = 0
        meters.clearBackendAlert()

        let stoppingSession = currentSession
        let stoppingBackend = backend
        let stoppingWriter = writer
        let stoppingStdoutTask = stdoutTask
        let stoppingBackendLogHandle = backendLogHandle
        let stoppingTranscriptEventsStartOffset = currentTranscriptEventsStartOffset
        let stoppingTranscriptEventsURL = transcriptEventsURL
        let stoppingTranscriptSegments = transcriptModel.segments.filter { !$0.isPartial }
        let stoppingSpeakerNames = transcriptModel.speakerNames
        let stoppingTimestampOffset = transcriptModel.timestampOffset
        let stoppingInferenceFailed = inferenceFailure != nil

        writer = nil
        backend = nil
        stdoutTask = nil
        backendLogHandle = nil
        backendLogURL = nil
        transcriptEventsURL = nil
        currentTranscriptEventsStartOffset = 0
        clearAttachments()

        isCapturing = false
        currentMeetingAccess = nil
        currentSession = nil
        activeScreen = .start

        guard let stoppingSession else {
            closeHandle(stoppingBackendLogHandle)
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
                transcriptEventsStartOffset: stoppingTranscriptEventsStartOffset,
                transcriptEventsURL: stoppingTranscriptEventsURL,
                transcriptSegmentsSnapshot: stoppingTranscriptSegments,
                speakerNamesSnapshot: stoppingSpeakerNames,
                acceptedSpeakerNames: acceptedSpeakerNames,
                timestampOffsetSnapshot: stoppingTimestampOffset,
                writer: stoppingWriter,
                sourceManifest: sourceResult,
                artifactResult: artifactResult,
                inferenceFailed: stoppingInferenceFailed,
                access: stoppingAccess
            )
        }
    }

    private func finalizeStoppedMeeting(
        session: MeetingSession,
        backend: BackendProcess?,
        stdoutTask: Task<Void, Never>?,
        backendLogHandle: FileHandle?,
        transcriptEventsStartOffset: UInt64,
        transcriptEventsURL: URL?,
        transcriptSegmentsSnapshot: [TranscriptSegment],
        speakerNamesSnapshot: [String: String],
        acceptedSpeakerNames: [String: String],
        timestampOffsetSnapshot: Double,
        writer: FramedWriter? = nil,
        sourceManifest: LocalAudioRecorder.Manifest? = nil,
        artifactResult: SessionArtifactFinishResult? = nil,
        inferenceFailed: Bool = false,
        access: MeetingFileAccess? = nil
    ) async {
        defer { withExtendedLifetime(access) {} }
        defer {
            // Ordered after any writes still queued on the writer's own
            // serial queue - see BackendLogWriter.close's doc comment for
            // why this must not be a bare `handle.close()` here.
            backendLogWriter.close(handle: backendLogHandle)
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

        // Exit wait with LIVE stall escalation (gate BLOCKER 4 fix): a
        // healthy finalize (joining ASR workers, muesli_backend stop path)
        // legitimately takes tens of seconds and always keeps the full 120s
        // grace - including a backend that stalled mid-meeting and then
        // RECOVERED, which the old fixed-5s-when-stalled-latch design would
        // have SIGTERMed mid-finalize, losing the transcript tail. Early
        // escalation happens only on live evidence of a wedged child: the
        // writer's queue re-measured EVERY second as having work outstanding
        // with zero completions for 15s straight (any progress resets the
        // clock inside the tracker).
        let exitStatus = await waitForBackendExit(
            backend: backend,
            writer: writer,
            maxWaitSeconds: 120,
            escalateAfterNoProgressSeconds: 15,
            logHandle: backendLogHandle
        )
        if exitStatus == nil {
            appendBackendLog(
                "Backend did not exit after stop; terminating.",
                toTail: false,
                handle: backendLogHandle
            )
            backend?.terminate()
            // A wedged child can ignore SIGTERM too (RCA rec #6) - escalate
            // to SIGKILL after a short grace. The kill closes the pipe's
            // read end, which is also what unblocks any FramedWriter write
            // still stuck on the full pipe.
            if await backend?.waitForExit(timeoutSeconds: 5) == nil {
                appendBackendLog(
                    "Backend ignored SIGTERM; force-killing.",
                    toTail: false,
                    handle: backendLogHandle
                )
                backend?.forceKill()
                _ = await backend?.waitForExit(timeoutSeconds: 2)
            }
        }
        // Single-queue stdin ownership (round-2 gate blocker): cleanup() no
        // longer touches stdin, so wait for the writer's queued close to
        // have actually run before tearing down the rest of the plumbing.
        // The child is dead by now, so EPIPE has unblocked any stuck write
        // and the queue drains fast; the bound is defensive. On timeout we
        // proceed WITHOUT closing stdin ourselves - the queued close still
        // runs whenever the queue unblocks.
        if let writer, await writer.closeStdinAndWait(timeoutSeconds: 5) == false {
            AudioLog.error("writequeue.close-barrier-timeout")
            appendBackendLog(
                "Writer queue close did not complete within 5s; stdin close left to the queue.",
                toTail: false,
                handle: backendLogHandle
            )
        }
        let journalDrain = await backend?.finishStdout(timeoutSeconds: 5)
        let journalComplete: Bool
        if case .drained(let status) = journalDrain { journalComplete = status.isComplete }
        else { journalComplete = false }
        // UI completion is irrelevant to the saved transcript. Its bounded
        // projection may be cancelled after authoritative EOF/drain handling.
        stdoutTask?.cancel()
        backend?.cleanup()
        backendLogWriter.synchronize(label: "backend log")

        let journalStatus = journalDrain?.status
        let incomplete = inferenceFailed || exitStatus != 0 || !journalComplete
        let saveID = meetingSavePublication.begin(folder: session.folderURL)
        do {
            let operation = try TranscriptPersistenceStore.shared.startAfterCurrent(in: session.folderURL,
                onCompletion: { [weak self] result in
                    Task { @MainActor [weak self] in self?.publishMeetingSave(result, folder: session.folderURL, id: saveID) }
                }) { context in
                defer { withExtendedLifetime(access) {} }
                return try TranscriptReplacement.commitStoppedMeeting(context: context,
                    timestampOffset: timestampOffsetSnapshot, segments: transcriptSegmentsSnapshot,
                    speakerNames: speakerNamesSnapshot, journalURL: transcriptEventsURL,
                    journalStatus: journalStatus, sourceManifest: sourceManifest,
                    artifactResult: artifactResult, incomplete: incomplete,
                    acceptedSpeakerNames: acceptedSpeakerNames)
            }
            switch await operation.wait(timeoutSeconds: 5) {
            case .completed, .failed: break // Actual completion publishes the observed result.
            case .timedOut, .cancelled:
                guard meetingSavePublication.isPending(folder: session.folderURL, id: saveID) else { return }
                meetingSaveNotices[session.folderURL.path] = "The meeting is still being saved. Its original disk operation retains ownership; the source recording and recovery files are preserved."
            }
        } catch {
            publishMeetingSave(.failure(.operationFailed(error.localizedDescription)), folder: session.folderURL, id: saveID)
        }
    }

    private func publishMeetingSave(_ result: Result<MeetingMetadata, TranscriptPersistenceStore.Failure>, folder: URL, id: UUID) {
        guard meetingSavePublication.markTerminal(folder: folder, id: id) else { return }
        meetingCatalog.invalidate()
        switch result {
        case .success:
            let transferredIDs = metadataEdits.completeRetirement(in: folder, successorSucceeded: true)
            meetingSaveNotices[folder.path] = nil
            if let noticeID = metadataEditNoticeOwners[folder.path], transferredIDs.contains(noticeID) {
                setMetadataEditNotice(nil, for: folder)
            }
            // The terminal result can wait behind a later edit's UI callback.
            // Read the current disk snapshot under ownership instead of putting
            // its older title/count/status snapshot back into history.
            loadMeetingHistory()
        case .failure(let error):
            metadataEdits.completeRetirement(in: folder, successorSucceeded: false)
            meetingSaveNotices[folder.path] = "Meeting save needs attention: \(error.localizedDescription) Original audio and recovery files have been retained."
        }
    }

    /// Root finalization carries this patch into its retained terminal intent.
    func retireMetadataEdits(in folder: URL) -> [String: String] {
        metadataEdits.retire(in: folder)
    }

    /// Post-stop exit wait: up to `maxWaitSeconds` for a clean exit, but
    /// gives up early when the stopped meeting's writer shows SUSTAINED
    /// zero progress with work still queued - the wedged-child signature
    /// (2026-07-16 RCA), re-measured fresh on every 1s tick rather than
    /// carried over from any mid-meeting stall flag. Returning nil sends
    /// the caller into the SIGTERM->SIGKILL escalation, whose kill closes
    /// the pipe's read end and thereby unblocks the write the queued
    /// stdin-close is stuck behind (see FramedWriter.forceCloseStdin).
    private func waitForBackendExit(
        backend: BackendProcess?,
        writer: FramedWriter?,
        maxWaitSeconds: Double,
        escalateAfterNoProgressSeconds: Double,
        logHandle: FileHandle?
    ) async -> Int32? {
        guard let backend else { return nil }
        let deadline = Date().addingTimeInterval(maxWaitSeconds)
        while Date() < deadline {
            if let status = await backend.waitForExit(timeoutSeconds: 1.0) {
                return status
            }
            if Task.isCancelled { return nil }
            if let writer, writer.hasMadeNoProgress(forAtLeast: escalateAfterNoProgressSeconds) {
                let snap = writer.backlogSnapshot()
                AudioLog.error("writequeue.stalled-at-finalize", [
                    "outstandingFrames": snap.outstandingFrames,
                    "outstandingBytes": snap.outstandingBytes,
                    "noProgressSeconds": Int(snap.secondsSinceLastProgress ?? -1)
                ])
                appendBackendLog(
                    "Backend write queue made no progress for \(Int(escalateAfterNoProgressSeconds))s after stop; escalating termination.",
                    toTail: false,
                    handle: logHandle
                )
                return nil
            }
        }
        return nil
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
        // This is a display suggestion. The storage preparation owner resolves
        // actual folder/title collisions when the user starts a meeting.
        (meetingHistory.compactMap { parseMeetingNumber(in: $0.title, datePrefix: datePrefix) }.max() ?? 0) + 1
    }

    private func normaliseMeetingTitle(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
        let filtered = trimmed.components(separatedBy: allowed.inverted).joined()
        let collapsed = filtered.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        return collapsed.isEmpty ? Self.defaultMeetingTitle() : collapsed
    }

    /// Finalization must retain this owner and await its typed outcome after
    /// native stop. Taking it closes screenshot admission immediately; pending
    /// SDK video callbacks continue to address this original session's ledger.
    private func takeSessionArtifactStore() -> SessionArtifactStore? {
        backendAdmission.retireAdmission()
        captureEngine.retireCaptureIntent()
        screenshotScheduler.stop()
        let store = sessionArtifactStore
        sessionArtifactStore = nil
        store?.stopScreenshots()
        captureEngine.recoveryRecordingURLProvider = nil
        captureEngine.onRecordingOutputCreated = nil
        return store
    }

    private func finalizeMeetingMetadata(
        for session: MeetingSession,
        finalizedSegments: [TranscriptSegment],
        sourceManifest: LocalAudioRecorder.Manifest? = nil,
        artifactResult: SessionArtifactFinishResult? = nil,
        incomplete: Bool = false,
        access: MeetingFileAccess? = nil
    ) async {
        defer { withExtendedLifetime(access) {} }
        let saveID = meetingSavePublication.begin(folder: session.folderURL)
        do {
            let operation = try TranscriptPersistenceStore.shared.startAfterCurrent(in: session.folderURL,
                onCompletion: { [weak self] result in
                    Task { @MainActor [weak self] in self?.publishMeetingSave(result, folder: session.folderURL, id: saveID) }
                }) { context in
                defer { withExtendedLifetime(access) {} }
                let prior = try context.readMetadata()
                let problems = OrphanedMeetingRecovery.finalizationSourceProblems(folderURL: context.folder, metadata: prior)
                let metadata = prior.finalized(segments: finalizedSegments, sourceManifest: sourceManifest,
                    artifactResult: artifactResult, incomplete: incomplete, sourceProblems: problems)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try context.commit(files: ["meeting.json": encoder.encode(metadata)])
                return metadata
            }
            switch await operation.wait(timeoutSeconds: 5) {
            case .completed, .failed: break
            case .timedOut, .cancelled:
                guard meetingSavePublication.isPending(folder: session.folderURL, id: saveID) else { return }
                meetingSaveNotices[session.folderURL.path] = "The interrupted meeting is still being saved. Its source recording and recovery files are preserved."
            }
        } catch {
            publishMeetingSave(.failure(.operationFailed(error.localizedDescription)), folder: session.folderURL, id: saveID)
        }
    }

    func renameSpeaker(id: String, to name: String) {
        let folder: URL?
        if let session = currentSession { folder = session.folderURL }
        else if case .viewing(let item) = activeScreen { folder = item.folderURL }
        else { folder = nil }
        guard let folder, canEditTranscript(in: folder) else { return }
        submitSpeakerNames(transcriptModel.speakerNameAssignments(id: id, name: name), to: folder)
    }

    private func submitSpeakerNames(_ names: [String: String], to folder: URL) {
        meetingCatalog.invalidate()
        metadataEdits.submitNames(names, in: folder, contentGeneration: transcriptModel.contentGeneration)
    }

    private func setMetadataEditNotice(_ message: String?, for folder: URL, owner: UUID? = nil) {
        metadataEditNotices[folder.path] = message
        metadataEditNoticeOwners[folder.path] = message == nil ? nil : owner
    }

    private func publishMetadataEdit(_ event: MeetingMetadataEdits.Event) {
        switch event {
        case .committed(let folder, let metadata, let patch):
            meetingCatalog.invalidate()
            setMetadataEditNotice(nil, for: folder)
            // Only publish fields this operation edited. A late name/title
            // callback must not roll back newer finalization status or counts.
            if patch.title != nil {
                if let index = meetingHistory.firstIndex(where: { $0.folderURL == folder }) {
                    let current = meetingHistory[index]
                    meetingHistory[index] = MeetingHistoryItem(id: current.id, folderURL: folder,
                        title: metadata.title, createdAt: current.createdAt, durationSeconds: current.durationSeconds,
                        segmentCount: current.segmentCount, status: current.status)
                }
                if case .viewing(let current) = activeScreen, current.folderURL == folder {
                    activeScreen = .viewing(MeetingHistoryItem(id: current.id, folderURL: folder,
                        title: metadata.title, createdAt: current.createdAt, durationSeconds: current.durationSeconds,
                        segmentCount: current.segmentCount, status: current.status))
                }
            }
            if let session = currentSession, session.folderURL == folder, patch.title != nil {
                currentSession = MeetingSession(title: metadata.title, folderURL: folder, startedAt: session.startedAt)
                meetingTitle = metadata.title
            }
            let visible: Bool
            if let session = currentSession { visible = session.folderURL == folder }
            else if case .viewing(let current) = activeScreen { visible = current.folderURL == folder }
            else { visible = false }
            if visible { transcriptModel.applyCommittedSpeakerNames(patch.names, expectedGeneration: patch.contentGeneration) }
        case .pending(let folder, let id):
            setMetadataEditNotice("Changes to \(folder.lastPathComponent) are still being saved. The original disk operation remains active.", for: folder, owner: id)
        case .failed(let folder, let message, let id):
            setMetadataEditNotice("Changes to \(folder.lastPathComponent) were not saved: \(message)", for: folder, owner: id)
        }
    }

    // MARK: - Attachments

    func saveImageAttachment(_ encodedImage: Data) {
        let input = AttachmentPersistence.ImageInput(data: encodedImage)
        saveAttachment(type: .image) { try input.png() }
    }

    func saveTextAttachment(_ text: String) {
        guard text.utf8.count <= AttachmentPersistence.maximumTextBytes else {
            if let folder = currentSession?.folderURL {
                setAttachmentNotice("The text exceeds the 1 MB attachment limit. Nothing was saved.", folder: folder, id: UUID())
            }
            return
        }
        saveAttachment(type: .text) { Data(text.utf8) }
    }

    private func saveAttachment(type: AttachmentType, data: @escaping @Sendable () throws -> Data) {
        guard isCapturing, !isFinalizing, let timeline = sourceTimeline,
              let sourceID = diagnosticSourceID, let session = currentSession else { return }
        let timestamp = transcriptModel.timestampOffset
            + Double(max(0, timeline.relativeMicroseconds(CaptureTimeline.hostNowMicroseconds()))) / 1_000_000
        performAttachmentEdit(folder: session.folderURL, sourceID: sourceID) { context in
            try AttachmentPersistence.add(context: context, type: type, timestamp: timestamp,
                                          sourceID: sourceID, data: data())
        }
    }

    func deleteAttachment(_ attachment: Attachment) {
        guard isCapturing, !isFinalizing, let session = currentSession,
              let sourceID = diagnosticSourceID else { return }
        performAttachmentEdit(folder: session.folderURL, sourceID: sourceID) { context in
            try AttachmentPersistence.remove(context: context, id: attachment.id)
        }
    }

    func attachmentFileURL(for attachment: Attachment) -> URL? {
        guard let session = currentSession, AttachmentPersistence.validFilename(attachment.filename),
              currentAttachments.contains(where: { $0.id == attachment.id && $0.filename == attachment.filename }) else { return nil }
        return session.folderURL.appendingPathComponent("attachments").appendingPathComponent(attachment.filename)
    }

    private func performAttachmentEdit(folder: URL, sourceID: String,
        operation: @escaping @Sendable (TranscriptPersistenceStore.Context) throws -> AttachmentPersistence.Snapshot) {
        let id = UUID()
        guard attachmentEditID == nil else {
            setAttachmentNotice("This attachment change was not accepted while another save was pending. Try again after it finishes.", folder: folder, id: id)
            return
        }
        do {
            let owner = try TranscriptPersistenceStore.shared.start(in: folder, onCompletion: { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.attachmentEditID == id else { return }
                    self.attachmentEditID = nil
                    switch result {
                    case .success(let snapshot):
                        if self.currentSession?.folderURL == folder, self.diagnosticSourceID == sourceID {
                            self.currentAttachments = snapshot.attachments
                        }
                        if self.attachmentNoticeOwners[folder.path] == id {
                            self.setAttachmentNotice(snapshot.cleanupNotice, folder: folder, id: id)
                        }
                    case .failure(let error):
                        if self.attachmentNoticeOwners[folder.path] == id {
                            self.setAttachmentNotice("Attachment change was not saved: \(error.localizedDescription)", folder: folder, id: id)
                        }
                    }
                }
            }, operation: operation)
            attachmentEditID = id
            setAttachmentNotice("Saving attachment…", folder: folder, id: id)
            Task { @MainActor [weak self] in
                let result = await owner.wait(timeoutSeconds: 5)
                guard let self, self.attachmentEditID == id, self.attachmentNoticeOwners[folder.path] == id else { return }
                switch result {
                case .timedOut, .cancelled:
                    self.setAttachmentNotice("The attachment save is still pending. Its original disk operation remains active.", folder: folder, id: id)
                case .completed, .failed: break // The original callback publishes the actual result.
                }
            }
        } catch {
            setAttachmentNotice("Attachment change was not accepted: \(error.localizedDescription)", folder: folder, id: id)
        }
    }

    private func setAttachmentNotice(_ message: String?, folder: URL, id: UUID) {
        attachmentNotices[folder.path] = message
        attachmentNoticeOwners[folder.path] = message == nil ? nil : id
    }

    private func clearAttachments() {
        currentAttachments = []
    }

    private func canEditTranscript(in folder: URL) -> Bool {
        do {
            try transcriptModel.assertNoPendingReplacement(in: folder)
            return true
        } catch {
            transcriptLoadError = "Check the pending save or reopen the meeting before editing its speakers. \(error.localizedDescription)"
            return false
        }
    }

    func applySpeakerMappings(_ mappings: [SpeakerIdentifier.SpeakerMapping], for meeting: MeetingHistoryItem) {
        guard case .viewing(let current) = activeScreen, current.folderURL == meeting.folderURL,
              canEditTranscript(in: meeting.folderURL) else { return }
        var assignments: [String: String] = [:]
        for mapping in mappings {
            let id = mapping.speakerId.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = mapping.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { continue }
            assignments.merge(transcriptModel.speakerNameAssignments(id: id, name: name)) { _, latest in latest }
        }
        submitSpeakerNames(assignments, to: meeting.folderURL)
    }

    func runBatchRediarization(
        for meeting: MeetingHistoryItem,
        stream: BatchRediarizer.Stream,
        progressHandler: @escaping @MainActor @Sendable (BatchRediarizer.Progress) -> Void
    ) async throws -> BatchRediarizer.Result {
        guard let backendProjectRoot = backendFolderURL else {
            throw NSError(
                domain: "Muesli",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Select the backend folder before reprocessing."]
            )
        }
        return try await batchRediarizer.run(meetingDirectory: meeting.folderURL,
            backendRoot: backendProjectRoot, stream: stream, progressHandler: progressHandler)
    }

    func applyBatchRediarization(_ result: BatchRediarizer.Result, requestID: UUID, for meeting: MeetingHistoryItem) async throws {
        guard case .viewing(let current) = activeScreen, current.folderURL == meeting.folderURL else {
            throw TranscriptPersistenceStore.Failure.superseded
        }
        guard !metadataEdits.isPending(in: meeting.folderURL) else { throw TranscriptPersistenceStore.Failure.busy }
        meetingCatalog.invalidate()
        let replacement = try await transcriptModel.applyBatchResult(result, requestID: requestID, in: meeting.folderURL)
        let metadata = replacement.metadata
        diagnosticRuntimeIdentity = metadata.lastReprocessIdentity
        // Use the committed worker result; do not reread storage on the UI.
        let updatedItem = MeetingHistoryItem(id: meeting.id, folderURL: meeting.folderURL,
                                             title: metadata.title, createdAt: metadata.createdAt,
                                             durationSeconds: metadata.durationSeconds,
                                             segmentCount: metadata.segmentCount, status: metadata.status)
        if let idx = meetingHistory.firstIndex(where: { $0.id == meeting.id }) {
            meetingHistory[idx] = updatedItem
        } else {
            meetingHistory.insert(updatedItem, at: 0)
        }
        if case .viewing(let current) = activeScreen, current.id == meeting.id {
            activeScreen = .viewing(updatedItem)
        }
    }

    @discardableResult
    func renameMeeting(folderURL: URL, to newTitle: String) async throws -> String {
        try transcriptModel.assertNoPendingReplacement(in: folderURL)
        meetingCatalog.invalidate()
        return try await metadataEdits.rename(in: folderURL, to: newTitle)
    }

    @discardableResult
    func renameMeeting(_ item: MeetingHistoryItem, to newTitle: String) async throws -> String {
        try await renameMeeting(folderURL: item.folderURL, to: newTitle)
    }

    @discardableResult
    func renameCurrentMeeting(to newTitle: String) async throws -> String {
        guard let session = currentSession else { throw MeetingRenameError.noActiveSession }
        return try await renameMeeting(folderURL: session.folderURL, to: newTitle)
    }

    func loadMeetingHistory() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muesli", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        meetingCatalog.refresh(in: base)
    }

    func deleteMeeting(_ item: MeetingHistoryItem) {
        let folder = item.folderURL
        guard !isFinalizing, currentSession?.folderURL != folder,
              !metadataEdits.isPending(in: folder), pendingDeletes[folder.path] == nil else {
            setMetadataEditNotice("This meeting is still in use. Wait for recording and saving to finish before deleting it.", for: folder)
            return
        }
        let id = UUID()
        do {
            try transcriptModel.assertNoPendingReplacement(in: folder)
            meetingCatalog.invalidate()
            let operation = try MeetingCatalogOwner.trash(in: folder, onCompletion: { [weak self] result in
                guard let self else { return }
                Task { @MainActor in
                    guard self.pendingDeletes[folder.path] == id else { return }
                    self.pendingDeletes[folder.path] = nil
                    self.meetingCatalog.invalidate()
                    switch result {
                    case .success:
                        self.setMetadataEditNotice(nil, for: folder)
                        self.meetingHistory.removeAll { $0.id == item.id }
                        if case .viewing(let current) = self.activeScreen, current.id == item.id { self.closeMeetingViewer() }
                    case .failure(let error):
                        self.setMetadataEditNotice("The meeting could not be moved to Trash: \(error.localizedDescription)", for: folder)
                    }
                }
            })
            pendingDeletes[folder.path] = id
            Task { @MainActor [weak self] in
                let outcome = await operation.wait(timeoutSeconds: 5)
                guard let self, self.pendingDeletes[folder.path] == id else { return }
                switch outcome {
                case .timedOut, .cancelled:
                    self.setMetadataEditNotice("Moving the meeting to Trash is still pending. The original disk operation remains active.", for: folder)
                default: break
                }
            }
        } catch {
            setMetadataEditNotice("The meeting could not be moved to Trash: \(error.localizedDescription)", for: folder)
        }
    }

    func openMeeting(_ item: MeetingHistoryItem) {
        loadTranscriptForViewer(from: item.folderURL)
        activeScreen = .viewing(item)
        Task { await refreshSpeakerIdStatus() }
    }

    func resumeMeeting(_ item: MeetingHistoryItem) {
        guard !isPreparingResume, !isStartingMeeting, !isCapturing, !isFinalizing else { return }
        isPreparingResume = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isPreparingResume = false }
            await startMeeting(resuming: item)
        }
    }

    func closeMeetingViewer() {
        activeScreen = .start
        clearViewerTranscript()
    }

    func exportTranscriptFiles(for meeting: MeetingHistoryItem) {
        presentTranscriptExport(sourceDirectory: meeting.folderURL, title: meeting.title)
    }

    @Published var transcriptLoadError: String?

    private var transcriptLoadIntent = UUID()

    private func loadTranscriptForViewer(from folderURL: URL) {
        let intent = UUID()
        transcriptLoadIntent = intent
        transcriptLoadError = nil
        transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
        let contentGeneration = transcriptModel.contentGeneration
        Task { @MainActor [weak self] in
            guard let self, self.transcriptLoadIntent == intent,
                  self.transcriptModel.contentGeneration == contentGeneration else { return }
            do {
                let operation = try TranscriptPersistenceStore.shared.start(in: folderURL) { context in
                    let jsonl = try context.readData(named: "transcript.jsonl")
                    let metadata = try? context.readMetadata() // Legacy transcripts may have no meeting.json.
                    return (String(decoding: jsonl, as: UTF8.self), metadata?.speakerNames ?? [:])
                }
                let (content, names) = try await operation.value(timeoutSeconds: 5)
                guard self.transcriptLoadIntent == intent,
                      case .viewing(let item) = self.activeScreen, item.folderURL == folderURL else { return }
                self.transcriptModel.applyLoadedTranscript(content: content, names: names, expectedGeneration: contentGeneration)
            } catch {
                guard self.transcriptLoadIntent == intent,
                      self.transcriptModel.contentGeneration == contentGeneration else { return }
                self.appendBackendLog("Transcript load is unresolved: \(error.localizedDescription)", toTail: true)
                self.transcriptLoadError = "Transcript could not be loaded: \(error.localizedDescription) Reopen the meeting to retry."
            }
        }
    }

    private func clearViewerTranscript() {
        transcriptLoadIntent = UUID()
        transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
    }

}
