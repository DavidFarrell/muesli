# Build overlay - Muesli

**Repo:** /Users/david/projects/muesli
**Stack:** Swift (SwiftUI app `MuesliApp`, Xcode project), AVFoundation / CoreAudio / AudioToolbox / ScreenCaptureKit for capture; Python backend (`muesli_backend.py`) for transcription/diarisation. The two communicate over a length-prefixed binary protocol.
**Style anchor:** the existing `MuesliApp/MuesliApp/*.swift` files - in particular `MicEngine.swift` (small actor, plain Core Audio) and `CaptureEngine.swift`. Match that depth: small actors, direct Core Audio calls, `print("[Component] ...")` logging. Do not introduce a DI framework, a "CaptureStrategy protocol hierarchy", or any abstraction the current files do not already use.
**Audience / reviewer:** David (solo). He reviews the diff himself. He dislikes over-abstracted, ocean-boiling AI code. Keep changes small, reviewable, and scoped to the files named in the plan.

## Project-specific taste notes

- **Two independent engines, kept independent.** `MicEngine` (AVAudioEngine, the user's voice) and `CaptureEngine` (ScreenCaptureKit, system audio + MP4 recording + screenshots) are separate. Mic-side changes must NOT touch the system-audio or recording path. A mic restart must never interrupt the recording.
- **No test target exists today.** Adding a minimal `MuesliAppTests` target for pure decision logic is acceptable and wanted. Do NOT attempt to unit-test AVAudioEngine/VPIO/Core Audio hardware behaviour - that is verified manually. Test only the pure functions (the AEC-mode decision, the format-validity predicate).
- **VPIO is fragile by nature.** Apple's VoiceProcessingIO is a duplex unit that uses the output device as its echo reference and must be configured while the engine is stopped. Treat it as best-effort: request it, verify real audio arrives, and degrade gracefully if it does not. Never let a silent VPIO failure leave the mic dead.
- **The only provably-safe auto-on case is the built-in MacBook speaker.** Core Audio cannot distinguish Bluetooth headphones from a Bluetooth speaker, nor a USB headset from USB desk speakers. So "is there a column of air between output and mic" is only knowable for the built-in speaker. Everything else defaults to no AEC, with a manual override.

## Key reference files

- Redesign spec (this build's plan): design/2026-05-29 - mic-aec-redesign.md
- Mic capture: MuesliApp/MuesliApp/MicEngine.swift
- Mic lifecycle / health check / device selection: MuesliApp/MuesliApp/AppModel.swift (see `startMeetingMicEngine`, `restartMeetingMicEngineForInputSwitch`, `scheduleMicStartupHealthCheck`)
- Audio device enumeration: MuesliApp/MuesliApp/ContentView.swift (`enum AudioDeviceManager`)
- Mic toggle / level UI: MuesliApp/MuesliApp/ContentView.swift, SessionView.swift
- Prior superseded spec: engineer-notes/spec-mic-aec-reimplementation.md
