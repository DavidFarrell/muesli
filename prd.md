You are basically at “v0 works”, and the architecture is still very close to the original intent (ScreenCaptureKit for capture, Python backend over stdin/stdout, live transcript UI, speaker renaming, screenshot cadence). The main things I’d tidy now are about **data integrity**, **meeting lifecycle**, and a couple of **easy correctness fixes** that will bite you as soon as you use it more heavily.

Below is a straight review, with the smallest changes that buy the most stability and quality of life.

## How you compare to the original vision

### Where you’re on track

* **Onboarding + permission checking**: You have both onboarding and an always-available Permissions sheet. Good.
* **Core capture**: ScreenCaptureKit is doing system audio + microphone (macOS 15+), plus optional screenshots every 5 seconds, and an optional recording.mp4.
* **Live transcript**: You ingest JSONL from the backend and render it nicely, with partials.
* **Speaker naming**: You have both per-row rename and a Speakers sheet, and renames update historical lines because display is a mapping, not baked into each segment.
* **Audio meters**: You’ve got system + mic meters and a debug panel.

### Where you’ve drifted (or where gaps remain)

1. **Window capture vs “capture everything” audio**

   * Right now, if `sourceKind == .window`, you build `SCContentFilter(desktopIndependentWindow: window)`.
   * Apple’s docs are explicit that a content filter “limits an SCStream object’s output to only that matching your filter criteria” and that this initialiser “captures only the specified window”. ([Apple Developer][1])
     Translation: if you pick a window, you are very likely capturing only that app’s audio, not full system audio. That may or may not match what you want. If your intention is “always capture full computer audio”, the audio pipeline should not be tied to a window filter. (At minimum: warn users in the UI.)

2. **Data persistence**

   * Your UI transcript currently lives only in memory (TranscriptModel has no persistence).
   * Your backend, by default, **deletes system.wav and mic.wav at the end** unless `--keep-wav` is passed. In audio-only mode you can easily end up with no durable audio artefact.
   * If you crash, quit, or start a new meeting and later clear state, you can lose everything.

3. **Start/stop meeting robustness**

   * `stopMeeting()` currently calls `writer?.send(.meetingStop…)` and immediately does `backend?.stop()` which closes stdin and then terminates the process.
   * Because `FramedWriter.send` is async on a queue, you have a real risk that:

     * the meetingStop frame never makes it to the backend, and
     * the backend is killed before it finalises and emits the last segments.
       This is the single biggest “silent data loss” risk in the app as written.

4. **“Both streams” transcript correctness in the backend**

   * In `muesli_backend.py`, `TranscriptEmitter` keeps `_last_emitted_t1` and `_last_partial` as single values shared across streams.
   * If you transcribe both system + mic, the first stream to emit segments will push `_last_emitted_t1` forward and can prevent the other stream from ever emitting segments properly.
   * That will present as “it kind of works, but one stream looks empty or late” and will be confusing to debug.

5. **Capture configuration vs backend expectations**

   * CaptureEngine requests 48 kHz mono, and the backend then normalises using ffmpeg to 16 kHz mono every time it runs the pipeline.
   * ScreenCaptureKit supports sample rates of 8000, 16000, 24000, 48000. ([Apple Developer][2])
     So you could simplify by capturing at 16 kHz from the start (or at least avoid ffmpeg for the “live” path).

## Quick wins I would do next

### 1) Fix meeting stop so it is graceful and cannot lose the final transcript

Current behaviour risks cutting off final segments. Fix this before adding more features.

Minimum change set:

* Add a **synchronous** write path for meetingStop (and ideally meetingStart too).
* Close stdin to let the backend exit naturally.
* Wait for backend exit (with a timeout), then only if needed terminate.

#### Swift change: FramedWriter “sendSync” for control frames

Keep async for high-frequency audio, but make stop deterministic:

```swift
final class FramedWriter {
    private let handle: FileHandle
    private let writeQueue = DispatchQueue(label: "muesli.framed-writer")

    init(stdinHandle: FileHandle) { self.handle = stdinHandle }

    func send(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        writeQueue.async { self.writeFrame(type: type, stream: stream, ptsUs: ptsUs, payload: payload) }
    }

    func sendSync(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        writeQueue.sync { self.writeFrame(type: type, stream: stream, ptsUs: ptsUs, payload: payload) }
    }

    private func writeFrame(type: MsgType, stream: StreamID, ptsUs: Int64, payload: Data) {
        var header = Data()
        header.append(type.rawValue)
        header.append(stream.rawValue)

        var pts = ptsUs.littleEndian
        header.append(Data(bytes: &pts, count: 8))

        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: payload)
        } catch {
            // TODO: surface error to UI if needed
        }
    }

    func closeStdinAfterDraining() {
        writeQueue.sync { }
        try? handle.close()
    }
}
```

#### Swift change: BackendProcess stop should not terminate immediately

Add a graceful stop:

```swift
final class BackendProcess {
    // ...
    func requestGracefulStop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdinPipe.fileHandleForWriting.closeFile()
    }

    func forceTerminate() {
        if process.isRunning { process.terminate() }
    }

    func waitForExit(timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { cont in
            let deadline = DispatchTime.now() + timeoutSeconds
            process.terminationHandler = { _ in cont.resume(returning: true) }
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if self.process.isRunning {
                    cont.resume(returning: false)
                }
            }
        }
    }
}
```

Then in `stopMeeting()`:

```swift
func stopMeeting() async {
    guard isCapturing else { return }
    isFinalizing = true

    screenshotScheduler.stop()
    await captureEngine.stopCapture()

    // Make meetingStop reliable
    writer?.sendSync(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
    writer?.closeStdinAfterDraining()
    writer = nil

    // Let backend finalise
    backend?.requestGracefulStop()
    if let backend {
        let exited = await backend.waitForExit(timeoutSeconds: 20)
        if !exited { backend.forceTerminate() }
    }
    backend = nil

    closeBackendLog()
    stopBackendAccess()

    isCapturing = false
    isFinalizing = false
    currentSession = nil
}
```

This is the difference between “works in demos” and “I trust it in real meetings”.

### 2) Make meeting folders and meeting titles collision-proof

Right now, `createMeetingFolder(title:)` will fail if a folder with that title already exists. That will happen constantly with the default yyyy-mm-dd-meeting.

Easy fix: if folder exists, suffix `-01`, `-02`, etc, and update the session title to match the actual folder created.

```swift
private func createMeetingFolder(title: String) throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Muesli", isDirectory: true)
        .appendingPathComponent("Meetings", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

    var folder = base.appendingPathComponent(title, isDirectory: true)
    var i = 1
    while FileManager.default.fileExists(atPath: folder.path) {
        folder = base.appendingPathComponent("\(title)-\(String(format: "%02d", i))", isDirectory: true)
        i += 1
    }

    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // write meta.json as you do now
    return folder
}
```

### 3) Add “Copy transcript” and “Export transcript” (very low effort)

You already have text selection per segment, but copying the whole transcript is a very normal need.

Add this to the Controls group in `SessionView`:

```swift
Button("Copy transcript") {
    let text = model.transcriptModel.asPlainText()
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
}
```

Then implement:

```swift
extension TranscriptModel {
    func asPlainText(includePartials: Bool = false) -> String {
        segments
            .filter { includePartials || !$0.isPartial }
            .map { seg in
                let name = displayName(for: seg.speakerID)
                let stream = seg.stream == "unknown" ? "" : "[\(seg.stream)] "
                return "\(stream)t=\(String(format: "%.2f", seg.t0))s \(name): \(seg.text)"
            }
            .joined(separator: "\n")
    }
}
```

Export is just:

```swift
Button("Export transcript.txt") {
    guard let folder = model.currentSession?.folderURL else { return }
    let url = folder.appendingPathComponent("transcript.txt")
    try? model.transcriptModel.asPlainText().write(to: url, atomically: true, encoding: .utf8)
}
```

Also add a button:

```swift
Button("Open folder") {
    if let folder = model.currentSession?.folderURL {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
```

### 4) Reset transcript state cleanly between meetings

At the moment, there is no clear reset call, which makes “start a new meeting” risky.

I’d do:

* On meeting start: `transcriptModel.segments.removeAll()` and optionally clear speaker names or keep them.
* On meeting stop: do not wipe immediately, but write transcript to disk (see next), then return to NewMeetingView and reset the title.

Minimum:

```swift
transcriptModel.segments.removeAll()
```

Better: have a `transcriptModel.reset(forNewMeeting:)` that decides whether speaker names carry over.

### 5) Persist the transcript to disk (so you never lose it)

This is the biggest quality of life improvement after graceful stop.

Simplest: in `createMeetingFolder`, create `transcript.jsonl`, open a file handle, and append each backend JSON line to it in `handleBackendJSONLine`.

That gives you:

* crash resilience
* ability to re-open and review old meetings later
* a clear interchange format for your diarisation tooling

### 6) Fix the backend “both streams” emitter bug

If you are going to keep `--transcribe-stream both`, fix `TranscriptEmitter` state to be per-stream.

Minimal patch concept:

```python
class TranscriptEmitter:
    def __init__(...):
        self._last_emitted_t1_by_stream = {}
        self._last_partial_by_stream = {}
        # keep _seen_speakers global if you like

    def emit_transcript(..., stream_name=None):
        key = stream_name or "default"
        last_emitted = self._last_emitted_t1_by_stream.get(key, 0.0)
        last_partial = self._last_partial_by_stream.get(key)

        # use last_emitted in your checks
        # update self._last_emitted_t1_by_stream[key] at the end
        # update self._last_partial_by_stream[key] for partials
```

Without this, your default UI state (both toggles on) is likely to produce confusing behaviour.

### 7) Stop deleting your audio artefacts by default (or at least don’t in audio-only mode)

Right now the backend removes `system.wav` and `mic.wav` unless `--keep-wav` is set.

Easy fix without touching backend logic:

* In Swift, add `--keep-wav` to the backend command by default.

```swift
let command = [
  backendPython, "-m", "diarise_transcribe.muesli_backend",
  "--emit-meters",
  "--transcribe-stream", transcribeStream,
  "--keep-wav",
  "--output-dir", audioDir.path
]
```

If you later decide you truly never want the WAVs, you can revert, but while you are iterating, keeping them is extremely useful.

### 8) Validate your audio filtering behaviour in the UI

Because SCContentFilter constrains what the stream outputs, a window capture mode is likely to constrain audio too. ([Apple Developer][1])

Two low-effort options:

* Add UI copy: “Window mode may only capture that app’s audio. Use Display mode to capture all system audio.”
* Or: add a toggle “Audio source: Full system (recommended) / Only selected content” and implement full system later.

## Small code-quality tidy-ups that are worth doing now

These are “keep the project healthy” changes that are not dramatic.

1. **Deduplicate sample rate and channels constants**

   * AppModel has `captureSampleRate`, CaptureEngine has `sampleRate`.
   * Pick one source of truth and pass it through.

2. **AudioSampleExtractor: make AudioBufferList allocation robust**

   * You currently pass `bufferListSize: MemoryLayout<AudioBufferList>.size` which is only safe for a single buffer configuration.
   * If you ever receive multi-buffer (for example non-interleaved), this can fail or misbehave.
   * Fix by first asking for `bufferListSizeNeededOut` and allocating that size.

3. **ScreenshotScheduler: prevent overlapping screenshots**

   * Right now you can trigger a new capture every 5 seconds regardless of whether the last capture finished.
   * Add an `inFlight` flag so you skip if one is running.

4. **Backend folder picker defaults**

   * `defaultBackendProjectRoot` is hard-coded to your machine path. That will confuse future you and any other engineer.
   * Replace with something like:

     * last-selected folder
     * user’s home directory
     * Application Support

5. **resolveBackendPython does not match the error enum**

   * You have errors for venvOutside and venvNotExecutable but you only ever emit venvMissing.
   * Either simplify the enum or implement the real checks (including resolving symlinks).

## A simple “sanity check” test list (use this every time you change something)

These are quick manual tests that catch 90 percent of regressions:

1. **Capture pipeline**

   * Start meeting (Display mode).
   * Play system audio (YouTube) and speak into mic.
   * Confirm both meters move.

2. **Window mode audio scope**

   * Start meeting (Window mode) targeting a window.
   * Play audio from a different app.
   * Confirm whether it is captured or not (this tells you how content filter affects your audio in practice). ([Apple Developer][1])

3. **Stop finalises**

   * Speak a sentence right before pressing Stop.
   * Confirm that sentence appears in transcript after stop and that backend exits cleanly (no forced terminate).

4. **Artefacts exist**

   * After stop: meeting folder contains transcript export, screenshots (if video), audio files or recording.mp4.

5. **Multiple meetings**

   * Start meeting, stop.
   * Start a new meeting immediately.
   * Confirm:

     * transcript resets for the new meeting
     * previous meeting transcript is still accessible on disk
     * folder naming does not collide



[1]: https://developer.apple.com/documentation/screencapturekit/sccontentfilter?utm_source=chatgpt.com "SCContentFilter | Apple Developer Documentation"
[2]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate?utm_source=chatgpt.com "sampleRate | Apple Developer Documentation"
