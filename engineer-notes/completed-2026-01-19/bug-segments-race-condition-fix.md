# Bug Fix: Segment Race Condition (Concurrent Task Interleaving)

## Problem Summary

Segments still disappear despite atomic assignment fixes. The root cause is that multiple `Task { @MainActor in ... }` blocks can interleave, each capturing stale state before writing.

## Evidence

Screenshots show:
- Screenshot 10: system:SPEAKER_01 t=14.08s present (correct)
- Screenshot 11: system:SPEAKER_01 t=14.08s missing (bug)

The segment was added, then disappeared when a subsequent update overwrote it.

## Root Cause

### The Race Condition

The backend sends JSON lines via stdout. Each line triggers:

```swift
// In BackendProcess, readabilityHandler runs on background thread
stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
    // ... parse line ...
    self.onStdoutLine?(line)  // Callback on background thread
}

// In AppModel, callback hops to MainActor
backend.onStdoutLine = { [weak self] line in
    Task { @MainActor in
        self?.handleBackendJSONLine(line)  // Creates a NEW Task each time
    }
}
```

**The problem:** Each JSON line creates a separate `Task`. Multiple Tasks can be queued on MainActor and interleave their execution.

### Interleaving Scenario

```
Timeline:
─────────────────────────────────────────────────────────────────────

Backend stdout:  [mic t=19.68]  [system t=14.08]
                      │              │
                      ▼              ▼
Background:      onStdoutLine   onStdoutLine
                      │              │
                      ▼              ▼
MainActor queue: [Task A]       [Task B]


MainActor execution (interleaved):

Task A starts:
  var updated = segments.filter { !$0.isPartial }  // captures [seg1, seg2, seg3]
  updated = mergeSegment(micSegment, into: updated)
  // ... Task A suspended, Task B runs ...

Task B starts:
  var updated = segments.filter { !$0.isPartial }  // ALSO captures [seg1, seg2, seg3]
                                                    // (Task A hasn't written yet!)
  updated = mergeSegment(systemSegment, into: updated)
  segments = sortedSegments(updated)  // writes [seg1, seg2, seg3, systemSegment]

Task A resumes:
  segments = sortedSegments(updated)  // OVERWRITES with [seg1, seg2, seg3, micSegment]
                                       // systemSegment is GONE!
```

## Fix Options

### Option 1: Serial AsyncStream (Recommended)

Replace the callback-based approach with an `AsyncStream` that processes lines serially.

**Changes to BackendProcess:**

```swift
@MainActor
final class BackendProcess: ObservableObject {
    // Remove: var onStdoutLine: ((String) -> Void)?

    // Add: AsyncStream for serial processing
    private var stdoutContinuation: AsyncStream<String>.Continuation?
    var stdoutLines: AsyncStream<String>!

    init() {
        stdoutLines = AsyncStream { continuation in
            self.stdoutContinuation = continuation
        }
    }

    func start(/* ... */) throws {
        // ... existing setup ...

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            // ... existing line parsing ...

            for line in lines where !line.isEmpty {
                self.stdoutContinuation?.yield(line)  // Send to stream
            }
        }
    }

    func cleanup() {
        stdoutContinuation?.finish()
        // ... existing cleanup ...
    }
}
```

**Changes to AppModel:**

```swift
private var stdoutTask: Task<Void, Never>?

func startBackend() async throws {
    // ... existing setup ...

    try backend.start(/* ... */)

    // Process lines SERIALLY via for-await
    stdoutTask = Task { @MainActor in
        for await line in backend.stdoutLines {
            self.handleBackendJSONLine(line)  // Runs one at a time, in order
        }
    }
}

func stopBackend() async {
    stdoutTask?.cancel()
    // ... existing stop logic ...
}
```

**Why this works:** `for await` processes one element at a time. The next line won't start processing until the previous one completes, eliminating interleaving.

---

### Option 2: Batch with Debounce

Collect lines that arrive within a short window and process as a single batch.

**Add to TranscriptModel:**

```swift
private var pendingLines: [String] = []
private var batchTask: Task<Void, Never>?

func queueLine(_ line: String) {
    pendingLines.append(line)

    // Cancel existing debounce timer
    batchTask?.cancel()

    // Process batch after 30ms of quiet
    batchTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 30_000_000)  // 30ms
        guard !Task.isCancelled else { return }
        self.processBatch()
    }
}

private func processBatch() {
    guard !pendingLines.isEmpty else { return }

    let lines = pendingLines
    pendingLines = []

    // Process all lines, building up a single new segments array
    var updated = segments

    for line in lines {
        // Parse and apply each line to `updated` (not to `segments`)
        updated = applyLine(line, to: updated)
    }

    // Single atomic write
    segments = sortedSegments(updated)
}

private func applyLine(_ line: String, to current: [TranscriptSegment]) -> [TranscriptSegment] {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = obj["type"] as? String else {
        return current
    }

    switch type {
    case "segment":
        // ... parse segment ...
        var updated = current.filter { !$0.isPartial }
        return mergeSegment(segment, into: updated)

    case "partial":
        // ... parse partial ...
        var updated = current
        if let idx = updated.lastIndex(where: { $0.isPartial && $0.stream == stream }) {
            updated[idx] = segment
        } else {
            updated.append(segment)
        }
        return updated

    default:
        return current
    }
}
```

**Why this works:** All lines within the batch window are processed together, building up changes incrementally on a single local array, then written once.

---

### Option 3: Lock-Based Serialization

Simpler but less elegant - use a lock to ensure only one `ingest` runs at a time.

**Add to TranscriptModel:**

```swift
private let ingestLock = NSLock()

func ingest(jsonLine: String) {
    ingestLock.lock()
    defer { ingestLock.unlock() }

    // ... existing ingest code ...
}
```

**Why this works:** The lock ensures mutual exclusion - only one thread can be inside `ingest` at a time.

**Caveat:** This blocks the MainActor while waiting for the lock, which could cause UI stuttering if lines arrive very rapidly. Options 1 and 2 are non-blocking.

---

## Recommendation

**Use Option 1 (AsyncStream)** - it's the most idiomatic Swift concurrency approach:
- Guarantees serial, in-order processing
- Non-blocking
- Clean cancellation on shutdown
- No timing assumptions (unlike batching)

Option 2 (batching) is good if you want to reduce UI update frequency during rapid transcription.

Option 3 (lock) works but is the least elegant and could block the main thread.

---

## Additional Fix: Stable Segment Identity

Currently `TranscriptSegment.id` is a new `UUID()` each time:

```swift
struct TranscriptSegment: Identifiable {
    let id = UUID()  // New identity every time
```

This causes SwiftUI to see "replaced" segments as completely new items, which can cause visual flickering.

**Fix:** Use a stable identity based on content:

```swift
struct TranscriptSegment: Identifiable {
    var id: String { "\(stream)_\(t0)_\(isPartial)" }
    // ... rest unchanged
```

Or if you need the UUID for other reasons, add a separate stable key for SwiftUI:

```swift
struct TranscriptSegment: Identifiable {
    let id = UUID()
    var stableKey: String { "\(stream)_\(t0)" }
}

// In view:
ForEach(segments, id: \.stableKey) { segment in
```

---

## Testing

After implementing the fix:

1. **Rapid dual-stream test**: Play system audio while speaking into mic simultaneously. Both streams should appear and stay visible.

2. **Burst test**: Send many segments in rapid succession (e.g., replay a recording at 2x speed). All segments should appear without any disappearing.

3. **Order test**: Segments should always appear in timestamp order, never jumping around.

---

## Files to Modify

- `ContentView.swift`:
  - `BackendProcess`: Add AsyncStream or batching logic
  - `AppModel`: Change from callback to stream consumption
  - `TranscriptModel`: Optionally add stable identity
