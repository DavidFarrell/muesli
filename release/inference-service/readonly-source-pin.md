# Read-only source-pin prerequisite

This isolated worktree begins at current application/backend commit `240a7c1`. `c4e8b39` copies the unchanged frozen `fe1a744` helper proof into it; it does not claim that the old four-module proof packaging already ships the current backend. The original proof worktree, picker, installed app and main-app client remain unchanged.

The first backend correction opens both existing shared ownership locks with `O_RDONLY`, preserving `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, exact directory/lock identities, regular-file/single-link/euid checks, fixed lock order, nonblocking shared `flock`, post-acquisition revalidation, and process-lifetime retention. No locks or source directories are created by Python.

Before changing the current backend, an actual separately signed sandbox harness tested the exact old `_ProcessPin` and a copy changing only its `O_RDWR` lock-open flags to `O_RDONLY`. Generated locks are mode `0400`. The old implementation is rejected; the read-only candidate imports the actual current package and reports three read-only, noninheritable descriptors. Both locks block an external exclusive flock after the actual native parent is killed. The surviving Python process rejects a subsequently substituted lock inode, and exclusive admission returns only when that child actually exits. Evidence: `/private/tmp/muesli-current-readonly-pin-v2/results.json`, each case's `events.jsonl`, and `/private/tmp/muesli-current-readonly-pin-v2.log`.

The native test parent has only App Sandbox; the bundled Python test child has only App Sandbox + inherit. Both keep hardened runtime. This pin-only test imports no models and needs neither JIT nor unsigned-memory entitlement. The harness receives a fresh bookmark for its generated temporary folder. Its first attempt without that original grant stopped before Python and is preserved in `...-v1.log`; it is not counted as a read-only-lock failure. Temporary-folder access does not qualify private HOME user-selection/bookmark transfer, which is still pending.

After the correction, all 27 existing actual Python/native-parent lease tests pass, including original-parent death, pre-import archive victory, replaced directory/lock identity, missing/symlink/hardlinked lock rejection, every package entry point and no fallback when app admission is required: `/private/tmp/muesli-current-readonly-existing-corrected-tests.log`.

Reproduction (fresh output; development signing only):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 release/inference-service/tests/test-readonly-pin.py FRESH_OUTPUT SIGNED_FROZEN_PROOF_APP SIGNING_IDENTITY
```

The script copies only the supplied test bundle's runtime into fresh temporary apps, replaces the copied Python package with the current source, and adds a read-write negative-control variant differing by one open flag. It never modifies the supplied proof/runtime or installed app. Its only signals target its own generated native parent and the verified executable/start identity of that parent's child.

Native source-free handshake, typed source admission before Python initialization, full current-package deployment and fixed LiveSource binding are the next isolated steps. This prerequisite alone does not qualify current inference or a main-app adapter.
