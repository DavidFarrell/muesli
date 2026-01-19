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
    private var transcriptEventsHandle: FileHandle?
    private var transcriptEventsURL: URL?
    private var backendAccessURL: URL?
    private var stdoutTask: Task<Void, Never>?
    private let backendBookmarkKey = "MuesliBackendBookmark"
    private let defaultBackendProjectRoot = URL(fileURLWithPath: "/Users/david/git/ai-sandbox/projects/muesli/backend/fast_mac_transcribe_diarise_local_models_only")
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
            self?.objectWillChange.send()
        }
        transcriptCancellable = transcriptModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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

    private func resetTranscriptEventsLog(in folderURL: URL) {
        let logURL = folderURL.appendingPathComponent("transcript_events.jsonl")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        transcriptEventsURL = logURL
        transcriptEventsHandle = try? FileHandle(forWritingTo: logURL)
    }

    private func closeTranscriptEventsLog() {
        if let handle = transcriptEventsHandle {
            try? handle.close()
        }
        transcriptEventsHandle = nil
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
        if let data = (line + "\n").data(using: .utf8) {
            transcriptEventsHandle?.write(data)
        }
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

    private func saveTranscriptFiles(for session: MeetingSession) {
        let finalized = transcriptModel.segments.filter { !$0.isPartial }
        let jsonlURL = session.folderURL.appendingPathComponent("transcript.jsonl")
        let txtURL = session.folderURL.appendingPathComponent("transcript.txt")

        var jsonlLines: [String] = []
        for seg in finalized {
            let payload: [String: Any] = [
                "speaker_id": seg.speakerID,
                "stream": seg.stream,
                "t0": seg.t0,
                "t1": seg.t1 ?? seg.t0,
                "text": seg.text
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let line = String(data: data, encoding: .utf8) {
                jsonlLines.append(line)
            }
        }

        let jsonlString = jsonlLines.joined(separator: "\n")
        let textString = transcriptModel.asPlainText()

        let jsonlData = jsonlString.data(using: .utf8)
        let textData = textString.data(using: .utf8)

        if let jsonlData {
            do {
                try jsonlData.write(to: jsonlURL)
            } catch {
                appendBackendLog("Failed to save transcript JSONL: \(error.localizedDescription)", toTail: true)
            }
        } else {
            appendBackendLog("Failed to encode transcript JSONL.", toTail: true)
        }

        if let textData {
            do {
                try textData.write(to: txtURL)
            } catch {
                appendBackendLog("Failed to save transcript text: \(error.localizedDescription)", toTail: true)
            }
        } else {
            appendBackendLog("Failed to encode transcript text.", toTail: true)
        }

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
            tempTranscriptFolderPath = tempFolder.path
            appendBackendLog("Transcript temp folder: \(tempFolder.path)", toTail: true)
        } catch {
            appendBackendLog("Failed to save transcript temp copy: \(error.localizedDescription)", toTail: true)
        }
    }

    func exportTranscriptFiles() {
        guard let session = currentSession else {
            appendBackendLog("Export failed: no active session.", toTail: true)
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = "\(session.title)-transcript.txt"
        panel.prompt = "Export"
        panel.message = "Export transcript as .txt (JSONL will be written alongside)."

        if panel.runModal() == .OK, let url = panel.url {
            let jsonlURL = url.deletingPathExtension().appendingPathExtension("jsonl")
            let targetDir = url.deletingLastPathComponent()

            let textString = transcriptModel.asPlainText()
            if let textData = textString.data(using: .utf8) {
                do {
                    try textData.write(to: url)
                } catch {
                    appendBackendLog("Failed to export transcript text: \(error.localizedDescription)", toTail: true)
                }
            } else {
                appendBackendLog("Failed to encode exported transcript text.", toTail: true)
            }

            let jsonlString = transcriptModel.segments
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
            if let jsonlData = jsonlString.data(using: .utf8) {
                do {
                    try jsonlData.write(to: jsonlURL)
                } catch {
                    appendBackendLog("Failed to export transcript JSONL: \(error.localizedDescription)", toTail: true)
                }
            } else {
                appendBackendLog("Failed to encode exported transcript JSONL.", toTail: true)
            }

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
            await captureThumbnails()

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

    @MainActor
    func refreshSpeakerIdStatus(modelName: String = "gemma3:27b") async {
        let url = URL(string: "http://localhost:11434/api/tags")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                speakerIdStatus = .error("invalid response")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                speakerIdStatus = .error("status \(http.statusCode)")
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                speakerIdStatus = .error("invalid payload")
                return
            }
            let hasModel = models.contains { ($0["name"] as? String) == modelName }
            speakerIdStatus = hasModel ? .ready : .modelMissing(modelName)
        } catch {
            if let urlError = error as? URLError, urlError.code == .cannotConnectToHost {
                speakerIdStatus = .ollamaNotRunning
            } else {
                speakerIdStatus = .error(error.localizedDescription)
            }
        }
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

        return await withCheckedContinuation { continuation in
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
        await startMeeting(resuming: nil, metadata: nil, timestampOffset: 0)
    }

    private func startMeeting(
        resuming meeting: MeetingHistoryItem?,
        metadata: MeetingMetadata?,
        timestampOffset: Double
    ) async {
        refreshPermissions()
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
        let audioDir: URL
        var sessionID = 1
        if let meeting, let metadata {
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
        if timestampOffset > 0 {
            transcriptModel.timestampOffset = timestampOffset
        }

        do {
            resetBackendLog(in: folderURL)
            resetTranscriptEventsLog(in: folderURL)
            if meeting == nil {
                try createInitialMeetingMetadata(for: session, audioFolderName: audioDir.lastPathComponent)
            } else if let metadata {
                try appendResumeSessionMetadata(metadata, for: session, sessionID: sessionID, audioFolderName: audioDir.lastPathComponent)
            }

            if selectedInputDeviceID != 0 {
                _ = AudioDeviceManager.setDefaultInputDevice(selectedInputDeviceID)
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
                appendBackendLog("Backend folder: \(backendProjectRoot.path)", toTail: true)
                appendBackendLog("PATH: \(mergedPath)", toTail: true)
                appendBackendLog("Command: \(command.joined(separator: " "))", toTail: true)
                backend.onExit = { [weak self] status in
                    Task { @MainActor in
                        self?.appendBackendLog("Backend exited with status \(status)", toTail: true)
                    }
                }
                backend.onStderrLine = { [weak self] line in
                    Task { @MainActor in
                        self?.appendBackendLog("[stderr] \(line)", toTail: true)
                    }
                }
                try backend.start()
                self.backend = backend
                stdoutTask?.cancel()
                stdoutTask = Task { @MainActor in
                    for await line in backend.stdoutLines {
                        self.handleBackendJSONLine(line)
                    }
                }
                let createdWriter = FramedWriter(stdinHandle: backend.stdin)
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
                contentFilter: filter,
                writer: writer,
                recordTo: recordURL
            )

            let formats = await captureEngine.waitForAudioFormats(timeoutSeconds: 2.0)
            let systemSampleRate = formats.systemSampleRate ?? captureSampleRate
            let systemChannels = formats.systemChannels ?? captureChannels
            let micSampleRate = formats.micSampleRate ?? captureSampleRate
            let micChannels = formats.micChannels ?? captureChannels

            if formats.systemSampleRate == nil {
                appendBackendLog("System audio format not detected; using requested settings.", toTail: true)
            } else if systemSampleRate != captureSampleRate || systemChannels != captureChannels {
                appendBackendLog("System audio: requested \(captureSampleRate)Hz/\(captureChannels)ch, got \(systemSampleRate)Hz/\(systemChannels)ch.", toTail: true)
            }

            if formats.micSampleRate == nil {
                appendBackendLog("Mic audio format not detected; using requested settings.", toTail: true)
            } else if micSampleRate != captureSampleRate || micChannels != captureChannels {
                appendBackendLog("Mic audio: requested \(captureSampleRate)Hz/\(captureChannels)ch, got \(micSampleRate)Hz/\(micChannels)ch.", toTail: true)
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
            writer.sendSync(type: .meetingStart, stream: .system, ptsUs: 0, payload: metaData)
            appendBackendLog("Sent meeting_start", toTail: true)
            updateMeetingMetadataStreams(
                for: session,
                systemSampleRate: systemSampleRate,
                systemChannels: systemChannels,
                micSampleRate: micSampleRate,
                micChannels: micChannels
            )
            captureEngine.setAudioOutputEnabled(true)

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
            activeScreen = .session
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

        screenshotScheduler.stop()
        await captureEngine.stopCapture()

        writer?.sendSync(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
        writer?.closeStdinAfterDraining()
        writer = nil

        let exitStatus = await backend?.waitForExit(timeoutSeconds: 120)
        if exitStatus == nil {
            appendBackendLog("Backend did not exit after stop; terminating.", toTail: true)
            backend?.terminate()
        }
        backend?.cleanup()
        stdoutTask?.cancel()
        stdoutTask = nil
        backend = nil
        if let session = currentSession {
            saveTranscriptFiles(for: session)
            finalizeMeetingMetadata(for: session)
            if let updatedItem = buildMeetingHistoryItem(for: session.folderURL),
               let idx = meetingHistory.firstIndex(where: { $0.folderURL == session.folderURL }) {
                meetingHistory[idx] = updatedItem
            } else if let updatedItem = buildMeetingHistoryItem(for: session.folderURL) {
                meetingHistory.insert(updatedItem, at: 0)
            }
        }
        closeBackendLog()
        closeTranscriptEventsLog()
        stopBackendAccess()
        isFinalizing = false
        isCapturing = false
        currentSession = nil
        activeScreen = .start
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
            title: session.folderURL.lastPathComponent,
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

    private func finalizeMeetingMetadata(for session: MeetingSession) {
        do {
            var metadata = try readMeetingMetadata(from: session.folderURL)
            let finalizedSegments = transcriptModel.segments.filter { !$0.isPartial }
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

    func applySpeakerMappings(_ mappings: [SpeakerIdentifier.SpeakerMapping], for meeting: MeetingHistoryItem) {
        var didUpdate = false
        let segmentIds = Set(transcriptModel.segments.map { $0.speakerID })
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
                targets.insert(rawId)
            }
            for target in targets {
                transcriptModel.renameSpeaker(id: target, to: trimmed)
                didUpdate = true
            }
        }
        guard didUpdate else { return }
        persistSpeakerNames(to: meeting.folderURL)
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
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = "\(meeting.title)-transcript.txt"
        panel.prompt = "Export"
        panel.message = "Export transcript as .txt (JSONL will be written alongside)."

        if panel.runModal() == .OK, let url = panel.url {
            let jsonlURL = url.deletingPathExtension().appendingPathExtension("jsonl")

            let transcriptURL = meeting.folderURL.appendingPathComponent("transcript.jsonl")
            if FileManager.default.fileExists(atPath: transcriptURL.path) {
                if let jsonlData = try? Data(contentsOf: transcriptURL) {
                    do {
                        try jsonlData.write(to: jsonlURL)
                    } catch {
                        appendBackendLog("Failed to export transcript JSONL: \(error.localizedDescription)", toTail: true)
                    }
                }
            } else {
                let jsonlString = transcriptModel.segments
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
                if let jsonlData = jsonlString.data(using: .utf8) {
                    do {
                        try jsonlData.write(to: jsonlURL)
                    } catch {
                        appendBackendLog("Failed to export transcript JSONL: \(error.localizedDescription)", toTail: true)
                    }
                }
            }

            let textString = transcriptModel.asPlainText()
            if let textData = textString.data(using: .utf8) {
                do {
                    try textData.write(to: url)
                } catch {
                    appendBackendLog("Failed to export transcript text: \(error.localizedDescription)", toTail: true)
                }
            } else {
                appendBackendLog("Failed to encode exported transcript text.", toTail: true)
            }
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
