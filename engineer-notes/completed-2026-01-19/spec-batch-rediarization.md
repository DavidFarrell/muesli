# Spec: Batch Re-Diarization (Post-Recording Speaker Segmentation)

**Date:** 2026-01-19
**Status:** Ready for implementation
**Depends on:** Existing backend `run_pipeline()` function

## Overview

Add a "Rerun speaker segmentation" button in the Meeting Viewer that re-processes the complete audio file using batch diarization, producing higher-quality speaker labels than the live incremental processing.

## Why This Matters

**The Problem:** Live transcription uses a 30-second sliding window (`CONTEXT_SECONDS = 30.0`) for diarization. This limits the clustering algorithm's ability to reliably distinguish speakers, often resulting in:
- One person split across multiple speaker IDs (SPEAKER_00, SPEAKER_02, SPEAKER_04 are all David)
- Speaker IDs that "drift" during long meetings

**The Solution:** Batch processing sees the complete audio file at once, allowing globally optimal speaker clustering. The fast-transcribe CLI tool already demonstrates this produces noticeably better results.

## User Experience

### UI Location

In the Meeting Viewer, above the existing "Identify Speakers" button:

```
┌─────────────────────────────────────────┐
│  [Rerun speaker segmentation]           │  ← NEW (this spec)
│  [Identify speakers]                    │  ← EXISTING
└─────────────────────────────────────────┘
```

### Flow

```
User clicks "Rerun speaker segmentation"
    ↓
App shows progress: "Re-processing audio..."
    ↓
Backend runs batch transcription + diarization on complete audio
    ↓
Backend returns new transcript with improved speaker labels
    ↓
App shows confirmation: "Found N speakers. Replace transcript?"
    ↓
User confirms
    ↓
App replaces transcript files with new version
    ↓
App reloads transcript view with improved labels
    ↓
User can now run "Identify speakers" on the cleaner labels
```

### Progress States

| State | UI Text | Description |
|-------|---------|-------------|
| `preparing` | "Preparing audio..." | Locating and validating audio files |
| `transcribing` | "Transcribing audio..." | Running ASR model (~58x realtime) |
| `diarizing` | "Identifying speakers..." | Running Senko batch diarization |
| `merging` | "Finalizing..." | Merging transcript with speaker labels |
| `complete` | "Complete" | Ready to show results |

## Implementation

### Phase 1: Backend - New Reprocess Command

Add a new CLI command to the backend that takes existing audio files and runs batch processing.

**New file: `reprocess.py`** (or add to existing `muesli_backend.py`)

```python
"""
Batch reprocessing command for completed meetings.
Re-runs transcription + diarization on existing audio files.
"""

import argparse
import json
import sys
from pathlib import Path

from .audio import normalise_audio, is_wav_16k_mono, check_ffmpeg
from .asr import ASRModel, DEFAULT_MODEL
from .diarisation import SortformerDiarizer, MODEL_CONFIGS
from .merge import merge_transcript_with_diarisation


def reprocess_audio(
    audio_path: Path,
    stream_name: str,
    diar_backend: str = "senko",
    diar_model: str = "default",
    asr_model: str = DEFAULT_MODEL,
    language: str | None = None,
    gap_threshold: float = 0.8,
    speaker_tolerance: float = 0.25,
    verbose: bool = False,
) -> dict:
    """
    Reprocess a single audio file with batch transcription + diarization.

    Returns dict with:
        - turns: list of {speaker_id, start, end, text}
        - speakers: list of unique speaker IDs found
        - duration: total audio duration in seconds
    """

    def log(msg: str):
        if verbose:
            print(msg, file=sys.stderr)

    # Normalize to 16kHz mono WAV if needed
    temp_wav = None
    delete_temp = False

    if is_wav_16k_mono(str(audio_path)):
        temp_wav = str(audio_path)
    else:
        if not check_ffmpeg():
            raise RuntimeError("ffmpeg not found")
        log("Normalizing audio...")
        temp_wav = normalise_audio(str(audio_path))
        delete_temp = True

    try:
        # ASR
        log(f"Running ASR with {asr_model}...")
        asr = ASRModel(asr_model)
        transcript = asr.transcribe(temp_wav, language=language)

        # Diarization (batch mode - full file)
        if diar_backend == "senko":
            log("Running Senko diarization (batch)...")
            from .senko_diarisation import SenkoDiarizer
            diarizer = SenkoDiarizer(quiet=not verbose)
            segments = diarizer.diarise(temp_wav)
        else:
            log(f"Running Sortformer diarization ({diar_model})...")
            diarizer = SortformerDiarizer(model_name=diar_model)
            segments = diarizer.diarise(temp_wav)

        # Merge
        log("Merging transcript with speaker labels...")
        merged = merge_transcript_with_diarisation(
            transcript,
            segments,
            gap_threshold=gap_threshold,
            speaker_tolerance=speaker_tolerance,
        )

        # Build result
        turns = []
        speakers = set()
        for turn in merged.turns:
            speaker_id = f"{stream_name}:{turn.speaker}"
            speakers.add(speaker_id)
            turns.append({
                "speaker_id": speaker_id,
                "speaker": turn.speaker,
                "stream": stream_name,
                "t0": turn.start,
                "t1": turn.end,
                "text": turn.text,
            })

        # Calculate duration from last word
        duration = 0.0
        if transcript.words:
            duration = max(w.end for w in transcript.words)

        return {
            "turns": turns,
            "speakers": sorted(speakers),
            "duration": duration,
        }

    finally:
        if delete_temp and temp_wav:
            try:
                Path(temp_wav).unlink(missing_ok=True)
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(
        description="Reprocess meeting audio with batch diarization"
    )
    parser.add_argument(
        "meeting_dir",
        help="Path to meeting directory containing audio/ folder"
    )
    parser.add_argument(
        "--stream",
        choices=["system", "mic", "both"],
        default="system",
        help="Which audio stream(s) to process (default: system)"
    )
    parser.add_argument(
        "--diar-backend",
        choices=["senko", "sortformer"],
        default="senko",
        help="Diarization backend (default: senko)"
    )
    parser.add_argument(
        "--diar-model",
        choices=list(MODEL_CONFIGS.keys()),
        default="default",
        help="Sortformer model variant"
    )
    parser.add_argument(
        "--asr-model",
        default=DEFAULT_MODEL,
        help=f"ASR model (default: {DEFAULT_MODEL})"
    )
    parser.add_argument(
        "--language",
        default=None,
        help="Language code (auto-detect if not specified)"
    )
    parser.add_argument(
        "--gap-threshold",
        type=float,
        default=0.8,
        help="Gap threshold for speaker turns (default: 0.8)"
    )
    parser.add_argument(
        "--speaker-tolerance",
        type=float,
        default=0.25,
        help="Word-speaker assignment tolerance (default: 0.25)"
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Verbose output to stderr"
    )
    parser.add_argument(
        "--output",
        help="Output file for results (default: stdout)"
    )

    args = parser.parse_args()

    meeting_dir = Path(args.meeting_dir)
    audio_dir = meeting_dir / "audio"

    if not audio_dir.exists():
        print(json.dumps({"error": "audio directory not found"}))
        return 1

    streams = ["system", "mic"] if args.stream == "both" else [args.stream]
    all_turns = []
    all_speakers = set()

    for stream_name in streams:
        # Try .wav first, then .raw
        audio_file = audio_dir / f"{stream_name}.wav"
        if not audio_file.exists():
            audio_file = audio_dir / f"{stream_name}.raw"
        if not audio_file.exists():
            print(json.dumps({
                "type": "error",
                "message": f"No audio file for stream: {stream_name}"
            }))
            continue

        print(json.dumps({
            "type": "progress",
            "stage": "transcribing",
            "stream": stream_name,
        }), flush=True)

        try:
            result = reprocess_audio(
                audio_path=audio_file,
                stream_name=stream_name,
                diar_backend=args.diar_backend,
                diar_model=args.diar_model,
                asr_model=args.asr_model,
                language=args.language,
                gap_threshold=args.gap_threshold,
                speaker_tolerance=args.speaker_tolerance,
                verbose=args.verbose,
            )
            all_turns.extend(result["turns"])
            all_speakers.update(result["speakers"])

        except Exception as e:
            print(json.dumps({
                "type": "error",
                "message": str(e),
                "stream": stream_name,
            }))
            return 1

    # Sort turns by timestamp
    all_turns.sort(key=lambda t: t["t0"])

    # Output final result
    output = {
        "type": "result",
        "turns": all_turns,
        "speakers": sorted(all_speakers),
        "turn_count": len(all_turns),
        "speaker_count": len(all_speakers),
    }

    if args.output:
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2)
    else:
        print(json.dumps(output))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

**Entry point in `pyproject.toml`:**

```toml
[project.scripts]
muesli-backend = "diarise_transcribe.muesli_backend:main"
muesli-reprocess = "diarise_transcribe.reprocess:main"  # NEW
```

### Phase 2: Swift - BatchRediarizer Actor

**New file: `BatchRediarizer.swift`**

```swift
import Foundation

/// Handles batch re-diarization of completed meetings
actor BatchRediarizer {

    enum Progress: Equatable {
        case preparing
        case transcribing(stream: String)
        case diarizing
        case merging
        case complete
    }

    struct RediarizationResult {
        let turns: [Turn]
        let speakers: [String]
        let turnCount: Int
        let speakerCount: Int
    }

    struct Turn: Codable {
        let speakerId: String
        let speaker: String
        let stream: String
        let t0: Double
        let t1: Double
        let text: String

        enum CodingKeys: String, CodingKey {
            case speakerId = "speaker_id"
            case speaker
            case stream
            case t0
            case t1
            case text
        }
    }

    private let backendPath: URL
    private let diarBackend: String
    private let timeout: TimeInterval = 600  // 10 minutes max

    init(backendPath: URL, diarBackend: String = "senko") {
        self.backendPath = backendPath
        self.diarBackend = diarBackend
    }

    /// Run batch re-diarization on a completed meeting
    func reprocess(
        meetingDirectory: URL,
        streams: [String] = ["system"],
        progressHandler: ((Progress) -> Void)? = nil
    ) async throws -> RediarizationResult {

        progressHandler?(.preparing)
        try Task.checkCancellation()

        // Verify audio directory exists
        let audioDir = meetingDirectory.appendingPathComponent("audio")
        guard FileManager.default.fileExists(atPath: audioDir.path) else {
            throw RediarizationError.audioNotFound
        }

        // Build command
        let reprocessPath = backendPath
            .deletingLastPathComponent()
            .appendingPathComponent("muesli-reprocess")

        let streamArg = streams.count > 1 ? "both" : streams.first ?? "system"

        let process = Process()
        process.executableURL = reprocessPath
        process.arguments = [
            meetingDirectory.path,
            "--stream", streamArg,
            "--diar-backend", diarBackend,
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Read output lines for progress + result
        var resultJSON: Data?
        let handle = stdout.fileHandleForReading

        while process.isRunning || handle.availableData.count > 0 {
            try Task.checkCancellation()

            guard let line = readLine(from: handle) else {
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                continue
            }

            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            switch type {
            case "progress":
                if let stage = json["stage"] as? String {
                    switch stage {
                    case "transcribing":
                        let stream = json["stream"] as? String ?? "system"
                        progressHandler?(.transcribing(stream: stream))
                    case "diarizing":
                        progressHandler?(.diarizing)
                    case "merging":
                        progressHandler?(.merging)
                    default:
                        break
                    }
                }

            case "result":
                resultJSON = data

            case "error":
                let message = json["message"] as? String ?? "Unknown error"
                throw RediarizationError.backendError(message)

            default:
                break
            }
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RediarizationError.backendFailed(exitCode: Int(process.terminationStatus))
        }

        guard let data = resultJSON else {
            throw RediarizationError.noResult
        }

        progressHandler?(.complete)

        // Parse result
        let decoder = JSONDecoder()
        let wrapper = try decoder.decode(ResultWrapper.self, from: data)

        return RediarizationResult(
            turns: wrapper.turns,
            speakers: wrapper.speakers,
            turnCount: wrapper.turnCount,
            speakerCount: wrapper.speakerCount
        )
    }

    private func readLine(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8) }
            if byte[0] == UInt8(ascii: "\n") { return String(data: buffer, encoding: .utf8) }
            buffer.append(byte)
        }
    }

    private struct ResultWrapper: Codable {
        let turns: [Turn]
        let speakers: [String]
        let turnCount: Int
        let speakerCount: Int

        enum CodingKeys: String, CodingKey {
            case turns
            case speakers
            case turnCount = "turn_count"
            case speakerCount = "speaker_count"
        }
    }
}

enum RediarizationError: LocalizedError {
    case audioNotFound
    case backendError(String)
    case backendFailed(exitCode: Int)
    case noResult

    var errorDescription: String? {
        switch self {
        case .audioNotFound:
            return "Audio files not found in meeting directory"
        case .backendError(let message):
            return "Backend error: \(message)"
        case .backendFailed(let code):
            return "Backend process failed with exit code \(code)"
        case .noResult:
            return "No result returned from backend"
        }
    }
}
```

### Phase 3: AppModel Integration

**Add to `AppModel.swift`:**

```swift
// MARK: - Batch Re-diarization

func reprocessMeeting(
    _ meeting: MeetingHistoryItem,
    progressHandler: ((BatchRediarizer.Progress) -> Void)? = nil
) async throws -> BatchRediarizer.RediarizationResult {

    guard let backendURL = backendURL else {
        throw RediarizationError.backendError("Backend not configured")
    }

    let rediarizer = BatchRediarizer(
        backendPath: backendURL,
        diarBackend: "senko"  // Could make configurable
    )

    return try await rediarizer.reprocess(
        meetingDirectory: meeting.folderURL,
        streams: ["system"],  // Could support ["system", "mic"] for both
        progressHandler: progressHandler
    )
}

func applyRediarization(
    _ result: BatchRediarizer.RediarizationResult,
    to meeting: MeetingHistoryItem
) throws {

    // 1. Build new transcript content
    var transcriptLines: [String] = []
    for turn in result.turns {
        let line = "[\(turn.stream)] t=\(String(format: "%.2f", turn.t0))s \(turn.speakerId): \(turn.text)"
        transcriptLines.append(line)
    }
    let transcriptText = transcriptLines.joined(separator: "\n")

    // 2. Build new transcript.jsonl content
    var jsonlLines: [String] = []
    for turn in result.turns {
        let obj: [String: Any] = [
            "type": "segment",
            "speaker_id": turn.speakerId,
            "speaker": turn.speaker,
            "stream": turn.stream,
            "t0": turn.t0,
            "t1": turn.t1,
            "text": turn.text,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let line = String(data: data, encoding: .utf8) {
            jsonlLines.append(line)
        }
    }
    let jsonlText = jsonlLines.joined(separator: "\n")

    // 3. Write files
    let txtURL = meeting.folderURL.appendingPathComponent("transcript.txt")
    let jsonlURL = meeting.folderURL.appendingPathComponent("transcript.jsonl")

    try transcriptText.write(to: txtURL, atomically: true, encoding: .utf8)
    try jsonlText.write(to: jsonlURL, atomically: true, encoding: .utf8)

    // 4. Update meeting.json
    var metadata = try readMeetingMetadata(from: meeting.folderURL)
    metadata.segmentCount = result.turnCount
    metadata.speakerNames = [:]  // Clear old names - user will re-identify
    metadata.updatedAt = Date()
    try writeMeetingMetadata(metadata, to: meeting.folderURL)

    // 5. Reload transcript into model
    transcriptModel.resetForNewMeeting(keepSpeakerNames: false)
    for turn in result.turns {
        let segment = TranscriptSegment(
            speakerID: turn.speakerId,
            stream: turn.stream,
            t0: turn.t0,
            t1: turn.t1,
            text: turn.text,
            isPartial: false
        )
        transcriptModel.segments.append(segment)
    }
    transcriptModel.segments.sort { $0.t0 < $1.t0 }
}
```

### Phase 4: UI Integration

**Add to `MeetingViewer` in `ContentView.swift`:**

```swift
struct MeetingViewer: View {
    // ... existing state ...

    @State private var isReprocessing = false
    @State private var reprocessProgress: BatchRediarizer.Progress?
    @State private var reprocessTask: Task<Void, Never>?
    @State private var showReprocessConfirmation = false
    @State private var reprocessResult: BatchRediarizer.RediarizationResult?

    var body: some View {
        VStack {
            // ... existing content ...

            // Action buttons section
            HStack(spacing: 12) {
                // Reprocess button (NEW)
                Button(action: startReprocess) {
                    HStack {
                        if isReprocessing {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text(reprocessProgressText)
                        } else {
                            Label("Rerun speaker segmentation", systemImage: "waveform.badge.magnifyingglass")
                        }
                    }
                }
                .disabled(isReprocessing || isIdentifyingSpeakers)
                .help("Re-process audio with batch diarization for better speaker separation")

                // Identify speakers button (EXISTING)
                Button(action: identifySpeakers) {
                    // ... existing code ...
                }
                .disabled(isIdentifyingSpeakers || isReprocessing)
            }
        }
        .alert("Reprocess Complete", isPresented: $showReprocessConfirmation) {
            Button("Cancel", role: .cancel) {
                reprocessResult = nil
            }
            Button("Replace Transcript") {
                applyReprocessResult()
            }
        } message: {
            if let result = reprocessResult {
                Text("Found \(result.speakerCount) speakers in \(result.turnCount) segments. Replace the current transcript with improved speaker labels?")
            }
        }
        .onDisappear {
            reprocessTask?.cancel()
            reprocessTask = nil
        }
    }

    private var reprocessProgressText: String {
        switch reprocessProgress {
        case .preparing:
            return "Preparing..."
        case .transcribing(let stream):
            return "Transcribing \(stream)..."
        case .diarizing:
            return "Identifying speakers..."
        case .merging:
            return "Finalizing..."
        case .complete:
            return "Complete"
        case nil:
            return "Processing..."
        }
    }

    private func startReprocess() {
        isReprocessing = true
        reprocessProgress = nil

        reprocessTask = Task {
            do {
                let result = try await model.reprocessMeeting(
                    meeting,
                    progressHandler: { progress in
                        Task { @MainActor in
                            reprocessProgress = progress
                        }
                    }
                )

                await MainActor.run {
                    reprocessResult = result
                    showReprocessConfirmation = true
                    isReprocessing = false
                }

            } catch is CancellationError {
                await MainActor.run {
                    isReprocessing = false
                }
            } catch {
                await MainActor.run {
                    isReprocessing = false
                    // Show error alert
                }
            }
        }
    }

    private func applyReprocessResult() {
        guard let result = reprocessResult else { return }

        do {
            try model.applyRediarization(result, to: meeting)
            reprocessResult = nil
        } catch {
            // Show error alert
        }
    }
}
```

## Data Flow

```
┌─────────────────────────────────┐
│  User clicks "Rerun speaker     │
│  segmentation"                  │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Swift calls muesli-reprocess   │
│  with meeting directory path    │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Backend loads audio files:     │
│  audio/system.wav               │
│  audio/mic.wav (if requested)   │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  ASR: Parakeet MLX              │
│  (~58x realtime)                │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Diarization: Senko BATCH       │
│  (sees complete audio file)     │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Merge: words + speaker labels  │
│  → speaker turns                │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Return JSON result to Swift    │
│  {turns, speakers, counts}      │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Show confirmation dialog       │
│  "Found N speakers. Replace?"   │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  User confirms → write files:   │
│  - transcript.txt               │
│  - transcript.jsonl             │
│  - meeting.json (clear names)   │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Reload transcript view         │
│  User can now "Identify"        │
└─────────────────────────────────┘
```

## File Changes After Reprocessing

| File | Change |
|------|--------|
| `transcript.txt` | **Replaced** with batch-diarized version |
| `transcript.jsonl` | **Replaced** with batch-diarized version |
| `transcript_events.jsonl` | **Unchanged** (historical record of live events) |
| `meeting.json` | Updated: `segment_count`, `speaker_names` cleared, `updated_at` |
| `audio/*.wav` | **Unchanged** (source files preserved) |
| `screenshots/` | **Unchanged** |

## Error Handling

| Error | User Message | Action |
|-------|--------------|--------|
| Audio files missing | "Audio files not found. Cannot reprocess." | Disable button |
| Backend not found | "Backend not configured" | Show setup instructions |
| Backend timeout | "Processing timed out. Try again." | Suggest retry |
| Backend crash | "Processing failed. Check logs." | Show error details |
| Write failed | "Could not save transcript. Check permissions." | Show error |

## Performance Expectations

For a typical meeting:

| Duration | Transcription | Diarization | Total |
|----------|---------------|-------------|-------|
| 5 min | ~5 sec | ~10 sec | ~15 sec |
| 30 min | ~30 sec | ~45 sec | ~1.5 min |
| 60 min | ~1 min | ~1.5 min | ~2.5 min |

Note: Diarization time depends on speaker count and audio complexity.

## Future Enhancements

1. **Automatic reprocessing** - Option to auto-reprocess when recording stops
2. **Selective stream reprocessing** - Reprocess only mic or only system
3. **Progress percentage** - Show actual progress based on audio duration
4. **Diff view** - Show what changed between old and new transcript
5. **Undo** - Keep backup of original transcript for rollback
6. **Expected speaker count** - Let user hint "this was a 2-person meeting"

## Testing

1. **Normal case**: Record short meeting, stop, reprocess, verify improved labels
2. **Long meeting**: Test with 30+ minute recording
3. **Multiple speakers**: Test with 3+ distinct speakers
4. **Cancellation**: Start reprocess, navigate away, verify clean cancellation
5. **Missing audio**: Delete audio files, verify graceful error
6. **After identify**: Reprocess after having identified speakers, verify names cleared

---

## Implementation Checklist

### Phase 1: Backend
- [ ] Create `reprocess.py` module
- [ ] Add `muesli-reprocess` entry point
- [ ] Test CLI independently: `muesli-reprocess /path/to/meeting --verbose`

### Phase 2: Swift Actor
- [ ] Create `BatchRediarizer.swift`
- [ ] Handle progress events from backend
- [ ] Parse result JSON
- [ ] Handle errors and cancellation

### Phase 3: AppModel
- [ ] Add `reprocessMeeting()` method
- [ ] Add `applyRediarization()` method
- [ ] Update transcript files
- [ ] Clear speaker names in metadata

### Phase 4: UI
- [ ] Add button to MeetingViewer
- [ ] Show progress states
- [ ] Confirmation dialog
- [ ] Error handling
- [ ] Disable during processing

### Phase 5: Testing
- [ ] Unit test backend CLI
- [ ] Integration test Swift → backend
- [ ] Manual testing with real recordings
- [ ] Edge cases (missing files, cancellation)
