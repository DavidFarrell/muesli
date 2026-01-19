# Bug: Segments disappearing and appearing in wrong order

## Symptoms

1. **Wrong order**: A segment at t=12.48s appears BELOW segments at t=22-32s (should be above)
2. **Disappearing**: The t=12.48s segment vanishes when t=72.48s segment arrives, then reappears later
3. **Flickering**: UI shows inconsistent state before settling to correct order

## Root Causes

### Bug #1: @Published Race Condition

**Location:** `insertSegment(_:)` in `TranscriptModel`

**Current code:**
```swift
if shouldAppend {
    segments.append(newSegment)          // ← triggers @Published IMMEDIATELY
}
segments.sort { $0.t0 < $1.t0 }          // ← runs AFTER @Published already fired
```

**The problem:**

1. `segments.append()` triggers `@Published` property observer immediately
2. SwiftUI captures the array in its render queue (UNSORTED)
3. `.sort()` then reorders the array in-place
4. But the render cycle was already queued with the unsorted version
5. UI renders wrong order, then corrects on next update

**Additional issue:** In-place `sort()` may not trigger `@Published` at all, since it's not a reassignment. The UI might never see the sorted state until something else triggers a publish.

---

### Bug #2: Multiple @Published fires during partial replacement

**Location:** `ingest(jsonLine:)` in `TranscriptModel`

**Current code:**
```swift
case "segment":
    // ... parse segment ...
    segments.removeAll { $0.isPartial }  // ← fires @Published (#1)
    insertSegment(segment)                // ← fires @Published (#2, #3 from append + sort)
```

**The problem:**

Multiple `@Published` notifications fire in rapid sequence:
1. `removeAll` fires - UI sees segments with partials removed
2. `append` fires - UI sees new segment added (unsorted)
3. Intermediate states get rendered, causing flicker/disappearance

---

## Fixes

### Fix #1: Force re-publish with assignment after sort

Replace the current `insertSegment` ending:

```swift
// OLD (buggy):
if shouldAppend {
    segments.append(newSegment)
}
segments.sort { $0.t0 < $1.t0 }

// NEW (fixed):
if shouldAppend {
    segments.append(newSegment)
}
// Force @Published by reassigning - guarantees UI sees sorted state
segments = segments.sorted { $0.t0 < $1.t0 }
```

Using `segments = segments.sorted()` (assignment) instead of `segments.sort()` (in-place) guarantees `@Published` fires with the sorted array.

---

### Fix #2: Make partial replacement atomic

Replace the segment case in `ingest()`:

```swift
// OLD (buggy):
case "segment":
    // ... parse segment ...
    segments.removeAll { $0.isPartial }
    insertSegment(segment)

// NEW (fixed):
case "segment":
    // ... parse segment ...
    // Build new array atomically, single @Published at the end
    var updated = segments.filter { !$0.isPartial }

    // Apply deduplication logic to updated array
    let dominated = updated.contains { existing in
        guard existing.stream == segment.stream else { return false }
        let existingEnd = existing.t1 ?? existing.t0
        let newEnd = segment.t1 ?? segment.t0
        return existing.t0 <= segment.t0 + 0.05
            && existingEnd >= newEnd - 0.05
            && existing.text.count >= segment.text.count
    }

    if !dominated {
        // Remove segments that the new one supersedes
        updated.removeAll { existing in
            guard existing.stream == segment.stream else { return false }
            let existingEnd = existing.t1 ?? existing.t0
            let newEnd = segment.t1 ?? segment.t0
            let overlap = min(existingEnd, newEnd) - max(existing.t0, segment.t0)
            guard overlap > 0 else { return false }

            let closeStart = abs(existing.t0 - segment.t0) <= 0.12
            let newCoversExisting = segment.t0 <= existing.t0 + 0.05 && newEnd >= existingEnd - 0.05
            let overlapRatio = overlap / max(0.01, min(existingEnd - existing.t0, newEnd - segment.t0))

            return newCoversExisting || closeStart || overlapRatio >= 0.8
        }
        updated.append(segment)
    }

    // Single assignment triggers single @Published with final sorted state
    segments = updated.sorted { $0.t0 < $1.t0 }

    lastTranscriptAt = Date()
    if !segment.text.isEmpty {
        lastTranscriptText = segment.text
    }
```

**Note:** This duplicates some deduplication logic, but ensures atomicity. Alternatively, refactor `insertSegment` to work on a passed-in array and return the result, then assign once.

---

### Alternative: Simpler refactor of insertSegment

If you want to keep `insertSegment` but fix the issue:

```swift
private func insertSegment(_ newSegment: TranscriptSegment) {
    // ... existing deduplication logic with removeAll ...

    if shouldAppend {
        segments.append(newSegment)
    }

    // CHANGE: Use assignment instead of in-place sort
    segments = segments.sorted { $0.t0 < $1.t0 }
}
```

And in `ingest()`:

```swift
case "segment":
    // ... parse segment ...
    // Combine removal and insert into single mutation block
    var temp = segments.filter { !$0.isPartial }
    segments = temp  // Clear partials
    insertSegment(segment)  // This now ends with assignment
```

This is simpler but still has two @Published fires. The atomic version is cleaner.

---

## Testing

After fixing, verify:

1. **Order test**: Send segments at t=30s, t=10s, t=20s rapidly. They should always display as 10s, 20s, 30s (never out of order, even briefly).

2. **No disappearing**: Send segment at t=12s, wait, send segment at t=72s. The t=12s segment should never disappear.

3. **Partial replacement**: Send partial "hello" at t=10s, then finalized "hello world" at t=10s. Should smoothly replace, no flicker.

---

## Summary

| Bug | Cause | Fix |
|-----|-------|-----|
| Wrong order | `append()` fires @Published before `sort()` runs | Use `segments = segments.sorted()` (assignment) |
| Disappearing | Multiple @Published fires cause intermediate renders | Make mutations atomic (single assignment) |

---

## UPDATE: Partial handling also needs fixing

The `case "segment":` fix was applied but `case "partial":` still has the same bug.

**Current buggy code:**

```swift
case "partial":
    // ... parse segment ...
    if let idx = segments.lastIndex(where: { $0.isPartial }) {
        segments[idx] = segment    // ← Direct mutation, triggers @Published
    } else {
        segments.append(segment)   // ← Direct mutation, triggers @Published
    }
    // ← No sort after modification!
```

**Problems:**

1. Direct mutation triggers `@Published` before sort
2. No sort at all - partials appear in arrival order, not timestamp order
3. `lastIndex(where: { $0.isPartial })` replaces ANY partial, even from a different stream (mic partial could overwrite system partial)

**Fix - make partial handling atomic and stream-aware:**

```swift
case "partial":
    let speakerID = (obj["speaker_id"] as? String) ?? "unknown"
    let stream = (obj["stream"] as? String) ?? "unknown"
    let t0 = (obj["t0"] as? Double) ?? 0
    let text = (obj["text"] as? String) ?? ""
    let segment = TranscriptSegment(
        speakerID: speakerID,
        stream: stream,
        t0: t0,
        t1: nil,
        text: text,
        isPartial: true
    )

    // Build new array atomically
    var updated = segments

    // Find existing partial for THIS stream (not any stream)
    if let idx = updated.lastIndex(where: { $0.isPartial && $0.stream == stream }) {
        updated[idx] = segment
    } else {
        updated.append(segment)
    }

    // Single atomic assignment with sort
    segments = updated.sorted { $0.t0 < $1.t0 }

    lastTranscriptAt = Date()
    if !text.isEmpty {
        lastTranscriptText = text
    }
```

**Key changes:**

1. **Copy first**: `var updated = segments` - work on a copy
2. **Stream-aware replacement**: `$0.isPartial && $0.stream == stream` - only replace partial from same stream
3. **Atomic assignment with sort**: `segments = updated.sorted { ... }` - single @Published with correct order
