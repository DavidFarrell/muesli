Doing well, thanks.

Below is a complete, engineer-ready design for **Muesli**: a macOS app that captures **system audio + microphone**, optionally records **screen video**, and produces **timestamped screenshots every 5 seconds**, while streaming live audio to your existing local transcription and diarisation pipeline and showing a live transcript UI.

I’m going to assume **macOS 15+** as the primary target because it materially simplifies “system + mic” capture in one pipeline and supports first-class recording output to file. Where it matters, I’ll note fallbacks for macOS 14.

---

## 1. Key capture approach and trade-offs

### Why ScreenCaptureKit is the correct foundation for your requirements

You want screen access (not just audio), and you want selection of display/window/area with a polished OS-native UX. **ScreenCaptureKit** is Apple’s intended, supported framework for high-performance capture of **screen + audio** on macOS. ([Apple Developer][1])

It gives you:

* **System audio capture** as audio sample buffers (no virtual audio devices).
* **Screen frames** and metadata from the same capture session.
* A system-provided **content picker** that matches user expectations and helps avoid scary prompts related to bypassing OS privacy UI. ([Apple Developer][2])

### Trade-offs you must accept with ScreenCaptureKit

* **Permissions UX**: You will need Screen Recording permission (and mic permission). Apple does not provide a dedicated Info.plist “purpose string” key for screen recording, so your onboarding screen must explain it clearly. ([Stack Overflow][3])
* **macOS 15 prompt recurrence**: macOS Sequoia introduced periodic re-confirmation prompts for screen recording permissions (reported as monthly in release builds). Build onboarding and “permission health checks” assuming permissions may need re-confirming. ([TidBITS][4])

### Why not a pure browser web app

A browser-only approach cannot reliably deliver:

* Whole-system audio capture on macOS with predictable behaviour
* Cross-app window capture and OS-native picker integration
* Robust permission onboarding and health checks

If you want a “web UI”, the practical solution is **hybrid**: native capture helper + local web UI. For speed and polish, I recommend **native SwiftUI UI** first, then optionally embed a web UI later.

---

## 2. What Muesli should produce

For each meeting, create a folder like:

```
~/Library/Application Support/Muesli/Meetings/
  2026-01-18-meeting/
    meta.json
    recording.mp4                (video mode, optional)
    audio/
      system.pcm                 (live stream capture dump, optional)
      mic.pcm
    screenshots/
      t+0000.000.png
      t+0005.000.png
      t+0010.000.png
    transcript.jsonl             (append-only events)
```

**Timestamp convention**: everything is keyed to **seconds since meeting start** (t+…). Your diariser can map “speaker changed at 35s” to `t+0035.000.png`, etc.

---

## 3. Architecture overview

### High-level component diagram

```text
+-------------------+                 +---------------------------+
|     Muesli.app     |                 |   Local ASR/Diarisation   |
| (SwiftUI + SCK)    |                 |  (your existing system)   |
+-------------------+                 +---------------------------+
| - Onboarding       |  framed stdin   | - Ingest audio streams    |
| - Meeting manager  |---------------> | - Consume screenshots      |
| - Source picker    |                 | - Transcribe + diarise     |
| - Capture engine   |  JSONL stdout   | - Emit transcript events   |
| - Screenshot timer |<--------------- |                           |
| - Transcript UI    |                 +---------------------------+
+-------------------+
        |
        | files (screenshots, meta, optional mp4)
        v
  Meeting folder on disk
```

### Capture pipeline diagram

```text
SCContentSharingPicker (user selects display/window)  :contentReference[oaicite:4]{index=4}
                |
                v
          SCContentFilter
                |
                v
          SCStreamConfiguration
   - capturesAudio = true  :contentReference[oaicite:5]{index=5}
   - sampleRate = 48000    :contentReference[oaicite:6]{index=6}
   - channelCount = 1      :contentReference[oaicite:7]{index=7}
   - excludesCurrentProcessAudio = true :contentReference[oaicite:8]{index=8}
   - captureMicrophone = true (macOS 15+) :contentReference[oaicite:9]{index=9}
                |
                v
              SCStream
        |                     |
        |                     +-----------------------------+
        |                                                   |
audio buffers (.audio)                         mic buffers (.microphone)
(sampleBuffer -> AudioBufferList)              (sampleBuffer -> AudioBufferList)
:contentReference[oaicite:10]{index=10}
        |
        v
PCM conversion + timestamps from PTS
(PTS timebase: stream.synchronizationClock) :contentReference[oaicite:11]{index=11}
        |
        v
Framed stream to backend + level meters in UI
```

---

## 4. Implementation plan (defensive, test-driven stages)

### Stage A: Project skeleton and meeting model

* SwiftUI app with screens:

  * Welcome / permissions
  * New meeting (title default `yyyy-mm-dd-meeting`)
  * Source selection (video mode default on)
  * Live session view: meters + transcript + speaker rename

**Tests**

* Unit test meeting folder naming and timestamp formatting.

### Stage B: Permissions and onboarding (must be excellent)

You need to manage:

* Screen Recording permission (ScreenCaptureKit will trigger the system flow; Apple’s sample explicitly notes the first run triggers Screen Recording permission). ([Apple Developer][5])
* Microphone permission (standard AVFoundation flow; must include `NSMicrophoneUsageDescription` or the OS can terminate access flows). ([Apple Developer][6])

Also, macOS 15 can re-prompt periodically; add a “Permission status” panel that can be opened any time. ([TidBITS][4])

**Tests**

* Manual: deny permissions, confirm app shows clear steps and a “Re-check” button.
* Manual: grant permissions, confirm app detects and proceeds.
* Manual (macOS 15): after an OS re-confirmation prompt appears, confirm Muesli recovers cleanly.

### Stage C: Source picker + filter creation

Use **SCContentSharingPicker** (system UI). ([Apple Developer][2])
This reduces your work and aligns with Apple’s direction as privacy prompts tighten. ([Apple Developer][7])

Support:

* Entire screen (single display)
* Window
* Dedicated area (implemented as display + `sourceRect` crop) ([Apple Developer][8])
* “Tab” is not a first-class ScreenCaptureKit concept. Workaround: user “moves tab to new window” and selects that window.

**Tests**

* Integration: select a window, confirm you receive frames or can screenshot it.
* Integration: region crop produces images of the expected area.

### Stage D: Audio capture + live level meters

Configure:

* `capturesAudio = true` ([Apple Developer][9])
* `sampleRate = 48000` ([Apple Developer][10])
* `channelCount = 1` (mono) ([Apple Developer][11])
* `excludesCurrentProcessAudio = true` (avoid Muesli’s own UI sounds contaminating). ([Apple Developer][12])
* `captureMicrophone = true` on macOS 15+. ([Apple Developer][13])

Audio sample buffers wrap an `AudioBufferList` and are controlled by your sample rate / channel count. ([Apple Developer][14])

**Tests**

* Automated-ish: play a 1 kHz tone through speakers, confirm system meter responds and captured RMS exceeds threshold.
* Manual: talk, confirm mic meter responds.
* Behaviour test: change system volume, see if captured amplitude changes (document outcome for your diariser).

### Stage E: Screenshots every 5 seconds with accurate timestamps

Best practical method:

* Use `SCScreenshotManager.captureSampleBuffer(contentFilter:configuration:...)` (macOS 14+). ([Apple Developer][15])
* Extract the sample buffer’s presentation timestamp and compute `t+seconds`. `CMSampleBuffer.presentationTimestamp` is the right API for this. ([Apple Developer][16])
* Convert image buffer to PNG and save: `screenshots/t+0035.000.png`

**Tests**

* Confirm screenshot cadence is correct even under load.
* Confirm filenames are monotonic and match approximate on-screen changes.

### Stage F: Stream to your backend and display transcript

* Muesli spawns your backend process (Python) locally.
* Muesli streams framed audio messages to backend stdin.
* Backend emits transcript events (JSON Lines) to stdout.
* Muesli parses JSONL and updates UI.

**Tests**

* Run a “fake backend” that returns deterministic transcript segments; verify UI rendering, scrolling, renaming and historical updates.

---

## 5. Concrete IPC protocol (simple and robust)

Use a binary framing protocol for audio (fast, no JSON overhead), and JSONL for transcript coming back.

### Muesli -> backend (stdin): framed messages

Header (fixed 1 + 1 + 8 + 4 = 14 bytes):

* `uint8` message_type
* `uint8` stream_id (0 = system, 1 = mic)
* `int64` pts_us (microseconds since meeting start)
* `uint32` payload_len
* `payload` bytes

Message types:

* `1` = PCM audio chunk (payload = int16 little-endian, mono, 48 kHz)
* `2` = Screenshot event (payload = UTF-8 JSON: `{ "t": 35.0, "path": "screenshots/t+0035.000.png" }`)
* `3` = Meeting start metadata (payload JSON: `{ "title": "...", "start_wall_time": "...", "sample_rate": 48000 }`)
* `4` = Meeting stop

### Backend -> Muesli (stdout): JSON Lines

Each line is a complete JSON object, for example:

```json
{"type":"segment","speaker":"Speaker 00","speaker_id":"spk0","t0":12.34,"t1":15.20,"text":"Hello everyone..."}
{"type":"partial","speaker_id":"spk1","t0":16.00,"text":"I think we should..."}
{"type":"speakers","known":[{"speaker_id":"spk0","name":"Speaker 00"},{"speaker_id":"spk1","name":"Speaker 01"}]}
```

Muesli maps `speaker_id -> display name` and updates historical rendering when names change.

---

## 6. Reference code: Swift (capture engine + permissions + framing)

Below is a working-quality skeleton that an engineer can drop into a SwiftUI macOS app target.

### 6.1 Info.plist and entitlements

**Info.plist**

* `NSMicrophoneUsageDescription`: explain why mic is needed. ([Apple Developer][6])
  There is no equivalent purpose-string key for screen recording; do that explanation in your onboarding UI. ([Stack Overflow][3])

**Sandbox entitlements (if sandboxed)**

* Audio input entitlement enabled (Xcode capability) for microphone access.

### 6.2 Permission checks (onboarding)

```swift
import Foundation
import AVFoundation
import CoreGraphics

enum PermissionState {
    case authorised
    case denied
    case notDetermined
}

struct Permissions {

    static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorised
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // Screen recording preflight and request use CoreGraphics.
    // Apple documents/mentions these functions in developer contexts; they are commonly used
    // to avoid surprising system prompts. :contentReference[oaicite:28]{index=28}
    static func screenCapturePreflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
```

### 6.3 Audio extraction: CMSampleBuffer -> int16 mono PCM

This is the core “no gaps” piece. It handles float32 or int16 PCM and always outputs int16 mono.

```swift
import Foundation
import CoreMedia
import AudioToolbox

enum AudioExtractError: Error {
    case missingFormat
    case unsupportedFormat
    case failedToGetBufferList(OSStatus)
}

struct PCMChunk {
    let pts: CMTime
    let data: Data              // int16 mono little-endian
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

        // Pull AudioBufferList out of CMSampleBuffer
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 0,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )

        var dataPointer: UnsafeMutableAudioBufferListPointer?

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

        dataPointer = UnsafeMutableAudioBufferListPointer(&audioBufferList)

        let pts = sampleBuffer.presentationTimeStamp  // :contentReference[oaicite:29]{index=29}
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)

        // Determine sample type
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        // We requested channelCount=1 in SCStreamConfiguration, so expect mono.
        // Still handle >1 buffers defensively.
        let bufferCount = Int(dataPointer?.count ?? 0)
        if bufferCount < 1 {
            throw AudioExtractError.unsupportedFormat
        }

        // Collect per-channel float samples (normalised) then downmix if needed.
        // Output: int16 mono.
        var mono = [Float](repeating: 0, count: frames)

        for b in 0..<bufferCount {
            guard let mData = dataPointer?[b].mData else { continue }
            let byteSize = Int(dataPointer?[b].mDataByteSize ?? 0)

            if isFloat && bitsPerChannel == 32 {
                let count = min(frames, byteSize / MemoryLayout<Float>.size)
                let floats = mData.bindMemory(to: Float.self, capacity: count)
                for i in 0..<count {
                    mono[i] += floats[i]
                }
            } else if isSignedInt && bitsPerChannel == 16 {
                let count = min(frames, byteSize / MemoryLayout<Int16>.size)
                let ints = mData.bindMemory(to: Int16.self, capacity: count)
                for i in 0..<count {
                    mono[i] += Float(ints[i]) / 32768.0
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
```

### 6.4 Framing writer (to backend stdin)

```swift
import Foundation
import CoreMedia

enum StreamID: UInt8 { case system = 0, mic = 1 }
enum MsgType: UInt8 { case audio = 1, screenshotEvent = 2, meetingStart = 3, meetingStop = 4 }

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
                // In production: surface this to UI and stop capture cleanly.
                // Do not block capture callback threads.
            }
        }
    }
}
```

### 6.5 ScreenCaptureKit stream setup (audio + mic + optional recording)

Key points:

* `capturesAudio` must be set true. ([Apple Developer][9])
* Supported sample rates include 48000. ([Apple Developer][10])
* Supported channel counts are 1 or 2. ([Apple Developer][11])
* `captureMicrophone` exists on macOS 15+. ([Apple Developer][13])
* You can record a stream to file on macOS 15+ using `SCRecordingOutput` and an output URL. ([Apple Developer][17])
* Sample buffer timestamps share the stream’s synchronisation clock timebase. ([Apple Developer][18])

```swift
import Foundation
import ScreenCaptureKit
import CoreMedia

@MainActor
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?

    private let extractor = AudioSampleExtractor()

    private var meetingStartPTS: CMTime?
    private var writer: FramedWriter?

    // Level meters (0..1)
    var systemLevel: Float = 0
    var micLevel: Float = 0

    // Provide a callback for UI updates
    var onLevelsUpdated: (() -> Void)?

    func startCapture(
        contentFilter: SCContentFilter,
        meetingMetaJSON: Data,
        backendStdin: FileHandle,
        recordTo url: URL?
    ) async throws {

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true  // :contentReference[oaicite:36]{index=36}

        if #available(macOS 15.0, *) {
            config.captureMicrophone = true  // :contentReference[oaicite:37]{index=37}
        }

        // If you need a dedicated area (crop), set config.sourceRect.
        // This applies to display capture, not single-window capture. :contentReference[oaicite:38]{index=38}
        // config.sourceRect = yourRect

        let stream = SCStream(filter: contentFilter, configuration: config, delegate: self) // :contentReference[oaicite:39]{index=39}
        self.stream = stream

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.system"))
        if #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "muesli.audio.mic"))
        }

        self.writer = FramedWriter(stdinHandle: backendStdin)
        self.writer?.send(type: .meetingStart, stream: .system, ptsUs: 0, payload: meetingMetaJSON)

        if #available(macOS 15.0, *), let recordURL = url {
            let roConfig = SCRecordingOutputConfiguration()
            roConfig.outputURL = recordURL
            roConfig.outputFileType = .mp4
            // roConfig.videoCodecType = .hevc (optional)
            let ro = SCRecordingOutput(configuration: roConfig, delegate: nil)
            try stream.addRecordingOutput(ro)
            self.recordingOutput = ro
        }

        try await withCheckedThrowingContinuation { cont in
            stream.startCapture { error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: ()) }
            }
        }
    }

    func stopCapture() async {
        guard let stream else { return }

        await withCheckedContinuation { cont in
            stream.stopCapture { _ in cont.resume() }
        }

        self.writer?.send(type: .meetingStop, stream: .system, ptsUs: 0, payload: Data())
        self.stream = nil
        self.recordingOutput = nil
        self.writer = nil
        self.meetingStartPTS = nil
    }

    // SCStreamOutput callback
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        do {
            let pcm = try extractor.extractInt16Mono(from: sampleBuffer)

            // Define meeting start as first received buffer PTS
            if meetingStartPTS == nil {
                meetingStartPTS = pcm.pts
            }
            guard let start = meetingStartPTS else { return }

            let delta = CMTimeSubtract(pcm.pts, start)
            let seconds = CMTimeGetSeconds(delta)
            let ptsUs = Int64(seconds * 1_000_000.0)

            let level = rmsLevelInt16(pcm.data)
            DispatchQueue.main.async {
                if type == .audio {
                    self.systemLevel = level
                } else if #available(macOS 15.0, *), type == .microphone {
                    self.micLevel = level
                }
                self.onLevelsUpdated?()
            }

            if type == .audio {
                writer?.send(type: .audio, stream: .system, ptsUs: ptsUs, payload: pcm.data)
            } else if #available(macOS 15.0, *), type == .microphone {
                writer?.send(type: .audio, stream: .mic, ptsUs: ptsUs, payload: pcm.data)
            }
        } catch {
            // In production: log and continue, but count failures and surface if sustained.
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
}
```

---

## 7. Reference code: periodic screenshots every 5 seconds

Use `SCScreenshotManager.captureSampleBuffer(contentFilter:configuration:...)` (macOS 14+). ([Apple Developer][15])

This gives you a `CMSampleBuffer` so you can extract a presentation timestamp (for accurate `t+...` naming). ([Apple Developer][16])

Skeleton:

```swift
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers

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
        t.setEventHandler {
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
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
    }
}
```

---

## 8. Python runnable backend demo (reads framed stdin, writes WAV, prints meters)

This is intentionally minimal and “out of the box”. It proves the ingest and timestamping are correct, and gives you a starting point to plug in your existing pipeline.

Save as `muesli_backend_demo.py`:

```python
import sys
import json
import struct
import wave
from dataclasses import dataclass
from typing import BinaryIO, Optional

MSG_AUDIO = 1
MSG_SCREENSHOT_EVENT = 2
MSG_MEETING_START = 3
MSG_MEETING_STOP = 4

STREAM_SYSTEM = 0
STREAM_MIC = 1

HDR_STRUCT = struct.Struct("<BBqI")  # type, stream, pts_us, payload_len


@dataclass
class Meeting:
    sample_rate: int = 48000
    channels: int = 1
    system_wav: Optional[wave.Wave_write] = None
    mic_wav: Optional[wave.Wave_write] = None


def read_exact(f: BinaryIO, n: int) -> bytes:
    b = f.read(n)
    if len(b) != n:
        raise EOFError
    return b


def rms_int16(pcm: bytes) -> float:
    if len(pcm) < 2:
        return 0.0
    count = len(pcm) // 2
    ints = struct.unpack("<" + "h" * count, pcm)
    acc = 0.0
    for v in ints:
        x = v / 32768.0
        acc += x * x
    return (acc / count) ** 0.5


def open_wav(path: str, sr: int, ch: int) -> wave.Wave_write:
    w = wave.open(path, "wb")
    w.setnchannels(ch)
    w.setsampwidth(2)  # int16
    w.setframerate(sr)
    return w


def emit_jsonl(obj: dict):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    meeting = Meeting()
    stdin = sys.stdin.buffer

    while True:
        try:
            hdr = read_exact(stdin, HDR_STRUCT.size)
        except EOFError:
            break

        msg_type, stream_id, pts_us, payload_len = HDR_STRUCT.unpack(hdr)
        payload = read_exact(stdin, payload_len) if payload_len else b""

        if msg_type == MSG_MEETING_START:
            meta = json.loads(payload.decode("utf-8"))
            meeting.sample_rate = int(meta.get("sample_rate", 48000))
            meeting.channels = int(meta.get("channels", 1))

            meeting.system_wav = open_wav("system.wav", meeting.sample_rate, meeting.channels)
            meeting.mic_wav = open_wav("mic.wav", meeting.sample_rate, meeting.channels)

            emit_jsonl({"type": "status", "message": "meeting_started", "meta": meta})

        elif msg_type == MSG_AUDIO:
            t = pts_us / 1_000_000.0
            level = rms_int16(payload)

            if stream_id == STREAM_SYSTEM and meeting.system_wav:
                meeting.system_wav.writeframes(payload)
                emit_jsonl({"type": "meter", "stream": "system", "t": t, "rms": level})

            elif stream_id == STREAM_MIC and meeting.mic_wav:
                meeting.mic_wav.writeframes(payload)
                emit_jsonl({"type": "meter", "stream": "mic", "t": t, "rms": level})

            # Demo transcript stub (replace with your ASR)
            if int(t) % 10 == 0 and abs(t - round(t)) < 0.02:
                emit_jsonl({"type": "partial", "speaker_id": "spk0", "t0": t, "text": f"(demo) audio at {t:.1f}s"})

        elif msg_type == MSG_SCREENSHOT_EVENT:
            evt = json.loads(payload.decode("utf-8"))
            emit_jsonl({"type": "screenshot", **evt})

        elif msg_type == MSG_MEETING_STOP:
            emit_jsonl({"type": "status", "message": "meeting_stopped"})
            break

    if meeting.system_wav:
        meeting.system_wav.close()
    if meeting.mic_wav:
        meeting.mic_wav.close()


if __name__ == "__main__":
    main()
```

What this demo proves quickly:

* You are receiving **two independent PCM streams** with timestamps
* You can compute meters and emit live events
* You can write WAVs for inspection (open with any player)

---

## 9. Transcript UI and speaker renaming (SwiftUI approach)

### Data model

* Store transcript segments with immutable speaker IDs.
* Render using a mapping `speakerID -> displayName`.
* When user renames a speaker, update the mapping only. Historic rendering updates automatically.

Skeleton:

```swift
import Foundation

struct TranscriptSegment: Identifiable {
    let id = UUID()
    let speakerID: String
    let t0: Double
    let t1: Double?
    let text: String
}

@MainActor
final class TranscriptModel: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var speakerNames: [String: String] = [:]  // speakerID -> display name

    func displayName(for speakerID: String) -> String {
        speakerNames[speakerID] ?? speakerID
    }

    func renameSpeaker(id: String, to name: String) {
        speakerNames[id] = name
    }

    func ingest(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        if type == "segment" || type == "partial" {
            let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
            let t0 = (obj["t0"] as? Double) ?? 0
            let t1 = obj["t1"] as? Double
            let text = (obj["text"] as? String) ?? ""
            segments.append(.init(speakerID: speakerID, t0: t0, t1: t1, text: text))
        }
    }
}
```

### UI behaviour requirements you listed

* Scrollable transcript view
* Rename dialog for speakers
* Past transcript entries update when renamed (achieved by mapping)

This is straightforward once transcript events are flowing.

---

## 10. Key engineering pitfalls and how to design around them

### A. Don’t bypass the system picker

macOS 15 introduced scarier alerts around bypassing privacy UI for content capture. Use `SCContentSharingPicker` rather than rolling your own picker wherever possible. ([Apple Developer][2])

### B. Treat screen recording permission as “might be revoked or re-confirmed”

Build an always-available “Permission health” screen and detect failure to start capture cleanly. macOS 15’s recurring prompts make this non-optional for a polished experience. ([TidBITS][4])

### C. Timestamp correctness

* Base everything on the **same timebase**:

  * Use `CMSampleBuffer.presentationTimeStamp` for audio and screenshots. ([Apple Developer][16])
  * ScreenCaptureKit provides a `synchronizationClock` that defines the timebase for its sample buffers. ([Apple Developer][18])
* Define “meeting start” as the PTS of the **first audio sample buffer** you accept. That makes downstream alignment deterministic.

### D. Capture “tab”

A browser tab isn’t a stable OS-level entity here. The best UX is:

* User selects **window**, or
* User “moves tab to new window” then selects that window

### E. Video mode without giant CPU usage

You don’t need 60 fps screen recording for diarisation screenshots every 5 seconds.

* Use screenshots for diarisation.
* Optionally record an mp4 to disk in macOS 15+ with `SCRecordingOutput` for a “forensics / backup” artefact. ([Apple Developer][17])

---

## 11. Test plan (defensive milestones)

These tests are written to catch the failures that waste weeks in macOS capture projects.

### Milestone 1: Permissions

**Manual tests**

1. Fresh install, click “Start meeting”:

   * App shows onboarding.
   * User denies screen recording: app detects and shows System Settings path.
2. Grant permissions:

   * App detects granted state and proceeds.
3. Restart behaviour:

   * Confirm the app explains if restart is needed (some permission changes can require it depending on OS/app state).

### Milestone 2: Audio capture integrity

**Repeatable test**

* Play a known tone file (1 kHz) for 10 seconds.
* Assertions:

  * System stream produces non-zero RMS for that period.
  * Mic stream stays near noise floor if you stay silent.
  * Confirm sample rate is 48000 and mono. ([Apple Developer][10])

### Milestone 3: Excluding self-audio

* With `excludesCurrentProcessAudio = true`, play a sound inside Muesli (button click or short wav).
* Assert it does not appear in the system capture (or is significantly reduced). ([Apple Developer][12])

### Milestone 4: Screenshot cadence and naming

* Run capture for 30 seconds.
* Assert:

  * 6 screenshots exist at approx `t+0005`, `t+0010`, … `t+0030`
  * Filenames monotonic and parseable.

### Milestone 5: IPC correctness

* Run with `muesli_backend_demo.py`
* Assert:

  * WAV files play correctly
  * JSONL meter events are emitted continuously
  * Screenshot events arrive with correct paths and `t`

### Milestone 6: Transcript UI correctness

* Use a fake backend that emits:

  * 2 speakers, interleaved segments
* Assert:

  * UI shows segments
  * Rename speaker updates all prior segments immediately
  * Scroll behaviour stays stable (auto-scroll only if user is at bottom)

---

## 12. Recommended baseline and fallbacks

### Baseline recommendation

* **macOS 15+ only** for V1.

  * Simplifies mic capture (`captureMicrophone`) ([Apple Developer][13])
  * Enables native record-to-file via `SCRecordingOutput` ([Apple Developer][17])
  * Lets you focus on product UX and backend integration rather than clock drift and multi-framework alignment.

### Fallback if you must support macOS 14

* System audio: ScreenCaptureKit
* Microphone: AVAudioEngine
* Timestamps: align both to host time and accept small drift, or resample in backend

(Doable, but more engineering and more “edge bug” risk.)

---


[1]: https://developer.apple.com/documentation/screencapturekit?utm_source=chatgpt.com "ScreenCaptureKit | Apple Developer Documentation"
[2]: https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker?utm_source=chatgpt.com "SCContentSharingPicker | Apple Developer Documentation"
[3]: https://stackoverflow.com/questions/62641652/is-there-an-info-plist-key-privacy-usage-description-for-screen-recordin "Is there an Info.plist key \"Privacy - ... Usage Description\" for screen recording in macOS? - Stack Overflow"
[4]: https://tidbits.com/2024/09/23/how-to-avoid-sequoias-repetitive-screen-recording-permissions-prompts/?utm_source=chatgpt.com "How to Avoid Sequoia’s Repetitive Screen Recording Permissions Prompts"
[5]: https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos?utm_source=chatgpt.com "Capturing screen content in macOS - Apple Developer"
[6]: https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media?utm_source=chatgpt.com "Requesting authorization to capture and save media"
[7]: https://developer.apple.com/forums/thread/760483?utm_source=chatgpt.com "Screen recording TCC permission ov… | Apple Developer Forums"
[8]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect?utm_source=chatgpt.com "sourceRect | Apple Developer Documentation"
[9]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio?utm_source=chatgpt.com "capturesAudio | Apple Developer Documentation"
[10]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/samplerate?utm_source=chatgpt.com "sampleRate | Apple Developer Documentation"
[11]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/channelcount?utm_source=chatgpt.com "channelCount | Apple Developer Documentation"
[12]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio?utm_source=chatgpt.com "excludesCurrentProcessAudio | Apple Developer Documentation"
[13]: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone?utm_source=chatgpt.com "captureMicrophone | Apple Developer Documentation"
[14]: https://developer.apple.com/documentation/screencapturekit/scstreamoutputtype/audio?utm_source=chatgpt.com "SCStreamOutputType.audio | Apple Developer Documentation"
[15]: https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager?utm_source=chatgpt.com "SCScreenshotManager | Apple Developer Documentation"
[16]: https://developer.apple.com/documentation/coremedia/cmsamplebuffer/presentationtimestamp?utm_source=chatgpt.com "presentationTimeStamp | Apple Developer Documentation"
[17]: https://developer.apple.com/documentation/screencapturekit/screcordingoutput?utm_source=chatgpt.com "SCRecordingOutput | Apple Developer Documentation"
[18]: https://developer.apple.com/documentation/screencapturekit/scstream/synchronizationclock?utm_source=chatgpt.com "synchronizationClock | Apple Developer Documentation"
