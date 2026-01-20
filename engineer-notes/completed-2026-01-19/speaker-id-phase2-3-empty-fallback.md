# Speaker Identification Phase 2.3 - Empty Screenshot Fallback

## Summary
- Added an explicit empty-input fallback so speaker identification can still run even if no screenshots are present.

## Approach
- Returned an empty selection when the input list is empty or the target count is zero.
- Allowed `identifySpeakers` to proceed with an empty image payload, which keeps the prompt/transcript path alive and avoids throwing or crashing in this phase.

## Files
- Updated: `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
