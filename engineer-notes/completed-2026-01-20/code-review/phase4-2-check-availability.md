# Phase 4.2 - Async Speaker Identifier Availability Check

## Problem
Speaker availability checks were intended to live in `SpeakerIdentifier`, but the review flagged synchronous networking that could block the actor. The check should be async with a short timeout to avoid UI stalls.

## Fix
- Added `SpeakerIdentifier.checkAvailability` as a fully async static method.
- Uses `URLSession.shared.data(for:)` with a short timeout.
- Maps common connection errors and timeouts to `.ollamaNotRunning`.

## Implementation Details
- The method performs the same `/api/tags` check as before, but uses async networking.
- `AppModel.refreshSpeakerIdStatus` now delegates to `SpeakerIdentifier.checkAvailability`.

## Why This Works
Availability checks are now non-blocking and bounded, keeping the UI responsive even if Ollama is down or unresponsive.

## Files
- `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
- `MuesliApp/MuesliApp/AppModel.swift`
