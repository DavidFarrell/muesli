# Retired initial setup after immediate Cancel Quit

Initial setup captures the Quit coordinator's Start token before its first
suspension. Once source files have been adopted, the remaining setup used only
the current recorder/events predicate. Cancel Quit reopens admission, so an
initial microphone closure that had not entered yet could capture the new Quit
token and start native work for the retired initial request. The same gap existed
after the initial forwarding setup and audio-format waits.

The initial setup now requires its original token after each remaining
suspension: forwarding setup, system capture start, microphone lifecycle drain,
format detection and backend admission. The queued initial microphone also
requires the original token before entering its source context. Backend startup
checks the token before admission and before claiming an offered process. A
cancelled initial attempt escapes the inference-only failure handler and reaches
the existing failed-start cleanup.

Every continuation first checks the original recorder and events identity.
If Stop already owns that source or another source replaced it, the old callback
does nothing. Otherwise a retired token throws, marks that original source as
finalizing and runs its owned cleanup, preserving its session index and captured
PCM. The original Start work token remains held across this cleanup; individual
native and disk owners retain their own tokens if bounded waits expire. No
global microphone-source retirement was added to accepted Quit. Established
recording recovery may still continue after Cancel Quit.

`reproductions/check_initial_start_intent.py` extracts the actual production
queue, initial enqueue, continuation predicates, adoption and failed-start catch,
plus the actual Quit coordinator and operation owner. Native capture, final
cleanup and source/UI containers are synthetic, avoiding AppModel initialization.
The original three queue scenarios are unchanged: healthy initial setup starts;
retired initial setup must not start; established recovery remains permitted.
Additional pre-system/pre-backend cases require original-source cleanup and
preserve a replacement source. The identical probe is red against `5b4182d` and
green against this correction:

- `/private/tmp/muesli-initial-start-intent-probe-red.log`
- `/private/tmp/muesli-initial-start-intent-probe-green.log`

Actual XCTest coverage uses the coordinator, source recorder and its original
file lease. A blocked commit outlives the initial cleanup waiter, retains Quit
ownership and prevents source reuse until actual close. It preserves the accepted
system PCM and records incomplete microphone startup. This is independent of the
separately reviewed native microphone Request ownership and per-stream disk-error
corrections. No app activation, capture hardware or Trash action is exercised.

The related 70-test run passed 69 tests, including all 15 cooperative-Quit tests,
and reproduced the already open microphone-offer ownership failure in
`testExpiredMicUIOfferReleasesActualSourceLeaseWhileUIRemainsBlocked`. That
separate Request/perform correction is not included or masked by this slice.
Exact log: `/private/tmp/muesli-initial-start-intent-tests.log`.
