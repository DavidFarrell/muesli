# Backend child ownership after abrupt app death

The native admission owner already retained source ownership through normal
Stop, timeout, cancellation, actual process exit, stdin close, and stdout journal
close. That parent-only guarantee did not cover a Python child surviving an app
crash. A delayed child could otherwise recreate a meeting that had been moved
once the kernel released the dead app's locks.

## Contract

`BackendAdmissionOwner` acquires the existing meeting's shared outer
`.meeting-access.lock`, then its shared `.backend-owner.lock`, before starting
Python. `BackendProcess.installMeetingLease` passes a versioned, bounded identity
record for the existing directory and both fixed lock files. It passes no
inherited parent descriptor, arbitrary command, or import path in this record.

Every `diarise_transcribe` package entry acquires its own shared pins before
entry-point and model imports. It opens only the existing original directory and
existing locks, rejects changed device/inode, symlink, hard-link, foreign-owner,
or unavailable lock evidence, and rechecks original path identities after lock
acquisition. Acquisition order is outer access, then backend; Python does not
acquire the transcript transaction lock or upgrade a shared lock.

The child deliberately retains its non-inheritable descriptors until actual
process exit. Returning from `main`, a failed or bounded worker join, garbage
collection, and ordinary interpreter exit hooks do not close the pins. The
kernel remains the final release authority. A forked worker can conservatively
retain an inherited pin until its own exit; an exec closes these descriptors.

Both app commands now require `--meeting-lease-required`. Current Python rejects
that flag without independent ownership. The known previous backend parser
rejects the unknown flag before its source `mkdir`, so a configured older backend
fails visibly instead of silently accepting a parent-only pin. Unmanaged CLI use
without an app token remains a separate path; an invalid supplied token always
fails closed. Source arguments for live, reprocess, and generic CLI are bound to
the admitted meeting; reprocess requires its exact root.

This is cooperative filesystem ownership, not a security boundary against a
same-user process deliberately ignoring locks or changing files. The signed XPC
helper, sandbox entitlements, external archive workflow, and installed app are
unchanged by this slice.

## Actual validation (2026-09-05)

- Full Python suite: **122 passed**. Log:
  `/private/tmp/muesli-child-lease-python-final.log`.
- Full app suite: **273 passed**. Log:
  `/private/tmp/muesli-child-lease-swift-final.log`.
- Changed native core compiled with Swift 6, default MainActor isolation,
  complete strict concurrency, and warnings as errors. Log:
  `/private/tmp/muesli-child-lease-strict-final.log`.
- Release build passed: `/private/tmp/muesli-child-lease-release-final.log`.

The Python suite compiles the actual Swift admission owner and native process
implementation. One test SIGKILLs that native parent after the real child has
pinned, verifies both exclusive locks remain refused, permits the surviving
child's final source write, and verifies release only after exit. Two others
SIGKILL the native parent before package admission, move the source under an
exclusive lock, optionally recreate the same pathname with different identities,
and verify that the delayed real child fails before recreating or writing source.
All files and processes are synthetic fixtures.

The Swift suite launches a real independently pinned descendant, lets the
original native admission actually finish, and calls the production catalog
Trash admission with an injected fixture-only move. It refuses deletion while
the descendant owns the meeting and permits it after actual exit. No host Trash
operation or capture hardware is used.

Additional tests cover every package entry mode, required-token absence,
source-path mismatch, changed folder and lock identities, missing locks,
symlink/hard-link locks, an archive winning the pre-pin race, non-inheritable
handles, and a non-daemon worker surviving the main entry's return.

The exact approved pre-child backend (`6845511`) was separately executed with
its real parser/module contents and the new flag: exit 2, unknown flag, no source
folder created. This compatibility probe passed in
`/private/tmp/muesli-child-lease-full-python-v4.log`; it is recorded as a local
historical compatibility check, not a CI test that depends on Git history being
available in a shallow checkout.

## Integration boundary

The native identity installer is commit `4c1db56`. Shared-access foundation and
native-owner dependencies in this worktree are `bfcc4a3` (equivalent to
`f338053`) and `68ccab9` (equivalent to `c9b7baa`). The parallel ownership slice's
`570768d` one-shot access handoff correction must remain present in the combined
app; this follow-up only hardens the separate backend lock validation block and
does not replace that handoff. Wider source/artifact/catalog ownership and
verified archive receipts belong to their separately reviewed slices.
