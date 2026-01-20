# Phase 3.2 - ContentView Split

## Problem
`ContentView.swift` had grown into a monolithic file containing the root router, onboarding flow, session view, meeting viewer, transcript row, and multiple sheets. This made review and maintenance difficult and increased the chance of merge conflicts.

## Fix
- Extracted major UI components into dedicated files:
  - `MeetingViewer.swift` (viewer layout, speaker ID UI, rediarization controls)
  - `SessionView.swift` (live capture session UI, level meter)
  - `TranscriptRow.swift` (row rendering for transcript segments)
  - `SpeakersSheet.swift` (speaker name editor)
- Kept `RootView`, onboarding, new meeting flow, rename sheet, and permissions sheet in `ContentView.swift` as the main entry point.

## Implementation Details
- Each extracted file is a standalone `struct` with the same `@EnvironmentObject` or `@Binding` inputs it previously relied on.
- Rewired any shared helpers (like `formatDuration`) locally where needed to avoid cross-file implicit dependencies.
- Verified that sheets and alerts still bind to the same state variables as before; no behavioral changes were introduced.

## Why This Works
Smaller, focused files are easier to review and reason about. This change reduces the cognitive load for future UI changes and minimizes accidental regressions caused by editing unrelated sections of a giant file.

## Files
- Added: `MuesliApp/MuesliApp/MeetingViewer.swift`
- Added: `MuesliApp/MuesliApp/SessionView.swift`
- Added: `MuesliApp/MuesliApp/TranscriptRow.swift`
- Added: `MuesliApp/MuesliApp/SpeakersSheet.swift`
- Updated: `MuesliApp/MuesliApp/ContentView.swift`
