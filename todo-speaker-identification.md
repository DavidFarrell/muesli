# TODO: Speaker Identification from Screenshots (Ollama)

## Phase 0 - Prereqs & Entitlements
- [x] Add `com.apple.security.network.client` entitlement.
- [x] Add runtime preflight: detect Ollama at `http://localhost:11434` and model availability.
- [x] Define user-facing error states for missing Ollama/model.

## Phase 1 - Core SpeakerIdentifier
- [x] Add `SpeakerIdentifier.swift` actor (request/response types, progress enum).
- [x] Implement screenshot loading + resizing to max dimension (e.g., 1024px).
- [x] Implement Anthropic Messages API request to local Ollama.
- [x] Parse response into `[speakerId -> name]` with confidence + raw response.

## Phase 2 - Screenshot Sampling
- [x] Select N screenshots (e.g., 12–24) evenly across timeline.
- [x] Ensure stable ordering and dedupe near-duplicates.
- [x] Add fallback for empty screenshots.

## Phase 3 - UI/Workflow
- [x] Add “Identify speakers” button in Meeting Viewer.
- [x] Show progress state (extracting, analyzing, complete).
- [x] Present proposed mappings for review (accept/edit).
- [x] Persist accepted mappings to `meeting.json` (speakerNames).

## Phase 4 - Safety & Performance
- [x] Ensure no screenshots or prompts are logged to disk.
- [x] Add cancellation support (Task cancellation).
- [x] Add timeout/retry strategy for Ollama requests.

## Phase 5 - QA
- [ ] Verify works with multiple windows/displays (Zoom/Meet/YouTube).
- [ ] Verify no-network mode fails gracefully.
- [ ] Confirm speaker names persist and render in transcript.
