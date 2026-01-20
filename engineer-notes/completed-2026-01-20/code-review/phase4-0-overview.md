# Phase 4 - Low Priority Overview

## Goal
Clean up low-severity issues that improve portability, code hygiene, and maintainability without changing user-facing behavior.

## Work Completed
- Removed the hardcoded `/Users/david` backend path and replaced it with environment and dev-friendly discovery.
- Added an async `SpeakerIdentifier.checkAvailability` with a short timeout.
- Deduplicated transcript export / persistence logic into shared helpers.
- Centralized gap/tolerance thresholds in backend constants.

## Approach
1) Make backend folder selection portable across machines and environments.
2) Avoid actor blocking by moving availability checks to async `URLSession`.
3) Consolidate transcript JSONL encoding and file-writing to reduce repetition.
4) Replace repeated threshold literals with named constants used across CLI and backend entrypoints.

## Verification
- Manual code review to confirm all hardcoded paths were removed.
- Verified availability checks now use async networking and short timeouts.
- Ensured transcript exports still generate both `.txt` and `.jsonl` outputs with existing error logging.
- Verified CLI help strings now reference named constants for thresholds.

## Files Touched
- `MuesliApp/MuesliApp/AppModel.swift`
- `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/constants.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/cli.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/reprocess.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/merge.py`
