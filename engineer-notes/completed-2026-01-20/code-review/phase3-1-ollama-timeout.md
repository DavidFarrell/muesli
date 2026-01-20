# Phase 3.1 - Speaker ID Timeout Feedback

## Problem
Speaker identification uses a local Ollama model. When the model stalls or the server is unreachable, requests could hang for a long time and the UI would show a generic failure message with no indication that a timeout occurred.

## Fix
- Set an explicit 30 second timeout on the Ollama HTTP request.
- Added explicit UI messaging for `URLError.timedOut` so the user sees a clear, actionable error.

## Implementation Details
- `SpeakerIdentifier` defines `requestTimeout = 30` and assigns it to `URLRequest.timeoutInterval`.
- `MeetingViewer.identifySpeakers` checks for `URLError.timedOut` and sets `identificationError` to a targeted message.
- Other errors continue to surface a generic failure message with the error description.

## Why This Works
A fixed timeout prevents UI tasks from hanging indefinitely and gives the user a deterministic retry path. The explicit error message distinguishes a timeout from other failures like invalid responses or model errors.

## Files
- `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
- `MuesliApp/MuesliApp/MeetingViewer.swift`
