# Reliability implementation ledger

Goal opened 5 September 2026 at David's request. Completion requires all audit issues corrected and an independent final Astra adversarial review with no P2-or-higher findings. Hardware claims require hardware evidence. This ledger does not replace those gates.

## Baseline

- Audited source: `64cbcafd9d046c65f89934588cd1d13d29a17351`.
- Audit/evidence checkpoint: `b072fd6`.
- GitHub main verified to match the audited source at implementation start.
- User authorizes implementation, PR creation, resolving reviewer disagreements, and merging only after Astra approval. Ask David only at a true impasse.

## Work and gates

| Item | Implementation | Independent review | Verification / remaining work |
|---|---|---|---|
| F1 bounded non-UI microphone ingress | Merged PR #6, `83ee2a5` | Astra approved `bdc2402` | Callback/UI blocking regression passed; bounded ingress verified |
| F6 original capture timestamps, shared clock, streaming converter | Merged PR #6, `83ee2a5` | Astra approved corrected `262b5f8` and merge head `bdc2402` | Jitter, partition, stereo conversion and UI blocking tests passed; hardware alignment remains |
| F8 independent starvation detection and genuine completion deadline | Merged PR #5, `fe9030c` | Astra approved `da6779c` | Off-UI detection and typed completion tests passed; native lifecycle assessed separately |
| F7 authoritative local recording independent of inference | Merged PR #7, `1240cee` | Astra approved `f0be283`; merge tree identical | 170 Swift + 64 Python tests passed, including all six reviewer regressions |
| F2/F3/F4/F5 unified preview/recording supervision and honest recovery | Merged PR #9, `25f69c9` | Astra approved author `3d5abae` and root integration `0c7bb87` | 193 combined Swift tests passed; reviewer independently ran actual lifecycle tests |
| F8 complete lifecycle bounds and artifact outcomes | Native bounds in `58eb4d3`; recording delegate `37f0dc5`; artifact finalization in progress | Independent review running | Start/stop callback timeouts, no competing owner, MP4 completion, interrupted metadata |
| F9 session-scoped screenshot/video integrity | Session artifact owner in progress; recovery/reprocessing frozen `48bb79d` | Pending | Resume, late callbacks, failed writes, common time |
| Offline mode/assets and Merge handoff | Offline merged PR #8, `480dfdf`; external Merge instructions updated with backup | Astra approved `63d8b57` and revised Merge contract | 77 Python tests, Release build, actual ASR+Senko synthetic speech under OS network denial passed; signed-package qualification and shared archive ownership remain |
| Distribution, build identity, CI, clean install/rollback | Pending | Pending | Signed release/runtime manifest; exact supported matrix |
| Duration/media integrity semantics | Pending | Pending | Recorded duration excludes idle gaps between sessions |
| Whole-project adversarial Astra audit | Not started | Must be a fresh review | No open P2+ findings |
| Release soak/hardware matrix | Not started | Pending | Actual wall time/routes and controlled signals, no substitute from unit tests |

## Design decisions

- Keep independent system and mic capture; a mic replacement must not stop system capture or MP4.
- Use a shared source clock created before capture, with original buffer timestamps. Explicitly journal sleep transitions; do not relabel delayed buffers with delivery time.
- Swift owns source PCM and a committed-byte manifest. Python reads only committed prefixes in the new mode; it must never open source files for writing or delete them. Existing framed-stdin mode remains supported for compatibility/tests.
- Authoritative events reach disk before UI delivery. Meter messages are disposable; transcript/control events are not.
- A timeout must report uncertainty and retain ownership correctly. Cancelling a Task is not proof that a framework operation ended.
- Preserve existing meetings/readers; schema changes need migration/defaults and tests.

## Review record

- PR #5: https://github.com/DavidFarrell/muesli/pull/5 — Astra-approved head `da6779c575c878f5945fe66936a0e4a30065f225`; merged as `fe9030cdc5cce9bbf9bf8230d5fcc4f869799d6e` on 5 September 2026.
- PR #6: https://github.com/DavidFarrell/muesli/pull/6 — Astra-approved head `bdc24029bf2979afe21c260c75d0711e3ab2e071`; merged as `83ee2a5f92f59a1c8093c20a0c1c7fa8b5102130` on 5 September 2026.
- F7 review identified inference-failure false success, unreported source gaps/overlap, failed-resume session rollback, torn UTF-8 replay and overlapping journal owners. Corrected in `01c501a`; reviewer independently verified all five. The final follow-up found stale published durability during a subsequent blocked synchronization; `f0be283` publishes each successful committed prefix immediately and adds a 602-event stalled-sync regression. Astra approved `f0be283`; merged PR #7.
- Review rejection is treated as work to resolve, not as a reason to waive the release gate. No hardware soak, clean-install, signed distribution or final whole-project approval is claimed.

## Additional merged and external work

- PR #7: https://github.com/DavidFarrell/muesli/pull/7 — approved source durability tree `f0be283`, identical merge candidate `ebe798d`; merge `1240cee6c709ba030e368ee1882f875c0a5d2eb6`.
- PR #8: https://github.com/DavidFarrell/muesli/pull/8 — approved offline tree `63d8b57`, identical candidate `690a587`; merge `480dfdf3c7e8f1f46ec1c4d28dad8c9bd00bff4f`.
- PR #9: https://github.com/DavidFarrell/muesli/pull/9 — approved combined lifecycle tree `0c7bb87`, identical candidate `9f28ddf`; merge `25f69c98570ce2d8762a0676f70940340d9f1fff`.
- External Merge skill: independently reviewed and hash-guarded update applied to its existing Obsidian skill location; original saved as `SKILL.md.pre-reliability-2026-09-05`. Approved contract hash `acae0f06158d54c1a4e9f30e47af10e8bee12d99da22a49f648dd31ac9208342`; installed entrypoint hash after reviewer-recommended example polish `9826846d12d3a0780ee6dea96ac4de0c7cb6995405b5f5ba4dd355d60eb8aa02`. No client recording processed or trashed. Cleanup remains blocked while Muesli runs until a shared ownership mechanism exists.
- Actual installed-runtime qualification: a 14.034-second generated Samantha voice fixture passed ASR and Senko under `sandbox-exec` with `(deny network*)`; output reproduced the test speech with one small transcription variation. A first fixture generated without the speech service permission was empty, failed inference and is not counted as a successful run. This is runtime evidence on this Mac, not a signed-release or clean-machine result.
- Pending F9 review corrections include resume media extent, missing indexed sources, truthful MP4 timing, durable failure events, screenshot callback ownership, zero-audio video scope, and transactional transcript replacement. Individual subprocess completion `fd7283b` is approved; integrated persistence remains under review.
