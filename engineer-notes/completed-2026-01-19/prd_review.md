This is a comprehensive code review and implementation plan based on the codebase provided and the "Meeting History & Resume" PRD.

### Code Review Summary

**Strengths:**
1.  **Modern Concurrency:** The code makes excellent use of Swift Concurrency (`async/await`, `Task`, `MainActor`), particularly in `CaptureEngine` and `AppModel`.
2.  **ScreenCaptureKit Integration:** The implementation of `SCStreamOutput` and audio extraction (PCM conversion) is robust and handles the complexities of macOS audio buffers well.
3.  **No Third-Party Dependencies:** The app relies entirely on standard libraries (`SwiftUI`, `AVFoundation`, `ScreenCaptureKit`), which makes it lightweight and easy to maintain.

**Weaknesses / Technical Debt:**
1.  **Monolithic Architecture:** `ContentView.swift` is nearly 1,500 lines long. It contains the View, the ViewModel (`AppModel`), the Data Models, and helper classes. This makes adding the requested features difficult without refactoring.
2.  **Ephemeral State:** The `AppModel` is designed to handle *one* session at a time. When the app restarts, all knowledge of previous meetings is lost.
3.  **Hardcoded Paths:** There are hardcoded paths to Python environments (`/opt/homebrew/...`) and project folders which might break on other machines.
4.  **Audio Sync Logic:** Timestamp generation relies on `meetingStartPTS` inside `CaptureEngine`. Resuming a meeting will require careful offset management to prevent timestamp collisions.

---

### Implementation Plan

To implement the PRD, we need to shift the architecture from "One Active Session" to "Library Management."

Here is the step-by-step proposal.

#### 1. Define Data Models (Persistence Layer)

We need to formalize the file structure defined in the PRD. Currently, the app uses a simple `meta.json`. We will upgrade this to `meeting.json`.

**Action:** Create a new file `MeetingData.swift` to hold these structures.

```swift
import Foundation

enum MeetingStatus: String, Codable {
    case recording
    case completed
    case resumed
}

struct StreamInfo: Codable {
    var sampleRate: Int
    var channels: Int
}

struct MeetingMetadata: Codable, Identifiable {
    var id: String { title } // Use title/folder name as ID
    var version: Int = 1
    var title: String
    var folderName: String
    var createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double
    var lastTimestamp: Double // Vital for Resume functionality
    var status: MeetingStatus
    var segmentCount: Int
    var speakerNames: [String: String]
}
```

#### 2. Refactor App State Management

Currently, `AppModel` uses booleans (`isCapturing`, `showPermissionsSheet`) to determine the view. We need a state machine to handle the new "Viewing" mode.

**Action:** Update `AppModel` to use an enum-based state.

```swift
enum AppScreen {
    case setup           // History list + New Meeting controls
    case recording       // Active SessionView
    case viewing(URL)    // Read-only SessionView for past meetings
}

class AppModel: ObservableObject {
    @Published var currentScreen: AppScreen = .setup
    @Published var meetingHistory: [MeetingMetadata] = []
    
    // ... existing properties
}
```

#### 3. Implement Meeting Storage Logic

We need logic to scan the file system, load old meetings, and handle the "Migration" step mentioned in the PRD (converting old folders to the new format).

**Action:** Add a `MeetingStore` class or extension to `AppModel`.

```swift
extension AppModel {
    func scanMeetingHistory() {
        let meetingsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muesli/Meetings")
        
        // 1. Get all subfolders
        // 2. Look for meeting.json
        // 3. If missing, generate it from transcript.jsonl (Migration logic)
        // 4. Sort by createdAt desc
        // 5. Assign to self.meetingHistory
    }
    
    func deleteMeeting(metadata: MeetingMetadata) {
        // Use FileManager.trashItem to move folder to bin
        // Remove from self.meetingHistory
    }
}
```

#### 4. Update TranscriptModel for History & Resume

The `TranscriptModel` currently assumes it receives live JSON lines. It needs to support:
1.  **Loading**: Parsing a full `transcript.jsonl` file at once.
2.  **Offsetting**: Accepting a `timeOffset` so when we resume, new segments start *after* the old ones.

**Action:** Modify `TranscriptModel`.

```swift
class TranscriptModel: ObservableObject {
    private var timestampOffset: Double = 0.0

    // Load from disk
    func loadHistory(from jsonlURL: URL) {
        let content = try? String(contentsOf: jsonlURL)
        let lines = content?.components(separatedBy: .newlines) ?? []
        // Parse lines into self.segments
        
        // Calculate offset for potential resume
        let maxTime = segments.map { $0.t1 ?? $0.t0 }.max() ?? 0
        self.timestampOffset = maxTime + 1.0 // Add 1s gap
    }

    // Update ingest to use offset
    func ingest(jsonLine: String) {
        // ... parse JSON ...
        // segment.t0 += self.timestampOffset
        // segment.t1 += self.timestampOffset
        // ... merge logic ...
    }
}
```

#### 5. Implement the "Resume" Logic

This is the most complex logic change. When "Resume" is clicked:
1.  Switch state to `.recording`.
2.  Pass the `MeetingMetadata.lastTimestamp` to the `CaptureEngine` or `TranscriptModel` as the offset.
3.  **Crucial:** We must ensure the `CaptureEngine` (audio writer) appends to the existing audio files or creates new ones (`part2.wav`) that the backend knows how to handle.
    *   *Simplest approach for Muesli:* The backend command currently takes `--output-dir`. If we restart the backend, it might overwrite `system.wav`.
    *   *Backend Adjustment:* Check if the backend Python script supports appending or if we need to generate unique filenames (e.g., `system-session2.wav`). *Assuming standard `diarise_transcribe` behavior, it might overwrite.*
    *   *Swift Fix:* When resuming, pass a new subdirectory or filename prefix to the backend command, but keep the same `MeetingSession` folder for the transcript.

#### 6. UI Implementation

We need to split `ContentView.swift` into smaller components.

**A. History List (New View)**
Added to `NewMeetingView`.
```swift
struct HistoryListView: View {
    let meetings: [MeetingMetadata]
    let onDelete: (MeetingMetadata) -> Void
    let onOpen: (MeetingMetadata) -> Void

    var body: some View {
        List(meetings) { meeting in
            HStack {
                VStack(alignment: .leading) {
                    Text(meeting.title).font(.headline)
                    Text("\(meeting.durationSeconds.formatted())s • \(meeting.segmentCount) segments")
                        .font(.caption)
                }
                Spacer()
                Button(action: { onDelete(meeting) }) {
                    Image(systemName: "trash")
                }
            }
            .onTapGesture { onOpen(meeting) }
        }
    }
}
```

**B. Viewer / Session Unified View**
Refactor `SessionView` to handle both `.recording` and `.viewing`.
- **Recording**: Shows stop button, level meters, live auto-scroll.
- **Viewing**: Shows "Resume" button, "Export" button, hidden level meters.

### Proposed Code Changes (Diff-style)

Here is how I would modify the specific parts of your `MuesliApp_codebase.xml`.

#### 1. Add `MeetingMetadata` (New File)
Since I cannot create a file in a review, add this to `ContentView.swift` (or a new file ideally).

```swift
struct MeetingMetadata: Codable, Identifiable {
    var id: String { folderName }
    var version: Int = 1
    var title: String
    var folderName: String
    var createdAt: Date
    var updatedAt: Date
    var durationSeconds: Double
    var lastTimestamp: Double
    var status: MeetingStatus
    var segmentCount: Int
    var speakerNames: [String: String]
    
    // Helper to initialize from a fresh session
    init(session: MeetingSession) {
        self.title = session.title
        self.folderName = session.folderURL.lastPathComponent
        self.createdAt = session.startedAt
        self.updatedAt = Date()
        self.durationSeconds = 0
        self.lastTimestamp = 0
        self.status = .recording
        self.segmentCount = 0
        self.speakerNames = [:]
    }
}
```

#### 2. Modify `AppModel` for History

```swift
// Inside AppModel

@Published var history: [MeetingMetadata] = []
@Published var viewMode: AppScreen = .setup // Define AppScreen enum as per plan

func loadHistory() {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Muesli/Meetings")
    
    // Logic to list directories and decode meeting.json
    // Logic to migrate old folders (check if meeting.json exists, if not, create it)
    // self.history = loadedItems.sorted(by: { $0.createdAt > $1.createdAt })
}

func resumeMeeting(_ metadata: MeetingMetadata) async {
    // 1. Load transcript into TranscriptModel
    let folderURL = getURL(for: metadata)
    transcriptModel.loadHistory(from: folderURL.appendingPathComponent("transcript.jsonl"))
    
    // 2. Set offset based on metadata
    transcriptModel.setOffset(metadata.lastTimestamp + 0.5)
    
    // 3. Start Capture (modified to append or use new audio files)
    // ...
}
```

#### 3. Modify `TranscriptModel` for Persistence

```swift
// Inside TranscriptModel

private var timeOffset: Double = 0

func setOffset(_ offset: Double) {
    self.timeOffset = offset
}

func loadHistory(from url: URL) {
    segments.removeAll()
    guard let content = try? String(contentsOf: url) else { return }
    
    let lines = content.components(separatedBy: .newlines)
    for line in lines where !line.isEmpty {
        self.ingest(jsonLine: line, applyOffset: false) // Don't offset historical data
    }
}

// Update ingest signature
func ingest(jsonLine: String, applyOffset: Bool = true) {
    // ... decode json ...
    
    if applyOffset {
        // segment.t0 += self.timeOffset
        // segment.t1 += self.timeOffset
    }
    // ... existing merge logic ...
}
```

#### 4. Update `saveTranscriptFiles` in `AppModel`

We need to ensure `meeting.json` is saved when stopping.

```swift
private func saveTranscriptFiles(for session: MeetingSession) {
    // ... existing save logic for jsonl/txt ...

    // NEW: Update Metadata
    let duration = transcriptModel.segments.last?.t1 ?? 0
    let count = transcriptModel.segments.count
    
    var metadata = MeetingMetadata(session: session)
    metadata.durationSeconds = duration
    metadata.lastTimestamp = duration
    metadata.segmentCount = count
    metadata.status = .completed
    metadata.speakerNames = transcriptModel.speakerNames
    metadata.updatedAt = Date()

    let metaURL = session.folderURL.appendingPathComponent("meeting.json")
    if let data = try? JSONEncoder().encode(metadata) {
        try? data.write(to: metaURL)
    }
}
```

### Next Steps for You

1.  **Refactor**: Before adding features, extract `AppModel`, `TranscriptModel`, and the Views into separate files. The `ContentView.swift` is currently too dense to safely modify logic without introducing regression.
2.  **Metadata**: Implement the `MeetingMetadata` struct and the saving logic in `AppModel.stopMeeting()`.
3.  **Viewer**: Build the "Read Only" version of the session view.
4.  **Integration**: Wire up the "Resume" button to trigger the start sequence but with the pre-loaded transcript and time offset.