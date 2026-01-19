# Someday / Maybe

Low-priority polish items captured during code review. Not blocking, but worth revisiting when time allows.

---

## From Todo Item 1 (Graceful Stop)

### Redundant stdin close
`cleanup()` calls `stdinPipe.fileHandleForWriting.closeFile()` but `closeStdinAfterDraining()` already closed it. Harmless (closing twice is safe) but could be cleaned up for clarity.

### Polling vs termination handler
`waitForExit` polls every 200ms. Could use `process.terminationHandler` with a continuation for a cleaner async pattern. Current approach works fine and is simple to understand.

---

## From Todo Item 2 (Crash-safe Persistence)

### No explicit flush after write
`transcriptEventsHandle?.write(data)` relies on OS buffering. For maximum crash safety, could call `synchronizeFile()` periodically (e.g., every N writes or every few seconds). In practice the OS flushes frequently so likely fine.

### Silent write failures for event log
The write to `transcript_events.jsonl` silently fails if there's an issue. Could add error logging similar to the finalized transcript file writes.

### Meter events bloat
With `--emit-meters`, high-frequency meter events all end up in `transcript_events.jsonl`. Options:
- Filter to only persist `segment`, `partial`, `speakers` events
- Accept the bloat (useful for debugging)

Current behaviour is fine for debugging. If file size becomes an issue, add filtering.

---

## From Todo Item 3 (Temp Transcript Artifacts)

### Temp folder cleanup
Temp folders (`Muesli-<title>-<uuid>`) accumulate in the system temp directory. Could explicitly clean up old Muesli temp folders on app launch or next meeting start. Low priority since OS cleans temp on reboot anyway.

---

## From Todo Item 5 (Reset Transcript State)

### Cross-meeting speaker identification
Currently `keepSpeakerNames: false` because diarisation assigns arbitrary IDs (SPEAKER_00, SPEAKER_01) per meeting - they don't map to the same people across recordings. Keeping names would show wrong names when IDs coincidentally match.

Future options to revisit:
- **Voice fingerprinting** - Store voice embeddings and match speakers across meetings
- **User-assisted matching** - "Is this the same David from last meeting?" prompt
- **Meeting context** - Use calendar/title to suggest likely participants

For now, clean slate is safest. Revisit if users find re-naming tedious in recurring meetings.

---

## Segment Deduplication

### Magic numbers in overlap detection
`insertSegment()` uses several hardcoded thresholds:
- `epsilon = 0.05` - timing tolerance for "covers" checks
- `closeStart` threshold `0.12` - how close two segment starts must be to be considered duplicates
- `overlapRatio >= 0.8` - minimum overlap ratio to trigger replacement
- `existingDuration > newDuration + 0.1` - margin for "existing is longer" check

These seem reasonable but are somewhat arbitrary. If edge cases appear (valid segments being dropped, or duplicates slipping through), these may need tuning.

### Sorting on every insert
`segments.sort { $0.t0 < $1.t0 }` runs on every segment insert. For long meetings with many segments this could get slow. Could optimize with binary insert to maintain sorted order. Probably fine for typical meeting lengths (<2 hours).

---

## General

### UI toast for errors
Engineer suggested adding a published error state for visible UI notifications (toast/banner) when things like transcript saves fail. Currently errors only go to the debug panel.

### Transcription delay indicator
Show users the latency between speaking and transcript appearing (typically several seconds due to VAD buffering + model inference). Options:
- Display "~Xs delay" badge near transcript
- Show a "processing..." indicator when audio is being transcribed
- Timestamp comparison between audio capture and segment arrival

This would reassure users the app isn't broken when there's a pause before text appears.

### Acoustic echo (mic picking up speakers)
When not using headphones, the mic picks up audio from speakers, causing duplicate/echo text in the mic transcript. Options:
- **Acoustic Echo Cancellation (AEC)** - macOS Voice Processing I/O has built-in AEC, but ScreenCaptureKit bypasses it. Could explore using AVAudioEngine with voice processing for mic input instead.
- **Post-processing deduplication** - Detect mic segments that closely match recent system segments (fuzzy text match + timing overlap) and filter them out.
- **User guidance** - Show a tip recommending headphones when both system and mic streams are active.

For now, headphones are the simple workaround.

### Ollama/Speaker ID Settings Page
The speaker identification feature has hardcoded values (model name `gemma3:27b`, base URL `localhost:11434`). Would be nice to:
- Load Ollama configuration from a config file or UserDefaults
- Add a Settings page in the app UI
- List available models from Ollama (`/api/tags`) and let user select
- Allow changing the Ollama URL (for remote instances)
- Persist user's model preference

This would also be the natural place to add other transcription settings (whisper model selection, diarization options, etc).

---

### Post-Recording Re-Diarization (Batch vs Incremental Quality Gap)

**The Problem:** The fast-transcribe skill produces noticeably better speaker diarization than Muesli's live transcription, despite using identical settings. Investigation revealed the cause is **incremental vs batch processing**, not hyperparameters.

**Current Settings (identical in both systems):**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `diar_backend` | `senko` | Pyannote segmentation-3.0 + CAM++ embeddings via CoreML |
| `gap_threshold` | `0.8s` | Gap before starting new speaker turn |
| `speaker_tolerance` | `0.25s` | Tolerance for word-to-speaker assignment |

**Why Batch Processing Wins:**

Senko uses **speaker embedding clustering** - it extracts voice fingerprints from audio segments and groups similar ones together. The quality depends heavily on how much audio the clustering algorithm can see:

| Mode | Context | Clustering Quality |
|------|---------|-------------------|
| **Muesli live** | 30-second sliding window (`CONTEXT_SECONDS = 30.0`) | Limited samples per speaker, cluster boundaries shift between chunks, speaker IDs can drift |
| **fast-transcribe batch** | Complete audio file | All voice patterns visible, globally optimal cluster separation, stable assignments |

This is inherent to clustering algorithms - they need enough samples to reliably distinguish speakers. With only 30 seconds of audio, Senko might only have 2-3 utterances per speaker, making reliable clustering difficult.

**Potential Solutions:**

1. **Post-recording re-diarization** (recommended)
   - After recording ends, run Senko on the complete WAV file
   - Replace all speaker IDs with the batch-quality assignments
   - Could be automatic or user-triggered ("Improve speaker labels" button)
   - Downside: Requires keeping the full audio file until re-diarization completes

2. **Larger context window**
   - Increase `CONTEXT_SECONDS` from 30 to 60-90 seconds
   - Trade-off: More memory usage, higher latency for speaker labels
   - Diminishing returns - still not as good as full-file processing

3. **On-demand mid-recording re-diarization** (half-baked idea)
   - Add a button that, when clicked, takes all audio so far and runs batch diarization
   - Could give "preview" of better speaker labels while recording continues
   - Complexity: Would need to reconcile live labels with batch labels, handle ongoing audio
   - Probably not worth the complexity

4. **Speaker embedding persistence**
   - Track voice embeddings across chunks
   - When a new chunk assigns "SPEAKER_03", check if it matches any existing speaker's embedding
   - Merge if similarity threshold met
   - Complex to implement correctly

**Recommendation:** Option 1 (post-recording re-diarization) gives the biggest quality improvement for the least complexity. Run it automatically when recording stops, before presenting final transcript.

**Files involved:**
- `muesli_backend.py` - `CONTEXT_SECONDS = 30.0` defines the live window
- `senko_diarisation.py` - Wrapper around Senko library
- `diarisation.py` - Sortformer implementation (alternative backend, same issue)

---

### Speaker over-segmentation (one person = multiple speaker IDs)
Diarization often splits a single person into multiple speaker IDs (e.g., 5 "speakers" for a 2-person meeting). Causes:
- **Voice variation** - Different pitch/energy when asking questions vs. answering, or emotional shifts
- **Audio artifacts** - Echo, background noise, varying mic distance
- **Short utterances** - Brief interjections get assigned to new speaker IDs
- **Clustering threshold too strict** - Model is too conservative about grouping similar voices

Potential solutions:
- **Set expected speaker count** - Pass `num_speakers=N` to pyannote to force clustering into N speakers. Could add a UI field for "Expected participants" before meeting starts.
- **Raise clustering threshold** - Make the model more lenient about what counts as "same voice"
- **Post-process merging** - After diarization, merge speaker IDs with similar voice embeddings automatically
- **UI speaker merging** - Let user drag one speaker label onto another to combine them (SPEAKER_01 + SPEAKER_03 → both become "David")
- **Prompt for speaker count** - Ask user "How many people in this meeting?" and use that to constrain diarization

---

### Chat with Transcript

**The Idea:** Add a "Chat with transcript" button in the Meeting Viewer (works for both live and completed meetings). When clicked:
1. The transcript pane shrinks to ~half height
2. A chat interface appears below it (ChatGPT-style input box + message history)
3. User types questions, LLM answers using the transcript as context
4. A "Refresh" button clears chat history and reloads the latest transcript

**Why this is useful:**
- During a live meeting: "What did they say about the deadline?" without scrolling
- After a meeting: "Summarize the action items" or "What were Pete's main concerns?"
- Quick way to extract information without reading the whole transcript
- Natural language queries vs. Cmd+F text search

**Design Considerations:**

1. **LLM Backend:**
   - Use `gemma3:27b` via Ollama (same as speaker identification)
   - Model is already loaded in memory, so no cold start penalty
   - Large context window - can send full transcripts without truncation
   - No need for a separate/lighter model

2. **UI Approach: Separate Window (Preferred)**
   - Opens as a new window rather than splitting the existing view
   - User can position chat window alongside main app
   - Doesn't interfere with transcript viewing or live recording
   - Simpler implementation than split-view resizing
   - Must NOT interrupt underlying transcription/recording process

3. **Prompt Structure:**
   ```
   You are a helpful assistant analyzing a meeting transcript.

   TRANSCRIPT:
   [full transcript or relevant portion]

   Answer questions about this meeting. Be concise and cite specific
   quotes when relevant. If the answer isn't in the transcript, say so.

   USER: [question]
   ```

4. **Separate Window Layout:**
   ```
   ┌─────────────────────────────────────────────┐
   │  Chat: 2026-01-19 - Awin - Pete    [Refresh]│
   ├─────────────────────────────────────────────┤
   │                                             │
   │  🤖: How can I help with this meeting?      │
   │                                             │
   │  You: What were the main topics discussed?  │
   │                                             │
   │  🤖: The meeting covered three main areas:  │
   │      1. Magic Eye content auditing...       │
   │      2. ...                                 │
   │                                             │
   │  ┌─────────────────────────────────────┐    │
   │  │ Ask about this meeting...           │    │
   │  └─────────────────────────────────────┘    │
   │                                    [Send]   │
   └─────────────────────────────────────────────┘
   ```
   - Separate macOS window, can be positioned alongside main app
   - Title bar shows meeting name
   - "Refresh" in title bar to reload transcript + clear history

5. **Live Meeting Considerations:**
   - Transcript grows during the meeting
   - "Refresh" button becomes more useful - reload latest transcript
   - Could auto-refresh context every N messages
   - Show indicator when context is stale: "Transcript updated 2 min ago"

6. **Streaming Responses:**
   - Ollama supports streaming via `/api/generate`
   - Show tokens as they arrive for better UX
   - User sees response building rather than waiting

7. **Conversation History:**
   - Keep chat history in memory (not persisted to disk)
   - Include previous Q&A pairs in context for follow-up questions
   - "Refresh" clears history and starts fresh
   - Optional: "Save chat" to export Q&A as markdown

8. **Suggested Questions:**
   - Show starter prompts when chat opens:
     - "Summarize this meeting"
     - "List action items"
     - "What questions were raised?"
     - "What did [speaker] say about...?"

**Implementation Phases:**

1. **Phase 1: Basic chat window** - Separate window, text input, send to Ollama with transcript, show response
2. **Phase 2: Streaming** - Stream responses for better UX
3. **Phase 3: Polish** - Suggested questions, save chat, auto-refresh indicator for live meetings

**Potential Challenges:**
- Model hallucination (making up things not in transcript) - mitigate with prompt instructions to only reference transcript content
- Ensuring chat window doesn't block or interfere with live recording
- Window management (positioning, remembering size/position)

**Verdict:** Nice-to-have feature that would make the app significantly more useful. Separate window approach keeps implementation simple while providing good UX.
