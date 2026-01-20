# Phase 4.4 - Replace Magic Numbers with Named Constants

## Problem
Gap thresholds and speaker tolerance values (0.8s and 0.25s) were repeated in multiple backend entrypoints and CLI defaults. This made it easy for defaults to drift and hid the meaning of the values.

## Fix
- Added `constants.py` in the backend package with:
  - `DEFAULT_GAP_THRESHOLD_SECONDS = 0.8`
  - `DEFAULT_SPEAKER_TOLERANCE_SECONDS = 0.25`
- Replaced repeated literals in CLI argument defaults and help text.
- Updated merge functions to reference the shared gap threshold constant.

## Implementation Details
- `cli.py`, `muesli_backend.py`, and `reprocess.py` import the constants and use them for default arguments.
- Help strings now interpolate the named constants so documentation matches code.
- `merge.py` now references the shared gap threshold constant for its defaults.

## Why This Works
Centralizing the defaults makes the configuration explicit and ensures consistent behavior across entrypoints.

## Files
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/constants.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/cli.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/reprocess.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/muesli_backend.py`
- `backend/fast_mac_transcribe_diarise_local_models_only/src/diarise_transcribe/merge.py`
