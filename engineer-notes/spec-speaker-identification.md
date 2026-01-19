# Spec: Speaker Identification from Screenshots

**Date:** 2026-01-19
**Status:** Ready for implementation (reviewed)
**Depends on:** Research findings in `speaker-identification-research.md`
**Reviewed by:** Colleague (2026-01-19) - see "Review Feedback" section at end

## Overview

Add the ability to identify speakers in meeting recordings by analyzing screenshots with a local vision model (Ollama gemma3:27b).

## User Experience

### Trigger Points

1. **Button in MeetingViewer** - "Identify Speakers" button when viewing a meeting
2. **Right-click in History List** - Context menu option on meetings
3. **Automatic (future)** - Checkbox during recording to auto-identify after

### Flow

```
User clicks "Identify Speakers"
    ↓
App extracts key frames from recording
    ↓
App sends frames + transcript to local Ollama
    ↓
Model returns proposed speaker mapping
    ↓
User sees confirmation dialog with editable names
    ↓
User confirms or edits mappings
    ↓
App updates transcript with real names
    ↓
Mapping saved to meeting metadata
```

## Prerequisites

### Required Entitlement

Add to `MuesliApp.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

**Why:** Even though `localhost` is local, the macOS App Sandbox treats it as a network connection. Without this entitlement, `URLSession` requests to `localhost:11434` will fail.

## Implementation

### 1. New File: `SpeakerIdentifier.swift`

```swift
import Foundation
import AppKit
import CoreGraphics

/// Handles speaker identification using local Ollama vision model
actor SpeakerIdentifier {

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
        case loadingModel
        case analyzing
        case complete
    }

    private let ollamaBaseURL = URL(string: "http://localhost:11434")!
    private let model = "gemma3:27b"
    private let maxImageDimension: CGFloat = 1024  // Resize for performance

    // MARK: - Public API

    /// Identify speakers from screenshots and transcript
    /// - Parameter progressHandler: Called with progress updates for UI feedback
    func identifySpeakers(
        screenshots: [URL],
        transcript: String,
        speakerIds: [String],
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws -> IdentificationResult {

        // 1. Select key frames (max 5)
        progressHandler?(.extractingFrames)
        let keyFrames = selectKeyFrames(from: screenshots, maxCount: 5)

        // 2. Load, resize, and encode images
        let encodedImages = try keyFrames.compactMap { url -> (data: String, mediaType: String)? in
            guard let resizedData = try resizeImage(at: url, maxDimension: maxImageDimension) else {
                return nil
            }
            let base64 = resizedData.base64EncodedString()
            return (base64, "image/jpeg")  // Always JPEG after resize for smaller size
        }

        // 3. Extract relevant transcript context (keyword-based + fallback)
        let excerpt = extractRelevantTranscript(from: transcript, maxLines: 150)

        // 4. Build prompt
        let prompt = buildPrompt(transcriptExcerpt: excerpt, speakerIds: speakerIds)

        // 5. Call Ollama
        progressHandler?(.analyzing)
        let response = try await callOllama(images: encodedImages, prompt: prompt)

        // 6. Parse response
        progressHandler?(.complete)
        let mappings = parseResponse(response, speakerIds: speakerIds)

        return IdentificationResult(mappings: mappings, rawResponse: response)
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
    private func extractRelevantTranscript(from transcript: String, maxLines: Int) -> String {
        let lines = transcript.components(separatedBy: .newlines)

        // Keywords that often indicate speaker identity
        let keywords = ["i'm", "my name is", "this is", "hi,", "hello,", "thanks,", "thank you,", " and i "]

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

        // If we found keyword hits, use those lines
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
           - If someone says "X and I did something" → they are NOT X (talking about X)
           - If someone says "Thanks, X" → they're talking TO X
        3. Map each SPEAKER_XX to their real name

        Provide your answer in this exact format:
        \(speakerList)

        If you cannot identify a speaker, write: SPEAKER_XX = unknown
        """
    }

    private func callOllama(
        images: [(data: String, mediaType: String)],
        prompt: String
    ) async throws -> String {

        let url = ollamaBaseURL.appendingPathComponent("v1/messages")

        // Build content array with images + text
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
        request.setValue("ollama", forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120  // Vision models can be slow

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpeakerIdentificationError.ollamaRequestFailed
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

enum SpeakerIdentificationError: Error {
    case ollamaNotRunning
    case ollamaRequestFailed
    case invalidResponse
    case noScreenshots
}

// MARK: - NSImage Extension for JPEG conversion

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

### 2. Add to Meeting Model

Update `meeting.json` schema to store speaker mappings:

```swift
// In Meeting struct
struct Meeting: Codable {
    // ... existing fields ...

    /// Speaker ID to name mappings (e.g., "SPEAKER_00" -> "Jeremy Howard")
    var speakerMappings: [String: String]?

    /// When speaker identification was last run
    var speakerIdentificationDate: Date?
}
```

### 3. UI: Confirmation Dialog

```swift
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

                    TextField("Name", text: Binding(
                        get: { editedMappings[mapping.speakerId] ?? mapping.name },
                        set: { editedMappings[mapping.speakerId] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)

                    // Confidence indicator
                    Circle()
                        .fill(mapping.confidence > 0.7 ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)

                Spacer()

                Button("Apply") {
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
            // Initialize with proposed values
            for mapping in proposedMappings {
                editedMappings[mapping.speakerId] = mapping.name
            }
        }
    }
}
```

### 4. Integration in MeetingViewer

```swift
// Add to MeetingViewer
struct MeetingViewer: View {
    // ... existing code ...

    @State private var isIdentifyingSpeakers = false
    @State private var identificationProgress: SpeakerIdentifier.Progress?
    @State private var showSpeakerConfirmation = false
    @State private var proposedMappings: [SpeakerIdentifier.SpeakerMapping] = []
    @State private var identificationTask: Task<Void, Never>?

    var body: some View {
        // ... existing view code ...

        // Add button to toolbar or view
        Button(action: identifySpeakers) {
            HStack {
                if isIdentifyingSpeakers {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(progressText)
                } else {
                    Label("Identify Speakers", systemImage: "person.2.wave.2")
                }
            }
        }
        .disabled(isIdentifyingSpeakers)

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
        .onDisappear {
            // Cancel identification if view disappears
            identificationTask?.cancel()
            identificationTask = nil
        }
    }

    private var progressText: String {
        switch identificationProgress {
        case .extractingFrames: return "Extracting frames..."
        case .loadingModel: return "Loading model..."
        case .analyzing: return "Analyzing with Ollama..."
        case .complete: return "Complete"
        case nil: return "Identifying..."
        }
    }

    private func identifySpeakers() {
        guard let meeting = selectedMeeting else { return }

        isIdentifyingSpeakers = true

        identificationTask = Task {
            do {
                // Check for cancellation
                try Task.checkCancellation()

                // 1. Get screenshots
                let screenshotsDir = meeting.directoryURL.appendingPathComponent("screenshots")
                let screenshots = try FileManager.default.contentsOfDirectory(
                    at: screenshotsDir,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "png" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

                // 2. Get transcript
                let transcriptURL = meeting.directoryURL.appendingPathComponent("transcript.txt")
                let transcript = try String(contentsOf: transcriptURL)

                // 3. Extract speaker IDs from transcript
                let speakerIds = extractSpeakerIds(from: transcript)

                try Task.checkCancellation()

                // 4. Run identification with progress updates
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
                    // Show error alert
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
        // 1. Update meeting metadata
        // 2. Optionally update transcript file with real names
        // 3. Save changes
    }
}
```

### 5. Check Ollama Availability

```swift
extension SpeakerIdentifier {
    /// Check if Ollama is running and has the required model
    static func checkAvailability() async -> (available: Bool, message: String) {
        let url = URL(string: "http://localhost:11434/api/tags")!

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let models = json?["models"] as? [[String: Any]] ?? []

            let hasGemma = models.contains { ($0["name"] as? String)?.contains("gemma3:27b") == true }

            if hasGemma {
                return (true, "Ollama ready with gemma3:27b")
            } else {
                return (false, "Ollama running but gemma3:27b not installed. Run: ollama pull gemma3:27b")
            }
        } catch {
            return (false, "Ollama not running. Start it with: ollama serve")
        }
    }
}
```

## Data Flow

```
┌─────────────────────┐
│  User clicks        │
│  "Identify Speakers"│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Check Ollama       │
│  availability       │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Load screenshots   │
│  (select 5 key      │
│  frames evenly)     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Load transcript    │
│  Extract SPEAKER_XX │
│  IDs                │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Build prompt with  │
│  reasoning guidance │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  POST to Ollama     │
│  /v1/messages       │
│  (Anthropic API)    │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Parse response     │
│  Extract mappings   │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Show confirmation  │
│  dialog to user     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  User confirms/edits│
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Save mappings to   │
│  meeting.json       │
└─────────────────────┘
```

## Error Handling

| Error | User Message | Action |
|-------|--------------|--------|
| Ollama not running | "Ollama is not running. Start it with `ollama serve`" | Show setup instructions |
| Model not installed | "Required model not found. Run `ollama pull gemma3:27b`" | Show installation command |
| No screenshots | "No screenshots found for this meeting" | Disable button |
| Timeout | "Request timed out. The model may be loading." | Suggest retry |

## Future Enhancements

1. **Automatic identification** - Run automatically after recording ends
2. **Speaker highlighting** - When playing back, highlight current speaker's name
3. **Export with names** - Include speaker names in exported transcripts
4. **Learn from corrections** - Remember user corrections for future meetings with same participants

## Testing

1. Test with Solve It with Code recordings (2 speakers)
2. Test with LLM Evals recordings (2 speakers, different format)
3. Test with Elite AI recordings (2 speakers)
4. Test error cases (Ollama not running, no screenshots)
5. Test user editing of proposed names

---

## Review Feedback (2026-01-19)

Reviewed by colleague. Summary of changes incorporated:

### 1. ✅ Network Entitlement (CRITICAL)
Added `com.apple.security.network.client` to prerequisites. Without this, `URLSession` requests to `localhost:11434` fail in App Sandbox.

### 2. ✅ Task Cancellation
- Added `@State private var identificationTask: Task<Void, Never>?`
- Task is cancelled in `onDisappear`
- Added `Task.checkCancellation()` calls throughout

### 3. ✅ Image Resizing (Performance)
- Added `resizeImage(at:maxDimension:)` method
- Screenshots resized to max 1024px before encoding
- Reduces token count and speeds up inference 2-4x

### 4. ✅ Transcript Selection
- Changed from "first 50 lines" to keyword-based extraction
- Searches for "I'm", "my name is", "this is", etc.
- Grabs context around keyword hits
- Falls back to first 150 lines if no keywords found

### 5. ✅ UI Progress Feedback
- Added `Progress` enum with stages
- Button shows spinner + stage text while processing
- Stages: "Extracting frames..." → "Analyzing with Ollama..." → "Complete"

### 6. Deferred: Type-Safe JSON
Reviewer suggested using `Codable` structs instead of `[String: Any]` for JSON. Deferred for now - current approach works and is readable.

### Original Review Comments

> "The research is solid and the approach is viable. With the network entitlement fix, this will work."

Key insight from review: Model loading on first request can take 10-20 seconds if model isn't in RAM. Consider showing "Loading model..." state if first byte takes too long.
