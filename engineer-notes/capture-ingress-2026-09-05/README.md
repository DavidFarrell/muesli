# Capture ingress and source timing

5 September 2026. First implementation slice for audit F1/F6.

Microphone native callbacks now invoke a Sendable callback from a nonisolated factory. `MicAudioIngress` admits an ordered, byte-bounded prefix and owns one detached draining worker. Its cap includes the in-flight packet. Saturation rejects newest input with packet/sample/byte counters, timestamps and an optional synchronous rejection callback for the recording owner's loss ledger. Display publication retains only the latest snapshot and recovery flags. Stop retires the native processor, drains SRC, drains admitted packets, then retires the forwarder. Each source has its own processor, ingress, actor, generation and stop path.

`CapturedMicAudio` carries native rate, channels, native frame count, format epoch, generation, normalized frame count and the first output sample's host timestamp. AVAudioEngine uses AVAudioTime.hostTime. AVCaptureSession converts sample PTS through `synchronizationClock` to the CoreMedia host clock. ScreenCaptureKit sample PTS and screenshots use that host domain. One immutable `CaptureTimeline` is established before either source starts and survives individual source restarts.

The host clock suspends during sleep. Recording lifecycle work must explicitly journal sleep as a pause/discontinuity; this slice does not imply source capture during sleep. No callback-arrival clock is used to invent native timing. A native format change or a measured source timestamp break exceeding 2 ms starts a fresh converter epoch and retains the actual source gap.

`AVAudioConverter` now retains filter and phase state across native callbacks. Normal priming compensates filter delay. End-of-stream draining and cumulative source-duration accounting remove filter padding without dropping fractional surplus between callbacks. Output is always signed 16-bit, 16 kHz, mono for both sources, regardless of the native format. The microphone intentionally averages active channels across fixed 20 ms source-frame analysis windows so inactive receiver lanes do not reduce a live lane. A stable divisor within each window preserves genuine stereo at zero crossings; retaining partial windows makes the policy independent of callback partitioning. Mono and system audio require no analysis lookahead. System audio uses arithmetic averaging of all channels.

The actual SCK relay is nonisolated and uses the same converter/ingress implementation; CaptureEngine owns UI and lifecycle only. Raw callback, conversion failure, converted frame and native format diagnostics are available separately from the latest-only meter publication.

## Verified

- All 126 Swift tests passed with Xcode's local test service, including the new capture/converter tests. Final full-suite log: `/private/tmp/muesli-ingress-tests-verified.log`.
- The exact callback factory used in AppModel delivers four seconds of synthetic native microphone samples while MainActor is synchronously blocked. Tests inspect the sink's samples and PTS before allowing UI execution.
- Saturation counts the in-flight packet, retains the accepted prefix, reports rejected source intervals and drains accepted data on stop.
- Bunched delivery retains native PTS; old generations cannot send after replacement. Separate mic/system forwarders and screenshot calculations share the same epoch through a simulated restart.
- A native CMSampleBuffer fixture drives the actual system relay at 48 kHz stereo; its sink receives exactly 16,000 mono samples for one second and retains the 250 ms source offset.
- At 44.1 and 48 kHz, arbitrarily partitioned input produces exactly the same samples as one large input buffer, with exactly 16,000 output samples per second. Impulse position confirms filter-delay compensation. A 12 kHz tone has at least 40 dB attenuation when converting 48 to 16 kHz. Active-channel and stereo downmix tests pass.
- Ad-hoc-signed Release compilation succeeded. Log: `/private/tmp/muesli-ingress-release-final.log`.
- [Compiler evidence](production-ingress.sil.txt), generated from the actual app sources with the app's MainActor default and concurrency flags, contains no MainActor reference in the production callback or forwarding closure. [Regeneration script](check_compiler.py).

## Integration boundaries

This slice retains `FrameSending` as the normalized audio sink. Independent durable storage, authoritative event journaling, lifecycle deadlines, recovery supervision and explicit sleep handling belong to subsequent slices. `MicAudioIngress.forwarding` accepts `onRejected(packet, reason)` for the recording loss ledger; callbacks must remain bounded and nonblocking. Native metadata is still available in `MicAudioForwarder.deliver` for a richer recording sink interface.

Three existing AppModel concurrency warnings remain: its detached temporary-file cleanup and nested weak-self task captures. No warning remains in the capture/converter/ingress/forwarder path. No microphone or screen was captured and no installed app was changed. Synthetic tests do not establish long-run hardware drift, Bluetooth route reliability, or real screenshot/audio alignment; those still require the controlled hardware acceptance matrix.

Apple API contracts: [AVAudioConverter sample-rate conversion](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions), [clock conversion](https://developer.apple.com/documentation/coremedia/cmsyncconverttime(_:from:to:)). The installed Xcode SDK's AVCaptureSession.h identifies synchronizationClock as the timebase of capture-output sample buffers.

Independent review identified per-sample activity as incorrect at stereo zero crossings. The follow-up uses fixed analysis windows and adds a 16,017-sample oscillating-stereo regression, including a final partial window. It compares every output sample with arithmetic stereo averaging and proves identical output for single-sample, irregular, and whole-buffer partitions.
