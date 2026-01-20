# Spec: Mic Reimplementation with Hardware AEC

## Overview

Currently, mic audio is captured via ScreenCaptureKit alongside system audio. This works but lacks **Acoustic Echo Cancellation (AEC)** - when users have speakers on, the mic picks up whatever is being played through the speakers, resulting in duplicate transcriptions.

The current software-based echo suppression (fuzzy text matching in `TranscriptModel`) helps but isn't perfect. The proper fix is hardware-level AEC via `AVAudioEngine` with `VoiceProcessingIO`.

## Goal

Replace ScreenCaptureKit mic capture with a dedicated `MicEngine` using `AVAudioEngine` that has VoiceProcessingIO enabled. This gives us hardware-level AEC that subtracts speaker output from mic input in real-time.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          AppModel                                │
│                                                                 │
│  ┌─────────────────────┐          ┌─────────────────────┐      │
│  │    CaptureEngine    │          │      MicEngine      │      │
│  │  (ScreenCaptureKit) │          │   (AVAudioEngine)   │      │
│  │                     │          │                     │      │
│  │  • System audio     │          │  • Mic audio        │      │
│  │  • Screen capture   │          │  • VoiceProcessingIO│      │
│  │  • Thumbnails       │          │  • Hardware AEC     │      │
│  └─────────┬───────────┘          └─────────┬───────────┘      │
│            │                                │                   │
│            │ Float32 48kHz                  │ Float32 48kHz     │
│            ▼                                ▼                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              AudioConverterHelper                        │   │
│  │              (Float32 48kHz → Int16 16kHz)              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│                      BackendProcess                             │
│                      (muesli_backend.py)                        │
└─────────────────────────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: AudioConverterHelper

Create a new file `AudioConverterHelper.swift` with a reusable conversion function.

**File:** `MuesliApp/AudioConverterHelper.swift`

```swift
import AVFoundation
import Accelerate

enum AudioConverterHelper {
    /// Converts Float32 48kHz audio to Int16 16kHz for the backend
    /// - Parameters:
    ///   - buffer: Input AVAudioPCMBuffer (Float32, 48kHz expected)
    ///   - targetSampleRate: Output sample rate (default 16000)
    /// - Returns: Data containing Int16 samples, or nil if conversion fails
    static func convertToInt16(
        buffer: AVAudioPCMBuffer,
        targetSampleRate: Double = 16000
    ) -> Data? {
        guard let floatData = buffer.floatChannelData else { return nil }

        let sourceRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)

        // Take first channel (mono)
        let sourcePtr = floatData[0]

        // Calculate output frame count based on sample rate ratio
        let ratio = targetSampleRate / sourceRate
        let outputFrames = Int(Double(frameCount) * ratio)

        // Resample using vDSP
        var resampled = [Float](repeating: 0, count: outputFrames)

        if ratio == 1.0 {
            // No resampling needed - just copy
            resampled = Array(UnsafeBufferPointer(start: sourcePtr, count: frameCount))
        } else {
            // Linear interpolation resampling
            for i in 0..<outputFrames {
                let srcIndex = Double(i) / ratio
                let srcIndexFloor = Int(srcIndex)
                let frac = Float(srcIndex - Double(srcIndexFloor))

                if srcIndexFloor + 1 < frameCount {
                    resampled[i] = sourcePtr[srcIndexFloor] * (1 - frac) +
                                   sourcePtr[srcIndexFloor + 1] * frac
                } else if srcIndexFloor < frameCount {
                    resampled[i] = sourcePtr[srcIndexFloor]
                }
            }
        }

        // Convert Float32 [-1, 1] to Int16 [-32768, 32767]
        var int16Samples = [Int16](repeating: 0, count: outputFrames)

        // Clamp and scale
        for i in 0..<outputFrames {
            let clamped = max(-1.0, min(1.0, resampled[i]))
            int16Samples[i] = Int16(clamped * 32767)
        }

        // Convert to Data
        return int16Samples.withUnsafeBufferPointer { ptr in
            Data(buffer: ptr)
        }
    }
}
```

**Why this approach:**
- The backend expects Int16 16kHz mono audio
- AVAudioEngine gives us Float32 at the hardware's native rate (typically 48kHz)
- vDSP provides efficient SIMD operations for the conversion
- Linear interpolation is fast and good enough for speech

---

### Phase 2: MicEngine Actor

Create a new actor to handle mic capture with AEC enabled.

**File:** `MuesliApp/MicEngine.swift`

```swift
import AVFoundation

actor MicEngine {
    private var engine: AVAudioEngine?
    private var isRunning = false
    private var onAudioData: ((Data) -> Void)?

    /// Start capturing mic audio with AEC enabled
    /// - Parameter onAudioData: Callback receiving Int16 16kHz audio data
    func start(onAudioData: @escaping (Data) -> Void) throws {
        guard !isRunning else { return }

        self.onAudioData = onAudioData

        let engine = AVAudioEngine()
        self.engine = engine

        let inputNode = engine.inputNode

        // Enable Voice Processing (this enables AEC)
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            print("[MicEngine] Failed to enable voice processing: \(error)")
            // Continue anyway - mic will still work, just without AEC
        }

        // Get the native format - typically Float32 48kHz
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[MicEngine] Native format: \(nativeFormat)")

        // Install tap to receive audio buffers
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: nativeFormat
        ) { [weak self] buffer, time in
            Task { [weak self] in
                await self?.processBuffer(buffer)
            }
        }

        // Prepare and start
        engine.prepare()
        try engine.start()

        isRunning = true
        print("[MicEngine] Started with AEC enabled")
    }

    /// Stop capturing
    func stop() {
        guard isRunning else { return }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        onAudioData = nil

        print("[MicEngine] Stopped")
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let data = AudioConverterHelper.convertToInt16(buffer: buffer) else {
            return
        }
        onAudioData?(data)
    }
}
```

**Key points:**
- `setVoiceProcessingEnabled(true)` enables Apple's built-in AEC
- The tap runs on an internal audio thread, so we dispatch to actor for safety
- If voice processing fails (e.g., on a Mac without hardware support), we continue without AEC
- The engine gives us Float32 at native rate, we convert to Int16 16kHz

---

### Phase 3: Modify CaptureEngine

Remove mic handling from `CaptureEngine.swift` - it should only handle system audio and screen capture.

**Current state:** CaptureEngine uses ScreenCaptureKit's `captureMicrophone` feature (macOS 15+), which captures mic audio but without AEC.

**Specific removals in `CaptureEngine.swift`:**

1. **Remove mic config (line ~248-250):**
```swift
// DELETE these lines:
if #available(macOS 15.0, *) {
    config.captureMicrophone = true
}
```

2. **Remove mic stream output (line ~256-258):**
```swift
// DELETE these lines:
if #available(macOS 15.0, *) {
    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.mic"))
}
```

3. **Remove mic-related properties:**
```swift
// DELETE or simplify:
private var pendingMicAudio: [PendingAudio] = []  // DELETE
private var micSampleRate: Int?                    // DELETE
private var micChannelCount: Int?                  // DELETE
var micLevel: Float = 0                            // DELETE
var debugMicBuffers: Int = 0                       // DELETE
var debugMicFrames: Int = 0                        // DELETE
var debugMicPTS: Double = 0                        // DELETE
var debugMicFormat: String = "-"                   // DELETE
var debugMicErrorMessage: String = "-"             // DELETE
var debugMicErrors: Int = 0                        // DELETE
```

4. **Remove mic handling in `stream(_:didOutputSampleBuffer:of:)`:**
   - Remove all `type == .microphone` branches
   - Remove mic level updates
   - Remove mic pending audio buffering
   - Remove mic writer sends

5. **Simplify `AudioFormats` struct:**
```swift
// Change from:
struct AudioFormats {
    var systemSampleRate: Int?
    var systemChannels: Int?
    var micSampleRate: Int?
    var micChannels: Int?
    var isComplete: Bool { systemSampleRate != nil && micSampleRate != nil }
}

// To:
struct AudioFormats {
    var systemSampleRate: Int?
    var systemChannels: Int?
    var isComplete: Bool { systemSampleRate != nil }
}
```

6. **Simplify `waitForAudioFormats()` and `setAudioOutputEnabled()`:**
   - Remove mic-related pending audio flushing
   - Remove mic format detection

**Keep intact:**
- System audio capture (`type == .audio`)
- Screen capture (`type == .screen`) - even though we return early, we need the output for thumbnails
- Recording output (MP4 recording)
- All system audio debug properties

---

### Phase 4: Update AppModel Integration

Modify `AppModel.swift` to use both engines.

**Changes:**

1. **Add MicEngine property (near line ~112):**
```swift
private let captureEngine = CaptureEngine()
private var micEngine: MicEngine?  // NEW
```

2. **Update debug accessors (lines ~199-212):**

Since mic debug properties are moving from CaptureEngine to MicEngine, update the accessors:
```swift
// Keep system accessors pointing to captureEngine
var systemLevel: Float { captureEngine.systemLevel }
var debugSystemBuffers: Int { captureEngine.debugSystemBuffers }
// etc...

// Change mic accessors to use MicEngine (or provide defaults when nil)
var micLevel: Float { /* from micEngine or 0 */ }
var debugMicBuffers: Int { /* from micEngine or 0 */ }
// etc...
```

*Note: MicEngine may need matching debug properties, or these can be simplified/removed.*

3. **In `startRecording()` (around line ~915):**

```swift
// Start system audio capture via CaptureEngine (existing)
try await captureEngine.startCapture(
    contentFilter: filter,
    writer: writer,
    recordTo: recordURL
)

// Start mic capture via MicEngine if enabled (NEW)
if transcribeMic {
    micEngine = MicEngine()
    try await micEngine?.start { [weak self] audioData in
        guard let self else { return }
        Task { @MainActor in
            // MicEngine already converts to Int16 16kHz
            let ptsUs = self.calculateMicPtsUs()  // Need to track mic timing
            self.writer?.send(type: .audio, stream: .mic, ptsUs: ptsUs, payload: audioData)
        }
    }
}

// Update format detection (line ~921):
let formats = await captureEngine.waitForAudioFormats(timeoutSeconds: 2.0)
let systemSampleRate = formats.systemSampleRate ?? captureSampleRate
let systemChannels = formats.systemChannels ?? captureChannels
// Mic is now always 16kHz mono from AudioConverterHelper
let micSampleRate = 16000
let micChannels = 1
```

4. **In `stopMeeting()` (around line ~1001):**
```swift
func stopMeeting() async {
    guard isCapturing else { return }

    isFinalizing = true

    screenshotScheduler.stop()
    await captureEngine.stopCapture()

    // Stop mic engine (NEW)
    await micEngine?.stop()
    micEngine = nil

    writer?.sendSync(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
    // ... rest unchanged
}
```

5. **PTS timing for mic audio:**

The tricky part is calculating `ptsUs` for mic audio. Options:
- **Option A:** Track mic start time separately and compute elapsed time
- **Option B:** Use captureEngine's `meetingStartPTS` as reference (requires converting wall clock time)
- **Option C:** Simplify - mic PTS starts at 0 when MicEngine starts

Recommend Option A - store `micStartTime = Date()` when MicEngine starts, then:
```swift
let elapsed = Date().timeIntervalSince(micStartTime)
let ptsUs = Int64(elapsed * 1_000_000.0)
```

6. **Optional: Mid-recording mic toggle:**

If user can toggle `transcribeMic` while recording:
```swift
func setMicEnabled(_ enabled: Bool) async {
    if enabled && micEngine == nil {
        micEngine = MicEngine()
        try? await micEngine?.start { /* callback */ }
    } else if !enabled && micEngine != nil {
        await micEngine?.stop()
        micEngine = nil
    }
}
```

*This is optional for v1 - can require stopping recording to change mic setting.*

---

## Testing Plan

### Test 1: Basic Mic Capture
1. Start recording with mic enabled, system audio disabled
2. Speak into the mic
3. Verify transcripts appear with "mic" stream label
4. Verify audio quality is acceptable (16kHz is fine for speech)

### Test 2: AEC Effectiveness
1. Connect speakers (not headphones)
2. Start recording with both mic and system audio enabled
3. Play audio through speakers (e.g., a YouTube video)
4. Speak while audio is playing
5. Verify:
   - System audio transcribes correctly
   - Mic transcribes your speech
   - Mic does NOT transcribe the speaker audio (AEC working)
   - No duplicate transcriptions

### Test 3: Fallback Without AEC
1. If `setVoiceProcessingEnabled(true)` fails, verify:
   - Mic still captures audio
   - Warning is logged
   - Software echo suppression in TranscriptModel still helps

### Test 4: Start/Stop Cycles
1. Start recording
2. Stop recording
3. Repeat 5 times
4. Verify no resource leaks (check Activity Monitor for audio handles)

### Test 5: Mid-Recording Toggle
1. Start with only system audio
2. Enable mic mid-recording
3. Verify mic audio starts flowing
4. Disable mic mid-recording
5. Verify mic audio stops cleanly

---

## Files Changed

| File | Change |
|------|--------|
| `AudioConverterHelper.swift` | **NEW** - Conversion utility |
| `MicEngine.swift` | **NEW** - AVAudioEngine wrapper with AEC |
| `CaptureEngine.swift` | **MODIFY** - Remove mic handling |
| `AppModel.swift` | **MODIFY** - Integrate MicEngine |

---

## Notes

- **Entitlements:** The app already has microphone permission via entitlements (used by ScreenCaptureKit). AVAudioEngine uses the same permission, so no changes needed.

- **Sample Rate Mismatch:** The backend already handles per-stream sample rates via the protocol. Send `{"type":"config","stream":"mic","sample_rate":16000,"channels":1}` when mic starts.

- **Existing Echo Suppression:** Keep the software-based echo suppression in `TranscriptModel` as a backup. It catches anything that slips through hardware AEC.

- **VoiceProcessingIO on macOS:** This feature has been available since macOS 10.15. It's the same tech used by FaceTime and other Apple apps for AEC.

---

## Success Criteria

1. ✅ Mic audio captured via AVAudioEngine
2. ✅ Hardware AEC enabled (speaker audio not transcribed via mic)
3. ✅ No duplicate transcriptions when using speakers
4. ✅ Clean start/stop with no resource leaks
5. ✅ Works alongside existing system audio capture
