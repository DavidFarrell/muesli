# Speaker Identification Phase 4.3 - Timeout and Retry Strategy

## Summary
- Added request timeouts and bounded retries for Ollama calls to improve resilience.

## Approach
- Set a per-request timeout and retried on transient network or server failures with exponential backoff.
- Introduced a lightweight HTTP error type so retry logic can reason about status codes.
- Left non-retryable errors unchanged so the UI can surface them immediately.

## Files
- Updated: `MuesliApp/MuesliApp/SpeakerIdentifier.swift`
