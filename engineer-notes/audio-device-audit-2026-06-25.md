# Muesli Audio Subsystem Audit - Synthesis & Implementation Plan

_Adversarial multi-agent audit, 2026-06-25. 38 agents, 30 findings raised, 20 survived adversarial verification._
_All paths under `/Users/david/git/ai-sandbox/projects/muesli/MuesliApp/MuesliApp/`. Line numbers verified against source at audit time._

---

## IMPLEMENTATION STATUS (2026-06-25) - full redesign built, builds green, NOT yet runtime-tested

The full redesign (SS3-SS5) was implemented in one pass. Build succeeds; the 7 existing unit tests pass. NOT yet exercised on real hardware - the Bluetooth-steal scenario can only be confirmed live (that is what the logging is for).

**What landed:**
- `AudioLog.swift` (new) - unified `os_log` subsystem `com.muesli.audio`, mirrored into the in-app backend log tail. Capture a failure with `log collect --last 30m --output ~/muesli-audio.logarchive` or Console filtered on `com.muesli.audio`.
- UID-based device identity: `AudioDevice.uid`, `AudioDeviceManager.deviceUID/deviceID(forUID:)/outputDevices/snapshot/setDefaultOutputDevice`.
- `InputSelection`/`OutputSelection` enums = single source of truth, persisted to UserDefaults by UID. `selectedInputDeviceID` is now a derived picker mirror (0 = System default). The three reset conditions are implemented.
- `loadInputDevices` rewritten: resolves via policy, restarts only when desired device != engine-bound device (kills D1/D3/D6). The `previousSelection != 0` and ID-delta guards are gone.
- All mic restarts serialized through one `micLifecycleTask` + generation token (D2/D8). `restartMeetingMicEngineForInputSwitch` cancels the startup health check first (D15).
- `MicEngine`: binds unconditionally when pinned (D7), `AVAudioEngineConfigurationChange` observer (D1/D9), surfaces `deviceBindFailed`, counts/logs tap conversion failures (D12).
- Continuous frames watchdog (2s heartbeat, 4s stall threshold) that force-restarts a mid-meeting dead mic once frames have flowed (D9/D10). `refreshMicrophones()` does liveness-based forced recovery regardless of ID delta (D3/SS4); both Refresh buttons wired to it.
- Output follow/pin mirror + output pickers; `handleOutputDeviceChange` re-asserts a pinned output / resets a vanished pin (D14).
- `CaptureEngine.stream(_:didStopWithError:)` implemented + surfaced (D13).
- Manual picks no longer mutate the global default INPUT (D11); a manual OUTPUT pick does set the default output (so playback moves there).

**Known behaviour changes for David to verify live:**
- The mic picker now shows "System default" as a selectable row; following = that row selected (not the named device).
- A manual pick STICKS through OS steals until you re-pick / it disappears / you choose System default.
- The watchdog auto-restarts a dead mic ONCE per death episode; a genuinely broken device won't restart-loop - hit Refresh for another attempt.
- `isSwitchingInputDevice` is no longer set by the (removed) old switch path, so the "Switching..." spinner won't show. Cosmetic only.

**Deferred:** auto-restart-on-`heartbeat.STALL` is live (not gated) - if it proves too eager in testing, gate it behind a confirmation or raise the threshold. The medium/low items beyond those listed are done; nothing outstanding from the ranked list except live validation.

---

---

## 1. Root-cause picture

When a Bluetooth headset (e.g. Bose) connects mid-meeting, macOS atomically steals **both** the default input and the default output. This single physical event fans out into up to four CoreAudio property-listener firings, and the app's response is structurally unable to do the right thing. The most likely sequence:

1. **The common user is "following the system default" (`selectedInputDeviceID == 0`).** This is the default state for anyone who never picks a device on the start screen. The running `MicEngine` was started with `preferredInputDeviceID: nil` (`AppModel.swift:798`), so the device bind was skipped entirely (`MicEngine.swift:43`) and the engine is tracking "whatever the default is" via an `AVAudioEngine` with no `AVAudioEngineConfigurationChange` observer (grep confirms none exists anywhere).

2. **The headset connects.** CoreAudio reroutes the default input under the running engine. Because the app has no `AVAudioEngineConfigurationChange` handler, nothing tells the engine its underlying device moved. The installed tap can stall - frames stop - which is the **silent dead mic** (Symptom 2).

3. **The input listener fires -> `loadInputDevices()`** (`AppModel.swift:1173`). In the follow-default case, `previousSelection` was captured as `0` at `:1179`, the selection is silently reassigned to the headset ID at `:1190-1191`, and then **`guard previousSelection != 0 else { return }` (`:1195`) short-circuits before the restart path at `:1204`**. So even the one path that could restart the engine returns having done nothing. No rebind, no restart, no log. This is the precise mechanism behind "mic stays on Wireless RX / gets stolen with no clean way back" (Symptom 1) for the common user.

4. **If the user HAD pinned a device, the symptom flips but is equally wrong.** `loadInputDevices` keeps any still-present selection (`:1182-1183`) regardless of the OS default move - correct for a pin, but the app has no flag saying it *was* a pin, and on a brief BT re-enumeration the pinned ID can vanish and be silently overwritten by the OS default (`:1184-1191`) with no resume-on-return.

5. **When a restart DOES fire, it can race itself into a dead state.** A BT connect changes both default input and default output, so the input path (`loadInputDevices -> queue -> applyInputDeviceSelectionChange -> restartMeetingMicEngineForInputSwitch`) and the output path (`handleOutputDeviceChange -> restartMeetingMicEngineForInputSwitch`, `:916-917`) can both arm. Only the input path is serialized (via `inputDeviceSelectionTask` and the `isSwitchingInputDevice` guard); the output and AEC paths spawn **free, unserialized `Task { ... }`**. Two `@MainActor` restarts then interleave at the `await engine.stop()` / `await startMeetingMicEngine()` suspension points (`MicEngine` is an `actor`), leaving `micEngine` pointing at a stopped engine and/or an orphaned live engine emitting into a torn-down generation. Net: dead mic, no error surfaced.

6. **Refresh cannot rescue any of this.** The Refresh button (`ContentView.swift:271-272`, `SessionView.swift:92-93`) calls only `loadInputDevices()`, whose restart is gated behind `guard previousSelection != resolvedSelection else { return }` (`:1196`). A dead-but-still-enumerated device produces no ID change, so Refresh returns having re-read the list and touched nothing (Symptom 3).

**Confidence.** The structural defects (guard logic, missing serialization, missing config-change observer, no UID anchoring, no continuous watchdog) are **high-confidence, code-confirmed**. The exact *runtime* behaviour of an unbound `AVAudioEngine` on a default-device steal - whether the tap goes fully silent vs silently follows vs delivers garbage - **can only be confirmed with runtime logs**, which is why Section 5 is the priority deliverable. The transient-`AudioObjectID` reuse hazard is real per CoreAudio semantics but its frequency in David's specific repro is also a logs question.

---

## 2. Confirmed defects (ranked)

| # | Sev | Location | Defect | Symptom | Fix direction |
|---|-----|----------|--------|---------|---------------|
| **D1** | **Critical** | `AppModel.loadInputDevices` `:1195` (`guard previousSelection != 0`) | Auto-follow is dead: when following the system default (`selectedInputDeviceID==0`), an OS default steal silently reassigns the ID but the `previousSelection != 0` guard returns before the restart at `:1204`. The unbound running engine is never restarted/rebound. | 1 + 2 | Treat follow-default as a first-class transition. On an OS default change while capturing in follow mode, restart the meeting mic engine. Branch/remove the `:1195` short-circuit for the follow case. |
| **D2** | **Critical** | `restartMeetingMicEngineForInputSwitch` `:832-848` + callers `:110-112, :641, :814, :892, :916-917` | Restart is **unserialized**. Five triggers call it; only the input-selection path flows through `inputDeviceSelectionTask`. Output-change and AEC paths spawn free `Task`s that interleave at `await engine.stop()`/`startMeetingMicEngine()`, clobbering the single `micEngine` field -> orphaned/stopped engine = dead mic. | 2 + 3 | Route **all** restarts through one serializing task (like `inputDeviceSelectionTask`), making stop/create/start atomic per generation. Add a monotonic generation token; `startMeetingMicEngine` bails if its token is stale before assigning `micEngine`. |
| **D3** | **Critical** | `loadInputDevices` `:1196` (`guard previousSelection != resolvedSelection`) <- Refresh buttons `ContentView.swift:271-272`, `SessionView.swift:92-93` | Refresh only restarts on a device-ID *delta*. A dead-but-present mic gives no delta -> early return -> engine untouched. Refresh "does nothing." | 3 (+ recovery half of 2) | Give Refresh a liveness-based recovery path: if `isCapturing && transcribeMic && (micEngine == nil || debugMicBuffers == 0)`, force `restartMeetingMicEngineForInputSwitch()` regardless of ID delta. Decouple "reload list" from "restart engine." |
| **D4** | **High** | `AudioDevice` struct `ContentView.swift:729-732`; `selectedInputDeviceID` `AppModel.swift:103` | Device identity is the transient `AudioObjectID` (`UInt32`), never the stable `kAudioDevicePropertyDeviceUID`. A BT reconnect can re-enumerate under a new ID, or reuse the old ID for a different device -> wrong-mic-kept or pin-lost. Not persisted to `UserDefaults` either (resets to 0 each launch). | 1 | Add `uid: String` to `AudioDevice` (read `kAudioDevicePropertyDeviceUID`); make UID the source of truth; re-resolve UID->current `AudioObjectID` on every `loadInputDevices` and before every bind. Compare by UID. |
| **D5** | **High** | `AppModel` selection model (`:103`, `:610-645`, `:1182-1188`) | **No source-of-truth flag for auto-follow vs pinned.** Only `selectedInputDeviceID` + the transient `updateSystemDefault` argument exist. The three policy reset conditions (re-pick / pin disappears / "System default") are unimplementable; a vanished pin reverts to OS default with no resume-on-return. | Policy gap (1) | Introduce explicit `enum InputSelection { case followSystem; case pinned(uid: String) }` as the single source of truth all four sequences read (see SS3). |
| **D6** | **High** | `loadInputDevices` resolution `:1182-1188` | One fixed "keep-if-present" rule serves both pin and follow. On an OS steal where the old mic is still enumerated, it keeps the old device - wrong for a follower (should move) but right for a pin; the code can't tell them apart. | 1 | Drive resolution off the D5 state enum: follow->adopt new default; pinned->hold until that exact UID disappears. |
| **D7** | **High** | `MicEngine.startEngine` `:43-45` + `bindPreferredInputDevice` `:165-185` | Bind-skip heuristic compares the requested ID against the live default *at start time*; a pinned device equal to the (stolen) default is never bound. `bindPreferredInputDevice` passes the raw `UInt32` to `AudioUnitSetProperty` with no validity check -> a stale ID either silently mis-routes or throws `deviceBindFailed` out of start (-> silent nil engine). | 1 + 2 | Re-resolve pinned UID -> fresh ID immediately before binding; bind **unconditionally** when a specific device is pinned (skip-on-equal-default is only correct for auto-follow). Surface `deviceBindFailed` to the UI. |
| **D8** | **High** | `handleOutputDeviceChange` `:902-919` vs `loadInputDevices` `:1197` | Re-entrancy guard asymmetry: `loadInputDevices` honours `!isSwitchingInputDevice`; `handleOutputDeviceChange` does not. An output event can fire a restart while an input switch is mid-flight (suspended at `waitForDefaultInputDevice`). | 2 | Make the guard symmetric / route through the shared serializer (folds into D2). |
| **D9** | **High/Crit** | `scheduleMicStartupHealthCheck` `:874-900` | The **only** liveness check is a one-shot 3s startup probe gated on `debugMicBuffers == 0`. A mic that dies mid-meeting after the window has passed is never detected or healed. | 2 | Add a repeating frames-flowing watchdog while `isCapturing` (see SS3 and SS5). |
| **D10** | **High** | `handleMicAudio` `:553-555` | `debugMicBuffers` is only ever compared `==0` once (`:885`); `debugMicFrames` is overwritten each callback (latest buffer size, not cumulative); no `lastMicAudioAt` timestamp. The liveness primitive needed for D9 is half-built. | 2 | Set `lastMicAudioAt = Date()` in `handleMicAudio`; the watchdog compares elapsed-since-last-frame vs threshold. |
| **D11** | **High** | `applyInputDeviceSelectionChange` `:620-629` | A manual pick rewrites the **global** OS default input (`setDefaultInputDevice`) - leaks Muesli's choice system-wide, when per-AudioUnit binding already exists (`bindPreferredInputDevice`). *(The "racing the OS steal feedback-loop" framing was refuted - the follow path uses `updateSystemDefault:false` and never re-writes, and arbitration via `isSwitchingInputDevice`/`inputDeviceSelectionTask` does exist. The side-effect itself is real; the race story is not.)* | 1 (side-effect) | Bind the chosen device at the AudioUnit level instead of mutating the system default; reserve the global write for an explicit opt-in. |
| **D12** | **Medium** | `MicEngine.swift:85-92` + `AudioConverterHelper` nil paths | Tap callback drops every failed conversion with a bare `return` - no counter, no log. 100% conversion failure on an odd route looks identical to a dead mic AND defeats the `buffers==0` health check (which then misfires a useless VPIO downgrade). | 2 | Count + log conversion failures (first-failure logs the input format); distinguish "tap firing but converting fails" from "tap never firing." *(Realistic trigger is an unsupported sample format, not mere layout - converter is layout-robust.)* |
| **D13** | **Medium** | `CaptureEngine.swift:187` | Declares `SCStreamDelegate` but does not implement `stream(_:didStopWithError:)` - OS-initiated stream stop/error is silently dropped. | 2 (system-audio side) | Implement `didStopWithError`; surface to AppModel + log. |
| **D14** | **Medium** | `handleOutputDeviceChange` `:902-919`; no output state anywhere | Output is never tracked or pinned - read only for the VPIO decision. The policy's symmetric "follow/pin output" is entirely unimplemented. | Policy gap (1, output theft) | Add an output selection enum mirroring input + output picker (see SS3). |
| **D15** | **Low** | `scheduleMicStartupHealthCheck` `:844` interaction | Health-check/teardown TOCTOU: a stale-generation health task can observe the new engine's freshly-zeroed `debugMicBuffers` and misfire one needless restart + VPIO downgrade. Self-limiting (cancel-replace keeps <=1 task live; recoverable). | minor | Call `cancelMicStartupHealthCheck()` at the top of `restartMeetingMicEngineForInputSwitch` (before `:836`); key the task to an engine generation token. |

**Did NOT survive (resolved non-issues):** the "manual pick writes wrong system default via ID reuse" silent-failure story (caught by the `:621` status guard + reconciliation); the "stale static listener closure fires against a torn-down AppModel" (the model is a root `@StateObject`, single-instance for process life); "duplicate `kAudioHardwarePropertyDevices` listener stacks restarts" (downstream handlers are idempotent - it's wasted enumeration, not stacked restarts); `guard !isRunning` no-op (every start is preceded by a fresh `MicEngine()`); "health check never arms at startup" (the `:1647` call is the deliberate arming point); and two policy-gap claims that misread `:1182`/`:1195`. These are genuinely fine as-is.

---

## 3. Redesign: follow-by-default + manual-pin-sticks

### 3.1 Single source of truth

Replace `selectedInputDeviceID: UInt32` with an explicit state plus a UID-keyed device model:

```swift
struct AudioDevice: Identifiable, Equatable {
    let id: UInt32          // current transient AudioObjectID (re-resolved each load)
    let uid: String         // kAudioDevicePropertyDeviceUID - STABLE identity
    let name: String
}

enum InputSelection: Equatable {
    case followSystem            // default at launch; resumes on the 3 reset conditions
    case pinned(uid: String)     // a deliberate user pick; survives OS default moves
}

@Published private(set) var inputSelection: InputSelection = .followSystem
@Published private(set) var outputSelection: OutputSelection = .followSystem  // mirror, see 3.5
```

Persist `inputSelection` (and `outputSelection`) to `UserDefaults` keyed by UID string so a pin survives relaunch. `followSystem` is the launch default (matches "mic + output default to whatever macOS is set to").

### 3.2 Track devices by stable UID, not transient ID

- `AudioDeviceManager.inputDevices()` (`ContentView.swift:780-784`): read `kAudioDevicePropertyDeviceUID` for each device and populate `uid`.
- Add `AudioDeviceManager.deviceID(forUID:) -> UInt32?` that re-resolves a UID to its **current** `AudioObjectID` by scanning the live device list.
- Everywhere a device ID is needed for a bind or a "is my device present" check, resolve `pinned(uid)` -> current ID at the moment of use - never trust a cached integer.

### 3.3 The resolution function (rewrite `loadInputDevices`, `:1173-1206`)

```
load available devices (with uids)
switch inputSelection {
case .followSystem:
    desiredID = AudioDeviceManager.defaultInputDeviceID()   // adopt current OS default
case .pinned(uid):
    if let id = deviceID(forUID: uid) { desiredID = id }     // pin present -> hold it
    else { inputSelection = .followSystem; desiredID = default }  // RESET #2 (pin vanished)
}
if isCapturing && desiredID != currentEngineDeviceID { restart(serialized) }   // liveness-aware, not ID-delta-gated
```

Key changes vs today:
- **Follow mode adopts the new default** (kills D1/D6). The `previousSelection != 0` and `previousSelection != resolvedSelection` guards (`:1195-1196`) are removed; the restart decision is "does the desired device differ from what the engine is actually bound to" plus liveness, not a bare integer delta.
- **Pinned mode holds** until the UID disappears.

### 3.4 The three reset conditions -> resume `followSystem`

1. **User re-picks a different device** (`selectInputDevice`, `:664`): set `inputSelection = .pinned(uid:)`. A re-pick of the *same* device is a no-op.
2. **Pinned device disappears**: detected in 3.3's `.pinned` branch when `deviceID(forUID:)` returns nil -> set `.followSystem`.
3. **User explicitly selects "System default"**: add a sentinel "System default" row to the picker (`ContentView.swift:262-265`); selecting it sets `inputSelection = .followSystem`.

### 3.5 Output follows independently

Add a mirror for output (D14): `OutputSelection { followSystem; pinned(uid) }`, an output `AudioDevice` list, an Output picker, and an output resolver driven by the same 3 reset conditions. `handleOutputDeviceChange` (`:902-919`) keeps its VPIO-decision responsibility but additionally honours the output selection (follow the new default, or hold a pin). Output binding for *capture* is moot (CaptureEngine is device-independent via ScreenCaptureKit), so "output follow/pin" here governs the user-facing chosen playback device + the VPIO/built-in-speaker decision, not the recording path.

### 3.6 Binding (fold in D7, D11)

In `MicEngine.startEngine` (`:43-45`): when the caller passes a pinned device, **bind unconditionally** (re-resolved from UID); only apply the skip-on-equal-default heuristic in follow mode. Prefer per-AudioUnit binding over `setDefaultInputDevice` so Muesli stops mutating the global default (D11); reserve the global write for an explicit opt-in.

### 3.7 Engine config-change observer (fold in D1, D9)

Register an `AVAudioEngineConfigurationChange` observer on each `MicEngine`'s engine. When it fires (the OS moved the route under us), route through the same serialized restart so an unbound follow-mode engine actually re-acquires the new default - this is the event-level complement to the polling watchdog in SS5.

---

## 4. Fix the Refresh button

**Today:** Both Refresh buttons (`ContentView.swift:271-272`, `SessionView.swift:92-93`) call only `model.loadInputDevices()`. That re-fetches the device list and re-resolves the selection, but its only engine-restart path is gated behind `guard previousSelection != resolvedSelection` (`:1196`) plus `!isSwitchingInputDevice` (`:1197`) and `isCapturing` (`:1198`). For a dead-but-still-present mic the resolved ID is unchanged, so Refresh returns having touched nothing. There is no liveness check on this path.

**Required behaviour:** Give Refresh an explicit, liveness-based recovery action independent of any ID delta:

```swift
func refreshMicrophones() {
    loadInputDevices()                          // keep: re-enumerate (now UID-aware)
    guard isCapturing, transcribeMic else { return }
    if micEngine == nil
        || debugMicBuffers == 0
        || Date().timeIntervalSince(lastMicAudioAt ?? .distantPast) > staleThreshold {
        Task { await restartViaSerializedQueue() }   // the SS3.3/D2 serialized restart
    }
}
```

Wire both Refresh buttons to `refreshMicrophones()`. This makes Refresh the user's reliable manual recovery lever: it re-acquires the device list AND force-restarts a dead engine even when the resolved device ID hasn't changed.

---

## 5. Defensive logging plan (PRIORITY DELIVERABLE)

The user cannot reproduce on demand, so the goal is: **from the logs alone, reconstruct the exact sequence that killed the mic.** Use a single unified subsystem so everything interleaves on one timeline.

### 5.1 One logger

Add `AudioLog.swift`:

```swift
import os
enum AudioLog {
    static let log = Logger(subsystem: "com.muesli.audio", category: "device")
}
```

Emit every line as `os_log` at `.info` (errors at `.error`) AND mirror into the existing `appendBackendLog` tail so it shows in-app. Each line: ISO8601 timestamp, a stable event key, and a flat key=value payload. Capturable post-hoc via `log collect` / Console filtered on subsystem `com.muesli.audio`.

### 5.2 Helper to snapshot device state (call at every transition)

Add to `AudioDeviceManager`:

```swift
static func snapshot() -> String  // "inID=<id> inUID=<uid> inName='<name>' outID=<id> outUID=<uid> outName='<name>'"
```

**Log device IDs, UIDs, AND names** so a transient-ID reuse is visible (same name, different ID, or same ID different UID).

### 5.3 Exactly what to log, where

- **Listeners fire** - `ContentView.swift` observer blocks (`:749-753`, `:916-920`): `listener.input.fired` / `listener.output.fired` + which selector + `snapshot()`. The only place we see which CoreAudio property fired and in what order on a BT connect.
- **User action** - `selectInputDevice` (`:664`), output equivalent, `refreshMicrophones`: `user.pick.input` / `user.pick.output` / `user.refresh` with `fromSelection`, `toUID`, `toName`, `snapshot()`.
- **Selection resolution** - `loadInputDevices` (`:1173`), after computing `resolvedSelection`: `resolve.input` with `inputSelection`, `previousID`, `resolvedID`, `resolvedUID`, `present`, `willRestart`, `gateReason:<which guard returned>`. **Log the guard that short-circuited** - this is exactly where D1/D3 hide.
- **Engine start** - `startMeetingMicEngine` (`:782`) and `MicEngine.start`/`startEngine`: `engine.start.begin` (generation token, `enableVPIO`, `preferredID`, `preferredUID`, `bindSkipped`, `nativeFormat`); `engine.start.ok`; on each catch `engine.start.fail` with the **full thrown error** (incl. `deviceBindFailed` status, `invalidInputFormat` details). No swallowed errors.
- **Engine stop / restart** - `stop()` (`MicEngine.swift:105`) -> `engine.stop`; `restartMeetingMicEngineForInputSwitch` (`:832`) -> `engine.restart.begin` / `.end` with caller tag (input-switch / output-change / aec-change / vpio-downgrade / health-check / refresh) and generation token. Two overlapping `restart.begin` with different tokens and no intervening `.end` is the D2/D8 smoking gun.
- **Bind** - `bindPreferredInputDevice` (`:165`): `engine.bind` with deviceID, resolved UID, status. `currentDefaultInputDeviceID` failure (`:158`): `engine.bind.skip.read-fail`.
- **Config change** - the new `AVAudioEngineConfigurationChange` observer: `engine.configchange` + `snapshot()`. The event we currently can't see at all.
- **Swallowed-error paths - log, don't drop:** tap conversion failure (`MicEngine.swift:86`, D12); `CaptureEngine` `didStopWithError` (new, D13); `AudioDeviceManager` getter `OSStatus` failures; listener-install failures (upgrade `print` -> `AudioLog.error`).

### 5.4 Frames-flowing heartbeat (the moment audio stops)

The single most valuable addition. Add `lastMicAudioAt: Date?` set in `handleMicAudio` (`:543`), and a **repeating** watchdog every 2s while `isCapturing && transcribeMic`:

```swift
let since = Date().timeIntervalSince(lastMicAudioAt ?? micStartTime ?? now)
AudioLog.event("heartbeat", buffers:debugMicBuffers, sinceLastFrameMs:since*1000,
               micLevel:micLevel, engineAlive:(micEngine != nil), snapshot())
if since > 2.0 { AudioLog.error("heartbeat.STALL", sinceLastFrameMs:since*1000, snapshot()) }
// auto-restart on STALL is a SEPARATE behaviour-change step, gated on log validation
```

The first `heartbeat.STALL` line timestamps the exact moment audio died; the immediately preceding `listener.*` / `engine.restart.*` / `engine.configchange` lines reveal what caused it. NB `debugMicFrames` is overwritten per callback (`:554`) so it is **not** a cumulative counter - use `debugMicBuffers` (already increments) or add a dedicated `micFrameCounter`.

### 5.5 What the reconstructed timeline looks like

A captured failure should read, on one subsystem: `listener.output.fired` + `listener.input.fired` (the BT connect) -> `resolve.input gateReason=previousSelection==0` (D1 caught red-handed) -> no `engine.restart.begin` -> `heartbeat.STALL sinceLastFrameMs=2100` -> `user.refresh` -> `resolve.input willRestart=false gateReason=previousSelection==resolvedSelection` (D3 caught). That sequence proves root cause without a live repro - the entire point of the deliverable.

---

## Implementation order

1. **Ship SS5 (logging) FIRST** - observability only, no behaviour change - to capture the next real failure and validate the SS1 hypotheses.
2. **D2 (serialization) + D1 (follow-default restart) + D3/SS4 (Refresh recovery)** as the core fixes.
3. **D4/D5 (UID + state enum)** as the structural redesign.
4. **D14 (output)** and the medium/low items.

Key files: `AppModel.swift`, `MicEngine.swift`, `ContentView.swift` (the `AudioDeviceManager` enum lives here), `CaptureEngine.swift`, `SessionView.swift`, and a new `AudioLog.swift`.
