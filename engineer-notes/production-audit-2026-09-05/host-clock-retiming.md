# Preserve continuous audio through device-clock drift

The previous processor compared the current native host timestamp with all
elapsed native frames at the nominal sample rate. Continuous device-clock drift
eventually crossed its 2 ms threshold. It then flushed the SRC, reanchored output
timestamps, and caused the actual source recorder to insert gaps or trim samples.

The unchanged original regression in
`reproductions/continuous-clock-drift.patch` applies to baseline `512f81e`. It
passes 600 contiguous 100 ms generated native buffers through the actual
AVAudioConverter and LocalAudioRecorder at each of -100 and +100 ppm. Baseline
results were three converter epochs and two source losses per run: 64 overlapping
frames trimmed at -100 ppm, 64 gap frames at +100 ppm, six failed assertions.
The corrected processor produces one epoch, zero gaps/overlaps/losses, and a
completed source in both runs. Logs are local evidence, not shipped recordings:
`/private/tmp/muesli-clock-drift-original-red.log` and
`/private/tmp/muesli-clock-drift-integrated-v2.log`.

## Clock and continuity policy

AVAudioConverter keeps its native-rate filter and phase for contiguous input.
The host retimer closes each nominal-output interval using the next native host
timestamp. It emits consecutive integer frames on one host 16 kHz grid through a
128-tap Blackman-windowed sinc. The next timestamp and filter support introduce
bounded lookahead. State contains recent anchors and filter history, not a growing
recording. Callback arrival time is never a timestamp source.

The supported observed clock range is +/-5000 ppm, with a separate 2 microsecond
allowance for timestamp quantization. This is an interval check, not a growing
epoch tolerance. Tiny callbacks can therefore have apparent diagnostic ratios
outside that range due to microsecond rounding. Format changes, unsupported host
time jumps and actual native sample-position discontinuities start new epochs.
Empty callbacks do not change conversion or timing state.

Only valid AVAudioTime sample positions with the buffer's sample rate supply an
exact native counter. A positive native gap retains its exact native-frame count;
a backward counter may reset its origin and does not prove a missing duration.
The recorder alone counts representable host-grid gaps or overlap. A separate
failure notice retains native discontinuity evidence, including gaps smaller
than one output frame, without counting that same interval twice.

Capture-session and ScreenCaptureKit buffers keep host-only continuity
uncertainty. Apple states an AVCapture input-port clock may not represent the
actual device clock. Inverse CMSync conversion must therefore not be rounded
into a fabricated exact sample counter. Small missing intervals and timestamp
noise can be indistinguishable without native frame-position evidence. This
limitation is explicit, rather than a claim that every acoustic event was captured.

At each epoch's final callback there is no next timestamp. Only that bounded tail
uses the last measured ratio (or nominal duration for a single callback), and
unavailable filter support is zero padded. Each such extrapolation increments
the uncertain-interval count. Cumulative nominal/native/host frames, ratio extrema
and uncertainty are forwarded through the real ingress/forwarder and persisted
as bounded clock summaries. These observations are distinct from capture loss.

## Verification and independent corrections

Generated waveform tests cover -5000, -100, 0, +100 and +5000 ppm, irregular
partitions, changing rates, timestamp jitter, final tail, bounded history and
actual processor -> ingress -> forwarder -> durable recorder delivery. The 1 kHz
waveform alignment SNR exceeds 78 dB at nonzero tested drift; the 7 kHz passband
is within 0.1 dB. A 7,990 Hz input at the fastest supported clock is rejected by
75.8 dB. The initial 64-tap candidate achieved only 25.2 dB and was rejected;
the filter was strengthened before approval. No near-neighbour or linear PCM
interpolation is used.

Independent actual-method regressions found and corrected three flaws in the
initial proposal. A native counter origin reset could invent eight hours of
dropped audio; a genuine 10 ms gap was counted twice; and inverse clock-derived
integers falsely certified continuity and produced 15 epochs from continuous
100 ppm drift. The accounting tests are unchanged between red and green. The
inverse-clock test only removes the rejected API argument in the final code.
An additional unchanged regression found empty callbacks lost 40 output frames
at 44.1 kHz; it now preserves all 6,400 frames with one epoch. Quantized irregular
partitions stay continuous and within one host frame at both supported extremes.
Evidence: `/private/tmp/muesli-clock-ingress-accounting-red.log`,
`/private/tmp/muesli-clock-ingress-native-clock-red.log`,
`/private/tmp/muesli-clock-ingress-boundary.log`, and
`/private/tmp/muesli-clock-drift-final-boundaries.log`.

Eight-hour frame/time arithmetic fits comfortably within Int64 and Double
precision; that is an arithmetic review, not an eight-hour execution test.
Physical device alignment, long recording, route changes and sleep/wake remain
installation qualification work. Generated tests do not replace those checks.

## Primary API contracts checked 2026-09-06

- [AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime)
  separates sample-time and host-time validity.
- [AVCapture input-port clock](https://developer.apple.com/documentation/avfoundation/avcaptureinput/port/clock)
  need not be the actual device clock.
- [AVCaptureSession synchronizationClock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock)
  describes timestamp conversion to the original input-port timebase.
- [CMSyncConvertTime](https://developer.apple.com/documentation/coremedia/cmsyncconverttime(_:from:to:))
  compensates measured clock drift; converted time is not an exact frame counter.
