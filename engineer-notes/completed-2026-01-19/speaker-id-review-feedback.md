# Speaker Identification - Review Feedback

**Date:** 2026-01-19
**Reviewer:** David / Claude Code
**Status:** Changes requested before Phase 3

---

## 1. Prompt Engineering - Please Use the Researched Prompt

The current prompt in `buildPrompt()` is too simple:

```swift
// Current (simplified)
"You are identifying real names for speakers in a transcript..."
```

During research, we tested extensively across 7 recordings and found that **indirect clues confuse the model without explicit reasoning guidance**. For example, when someone says "Hamel and I went through the code", the model sometimes incorrectly identifies the speaker AS Hamel, when they're actually talking ABOUT Hamel.

**Please replace with this tested prompt:**

```swift
private func buildPrompt(transcript: String, speakerIds: [String]) -> String {
    let speakerList = speakerIds.map { "\($0) = [name]" }.joined(separator: "\n")

    return """
    I'm sending you screenshots from a video recording (meeting, lecture, or video call).

    Here is an excerpt from the transcript with anonymous speaker labels:

    \(transcript)

    Your task:
    1. Look at the screenshots to identify participants (look for name labels on video tiles, presenter names, channel names)
    2. Use context clues in the transcript:
       - If someone says "Hi, I'm X" → they ARE X
       - If someone says "X and I did something" → they are NOT X (talking ABOUT X)
       - If someone says "Thanks, X" → they're talking TO X
    3. Map each SPEAKER_XX to their real name

    Provide your answer as JSON array with objects containing: speaker_id, name, confidence (0.0-1.0).
    If you cannot identify a speaker, set name to "Unknown" and confidence to 0.0.

    Example format:
    [{"speaker_id": "SPEAKER_00", "name": "Jeremy Howard", "confidence": 0.9}]
    """
}
```

**Why this matters:** The explicit reasoning guidance ("If someone says 'X and I'...") achieved 100% accuracy in testing. Without it, we saw ~60% accuracy on indirect clues.

---

## 2. Image Format - Switch from PNG to JPEG

Current code in `loadImagePayloads()`:

```swift
let mediaType = "image/png"
// ...
private func encodePNG(_ image: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}
```

**Problem:** Muesli already captures screenshots as JPEG. Re-encoding them as PNG:
- Doesn't improve quality (can't recover information lost in JPEG compression)
- Increases file size (PNG is lossless, so the re-encoded file is larger)
- Wastes CPU cycles on pointless transcoding

**Please change to:**

```swift
private func loadImagePayloads(from urls: [URL]) throws -> [ImagePayload] {
    var payloads: [ImagePayload] = []
    for url in urls {
        guard let image = loadImage(from: url),
              let resized = resizeImage(image, maxDimension: maxImageDimension),
              let data = encodeJPEG(resized, quality: 0.8) else {
            continue
        }
        payloads.append(ImagePayload(mediaType: "image/jpeg", base64Data: data.base64EncodedString()))
    }
    return payloads
}

private func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
}
```

**Benefits:**
- Smaller payload size (JPEG at 0.8 quality is typically 3-5x smaller than PNG)
- Faster upload to Ollama
- No quality loss vs current approach (we're already starting from JPEG)

---

## Summary

| Change | File | Location |
|--------|------|----------|
| Use researched prompt | `SpeakerIdentifier.swift` | `buildPrompt()` |
| Switch to JPEG encoding | `SpeakerIdentifier.swift` | `loadImagePayloads()`, add `encodeJPEG()` |

These are the only blocking changes before proceeding to Phase 3.

---

## Reference

The full research and prompt development is documented in:
- `engineer-notes/speaker-identification-research.md`
- `engineer-notes/engineering-spec-speaker-identification.md`
