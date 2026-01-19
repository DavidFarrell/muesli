# PRD: Meeting History & Resume

## Overview

Add meeting history browsing, viewing, and resume capabilities to Muesli. Users should be able to see past meetings, review transcripts, edit speaker names, resume recording, and delete old meetings.

---

## Goals

1. **Discoverability**: Users can easily find and access past meetings
2. **Continuity**: Users can resume an interrupted meeting seamlessly
3. **Editability**: Users can edit speaker names and export from any past meeting
4. **Housekeeping**: Users can delete old meetings they no longer need

---

## Current State

Meetings are already saved to a permanent location:
```
~/Library/Application Support/Muesli/Meetings/{title}/
```

Each meeting folder contains:
- `transcript.jsonl` - Machine-readable transcript
- `transcript.txt` - Human-readable transcript
- `transcript_events.jsonl` - Streaming events (crash-safe)
- `backend.log` - Debug log
- `audio/` - Audio files (system.wav, mic.wav, PCM files)
- Optionally: `screenshots/`, `recording.mp4`

**Current limitations**:
- No metadata file exists - meeting info must be parsed from transcripts
- After stopping a meeting, users return to the start screen with no way to see or access past meetings
- No way to resume a stopped meeting

---

## Pre-requisite: Code Refactoring

Before implementing these features, the codebase requires refactoring:

**Current state**: `ContentView.swift` is ~2,600 lines containing Views, ViewModels, Data Models, and helper classes in a single file.

**Required refactoring**:
1. Extract `AppModel` to `AppModel.swift`
2. Extract `TranscriptModel` to `TranscriptModel.swift`
3. Extract `CaptureEngine` and `AudioSampleExtractor` to `CaptureEngine.swift`
4. Extract `BackendProcess` and `FramedWriter` to `BackendProcess.swift`
5. Create `MeetingData.swift` for new data types
6. Keep Views in `ContentView.swift` or split further

**Why this matters**: The current monolithic structure makes it difficult to add features without introducing regressions. The new history/resume features touch multiple concerns (state management, persistence, UI) that should be cleanly separated.

---

## Requirements

### 1. Meeting Metadata File

**File**: `meeting.json` in each meeting folder

**Contents**:
```json
{
  "version": 1,
  "title": "2026-01-19-meeting-01",
  "created_at": "2026-01-19T07:30:00Z",
  "updated_at": "2026-01-19T08:15:00Z",
  "duration_seconds": 2700,
  "last_timestamp": 2700.5,
  "status": "completed",
  "sessions": [
    {
      "session_id": 1,
      "started_at": "2026-01-19T07:30:00Z",
      "ended_at": "2026-01-19T08:15:00Z",
      "audio_folder": "audio",
      "streams": {
        "system": { "sample_rate": 16000, "channels": 1 },
        "mic": { "sample_rate": 48000, "channels": 1 }
      }
    }
  ],
  "segment_count": 127,
  "speaker_names": {
    "mic:SPEAKER_01": "David",
    "mic:SPEAKER_02": "Nikki",
    "system:SPEAKER_01": "Podcast Host"
  }
}
```

**Fields**:
| Field | Type | Description |
|-------|------|-------------|
| `version` | int | Schema version for future compatibility |
| `title` | string | Meeting title (folder name) |
| `created_at` | ISO8601 | When meeting first started |
| `updated_at` | ISO8601 | Last modification time |
| `duration_seconds` | float | Total duration of transcript |
| `last_timestamp` | float | Highest `t1` value in segments (for resume) |
| `status` | enum | `"recording"`, `"completed"` |
| `sessions` | array | Recording sessions (supports resume) |
| `segment_count` | int | Number of finalized segments |
| `speaker_names` | object | Speaker ID to display name mapping |

**Session object fields**:
| Field | Type | Description |
|-------|------|-------------|
| `session_id` | int | Sequential session number (1, 2, 3...) |
| `started_at` | ISO8601 | When this session started |
| `ended_at` | ISO8601 | When this session ended (null if recording) |
| `audio_folder` | string | Subfolder for this session's audio files |
| `streams` | object | Per-stream audio format info for this session |

**Behavior**:
- Created when meeting starts
- Updated on stop (duration, segment_count, status → completed)
- Updated when speaker names are edited
- New session added when meeting is resumed

---

### 2. Meeting History List

**Location**: Start screen, below the "Start Meeting" controls

**UI**:
```
┌─────────────────────────────────────────────────────┐
│  [Meeting Title Input]                              │
│  [Capture Mode] [Source Selection]                  │
│  [✓ System Audio] [✓ Microphone]                    │
│                                                     │
│  [Start Meeting Button]                             │
│                                                     │
├─────────────────────────────────────────────────────┤
│  Recent Meetings                                    │
│  ─────────────────────────────────────────────────  │
│  📁 2026-01-19-meeting-07    45m    127 segments 🗑 │
│  📁 2026-01-19-meeting-06    32m     89 segments 🗑 │
│  📁 2026-01-19-meeting-05    18m     42 segments 🗑 │
│  📁 2026-01-18-meeting-01   1h 5m   203 segments 🗑 │
│  [Show More...]                                     │
└─────────────────────────────────────────────────────┘
```

**Behavior**:
- Scan `~/Library/Application Support/Muesli/Meetings/` on app launch
- Load `meeting.json` from each folder (fallback to folder name if missing)
- Sort by `created_at` descending (most recent first)
- Show initially: 5-10 meetings, with "Show More" to expand
- Each row shows: title, duration (formatted), segment count, delete icon
- Click row → Open meeting viewer
- Click 🗑 → Delete confirmation

**Data Loading**:
```swift
struct MeetingHistoryItem: Identifiable {
    let id: String  // folder name
    let folderURL: URL
    let title: String
    let createdAt: Date
    let durationSeconds: Double
    let segmentCount: Int
    let status: MeetingStatus
}

enum MeetingStatus: String, Codable {
    case recording
    case completed
}
```

---

### 3. Meeting Viewer

**Purpose**: View a past meeting's transcript, edit speaker names, export, or resume

**Navigation**: Click on a meeting in the history list → Meeting Viewer

**UI**: Similar to current `SessionView` but without live capture controls

```
┌─────────────────────────────────────────────────────┐
│  ← Back    2026-01-19-meeting-07         [Resume ▶] │
│            45 minutes • 127 segments                │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Transcript                             [📋] [↗]   │
│  ┌─────────────────────────────────────────────┐   │
│  │ mic:SPEAKER_01  Mic  t=0.32s                │   │
│  │ Okay, so microphone starting first,         │   │
│  │                                             │   │
│  │ system:SPEAKER_02  System  t=0.56s          │   │
│  │ Maybe.                                      │   │
│  │                                             │   │
│  │ ... (scrollable transcript)                 │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
├─────────────────────────────────────────────────────┤
│  Speakers                                           │
│  ┌─────────────────────────────────────────────┐   │
│  │ mic:SPEAKER_01    [David          ]         │   │
│  │ mic:SPEAKER_02    [Nikki          ]         │   │
│  │ system:SPEAKER_01 [Podcast Host   ]         │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  [Delete Meeting]                                   │
└─────────────────────────────────────────────────────┘
```

**Features**:
- **Back button**: Return to start screen
- **Resume button**: Continue recording this meeting
- **Copy button** (📋): Copy transcript to clipboard
- **Export button** (↗): Export as TXT/JSONL via Save panel
- **Transcript view**: Read-only scrollable transcript
- **Speaker editing**: Same as current session view, saves to `meeting.json`
- **Delete button**: Delete this meeting (with confirmation)

**Data Loading**:
- Load `transcript.jsonl` → parse into `[TranscriptSegment]`
- Load `meeting.json` → get speaker names, duration, etc.
- Populate `TranscriptModel` with loaded data

---

### 4. Resume Meeting

**Purpose**: Continue recording a previously stopped meeting with seamless timestamp continuation

**Trigger**: Click "Resume" button in Meeting Viewer

#### 4.1 Audio File Strategy

When resuming, audio files are stored in a **separate subfolder per session** to avoid overwriting:

```
~/Library/Application Support/Muesli/Meetings/2026-01-19-meeting-01/
├── meeting.json
├── transcript.jsonl          # Combined transcript (all sessions)
├── transcript.txt
├── transcript_events.jsonl
├── backend.log
├── audio/                    # Session 1 audio
│   ├── system.wav
│   ├── system.pcm
│   ├── mic.wav
│   └── mic.pcm
├── audio-session-2/          # Session 2 audio (first resume)
│   ├── system.wav
│   ├── system.pcm
│   ├── mic.wav
│   └── mic.pcm
└── audio-session-3/          # Session 3 audio (second resume)
    └── ...
```

**Why separate folders**:
- Backend doesn't need modification (just different `--output-dir`)
- No risk of overwriting previous audio
- Each session's audio is self-contained
- Easy to identify which audio belongs to which session

#### 4.2 Resume Behavior

1. **Load existing state**:
   - Load all segments from `transcript.jsonl`
   - Load speaker names from `meeting.json`
   - Get `last_timestamp` from `meeting.json`
   - Calculate next session ID from `sessions` array

2. **Create new audio folder**:
   ```swift
   let sessionId = (metadata.sessions.count) + 1
   let audioFolder = sessionId == 1 ? "audio" : "audio-session-\(sessionId)"
   ```

3. **Calculate timestamp offset**:
   ```swift
   let timestampOffset = lastTimestamp + 0.5  // Small gap for clarity
   ```

4. **Configure TranscriptModel**:
   ```swift
   transcriptModel.setTimestampOffset(timestampOffset)
   ```

5. **Start capture**:
   - Backend receives new audio folder path
   - New segments from backend have timestamps starting at ~0
   - TranscriptModel applies offset: `segment.t0 += offset`, `segment.t1 += offset`
   - New segments appear after existing ones in the transcript

6. **Update metadata on resume start**:
   ```json
   {
     "status": "recording",
     "updated_at": "...",
     "sessions": [
       { "session_id": 1, "audio_folder": "audio", ... },
       { "session_id": 2, "audio_folder": "audio-session-2", "started_at": "...", "ended_at": null, ... }
     ]
   }
   ```

7. **On stop**:
   - Update current session's `ended_at`
   - Recalculate `duration_seconds` and `last_timestamp`
   - Update `segment_count`
   - Set `status: "completed"`
   - Save updated `transcript.jsonl` and `transcript.txt` (merged)

#### 4.3 UI During Resume

- Same as normal recording session
- Transcript shows all segments (old + new)
- New segments appear at bottom as they arrive
- Optional: "Resumed" badge or indicator showing this is a continuation

#### 4.4 Edge Cases

- If user edits speaker names during resume, save immediately to `meeting.json`
- If backend crashes during resume, existing segments are preserved (crash-safe persistence)
- If meeting folder is missing required files, show error and prevent resume
- If `transcript.jsonl` is corrupted, show error with option to start fresh

---

### 5. Delete Meeting

**Trigger**: Click trash icon in history list, or "Delete Meeting" button in viewer

**Confirmation dialog**:
```
┌─────────────────────────────────────────────┐
│  Delete Meeting?                            │
│                                             │
│  "2026-01-19-meeting-07" will be            │
│  permanently deleted. This cannot be        │
│  undone.                                    │
│                                             │
│  [Cancel]                    [Delete]       │
└─────────────────────────────────────────────┘
```

**Behavior**:
- On confirm: Move entire meeting folder to Trash (recoverable)
- Remove from history list immediately
- If in Meeting Viewer: navigate back to start screen

**Implementation**: Use `FileManager.trashItem(at:resultingItemURL:)` to move to Trash instead of permanent deletion.

---

## Technical Implementation

### New Types (MeetingData.swift)

```swift
import Foundation

enum MeetingStatus: String, Codable {
    case recording
    case completed
}

struct StreamInfo: Codable {
    var sampleRate: Int
    var channels: Int
}

struct RecordingSession: Codable {
    var sessionId: Int
    var startedAt: Date
    var endedAt: Date?
    var audioFolder: String
    var streams: [String: StreamInfo]
}

struct MeetingMetadata: Codable {
    var version: Int = 1
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double
    var lastTimestamp: Double
    var status: MeetingStatus
    var sessions: [RecordingSession]
    var segmentCount: Int
    var speakerNames: [String: String]
}

struct MeetingHistoryItem: Identifiable {
    let id: String
    let folderURL: URL
    let title: String
    let createdAt: Date
    let durationSeconds: Double
    let segmentCount: Int
    let status: MeetingStatus

    init(from metadata: MeetingMetadata, folderURL: URL) {
        self.id = folderURL.lastPathComponent
        self.folderURL = folderURL
        self.title = metadata.title
        self.createdAt = metadata.createdAt
        self.durationSeconds = metadata.durationSeconds
        self.segmentCount = metadata.segmentCount
        self.status = metadata.status
    }
}
```

### New App States

```swift
enum AppScreen {
    case setup           // Start screen with history
    case recording       // Active capture session
    case viewing(URL)    // Viewing past meeting (folder URL)
}

// In AppModel:
@Published var currentScreen: AppScreen = .setup
@Published var meetingHistory: [MeetingHistoryItem] = []
```

### TranscriptModel Updates

```swift
// In TranscriptModel:
private var timestampOffset: Double = 0.0

func setTimestampOffset(_ offset: Double) {
    self.timestampOffset = offset
}

func loadFromDisk(jsonlURL: URL) {
    // Parse transcript.jsonl and populate segments
    // Don't apply offset to loaded segments
}

func ingest(jsonLine: String) {
    // ... existing parsing ...

    // Apply offset to new segments
    segment.t0 += timestampOffset
    if let t1 = segment.t1 {
        segment.t1 = t1 + timestampOffset
    }

    // ... existing merge logic ...
}

func resetForNewMeeting(keepSpeakerNames: Bool) {
    timestampOffset = 0.0  // Reset offset
    // ... existing reset logic ...
}
```

### File Operations

```swift
// Load meeting metadata
func loadMeetingMetadata(from folderURL: URL) -> MeetingMetadata?

// Save meeting metadata
func saveMeetingMetadata(_ metadata: MeetingMetadata, to folderURL: URL)

// Load transcript from JSONL
func loadTranscript(from folderURL: URL) -> [TranscriptSegment]

// Scan meetings folder
func scanMeetingsFolder() -> [MeetingHistoryItem]

// Delete meeting (move to Trash)
func deleteMeeting(at folderURL: URL) throws
```

---

## Migration

For existing meetings without `meeting.json`:

1. On first scan, detect folders without metadata
2. Generate metadata from available info:
   - `title`: folder name
   - `created_at`: folder creation date (from filesystem)
   - `duration_seconds`: parse `transcript.jsonl`, find max `t1`
   - `last_timestamp`: same as duration
   - `segment_count`: count non-empty lines in `transcript.jsonl`
   - `status`: `"completed"`
   - `sessions`: single session with `audio_folder: "audio"`
   - `speaker_names`: empty (user can edit later)
3. Save generated `meeting.json`

---

## Out of Scope (Future)

- Search across meetings
- Tags or categories for meetings
- Cloud sync / backup
- Meeting merge (combine two meetings)
- Transcript editing (change text, not just speaker names)
- Audio playback within the app

---

## Success Metrics

- Users can find past meetings within 2 clicks
- Resume adds new content with correct timestamps (no reset to 0)
- Speaker name edits persist across app restarts
- Delete removes all files and frees disk space
- Multiple resume sessions work correctly with separate audio folders

---

## Implementation Order

### Phase 0: Refactoring (Pre-requisite)
1. Extract `AppModel` to separate file
2. Extract `TranscriptModel` to separate file
3. Extract `CaptureEngine` to separate file
4. Extract `BackendProcess` to separate file
5. Create `MeetingData.swift` with new types

### Phase 1: Foundation
1. **Meeting metadata** - Create/save/load `meeting.json`
2. **Migration** - Generate metadata for existing meetings

### Phase 2: History & Viewing
3. **History list** - Scan folder, display list on start screen
4. **Meeting viewer** - Load and display past transcript
5. **Speaker editing persistence** - Save names to `meeting.json`

### Phase 3: Management
6. **Delete** - Trash icon, confirmation, file removal

### Phase 4: Resume
7. **Resume** - Load state, offset timestamps, new audio folder, merge transcripts
