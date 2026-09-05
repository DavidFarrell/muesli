# Backend admission and actual resource ownership

The previous live startup synchronously acquired/flocked/synchronized the event journal on MainActor, then held `processLock` across `Process.run`. Moving only the call to a background task would still let cancellation block the UI on that lock and could publish a late backend into a stopped session.

`BackendAdmissionOwner.start` admits one retained attempt. Its worker owns folder security access, executable lookup/stat, backend and stdin-writer construction, journal setup and native launch. The independent monotonic deadline retires unclaimed intent even if MainActor never observes the ready offer. The consumer must claim on its publication executor after checking the original source identity, with no intervening await. Stop retires unclaimed admission before native teardown. AppModel makes Stop available once the source/session exists and fences every subsequent awaited startup step by the original recorder and event URL.

The deadline is a caller outcome, not operation completion. A blocked factory or native launch retains its admission. A late successful native start belongs to the original owner, which terminates/escalates it and waits for actual exit. A healthy claim retains the same owner until the normal child exits. Both paths retain folder access through the writer's actual queued close and the reader's actual journal close. A stalled close leaves admission busy. Repeated close waits share one stdin close operation and completion event, so a stuck writer cannot accumulate queued closes.

BackendProcess serializes native launch and process-control commands on its native queue; the small lock contains only snapshots and callbacks. `terminate`, `forceKill`, `isRunning` and cancellation never wait for native launch. Real prepare/launch checkpoints are fault-injection seams only. Batch uses the same owner, includes startup in its overall deadline, and keeps one runner in AppModel. Cancellation waits at most two additional seconds for prompt cleanup; unfinished cleanup remains owned and refuses another launch.

Live and batch admission also hold a shared `.backend-owner.lock` in the meeting folder. Actual catalog Trash holds an exclusive lease throughout its move, so a source whose Stop/finalizer has returned cannot be moved while an unclaimed native launch or event journal still owns it. The lock is acquired before factory IO, uses `O_CLOEXEC` and `O_NOFOLLOW`, never creates the source folder, and checks its original-path inode after acquisition to reject an open-versus-move race. Metadata finalization remains independent of this deletion lease.

The live source recorder and source-session journal stay Swift-owned. Initial output before UI handoff remains durably journaled, and AppModel adopts the journal's actual start offset. Missing/failed/timed-out inference still yields degraded finalization and leaves source audio available. This patch does not integrate or qualify the pending XPC runtime, change its entitlements, operate capture hardware, or access user recordings.

Validation uses synthetic child processes and isolated temporary fixtures:

- Real prepare blocked after journal flock: bounded UI return, MainActor heartbeat, actual source PCM commits while UI is blocked, hard-link competitor refusal, no late child launch, and actual-close lease release.
- Offered result left unclaimed while MainActor is blocked: deadline and cleanup complete without UI assistance.
- Stop retires an old offer; a new source cannot claim it or launch until the original closes.
- Native before-run and after-run stalls: cancellation/control/snapshots return promptly, ownership persists, and late child exits before release.
- Child exits while journal write remains blocked: scope and admission persist through actual journal closure.
- Setup/launch exceptions, 800 events preceding UI attachment, durable prefix/start offset, and production Batch cancellation during real journal setup.
- Forty waits behind a real blocked stdin pipe queue exactly one close, reject later sends, and observe the same prompt actual completion.
- Stopped/unclaimed native launch keeps catalog Trash blocked, including through a folder alias; actual owner closure permits the move, while a move's exclusive lease rejects new launch factories.

Final full 271 Swift tests passed in `/private/tmp/muesli-admission-lease-corrected-tests.log`. Strict Swift 6/default-MainActor/warnings-as-errors typechecking of the actual owner, backend, reader, completion and backlog sources passed in `/private/tmp/muesli-admission-strict-corrected.log`, using the exact extracted FrameSending protocol. Release passed in `/private/tmp/muesli-admission-release-corrected.log`. The old cat teardown test now waits for child exit before explicitly aborting stdout, matching the production drain contract rather than relying on a delayed close barrier. These are local development checks, not hardware or signed production qualification.
