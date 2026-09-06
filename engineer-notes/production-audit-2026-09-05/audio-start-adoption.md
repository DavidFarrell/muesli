# Initial microphone start adoption (6 September 2026)

Fresh combined review at ce7028c found a P1 ownership defect. Initial meeting microphone startup bypassed the microphone lifecycle worker. Stop could finish while that native start was pending because `micEngine` had not been assigned. Its later UI continuation checked generation and `!isFinalizing`; Stop did not retire the generation, and finalization eventually cleared that flag. The continuation could therefore assign a live old engine after Stop, including over a subsequent source. The caller's later source check did not stop that engine.

The source now has a distinct microphone intent, retired before the first Stop, failed-start teardown or Quit suspension. An attempt captures immutable recorder, timeline, event path, meeting access and Quit intent. Setup and failure cleanup revalidate source and generation after suspensions. Initial startup uses the same retained/coalescing microphone lifecycle worker as route and recovery work, so shared forwarder commands cannot race a second startup. Stop records a source failure before closing the recorder if microphone startup was never adopted.

CaptureOperationOwner optionally offers native-start adoption while it still owns the native operation. The MainActor callback checks current source/generation and takes a synchronous, one-use claim immediately before assigning the engine. Claim and deadline retirement share a lock. Claim releases native admission atomically before assignment, allowing an immediate Stop to reserve it; refusal or timeout instead retains the original reservation and Quit token through actual native stop and ingress drainage. One queued UI offer cannot hold cleanup hostage: the independent deadline retires its claim and releases the cleanup worker even while MainActor is blocked. Existing non-adopting operation callers retain their previous contract.

## Reproduction and verification

`reproductions/check_mic_adoption.py` reads the actual AppModel adoption block and source predicates plus the actual CaptureOperationOwner, completion and shutdown implementations. It substitutes small storage/UI containers and a gated native engine identity, avoiding hardware-backed AppModel initialization. It is a focused boundary test, not a claim to execute the complete app start/stop flow.

Run from this checkout with the local Xcode toolchain:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 engineer-notes/production-audit-2026-09-05/reproductions/check_mic_adoption.py --source-ref ce7028c
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 engineer-notes/production-audit-2026-09-05/reproductions/check_mic_adoption.py
```

The same probe fails on ce7028c for Stop-completed, Stop/new-source and Quit/Cancel, and passes on the correction. Same-source generation replacement remains rejected; healthy current startup remains accepted. Logs: `/private/tmp/muesli-initial-mic-adoption-red.log` and `/private/tmp/muesli-initial-mic-adoption-green.log`.

Six additional actual XCTest owner tests cover late original cleanup before replacement, immediate Stop after claim, a blocked MainActor past adoption deadline, Quit/Cancel rejection and Quit-token retention through a rejected start's actual cleanup. The queued UI offer holds a consumable box; the worker clears its resource payload before retiring the token. A real shared source lease closes and a fresh exclusive lease succeeds while MainActor is still blocked. All 60 selected lifecycle/Quit/forwarder/recorder tests passed, followed by the full 530-test Swift suite, including CaptureIngressTests. Whole-app Swift 6/default MainActor/complete-concurrency/warnings-as-errors passed with an empty log. Evidence: `/private/tmp/muesli-audio-review-final-tests.log`, `/private/tmp/muesli-audio-review-full-tests.log` and `/private/tmp/muesli-audio-review-strict.log`. An optimized, identified ad-hoc Release is checked separately after the commit is frozen.

No recording, route changes, Mac sleep, actual Quit, installed replacement or client data were used. This correction addresses the confirmed initial-start ownership defect. The fresh F1–F9 integration review paused to fix it; it is not a completed all-day hardware or whole-project qualification.
