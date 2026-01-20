# Spec: Acoustic Echo Suppression

## Problem

When using both System and Mic capture without headphones, the microphone picks up audio playing from speakers. This results in duplicate transcript segments: the clean digital "System" version and a delayed, reverb-contaminated "Mic" version of the same speech.

**Example:**
```
system:SPEAKER_01  t=10.32s  "Welcome to the podcast"
mic:SPEAKER_02     t=10.48s  "Welcome to the podcast"   ← Echo (should be suppressed)
```

## Solution

Two-part fix:
1. **Fuzzy deduplication** in `TranscriptModel` to detect and drop echo segments
2. **UX warning** when both streams are enabled without headphones

---

## Part 1: Echo Deduplication

### Location
`MuesliApp/MuesliApp/TranscriptModel.swift`

### Logic

When a final segment arrives, check if it's an echo:
- **Mic segments echoing System**: If a mic segment arrives within 1.0 second of a system segment with similar text, drop the mic segment (trust System as authoritative)
- **Retroactive cleanup**: When a system segment arrives, check if any recent mic segments were actually echoes and remove them
- **Finals only**: Echo suppression runs only for `segment` (final) events, not for `partial` updates
- **Short phrases**: Small identical phrases may be suppressed; this is acceptable to reduce duplication

### Implementation

#### 1. Add text similarity helper

```swift
extension String {
    /// Returns true if strings are similar enough to be considered echoes
    func isEchoOf(_ other: String) -> Bool {
        let s1 = self.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let s2 = other.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty strings are not echoes
        guard !s1.isEmpty, !s2.isEmpty else { return false }

        // Check containment (handles partial echoes)
        if s1.count >= 5 && s2.contains(s1) { return true }
        if s2.count >= 5 && s1.contains(s2) { return true }

        // Check word overlap ratio
        let words1 = Set(s1.split(separator: " ").map(String.init))
        let words2 = Set(s2.split(separator: " ").map(String.init))

        guard !words1.isEmpty, !words2.isEmpty else { return false }

        let intersection = words1.intersection(words2)
        let smaller = min(words1.count, words2.count)

        // 70% word overlap = likely echo
        return Double(intersection.count) / Double(smaller) >= 0.7
    }
}
```

#### 2. Add echo detection to TranscriptModel

```swift
// Configuration
private let echoTimeWindowSeconds: Double = 1.0

/// Check if a new mic segment is an echo of a recent system segment
private func isEcho(_ segment: TranscriptSegment) -> Bool {
    // Only mic segments can be echoes of system
    guard segment.stream == "mic" else { return false }
    guard echoSuppressionEnabled else { return false }

    // Look for system segments within the time window
    return segments.contains { existing in
        existing.stream == "system" &&
        abs(existing.t0 - segment.t0) < echoTimeWindowSeconds &&
        segment.text.isEchoOf(existing.text)
    }
}

/// Remove mic segments that are echoes of a newly arrived system segment
private func removeEchoes(causedBy systemSegment: TranscriptSegment) {
    guard systemSegment.stream == "system" else { return }
    guard echoSuppressionEnabled else { return }

    let countBefore = segments.count
    segments.removeAll { existing in
        existing.stream == "mic" &&
        abs(existing.t0 - systemSegment.t0) < echoTimeWindowSeconds &&
        existing.text.isEchoOf(systemSegment.text)
    }

    let removed = countBefore - segments.count
    if removed > 0 {
        // Optional debug logging (avoid printing transcript text).
    }
}
```

#### 3. Integrate into ingest()

In the `case "segment":` branch, after creating the segment but before merging (do not apply this to `partial` events):

```swift
case "segment":
    // ... existing segment creation code ...

    // Echo suppression: drop if mic echoing system
    if isEcho(segment) {
        return
    }

    // Echo suppression: retroactively remove mic echoes when system arrives
    if segment.stream == "system" {
        removeEchoes(causedBy: segment)
    }

    // ... existing merge logic ...
```

### Configuration

Add a toggle to disable echo suppression (in case someone genuinely has two people - one on system, one in room):

```swift
// In TranscriptModel
var echoSuppressionEnabled: Bool = true

// In isEcho():
guard echoSuppressionEnabled else { return false }
```

Wire this to a future Settings page. For now, default to `true`.

---

## Part 2: UX Warning

### Location
`MuesliApp/MuesliApp/ContentView.swift` (in the new meeting setup area)

### Implementation

When both System and Mic are enabled, show a warning:

```swift
// In the stream selection area of NewMeetingView or ContentView
if transcribeSystem && transcribeMic {
    HStack(spacing: 8) {
        Image(systemName: "speaker.wave.2.bubble.left")
            .foregroundStyle(.orange)
        Text("Using speakers? Headphones prevent duplicate transcription.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
}
```

### Design Notes
- Keep it subtle (caption size, secondary color)
- Orange icon draws attention without being alarming
- Explains the "why" (duplicate transcription) so users understand
- No action required - just informational

---

## Testing

### Manual Test Cases

1. **Echo detection works**
   - Play audio from speakers (e.g., YouTube)
   - Have mic enabled alongside system
   - Verify system segments appear, mic echoes are dropped

2. **Timing window is correct**
   - Echo within 1.0s of system → dropped
   - Different content at same time → kept
   - Same content but >1.0s apart → both kept (not an echo)

3. **Retroactive removal works**
   - If mic segment arrives before system segment (due to processing latency)
   - Then system segment arrives
   - Mic segment should be retroactively removed

4. **Real conversation preserved**
   - Two people actually talking at the same time
   - One on system audio, one in room on mic
   - Both should be kept (different content)

5. **Warning appears correctly**
   - Enable both System and Mic → warning shows
   - Disable either one → warning hides

---

## Future Improvements

If fuzzy deduplication isn't sufficient:

1. **Acoustic Echo Cancellation (AEC)** - Use `AVAudioEngine` with Voice Processing I/O for mic capture instead of ScreenCaptureKit. This removes echo at the audio level before transcription.

2. **Embedding-based similarity** - Instead of word overlap, use sentence embeddings to detect semantic similarity. More robust but adds complexity.

3. **Configurable threshold** - Expose `echoTimeWindowSeconds` and word overlap ratio in Settings for power users to tune.

---

## Files to Modify

| File | Changes |
|------|---------|
| `TranscriptModel.swift` | Add `isEchoOf()` extension, `isEcho()`, `removeEchoes()`, integrate into `ingest()` |
| `ContentView.swift` | Add headphones warning in stream selection area |

## Estimated Effort

Small - ~50 lines of new code, no architectural changes.
