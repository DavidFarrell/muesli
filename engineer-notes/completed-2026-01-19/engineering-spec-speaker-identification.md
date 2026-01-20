# Engineering Spec: Speaker Identification from Screenshots

**Date:** 2026-01-19
**Author:** David (with Claude Code research assistance)
**Status:** Ready for implementation
**Priority:** Enhancement

---

## Executive Summary

Add the ability to identify speakers in Muesli meeting recordings by analyzing screenshots with a local vision model. This maps anonymous diarization labels (`SPEAKER_00`, `SPEAKER_01`) to real names (`Jeremy Howard`, `Shreya Shankar`).

**Key points:**
- Uses **local Ollama** with `gemma3:27b` vision model - no cloud APIs, full privacy
- Achieves **100% accuracy** in testing across 7 different recordings
- Ollama now supports the **Anthropic Messages API** natively (v0.14.0+) - this is new and you may not know about it
- Requires one new entitlement: `com.apple.security.network.client`

---

## The Problem

Muesli uses Pyannote for speaker diarization, which produces transcripts like:

```
[SPEAKER_00] Welcome everyone to today's session.
[SPEAKER_01] Thanks for having me. I'm excited to be here.
[SPEAKER_00] Let's start with introductions.
```

These anonymous labels are functional but not user-friendly. Users want to see:

```
[Jeremy Howard] Welcome everyone to today's session.
[Shreya Shankar] Thanks for having me. I'm excited to be here.
```

---

## The Solution: Local Vision Model

We send screenshots from the recording to a local vision model (Ollama) along with transcript context. The model reads name labels from video tiles, presenter names on slides, YouTube channel names, etc.

### Why This Approach?

1. **Privacy** - Data never leaves the machine (aligns with Muesli's architecture)
2. **No API costs** - Free after initial model download
3. **Reliable** - Name labels in video UIs are large, high-contrast text - easy for vision models
4. **Context-aware** - Can use transcript clues ("Hi, I'm X") to disambiguate

---

## Research Journey & Proof of Concept

### Discovery: Ollama Now Has Anthropic-Compatible API

**This is important because you probably don't know this yet.**

As of Ollama v0.14.0 (released late 2025), Ollama natively supports the Anthropic Messages API format. This means we can use the familiar Anthropic SDK syntax instead of raw llama.cpp prompt formatting.

**Verification:**
```bash
# Check your Ollama version
ollama --version
# Need 0.14.0 or higher

# The model we use
ollama pull gemma3:27b
```

**API endpoint:** `http://localhost:11434/v1/messages`

**Critical detail:** The base URL is just `http://localhost:11434` - do NOT add `/v1` suffix when configuring clients, as the client adds the path automatically.

### Proof It Works (Python Test)

I built test scripts to validate the approach. Here's the core pattern:

```python
import anthropic
import base64
from pathlib import Path

# Point to local Ollama - note: just the base URL, no /v1 suffix
client = anthropic.Anthropic(
    base_url="http://localhost:11434",  # NOT http://localhost:11434/v1
    api_key="ollama"  # Required by SDK but ignored by Ollama
)

def analyze_screenshot(image_path: Path, prompt: str) -> str:
    """Send image to Ollama vision model."""

    # Load and encode image
    with open(image_path, "rb") as f:
        image_data = base64.standard_b64encode(f.read()).decode("utf-8")

    # Determine media type
    suffix = image_path.suffix.lower()
    media_type = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
    }.get(suffix, "image/png")

    # Send to model using Anthropic Messages API format
    response = client.messages.create(
        model="gemma3:27b",
        max_tokens=1024,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": media_type,
                            "data": image_data
                        }
                    },
                    {
                        "type": "text",
                        "text": prompt
                    }
                ]
            }
        ]
    )

    return response.content[0].text
```

### Test Results

Tested across 3 courses with 7 lessons, 14 total speaker identifications:

| Course | Lesson | Speakers | Result |
|--------|--------|----------|--------|
| Solve It with Code | Lesson 01 | Jeremy Howard, Johnno | ✅ 100% |
| Solve It with Code | Lesson 02 | Jeremy Howard, Johnno | ✅ 100% |
| Solve It with Code | Lesson 03 | Jeremy Howard, Johnno | ✅ 100% |
| LLM Evals | Lesson 01 | Shreya Shankar, Hamel Husain | ✅ 100% |
| LLM Evals | Lesson 02 | Shreya Shankar, Hamel Husain | ✅ 100% |
| Elite AI Coding | Lesson 01 | Eleanor Berger, Isaac Flath | ✅ 100% |
| Elite AI Coding | Lesson 02 | Eleanor Berger, Isaac Flath | ✅ 100% |

**Overall: 14/14 speakers correctly identified (100%)**

### What We Learned

**Works reliably:**
- Extracting names from video tile labels (Zoom, Teams, Meet, YouTube)
- Reading presenter names from slides
- Using transcript clues like "Hi, I'm X" or "Thanks, Y"

**Requires careful prompting:**
- Indirect clues like "Hamel and I went through..." can confuse the model
- Solution: Explicit reasoning guidance in the prompt (see implementation below)

**Doesn't work well:**
- Single-frame "who is speaking right now" detection (only ~60% accuracy)
- Solution: Don't try to do this - use aggregate approach instead

---

## Technical Implementation

### Prerequisites

#### 1. Add Network Entitlement (CRITICAL)

Add to `MuesliApp.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

**Why:** Even though `localhost` is local, the macOS App Sandbox treats it as a network connection. Without this entitlement, `URLSession` requests to `localhost:11434` will fail silently.

Your current entitlements have:
- `device.audio-input` ✓
- `device.screen-recording` ✓
- `files.user-selected.read-write` ✓
- `network.client` ✗ **← ADD THIS**

#### 2. User Requirements

- Ollama installed and running (`ollama serve`)
- `gemma3:27b` model pulled (`ollama pull gemma3:27b`)
- ~20GB RAM available when model is loaded

---

### New File: `SpeakerIdentifier.swift`

```swift
import Foundation
import AppKit
import CoreGraphics

/// Handles speaker identification using local Ollama vision model
actor SpeakerIdentifier {

    // MARK: - Types

    struct SpeakerMapping: Codable {
        var speakerId: String      // e.g., "SPEAKER_00"
        var name: String           // e.g., "Jeremy Howard"
        var confidence: Double     // 0.0 - 1.0
    }

    struct IdentificationResult {
        var mappings: [SpeakerMapping]
        var rawResponse: String
    }

    /// Progress stages for UI feedback
    enum Progress {
        case extractingFrames
        case analyzing
        case complete
    }

    // MARK: - Configuration

    private let ollamaBaseURL = URL(string: "http://localhost:11434")!
    private let model = "gemma3:27b"
    private let maxImageDimension: CGFloat = 1024  // Resize for performance

    // MARK: - Public API

    /// Identify speakers from screenshots and transcript
    /// - Parameters:
    ///   - screenshots: URLs to screenshot images
    ///   - transcript: Full transcript text with SPEAKER_XX labels
    ///   - speakerIds: List of speaker IDs to identify (e.g., ["SPEAKER_00", "SPEAKER_01"])
    ///   - progressHandler: Called with progress updates for UI feedback
    /// - Returns: Identification result with proposed mappings
    func identifySpeakers(
        screenshots: [URL],
        transcript: String,
        speakerIds: [String],
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws -> IdentificationResult {

        // 1. Select key frames (max 5, evenly distributed)
        progressHandler?(.extractingFrames)
        let keyFrames = selectKeyFrames(from: screenshots, maxCount: 5)

        // 2. Load, resize, and encode images
        let encodedImages = try keyFrames.compactMap { url -> (data: String, mediaType: String)? in
            guard let resizedData = try resizeImage(at: url, maxDimension: maxImageDimension) else {
                return nil
            }
            let base64 = resizedData.base64EncodedString()
            return (base64, "image/jpeg")  // Always JPEG after resize
        }

        // 3. Extract relevant transcript context
        let excerpt = extractRelevantTranscript(from: transcript, maxLines: 150)

        // 4. Build prompt with reasoning guidance
        let prompt = buildPrompt(transcriptExcerpt: excerpt, speakerIds: speakerIds)

        // 5. Call Ollama
        progressHandler?(.analyzing)
        let response = try await callOllama(images: encodedImages, prompt: prompt)

        // 6. Parse response
        progressHandler?(.complete)
        let mappings = parseResponse(response, speakerIds: speakerIds)

        return IdentificationResult(mappings: mappings, rawResponse: response)
    }

    /// Check if Ollama is running and has the required model
    static func checkAvailability() async -> (available: Bool, message: String) {
        let url = URL(string: "http://localhost:11434/api/tags")!

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["models"] as? [[String: Any]] ?? []

            let hasGemma = models.contains { model in
                (model["name"] as? String)?.contains("gemma3:27b") == true
            }

            if hasGemma {
                return (true, "Ollama ready with gemma3:27b")
            } else {
                return (false, "Ollama running but gemma3:27b not installed.\nRun: ollama pull gemma3:27b")
            }
        } catch {
            return (false, "Ollama not running.\nStart it with: ollama serve")
        }
    }

    // MARK: - Private Methods

    private func selectKeyFrames(from screenshots: [URL], maxCount: Int) -> [URL] {
        guard screenshots.count > maxCount else { return screenshots }

        // Select evenly distributed frames
        var selected: [URL] = []
        let step = screenshots.count / maxCount

        for i in stride(from: 0, to: screenshots.count, by: step) {
            if selected.count < maxCount {
                selected.append(screenshots[i])
            }
        }

        return selected
    }

    /// Resize image to max dimension for faster processing
    /// Vision models work fine at 1024px for reading name labels
    private func resizeImage(at url: URL, maxDimension: CGFloat) throws -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }

        let originalSize = image.size
        let scale = min(maxDimension / originalSize.width, maxDimension / originalSize.height, 1.0)

        if scale >= 1.0 {
            // Already small enough, just convert to JPEG
            return image.jpegData(compressionQuality: 0.8)
        }

        let newSize = NSSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )

        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: originalSize),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()

        return resizedImage.jpegData(compressionQuality: 0.8)
    }

    /// Extract relevant transcript lines using keyword search + fallback
    /// Looks for introduction patterns rather than just taking first N lines
    private func extractRelevantTranscript(from transcript: String, maxLines: Int) -> String {
        let lines = transcript.components(separatedBy: .newlines)

        // Keywords that often indicate speaker identity
        let keywords = [
            "i'm", "my name is", "this is",
            "hi,", "hello,",
            "thanks,", "thank you,",
            " and i "  // "Hamel and I" pattern
        ]

        var relevantLines: Set<Int> = []

        // Find lines containing keywords and grab context around them
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            if keywords.contains(where: { lower.contains($0) }) {
                // Add this line and 2 lines of context before/after
                for i in max(0, index - 2)...min(lines.count - 1, index + 2) {
                    relevantLines.insert(i)
                }
            }
        }

        // If we found enough keyword hits, use those lines
        if relevantLines.count >= 10 {
            let sortedIndices = relevantLines.sorted()
            let selectedLines = sortedIndices.prefix(maxLines).map { lines[$0] }
            return selectedLines.joined(separator: "\n")
        }

        // Fallback: use first maxLines lines
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    private func buildPrompt(transcriptExcerpt: String, speakerIds: [String]) -> String {
        let speakerList = speakerIds.map { "\($0) = [name]" }.joined(separator: "\n")

        return """
        I'm sending you screenshots from a video recording (meeting, lecture, or video call).

        Here is an excerpt from the transcript with anonymous speaker labels:

        \(transcriptExcerpt)

        Your task:
        1. Look at the screenshots to identify participants (look for name labels on video tiles, presenter names, channel names)
        2. Use context clues in the transcript:
           - If someone says "Hi, I'm X" → they ARE X
           - If someone says "X and I did something" → they are NOT X (talking ABOUT X)
           - If someone says "Thanks, X" → they're talking TO X
        3. Map each SPEAKER_XX to their real name

        Provide your answer in this exact format:
        \(speakerList)

        If you cannot identify a speaker, write: SPEAKER_XX = unknown
        """
    }

    /// Call Ollama using Anthropic-compatible Messages API
    private func callOllama(
        images: [(data: String, mediaType: String)],
        prompt: String
    ) async throws -> String {

        // Ollama's Anthropic-compatible endpoint
        let url = ollamaBaseURL.appendingPathComponent("v1/messages")

        // Build content array with images + text (Anthropic format)
        var content: [[String: Any]] = images.map { image in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mediaType,
                    "data": image.data
                ]
            ]
        }
        content.append([
            "type": "text",
            "text": prompt
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                [
                    "role": "user",
                    "content": content
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ollama", forHTTPHeaderField: "x-api-key")  // Required but ignored
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120  // Vision models can be slow

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SpeakerIdentificationError.ollamaRequestFailed(statusCode: statusCode)
        }

        // Parse Anthropic-style response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let contentArray = json?["content"] as? [[String: Any]],
              let firstContent = contentArray.first,
              let text = firstContent["text"] as? String else {
            throw SpeakerIdentificationError.invalidResponse
        }

        return text
    }

    private func parseResponse(_ response: String, speakerIds: [String]) -> [SpeakerMapping] {
        var mappings: [SpeakerMapping] = []

        for speakerId in speakerIds {
            // Match patterns like "SPEAKER_00 = Jeremy Howard" or "SPEAKER_00 = [Jeremy Howard]"
            let pattern = "\(speakerId)\\s*=\\s*(.+?)(?:\\n|$)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: response, range: NSRange(response.startIndex..., in: response)),
               let nameRange = Range(match.range(at: 1), in: response) {

                var name = String(response[nameRange])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]**"))

                // Calculate confidence based on response quality
                let confidence: Double = name.lowercased() == "unknown" ? 0.0 : 0.8

                mappings.append(SpeakerMapping(
                    speakerId: speakerId,
                    name: name,
                    confidence: confidence
                ))
            }
        }

        return mappings
    }
}

// MARK: - Errors

enum SpeakerIdentificationError: LocalizedError {
    case ollamaNotRunning
    case ollamaRequestFailed(statusCode: Int)
    case invalidResponse
    case noScreenshots

    var errorDescription: String? {
        switch self {
        case .ollamaNotRunning:
            return "Ollama is not running. Start it with: ollama serve"
        case .ollamaRequestFailed(let code):
            return "Ollama request failed with status \(code)"
        case .invalidResponse:
            return "Could not parse Ollama response"
        case .noScreenshots:
            return "No screenshots found for this meeting"
        }
    }
}

// MARK: - NSImage Extension

extension NSImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
```

---

### UI: Confirmation Dialog

```swift
import SwiftUI

struct SpeakerMappingConfirmationView: View {
    let proposedMappings: [SpeakerIdentifier.SpeakerMapping]
    let onConfirm: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var editedMappings: [String: String] = [:]

    var body: some View {
        VStack(spacing: 16) {
            Text("Confirm Speaker Names")
                .font(.headline)

            Text("The following speakers were identified. Edit if needed:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(proposedMappings.sorted(by: { $0.speakerId < $1.speakerId }), id: \.speakerId) { mapping in
                HStack {
                    Text(mapping.speakerId)
                        .frame(width: 100, alignment: .leading)
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))

                    TextField("Name", text: Binding(
                        get: { editedMappings[mapping.speakerId] ?? mapping.name },
                        set: { editedMappings[mapping.speakerId] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    // Confidence indicator
                    Circle()
                        .fill(mapping.confidence > 0.7 ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                        .help(mapping.confidence > 0.7 ? "High confidence" : "Low confidence - please verify")
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                Button("Apply Names") {
                    var finalMappings: [String: String] = [:]
                    for mapping in proposedMappings {
                        finalMappings[mapping.speakerId] = editedMappings[mapping.speakerId] ?? mapping.name
                    }
                    onConfirm(finalMappings)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            for mapping in proposedMappings {
                editedMappings[mapping.speakerId] = mapping.name
            }
        }
    }
}
```

---

### Integration in MeetingViewer

Add to your existing `MeetingViewer`:

```swift
// MARK: - Speaker Identification State

@State private var isIdentifyingSpeakers = false
@State private var identificationProgress: SpeakerIdentifier.Progress?
@State private var showSpeakerConfirmation = false
@State private var proposedMappings: [SpeakerIdentifier.SpeakerMapping] = []
@State private var identificationTask: Task<Void, Never>?

// MARK: - In body

// Add button to toolbar
Button(action: identifySpeakers) {
    HStack(spacing: 4) {
        if isIdentifyingSpeakers {
            ProgressView()
                .scaleEffect(0.7)
            Text(progressText)
                .foregroundColor(.secondary)
        } else {
            Label("Identify Speakers", systemImage: "person.2.wave.2")
        }
    }
}
.disabled(isIdentifyingSpeakers || !hasScreenshots)
.help("Use AI to identify speaker names from screenshots")

// Add sheet for confirmation
.sheet(isPresented: $showSpeakerConfirmation) {
    SpeakerMappingConfirmationView(
        proposedMappings: proposedMappings,
        onConfirm: { mappings in
            applySpeakerMappings(mappings)
            showSpeakerConfirmation = false
        },
        onCancel: {
            showSpeakerConfirmation = false
        }
    )
}

// Cancel task on view disappear
.onDisappear {
    identificationTask?.cancel()
    identificationTask = nil
}

// MARK: - Supporting Code

private var progressText: String {
    switch identificationProgress {
    case .extractingFrames: return "Extracting frames..."
    case .analyzing: return "Analyzing with Ollama..."
    case .complete: return "Complete"
    case nil: return "Identifying..."
    }
}

private var hasScreenshots: Bool {
    guard let meeting = selectedMeeting else { return false }
    let screenshotsDir = meeting.directoryURL.appendingPathComponent("screenshots")
    return FileManager.default.fileExists(atPath: screenshotsDir.path)
}

private func identifySpeakers() {
    guard let meeting = selectedMeeting else { return }

    isIdentifyingSpeakers = true

    identificationTask = Task {
        do {
            try Task.checkCancellation()

            // 1. Get screenshots
            let screenshotsDir = meeting.directoryURL.appendingPathComponent("screenshots")
            let screenshots = try FileManager.default.contentsOfDirectory(
                at: screenshotsDir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "png" }
             .sorted { $0.lastPathComponent < $1.lastPathComponent }

            guard !screenshots.isEmpty else {
                throw SpeakerIdentificationError.noScreenshots
            }

            // 2. Get transcript
            let transcriptURL = meeting.directoryURL.appendingPathComponent("transcript.txt")
            let transcript = try String(contentsOf: transcriptURL)

            // 3. Extract speaker IDs
            let speakerIds = extractSpeakerIds(from: transcript)

            try Task.checkCancellation()

            // 4. Run identification
            let identifier = SpeakerIdentifier()
            let result = try await identifier.identifySpeakers(
                screenshots: screenshots,
                transcript: transcript,
                speakerIds: speakerIds,
                progressHandler: { progress in
                    Task { @MainActor in
                        identificationProgress = progress
                    }
                }
            )

            try Task.checkCancellation()

            // 5. Show confirmation
            await MainActor.run {
                proposedMappings = result.mappings
                showSpeakerConfirmation = true
                isIdentifyingSpeakers = false
                identificationProgress = nil
            }

        } catch is CancellationError {
            await MainActor.run {
                isIdentifyingSpeakers = false
                identificationProgress = nil
            }
        } catch {
            await MainActor.run {
                isIdentifyingSpeakers = false
                identificationProgress = nil
                // TODO: Show error alert
                print("Speaker identification failed: \(error)")
            }
        }
    }
}

private func extractSpeakerIds(from transcript: String) -> [String] {
    let pattern = "SPEAKER_\\d+"
    let regex = try? NSRegularExpression(pattern: pattern)
    let matches = regex?.matches(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) ?? []

    var ids = Set<String>()
    for match in matches {
        if let range = Range(match.range, in: transcript) {
            ids.insert(String(transcript[range]))
        }
    }

    return ids.sorted()
}

private func applySpeakerMappings(_ mappings: [String: String]) {
    guard let meeting = selectedMeeting else { return }

    // 1. Update meeting metadata
    var updatedMeeting = meeting
    updatedMeeting.speakerMappings = mappings
    updatedMeeting.speakerIdentificationDate = Date()

    // 2. Save to meeting.json
    // ... your existing save logic ...

    // 3. Optionally update transcript display
    // ... refresh transcript view with mapped names ...
}
```

---

### Update Meeting Model

Add to your `Meeting` struct:

```swift
struct Meeting: Codable {
    // ... existing fields ...

    /// Speaker ID to name mappings (e.g., "SPEAKER_00" -> "Jeremy Howard")
    var speakerMappings: [String: String]?

    /// When speaker identification was last run
    var speakerIdentificationDate: Date?
}
```

---

## Error Handling

| Error | User Message | Recovery |
|-------|--------------|----------|
| Ollama not running | "Ollama is not running. Start it with `ollama serve`" | Show instructions |
| Model not installed | "Required model not found. Run `ollama pull gemma3:27b`" | Show command |
| No screenshots | "No screenshots found for this meeting" | Disable button |
| Request timeout | "Request timed out. The model may still be loading." | Suggest retry |
| Network error | "Could not connect to Ollama" | Check entitlement |

---

## Testing Checklist

- [ ] Add `com.apple.security.network.client` entitlement
- [ ] Test with Ollama running - should succeed
- [ ] Test with Ollama stopped - should show helpful error
- [ ] Test with model not installed - should show `ollama pull` command
- [ ] Test cancellation - close view mid-identification
- [ ] Test with meeting that has 2 speakers
- [ ] Test with meeting that has 3+ speakers
- [ ] Test user editing of proposed names
- [ ] Test persistence of mappings after app restart

---

## Performance Notes

- **Model size:** `gemma3:27b` is ~17GB (Q4_K_M quantization)
- **First request:** 10-20 seconds if model not in RAM (loading from disk)
- **Subsequent requests:** 5-15 seconds depending on image count
- **Memory:** ~20GB RAM when model is loaded
- **Image resize:** 1024px max dimension reduces token count by 4-8x

---

## Future Enhancements

1. **Auto-identify after recording** - Checkbox during recording setup
2. **Speaker highlighting** - Highlight current speaker name during playback
3. **Export with names** - Include real names in exported transcripts
4. **Remember corrections** - Learn from user edits for future meetings with same participants

---

## Files Reference

Test scripts used during research (in `/tmp/`):
- `test_ollama_vision.py` - Basic single-image test
- `test_names_only.py` - Name extraction validation
- `speaker_id_framework.py` - Comprehensive test framework
- `comprehensive_test.py` - Batch testing across multiple courses

Research documentation:
- `engineer-notes/speaker-identification-research.md` - Full research notes and learnings
