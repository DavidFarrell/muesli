# System native retirement after failed startup or stop

A failed native start followed by `attemptToStopStreamState` previously left the
production `NativeSystemCapture` unretired. Its real meeting file lease and Quit
token remained held, and CaptureEngine kept the old stream busy. A later terminal
delegate callback also failed to complete a previously failed cleanup without a
new UI-driven stop attempt. Setup failures before any native start unnecessarily
called `stopCapture` and could enter the same quarantine.

The owner now retires after native stop succeeds, after the documented stopped
state error, or after a terminal delegate callback. A setup failure before any
start invocation skips native stop. Unknown start/stop errors retain ownership;
they do not establish that a partially configured or running stream is stopped.
A delayed terminal callback can complete the original requested retirement on a
worker, including while MainActor is blocked. Native calls still have to return
before output detachment, relay drain and file-lease disposal. Those operations
must all finish before retirement is published and the native Quit token closes.
Repeated stop/delegate events share one cleanup, and a retired generation cannot
start again. CaptureEngine publishes its handle only after native admission
succeeds, avoiding a phantom busy stream when the Quit registry is sealed.

## Native contract checked 2026-09-06

Apple's [attemptToStopStreamState documentation](https://developer.apple.com/documentation/screencapturekit/scstreamerror/attempttostopstreamstate)
defines it as a stream already stopped or absent. Only that code in
`SCStreamErrorDomain` is accepted as stopped evidence. The installed macOS 26.5
SDK's SCError.h has a contradictory duplicated comment for -3808; the current
Apple symbol documentation explicitly describes its stop-state meaning.

The [stopCapture completion contract](https://developer.apple.com/documentation/screencapturekit/scstream/stopcapture(completionhandler:))
reports an error when stopping fails. An arbitrary error therefore cannot release
ownership. The [terminal delegate contract](https://developer.apple.com/documentation/screencapturekit/scstreamdelegate/stream(_:didstopwitherror:))
reports a stream that stopped. The [start completion contract](https://developer.apple.com/documentation/screencapturekit/scstream/startcapture(completionhandler:))
reports whether startup succeeded; this implementation conservatively seeks
separate stopped evidence even after startup fails. Native retirement does not
claim the MP4 artifact finished; the recording delegate retains that responsibility.

## Reproduction and evidence

`NativeSystemCaptureTests.swift` exercises the actual production start/stop owner,
actual relay/forwarder, actual ShutdownWorkRegistry and actual temporary shared /
exclusive MeetingFileAccess locks. Only the ScreenCaptureKit call boundary is
synthetic. No hardware or installed app is used. The native owner itself is not a
stub with a mutable `isRetired` flag.

The seam-only patch in `reproductions/native-system-retirement-seam.patch` applies
to baseline `512f81ea19bd64659d79f2433abb08e328b1ba0e`. It exposes that original
owner to tests and replaces only the framework call boundary plus injectable
shutdown registry; it preserves the original start/stop retirement policy.
To reproduce, apply that patch in a disposable baseline checkout, copy the seven
native tests from this change, and run:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project MuesliApp/MuesliApp.xcodeproj -scheme MuesliApp \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/muesli-system-retirement-repro-derived \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  -only-testing:MuesliAppTests/NativeSystemCaptureTests test
```

The exact same seven-test file, SHA-256
`114a8f246e7852441e7680d6182c886f880152175e0c62f8e6d9de0b10d99f63`,
produced 18 failed assertions across four baseline cases, then zero failures on
the corrected implementation. Baseline safety controls for a running source's
unknown stop error, a blocked native stop and sealed admission already passed.
The failures verify actual file-lock and Quit ownership, delayed delegate cleanup
while MainActor is blocked, setup-before-start cleanup, and a subsequent native
generation using the same operation owner. Logs are local review artifacts:
`/private/tmp/muesli-system-retirement-red.log` and
`/private/tmp/muesli-system-retirement-green.log`.

The complete Swift suite passed 612 tests. Whole-app Swift 6 strict-concurrency
type checking with warnings as errors also passed.

Three additional ownership tests cover terminal evidence during blocked startup,
blocked output detachment, and repeated cleanup / old-generation restart. The
existing system terminal-health reproduction keeps its actual relay method and
adds only an unused native-observer container to its framework-free health probe.

Unknown errors without later terminal evidence remain quarantined with truthful
pending Quit ownership. This is deliberate: a timeout or an arbitrary error must
not falsely claim macOS stopped capture. Physical capture, signed packaging,
installed Quit/recovery and long-run qualification remain separate open work.
