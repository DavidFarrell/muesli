This is a consolidated, prioritized engineering audit for the **Muesli** project. It combines findings from the architectural review and the logic/concurrency review.

**Executive Summary:**
While the core architecture (Swift Actors + ScreenCaptureKit + Python via Stdin/Stdout) is sound, the application currently suffers from **critical concurrency hazards** that could lead to data loss, zombie processes, or UI corruption. There are also significant performance bottlenecks that will manifest during long meetings (>45 mins).

---

### 🚨 Critical Severity
*Immediate fixes required to prevent crashes, data loss, or deadlocks.*

#### 1. Race Condition in `BatchRediarizer` Cancellation
**The Issue:** In `BatchRediarizer.run`, the local variable `process` is assigned *after* the `BackendProcess` initializer returns. If the task is cancelled immediately (e.g., user closes the view), `onCancel` fires while `process` is still `nil`. The process launches but is never terminated, creating a "zombie" backend that eats CPU.
**The "Why":** This leads to resource exhaustion and orphaned processes that persist even after the app quits.
**Suggested Fix:**
Use `withTaskCancellationHandler` and ensure atomic access to the process reference.

```swift
// BatchRediarizer.swift
func run(...) async throws -> Result {
    let processWrapper = ProcessWrapper() // Simple class to hold the process reference
    
    return try await withTaskCancellationHandler {
        let backend = try BackendProcess(...) 
        await processWrapper.set(backend) // Thread-safe set
        // check for cancellation *again* here before starting
        try Task.checkCancellation() 
        try backend.start()
        return await backend.waitForExit(...)
    } onCancel: {
        Task { await processWrapper.terminate() }
    }
}
```

#### 2. TranscriptSegment ID Collisions (UI Corruption)
**The Issue:** `TranscriptSegment.id` relies on `round(t0 * 1000)`. If two segments (or a partial and its correction) occur within the same millisecond, they generate identical IDs.
**The "Why":** SwiftUI uses `id` for diffing. Duplicate IDs cause undefined behavior: rows might vanish, jump around, or crash the app during updates.
**Suggested Fix:**
Decouple the logic identity from the UI identity.

```swift
struct TranscriptSegment: Identifiable {
    let id = UUID() // Stable, unique UI identity
    
    // Use this for logic/deduplication, not for SwiftUI Identifiable
    var logicKey: String { "\(stream)_\(Int(round(t0 * 1000)))" }
}
```

#### 3. Data Loss Race in `stopMeeting`
**The Issue:** In `AppModel.stopMeeting()`, `stdoutTask?.cancel()` is called immediately. This stops the Swift consumer loop (`for await line in backend.stdoutLines`) *before* the backend has finished flushing its final buffer.
**The "Why":** The final transcript segments or the "meeting_stopped" confirmation event may be dropped, leaving the meeting in a corrupt "processing" state.
**Suggested Fix:**
Allow the consumer loop to finish naturally when the pipe closes.

```swift
// AppModel.swift
func stopMeeting() async {
    // 1. Send Stop
    writer?.sendSync(...) 
    writer?.closeStdinAfterDraining()
    
    // 2. Wait for exit (do NOT cancel stdoutTask yet)
    if let backend {
        _ = await backend.waitForExit(timeoutSeconds: 10)
    }
    
    // 3. stdoutTask finishes automatically when pipe closes. 
    // Only force cancel if it hangs.
    stdoutTask = nil 
}
```

#### 4. Python Stdout Deadlock Risk
**The Issue:** The Python backend uses `threading.Lock()` around `sys.stdout.write`. If the OS pipe buffer fills up because Swift isn't reading fast enough, `write` blocks holding the lock. If another thread tries to log an error, it waits for the lock → Deadlock.
**The "Why":** The backend freezes completely.
**Suggested Fix:**
Use non-blocking writes or ensure the lock is re-entrant and scoped strictly to the `json.dumps` + `write` atomic operation, or rely on a dedicated thread for outputting to stdout to avoid blocking logic threads.

---

### 🟠 High Severity
*Fixes required for security, stability, and UX.*

#### 5. Security: Path Traversal in Meeting Titles
**The Issue:** `createMeetingFolder` uses user input (`meetingTitle`) directly in file paths.
**The "Why":** A malicious or accidental title like `../../Library` could overwrite critical system files or write data outside the intended sandbox container.
**Suggested Fix:**
Sanitize the input.

```swift
private func normaliseMeetingTitle(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ")
    return s.components(separatedBy: allowed.inverted).joined()
}
```

#### 6. Performance: O(N log N) Sorting on Main Thread
**The Issue:** `TranscriptModel.ingest` sorts the entire segment array on the Main Actor every time a new packet arrives.
**The "Why":** As the meeting exceeds 30-45 minutes (1000+ segments), the UI will begin to stutter and drop frames during live transcription.
**Suggested Fix:**
Optimize the insertion. Live transcripts are chronological.

```swift
// TranscriptModel.swift
if let last = segments.last, newSegment.t0 >= last.t0 {
    segments.append(newSegment) // O(1)
} else {
    segments.append(newSegment)
    segments.sort { $0.t0 < $1.t0 } // O(N log N) only when out-of-order corrections arrive
}
```

#### 7. Silent Exception Swallowing in `FramedWriter`
**The Issue:** `FramedWriter` uses `try? handle.write(...)`.
**The "Why":** If the backend crashes, the pipe breaks. Swift continues "writing" audio into the void with no error, giving the user a false sense that recording is active.
**Suggested Fix:**
Propagate the error or trigger a state change.

```swift
do {
    try handle.write(...)
} catch {
    // Notify AppModel to pause UI or show "Backend Connection Lost"
    onWriteError?(error) 
}
```

#### 8. Unbounded AsyncStream Buffer
**The Issue:** `stdoutLines` uses the default unbounded buffer.
**The "Why":** If the backend enters a loop or emits logs faster than the UI can render, memory usage will spike until the app crashes (OOM).
**Suggested Fix:**
Use a buffering policy.

```swift
AsyncStream(String.self, bufferingPolicy: .bufferingNewest(500))
```

---

### 🟡 Medium Severity
*Architectural hygiene and robustness.*

#### 9. No Timeout Feedback for Ollama
**The Issue:** `SpeakerIdentifier` requests can take 90+ seconds. The UI shows a spinner but no timeout countdown or cancel option.
**The "Why":** Users assume the app has frozen.
**Suggested Fix:** Use `URLSession` configuration with a specific timeout (e.g., 30s) and handle `URLError.timedOut` explicitly in the UI state.

#### 10. Monolithic `ContentView.swift`
**The Issue:** The file is ~1500 lines mixing UI, Model, and Logic.
**The "Why":** Makes testing impossible and increases the risk of regressions when fixing the race conditions mentioned above.
**Suggested Fix:** Split into `SessionView.swift`, `ControlPanel.swift`, `MeetingViewer.swift`.

#### 11. Python File Descriptor Leak
**The Issue:** In `muesli_backend.py`, if `pcm = open(...)` fails, `wav.close()` is never called.
**Suggested Fix:** Use `contextlib.ExitStack` or nested `try...finally` blocks to ensure resources are always closed.

#### 12. Audio Format Mismatch Checks
**The Issue:** Capture format is detected in Swift, but Python makes assumptions about 16kHz vs 48kHz.
**Suggested Fix:** Pass the *detected* format explicitly in the `meeting_start` JSON payload, and have Python reconfigure its FFmpeg pipeline dynamically based on that header.

---

### 🟢 Low Severity / Maintenance
*Clean code and best practices.*

13. **Hardcoded Paths:** `/Users/david/` exists in `AppModel`. This will break on any other machine. Use relative paths or `FileManager` API.
14. **Synchronous Networking on Actor:** `SpeakerIdentifier.checkAvailability` blocks the actor. Use a short timeout `URLSession`.
15. **Duplicate Code:** Export logic is repeated in `saveTranscriptFiles` and `exportTranscriptFiles`.
16. **Magic Numbers:** Thresholds (0.8s gap, 0.25s tolerance) should be defined constants.

### Positive Findings (Keep these!)
*   **Protocol Design:** The binary framing protocol (Type + Stream + PTS + Len) is efficient and robust.
*   **Swift Actors:** Proper usage of `@MainActor` and background actors for isolation.
*   **ScreenCaptureKit:** Correct implementation of the complex `SCStreamOutput` delegate methods.