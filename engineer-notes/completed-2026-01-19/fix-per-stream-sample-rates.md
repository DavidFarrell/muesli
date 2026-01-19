# Fix: Per-Stream Sample Rates

## Problem

The current implementation sends ONE sample rate in `meeting_start`, but macOS can return different rates for different streams:

```
System format: sr=16000  ← macOS honored the 16kHz request
Mic format: sr=48000     ← macOS ignored it, returned 48kHz
```

The backend writes both WAV files with the same sample rate from `meeting_start`. When mic data (48kHz) is written with a 16kHz header:
1. `is_wav_16k_mono` sees "16kHz" header → skips ffmpeg
2. ASR receives garbage (48kHz samples interpreted as 16kHz)
3. Transcription fails with `'NoneType' object is not subscriptable`

Result: System audio transcribes fine, mic audio never appears.

---

## Solution: Per-Stream Sample Rate Tracking

### Swift Changes

**1. Track format per stream in CaptureEngine:**

```swift
// Replace single format tracking:
// private var actualSampleRate: Int?
// private var actualChannelCount: Int?

// With per-stream tracking:
private var systemSampleRate: Int?
private var systemChannelCount: Int?
private var micSampleRate: Int?
private var micChannelCount: Int?
```

**2. Detect format from each stream separately:**

In `stream(_:didOutputSampleBuffer:of:)`, update the format detection to track which stream it came from:

```swift
audioStateLock.lock()
if type == .audio {
    // System audio
    if systemSampleRate == nil {
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            let asbd = asbdPtr.pointee
            systemSampleRate = Int(asbd.mSampleRate)
            systemChannelCount = Int(asbd.mChannelsPerFrame)
        }
    }
} else if #available(macOS 15.0, *), type == .microphone {
    // Mic audio
    if micSampleRate == nil {
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            let asbd = asbdPtr.pointee
            micSampleRate = Int(asbd.mSampleRate)
            micChannelCount = Int(asbd.mChannelsPerFrame)
        }
    }
}
audioStateLock.unlock()
```

**3. Update waitForAudioFormat to return both:**

```swift
struct AudioFormats {
    var systemSampleRate: Int?
    var systemChannels: Int?
    var micSampleRate: Int?
    var micChannels: Int?

    var isComplete: Bool {
        systemSampleRate != nil && micSampleRate != nil
    }
}

func waitForAudioFormats(timeoutSeconds: Double) async -> AudioFormats {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        audioStateLock.lock()
        let formats = AudioFormats(
            systemSampleRate: systemSampleRate,
            systemChannels: systemChannelCount,
            micSampleRate: micSampleRate,
            micChannels: micChannelCount
        )
        audioStateLock.unlock()

        // Return early if both detected
        if formats.isComplete {
            return formats
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    // Return whatever we have (may be partial)
    audioStateLock.lock()
    let formats = AudioFormats(
        systemSampleRate: systemSampleRate,
        systemChannels: systemChannelCount,
        micSampleRate: micSampleRate,
        micChannels: micChannelCount
    )
    audioStateLock.unlock()
    return formats
}
```

**4. Send per-stream metadata in meeting_start:**

```swift
let formats = await captureEngine.waitForAudioFormats(timeoutSeconds: 2.0)

// Log what we detected
if formats.systemSampleRate != captureSampleRate {
    appendBackendLog("System audio: requested \(captureSampleRate)Hz, got \(formats.systemSampleRate ?? captureSampleRate)Hz", toTail: true)
}
if formats.micSampleRate != captureSampleRate {
    appendBackendLog("Mic audio: requested \(captureSampleRate)Hz, got \(formats.micSampleRate ?? captureSampleRate)Hz", toTail: true)
}

let meta: [String: Any] = [
    "protocol_version": 1,
    "sample_format": "s16le",
    "title": title,
    "start_wall_time": ISO8601DateFormatter().string(from: session.startedAt),
    // Per-stream rates (fall back to requested if not detected)
    "system_sample_rate": formats.systemSampleRate ?? captureSampleRate,
    "system_channels": formats.systemChannels ?? captureChannels,
    "mic_sample_rate": formats.micSampleRate ?? captureSampleRate,
    "mic_channels": formats.micChannels ?? captureChannels
]
```

**5. Reset per-stream state on stop:**

```swift
func stopCapture() {
    // ...
    audioStateLock.lock()
    systemSampleRate = nil
    systemChannelCount = nil
    micSampleRate = nil
    micChannelCount = nil
    audioStateLock.unlock()
}
```

---

### Python Changes

**1. Update SharedState to track per-stream rates:**

```python
# In SharedState.__init__:
self.system_sample_rate: int = 48000
self.system_channels: int = 1
self.mic_sample_rate: int = 48000
self.mic_channels: int = 1
```

**2. Update meeting_start handler:**

```python
if msg_type == MSG_MEETING_START:
    meeting_meta = json.loads(payload.decode("utf-8")) if payload else {}
    with state.lock:
        # Per-stream rates (with backwards-compatible fallback)
        default_rate = int(meeting_meta.get("sample_rate", 48000))
        default_channels = int(meeting_meta.get("channels", 1))

        state.system_sample_rate = int(meeting_meta.get("system_sample_rate", default_rate))
        state.system_channels = int(meeting_meta.get("system_channels", default_channels))
        state.mic_sample_rate = int(meeting_meta.get("mic_sample_rate", default_rate))
        state.mic_channels = int(meeting_meta.get("mic_channels", default_channels))

        state.system_writer = open_stream_writer(
            output_dir / "system.wav",
            state.system_sample_rate,
            state.system_channels
        )
        state.mic_writer = open_stream_writer(
            output_dir / "mic.wav",
            state.mic_sample_rate,
            state.mic_channels
        )

    emit_jsonl({"type": "status", "message": "meeting_started", "meta": meeting_meta}, stdout_lock)
```

**3. Update audio writing to use per-stream rates:**

```python
elif msg_type == MSG_AUDIO:
    t = pts_us / 1_000_000.0
    with state.lock:
        if stream_id == STREAM_SYSTEM and state.system_writer:
            write_aligned_audio(
                state.system_writer, payload, pts_us,
                state.system_sample_rate, state.system_channels  # Use system-specific
            )
            if args.emit_meters:
                emit_jsonl({"type": "meter", "stream": "system", "t": t, "rms": rms_int16(payload)}, stdout_lock)
            if not args.no_live and "system" in live_processors:
                duration = state.system_writer.last_sample_index / float(state.system_sample_rate)
                live_processors["system"].notify_duration(duration)

        elif stream_id == STREAM_MIC and state.mic_writer:
            write_aligned_audio(
                state.mic_writer, payload, pts_us,
                state.mic_sample_rate, state.mic_channels  # Use mic-specific
            )
            if args.emit_meters:
                emit_jsonl({"type": "meter", "stream": "mic", "t": t, "rms": rms_int16(payload)}, stdout_lock)
            if not args.no_live and "mic" in live_processors:
                duration = state.mic_writer.last_sample_index / float(state.mic_sample_rate)
                live_processors["mic"].notify_duration(duration)
```

**4. Update snapshot_stream calls:**

```python
def _snapshot(self) -> Optional[StreamSnapshot]:
    with self._state.lock:
        writer = self._state.get_stream(self._stream_name)
        if self._stream_name == "system":
            sample_rate = self._state.system_sample_rate
            channels = self._state.system_channels
        else:
            sample_rate = self._state.mic_sample_rate
            channels = self._state.mic_channels
    if not writer:
        return None
    return snapshot_stream(writer, sample_rate, channels)
```

**5. Update finalization:**

```python
# In the finalization loop:
for stream_name, writer in writers.items():
    if stream_name == "system":
        sample_rate = state.system_sample_rate
        channels = state.system_channels
    else:
        sample_rate = state.mic_sample_rate
        channels = state.mic_channels

    snapshot = snapshot_stream(writer, sample_rate, channels)
    # ... rest of finalization
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `ContentView.swift` | Per-stream format tracking in CaptureEngine, updated meeting_start metadata |
| `muesli_backend.py` | Per-stream rates in SharedState, updated writers and audio handling |

---

## Testing

After implementing:

1. **Check debug log for per-stream rates:**
   ```
   System audio: requested 16000Hz, got 16000Hz
   Mic audio: requested 16000Hz, got 48000Hz
   ```

2. **Verify both streams transcribe:**
   - Transcript should show both `[system]` and `[mic]` entries

3. **Check ffmpeg usage:**
   - System (16kHz) → ffmpeg skipped
   - Mic (48kHz) → ffmpeg used for normalization

4. **Edge case - both 16kHz:**
   - If hardware honors 16kHz for both, ffmpeg should be skipped for both

---

## Backwards Compatibility

The Python changes include fallback to the old single `sample_rate` field:

```python
default_rate = int(meeting_meta.get("sample_rate", 48000))
state.system_sample_rate = int(meeting_meta.get("system_sample_rate", default_rate))
```

This means old Swift builds will still work (using the single rate for both streams).
