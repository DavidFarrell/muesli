# Implementation plan - ObjC exception bridge for MicEngine (11 Aug 2026, rev 3)

**Incident:** MuesliApp aborted 11 Aug 09:08:40. A Bluetooth headset disconnected
messily; the start-screen preview mic engine restarted; mid-restart the HAL input
format was invalid (0 ch / 0 Hz) while `inputNode.outputFormat(forBus: 0)` still
reported a stale 44.1 kHz / 2 ch format, so the `isUsableInputFormat` guard passed;
`installTap` then compared against the live hw format and raised the ObjC exception
`"Failed to create tap due to format mismatch"`. Swift `do/catch` cannot catch
NSExceptions and the codebase has no bridge, so the process died via
`_objc_terminate` -> `abort()`. The Catherine meeting had already finalized cleanly;
only the idle preview was running.

**Goal:** an NSException raised by AVFoundation during mic-engine start becomes an
ordinary thrown Swift error, absorbed by the failure handling that already exists
(`handlePreviewMicStartFailure`, the meeting-side recovery ladder, the
CaptureSession fallback). The app must never again abort because a device vanished
mid-restart.

**Non-goals:** no change to `CaptureEngine` (system audio / recording), no change to
`CaptureSessionMicEngine` (AVCaptureSession reports errors, it does not raise), no
attempt to close the TOCTOU window itself (the OS owns it; converting the raise to
an error IS the fix), no retry logic (the recovery ladder already owns retries).

## Facts the plan rests on

- The only `AVAudioEngine()` and the only `installTap` in the app are in
  `MuesliApp/MuesliApp/MicEngine.swift` (lines 66, 127). Both the preview and the
  meeting mic paths go through `MicEngine.start` -> `startEngine`, so one change
  covers both.
- The Xcode project uses filesystem-synchronized groups
  (`PBXFileSystemSynchronizedRootGroup`): new files under `MuesliApp/MuesliApp/`
  auto-join the **app** target.
- The **test target does NOT link the app**: `MuesliAppTests` has no `TEST_HOST`
  and no `BUNDLE_LOADER`. It compiles selected app sources directly into the test
  bundle via a `PBXFileSystemSynchronizedBuildFileExceptionSet`
  `membershipExceptions` list (pbxproj lines 24-50; filenames only, files live
  flat in `MuesliApp/MuesliApp/`). Any new source a test exercises must be added
  to that list, and since the ObjC class arrives via bridging header (not a
  module), the test target needs its own `SWIFT_OBJC_BRIDGING_HEADER` setting.
- There is currently no bridging header anywhere. The full, honest pbxproj cost is
  therefore:
  - `SWIFT_OBJC_BRIDGING_HEADER = "MuesliApp/MuesliApp-Bridging-Header.h";` in the
    **app** target's Debug + Release `buildSettings` (blocks `636552DB` /
    `636552DC`),
  - the same setting in the **test** target's Debug + Release `buildSettings`
    (the `SUPPORTED_PLATFORMS = macosx` blocks),
  - `ObjCExceptionCatcher.m` and `ObjCExceptionCatching.swift` appended to the
    `membershipExceptions` list.
  The path is `$(SRCROOT)`-relative and `$(SRCROOT)` is the `MuesliApp/` folder
  holding the xcodeproj - it matches the existing `CODE_SIGN_ENTITLEMENTS =
  MuesliApp/...` pattern.
- Both targets set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so any new free
  function is MainActor-isolated unless declared `nonisolated`.
- The test target exists (`MuesliAppTests`, 18 suites) and per the overlay tests
  pure decision logic only - no hardware. An NSException raised *by the test
  itself* inside the bridge is hardware-free and exactly testable.
- Tests + build need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (xcode-select points at CommandLineTools). Scheme: `MuesliApp`.
- `startEngine` is synchronous (no `await` inside), so a synchronous ObjC
  `@try/@catch` wrapper composes with it directly.

## Slice 1 (the whole fix - one slice)

### 1. `MuesliApp/MuesliApp/ObjCExceptionCatcher.h` + `.m` (new)

```objc
// .h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
extern NSErrorDomain const MuesliObjCExceptionErrorDomain;

@interface ObjCExceptionCatcher : NSObject
/// Runs the block; an NSException raised inside it is returned as an NSError
/// (domain MuesliObjCExceptionErrorDomain, userInfo carries the exception name
/// and reason) instead of propagating.
+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))tryBlock
                 error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
```

The `.m` is a plain `@try { tryBlock(); return YES; } @catch (NSException *e) {
*error = ...; return NO; }`. **`NSException.reason` is nullable: the `.m` maps a
nil reason to `"unknown"` when building the NSError userInfo**, so the Swift side
never sees a missing key. No swallowing of non-NSException C++ throws - those stay
fatal, which is correct (they are not the device-churn case and we cannot reason
about their state).

### 2. `MuesliApp/MuesliApp/ObjCExceptionCatching.swift` (new)

The Swift-side helper lives beside the `.m` as an **internal, `nonisolated` free
function** (not a private actor method) so both the app and the test target can
exercise the real shipped code. Its error type lives in the SAME file, deliberately
decoupled from `MicEngineError` - MicEngine.swift is not in the test target's
membership list and cannot reasonably be added (it drags in AVFoundation actor
code), so the helper must not reference it:

```swift
/// An ObjC NSException caught at the bridge, surfaced as a Swift error.
struct ObjCExceptionError: Error, CustomStringConvertible {
    let name: String
    let reason: String
    var description: String { "NSException \(name): \(reason)" }
}

/// Runs `body`, converting an ObjC NSException raised inside it into a thrown
/// ObjCExceptionError. Swift errors thrown by `body` pass through unchanged.
nonisolated func catchingObjCExceptions<T>(_ body: () throws -> T) throws -> T
```

No new `MicEngineError` case: both absorption sites
(`handlePreviewMicStartFailure`, `handleMeetingMicEngineStartFailure`) catch
generic `Error`, and the `engine.start.fail` event stringifies whatever is thrown,
so `ObjCExceptionError` flows through unchanged and its fields surface via
`String(describing:)`/`description`.

Mechanics: capture `body`'s result or thrown Swift error into locals inside the
non-escaping ObjC block (`NS_NOESCAPE` imports as non-escaping, so actor-state
capture at the call site stays legal); call
`ObjCExceptionCatcher.catchException`; if it reports an NSError, throw
`ObjCExceptionError(name:reason:)` built from its userInfo; otherwise rethrow
the captured Swift error or return the captured value. `nonisolated` is required:
with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a bare free function could not be
called from MicEngine's actor-isolated synchronous `startEngine`.

### 3. `MuesliApp/MuesliApp/MuesliApp-Bridging-Header.h` (new)

One import: `#import "ObjCExceptionCatcher.h"`.

### 4. `project.pbxproj` - the edits from "Facts" above

Four `SWIFT_OBJC_BRIDGING_HEADER` lines (app Debug/Release + test Debug/Release)
and two filenames appended to `membershipExceptions`. Nothing else.

### 5. `MicEngine.swift` - integrate

- No `MicEngineError` change (see step 2 - the bridge throws its own
  `ObjCExceptionError`).
- `startEngine` restructures to this shape (shown so the review is of the actual
  structure, not a slogan):

  ```swift
  private func startEngine(...) throws {
      let engine = AVAudioEngine()
      let inputNode = engine.inputNode          // unwrapped - see tradeoffs

      if let preferredInputDeviceID { ... }     // C API, cannot raise - unchanged

      do {
          try catchingObjCExceptions {
              if enableVoiceProcessing { try inputNode.setVoiceProcessingEnabled(true); ... }
              let nativeFormat = inputNode.outputFormat(forBus: 0)
              ...log + guard isUsableInputFormat else { throw .invalidInputFormat(...) }
              inputNode.installTap(...) { ... }
              if let onConfigurationChange { configChangeObserver = ... }
              engine.prepare()
              try engine.start()
          }
          self.engine = engine
      } catch {
          engine.inputNode.removeTap(onBus: 0)
          engine.stop()
          if let observer = configChangeObserver {
              NotificationCenter.default.removeObserver(observer)
              configChangeObserver = nil
          }
          throw error
      }
  }
  ```

  **Deliberate semantics change, recorded:** today the cleanup (current lines
  160-172) runs only when `engine.prepare()`/`engine.start()` fails; failures at
  `setVoiceProcessingEnabled` or the `invalidInputFormat` guard skip it. In the
  new shape the cleanup runs for every failure inside the block. This is safe and
  intended: `removeTap` with no tap installed and `stop()` on a never-started
  engine are safe in practice (no-ops as observed; neither raises - Apple does
  not document this), and observer removal is guarded by the optional.
  One catch path instead of three is the smaller structure.
- Log the caught case through the existing channel: the `engine.start.fail` error
  event in `start()` already stringifies the thrown error, so the exception name
  and reason land in the unified log with no new logging code.

### 6. `MuesliAppTests/ObjCExceptionCatcherTests.swift` (new)

Three tests, all hardware-free, each fails meaningfully if the bridge or its
integration is deleted:

1. `catchingObjCExceptions` with a body that calls
   `NSException(name:reason:userInfo:).raise()` -> throws `ObjCExceptionError`
   carrying that name and reason.
2. `catchingObjCExceptions` with a body that returns a value -> the value comes
   back, nothing thrown.
3. `catchingObjCExceptions` with a body that throws a Swift error -> the SAME
   Swift error comes out, not wrapped as `ObjCExceptionError`.
4. A nil-reason NSException (constructible via the public
   `NSException(name:reason:userInfo:)` initializer) -> `ObjCExceptionError`
   with reason `"unknown"` (locks the `.m`'s nil mapping).

All four exercise the real shipped function (internal + compiled into the test
target per step 4).

### Verification (copy-pasteable from the repo root)

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project MuesliApp/MuesliApp.xcodeproj -scheme MuesliApp \
  -destination 'platform=macOS'
xcodebuild -project MuesliApp/MuesliApp.xcodeproj -scheme MuesliApp \
  -configuration Release -destination 'platform=macOS' build
```

Full suite green (existing 18 suites + the new one); Release build compiles.
Manual scenario (post-merge, David): disconnect Bluetooth headphones while the
start-screen preview is live - app survives, preview recovers or parks with the
existing alert; no crash report.

### Accepted tradeoffs (recorded, not hidden)

- ObjC exception unwinding does not run ARC cleanups for the frames it crosses -
  a caught exception may leak the partially-configured engine. Accepted: the
  status quo is `abort()`. The engine object is small and the event is rare.
- **`engine.inputNode` (line 67) stays unwrapped.** It can reportedly raise during
  extreme churn on some OS versions, but the incident was at `installTap`, and
  wrapping first-touch property access would push the bridge outward speculatively.
  If a future crash report lands there, extend the block upward one line.
- **`stop()` stays unwrapped** (`removeTap`/`engine.stop`, lines 203-204). Same
  reasoning: no observed incident, teardown raises are not the device-churn case,
  and a raise there would indicate state we should not paper over.
- The cleanup-semantics change in step 5 (cleanup now runs for all in-block
  failures, not just start failures) - intended, see there.
- The stale-format TOCTOU remains; a future start attempt after the device
  settles succeeds. The recovery ladder already handles "start failed, retry
  later".

### Deployment

After merge: rebuild Release + `ditto` into /Applications per
`~/dfsystem/muesli-build.md`, relaunch. (David runs from /Applications since
7 Jul.)
