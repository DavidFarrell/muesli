# Spec: Mic AEC redesign - conditional VPIO with graceful degradation

**Date:** 2026-05-29
**Scope:** `MicEngine.swift`, `AppModel.swift`, `ContentView.swift` (`AudioDeviceManager` + the mic settings UI), and a new minimal `MuesliAppTests` target. The ScreenCaptureKit system-audio and recording paths are out of scope and must not change.

## Problem

Mic capture uses `AVAudioEngine` with `setVoiceProcessingEnabled(true)` (VoiceProcessingIO / VPIO) to get hardware acoustic echo cancellation (AEC). VPIO is a duplex unit that uses the current output device as its echo reference. With an output route VPIO cannot handle (observed: a USB wireless mic input together with a Bluetooth A2DP output), VPIO delivers no audio - the tap never fires - and `engine.start()` does NOT throw. The result is a dead mic ("Mic enabled but no audio received yet", level flat at 0.00) with no recovery, because:

1. `MicEngine.start()` only falls back to non-VPIO when `startEngine` *throws*; a silent zero-buffer failure is never caught.
2. The device is bound via `kAudioOutputUnitProperty_CurrentDevice` *after* VPIO is enabled, which is unreliable and can leave a 0 Hz / 0 channel format that the tap then installs against.
3. The startup health check restarts with the *identical* VPIO+device config, so it cannot escape a VPIO incompatibility - it just exhausts its retries.

Granola, on the same machine and same default input device, captures fine because it does not use VPIO.

## Design principle

Hardware AEC only helps when the microphone can physically hear the speakers (a shared column of air). Headphones break that path, so AEC is pointless there - and currently it is actively breaking capture. The echo problem AEC exists to solve (other participants' voices leaving the speakers and being re-captured as the user's mic words) only arises when the output is an open-air speaker.

Core Audio cannot tell a Bluetooth speaker from Bluetooth headphones, nor a USB headset from USB desk speakers. The **only** output route where an echo path is guaranteed and detectable is the **built-in MacBook speaker**. Therefore:

- **Auto (default):** enable VPIO only when the current output device is the built-in speaker; plain capture (no VPIO) otherwise.
- **Manual override:** the user can force AEC On or Off regardless of output device.
- **Escalation fallback (always):** if VPIO is requested but no audio buffers arrive within a short window, tear the engine down and restart once with VPIO disabled. A VPIO failure must never leave the mic dead - it degrades to plain capture.

## Decision model

```
enum AECMode { case auto, on, off }   // user setting, default .auto

// pure, unit-tested
func shouldRequestVoiceProcessing(mode: AECMode, outputIsBuiltInSpeaker: Bool) -> Bool {
    switch mode {
    case .on:   return true
    case .off:  return false
    case .auto: return outputIsBuiltInSpeaker
    }
}
```

`outputIsBuiltInSpeaker` is computed from Core Audio with a strict predicate, because transport type alone is not enough: `kAudioDeviceTransportTypeBuiltIn` also covers the 3.5 mm headphone jack (built-in output, data source "Headphones"). The predicate is: the default output device's transport type is `kAudioDeviceTransportTypeBuiltIn` AND it has an output scope AND its active output data source identifies the internal speaker (query `kAudioDevicePropertyDataSource` on the output scope; the internal-speaker source is `'ispk'`). If the data source cannot be read or is anything else (e.g. headphone jack), return false. This is the requested VPIO state; the escalation fallback may still downgrade it at runtime if no audio arrives.

## Slices

### Slice 1 - MicEngine: caller-controlled VPIO, format guard, bind minimisation

- Change `MicEngine.start` so the **caller decides** voice processing: `start(enableVoiceProcessing: Bool, preferredInputDeviceID: UInt32?, onAudioData:)`. Remove the internal "try VPIO, catch, retry without" behaviour - escalation moves up to `AppModel` (slice 3) where it can be driven by actual buffer activity rather than thrown errors.
- **Explicit configuration sequence** inside `startEngine` (order matters - the format must be read and validated AFTER VPIO is enabled, because enabling VPIO changes the input node's format and is exactly where the 0 Hz / 0 channel failure shows up):
  1. Create a fresh `AVAudioEngine` (it is stopped - VPIO must be configured while stopped).
  2. If a device bind is needed (see bind minimisation below), bind the input device first.
  3. If `enableVoiceProcessing`, call `setVoiceProcessingEnabled(true)` and the ducking config.
  4. Read the input node's format (`outputFormat(forBus: 0)`).
  5. Validate it with the pure predicate `isUsableInputFormat(sampleRate:channelCount:)`. If invalid (0 Hz or 0 channels), throw `MicEngineError.invalidInputFormat`.
  6. Install the tap with the validated format.
  7. `prepare()` and `start()`.
- Bind minimisation: only call `kAudioOutputUnitProperty_CurrentDevice` when the requested device differs from the current default input. When it equals the default, skip the bind entirely (it is the unnecessary, risky call implicated in the bug). The bind, when needed, happens before enabling voice processing (step 2 above).
- Add typed errors: `enum MicEngineError: Error { case invalidInputFormat(sampleRate: Double, channelCount: UInt32, deviceID: UInt32?, vpioRequested: Bool) }`. The associated values carry the debug context so the caller's log line does not have to invent ad hoc strings.
- **Tests (new `MuesliAppTests` target):** `isUsableInputFormat` rejects 0 Hz / 0 channels and accepts a normal 48 kHz mono/stereo format.

### Slice 2 - AEC policy, device APIs, and settings UI

- Add to `AudioDeviceManager`: `defaultOutputDeviceID()`, `isBuiltInSpeaker(_ deviceID:)` (the strict predicate from the Decision model section: built-in transport AND output scope AND output data source == internal speaker `'ispk'`; false if the data source cannot be read or differs), and `observeOutputDeviceChanges(_:)` (mirrors the existing input observer).
- Add `AECMode` and `shouldRequestVoiceProcessing` (pure). Add `@Published var aecMode: AECMode = .auto` to `AppModel`, persisted to `UserDefaults` via a stable string raw value (`AECMode: String`); on missing or unrecognised stored value, default to `.auto`. No migration logic.
- `startMeetingMicEngine` and the preview path both compute the VPIO flag via `shouldRequestVoiceProcessing(mode: aecMode, outputIsBuiltInSpeaker: AudioDeviceManager.isBuiltInSpeaker(AudioDeviceManager.defaultOutputDeviceID()))` and pass it to `MicEngine.start`. The preview path is the level-preview start (the function that creates `previewMicEngine`, around `AppModel` line ~685) plus `restartPreviewMicEngineForInputSwitch`; reuse the same decision helper and do not change any meeting-recording state from the preview path.
- UI: a small segmented control (Auto / On / Off) in the mic settings area of `ContentView`, labelled "Echo cancellation", with a one-line helper that auto means "on only with built-in speakers".
- **Tests:** `shouldRequestVoiceProcessing` truth table across the three modes x built-in/not.

### Slice 3 - Escalation fallback and output-change re-evaluation

- Replace `scheduleMicStartupHealthCheck`'s identical-retry with a single graceful downgrade. The downgrade fires whenever **VPIO was requested** (whether the request came from `.auto` or manual `.on` - a manual On can also land on a hostile route) and either:
  - `debugMicBuffers == 0` after the window (~2 s), or
  - `MicEngine.start` threw `MicEngineError.invalidInputFormat` with `vpioRequested == true` (treat this as the same condition - restart without VPIO rather than surfacing a hard failure).
  On that condition, restart `MicEngine` once with `enableVoiceProcessing: false`, and append a one-line note via the existing `appendBackendLog(_:toTail:)` (the app-visible log, NOT the Python backend): "Echo cancellation could not start on this audio route; continuing without it." If plain capture also yields zero buffers, keep the existing "no audio" warning - that is a genuine mic problem, not a VPIO one.
- Downgrade scope: track requested-vs-effective VPIO per mic-start generation; attempt the downgrade at most once per generation. Reset the downgrade flag (allowing a fresh VPIO attempt) when the user changes `aecMode`, the input device, or the default output device.
- Output-change re-evaluation: when in `.auto` mode and the default output device changes mid-meeting such that the VPIO decision flips, restart `MicEngine` to match (reuse the existing mic-restart path; system capture and recording untouched). Driven by `observeOutputDeviceChanges`. Manual `.on`/`.off` modes do not re-evaluate the decision on output change, but a restart in manual `.on` still runs the downgrade check above.
- **Tests:** none new that are meaningful at the unit level (this slice is integration/hardware). Cover the decision flip via the slice 2 pure function. Manual verification below.

## Manual verification (hardware paths)

1. Built-in speakers + built-in mic, audio playing: AEC on; other-party audio not re-transcribed as mic.
2. Bluetooth headphones (Bose) + USB wireless mic (the failing case): mic level moves, transcript flows, no dead mic.
3. Force On while on Bluetooth output, VPIO fails: auto-downgrades to plain capture within ~2 s, mic still works, log note shown.
4. Toggle Auto/On/Off mid-meeting: mic restarts within ~1 s, recording uninterrupted.
5. Switch output from built-in speakers to Bluetooth mid-meeting in Auto: mic restarts, drops VPIO, no dead mic.

## Out of scope

- Re-adding a ScreenCaptureKit mic path as a third fallback tier. Plain `AVAudioEngine` (no VPIO) is the fallback; it is the same path Granola-style plain capture uses and is sufficient. Note it as a possible future tier, do not build it now.
- Any change to system-audio capture, the MP4 recording, screenshots, or the backend protocol.
- Detecting wired 3.5 mm headphones (the user does not use them).
