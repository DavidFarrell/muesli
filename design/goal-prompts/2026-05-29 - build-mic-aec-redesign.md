Use the careful-build-lifecycle skill, BUILD stage.

Project repo: /Users/david/projects/muesli
Overlay: design/_build-overlay.md

Build the mic AEC redesign, slice by slice, from the spec at
`design/2026-05-29 - mic-aec-redesign.md`. The spec defines three slices:

1. MicEngine: caller-controlled voice processing, input-format guard, bind minimisation.
2. AEC policy + output-device APIs in AudioDeviceManager + Auto/On/Off settings UI.
3. Escalation fallback (VPIO requested but no buffers -> restart once without VPIO) + output-change re-evaluation.

What this change achieves: hardware echo cancellation (VoiceProcessingIO) currently
runs unconditionally and silently kills mic capture on audio routes it cannot handle
(e.g. USB wireless mic input + Bluetooth output). After this change, VPIO is requested
only when it can help and is provably safe (Auto mode = on only with the built-in
MacBook speaker), the user can force it On or Off, and a VPIO failure degrades to plain
capture instead of leaving the mic dead.

Hard constraints (from the overlay - do not violate):
- Touch only MicEngine.swift, AppModel.swift, ContentView.swift (AudioDeviceManager +
  mic settings UI), and a new minimal MuesliAppTests target. Do NOT change the
  ScreenCaptureKit system-audio path, the MP4 recording, screenshots, or the backend.
- A mic restart must never interrupt the recording. MicEngine and CaptureEngine stay
  independent.
- Match the existing file style: small actors, direct Core Audio, [Component] prints.
  No new abstraction layers, no strategy/protocol hierarchy, no DI framework.
- Tests cover ONLY the pure decision logic (shouldRequestVoiceProcessing truth table;
  isUsableInputFormat predicate). Do NOT attempt to unit-test AVAudioEngine / VPIO /
  Core Audio hardware behaviour - that is verified manually per the spec.

Per slice, run the skill's convergence loop: a fresh Opus builder plans and writes the
slice, then loops with /ask-gpt5 against the good-taste doctrine (up to 5 rounds, you
adjudicate at the cap). The builder/critic/boss roles and the branch-PR-review workflow
are defined by the careful-build-lifecycle skill - load it. The build must compile
(xcodebuild) and the MuesliAppTests must pass before a slice is committed. Branch per
slice, tag (slice N), open a PR, and ask me how to review before merging. The repo has
`origin` (git@github.com:DavidFarrell/muesli.git) and `gh` is authenticated, so the PR
workflow is available.

Completion: all three slices merged to main, build green, MuesliAppTests passing, and
the manual-verification list in the spec handed back to me to run on real hardware.

Escalate to me per the skill's escalation rules rather than guessing - in particular if
a slice cannot be made to build or if VPIO behaviour on the hardware contradicts the
spec's assumptions.
