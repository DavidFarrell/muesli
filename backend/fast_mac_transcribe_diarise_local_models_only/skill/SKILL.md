---
name: fast-diarize
description: Transcribe audio/video with speaker diarization (who said what). FAST - 58x realtime on Apple Silicon. Uses Parakeet MLX + Senko CoreML. Outputs speaker-labelled transcripts. Accepts local files or YouTube URLs.
---

# Fast Diarization Transcription

Blazing fast offline transcription + speaker diarisation for Apple Silicon Macs using local models only.

**Speed:** ~58x realtime (92 min file → 95 seconds)
**Tech:** Parakeet MLX (ASR) + Senko/pyannote+CAM++ CoreML (diarisation)

## Full Workflow

1. **Transcribe & Diarize** - Run the fast transcription (output to /tmp/)
2. **Identify Speakers** - Use visual + textual cues to map SPEAKER_XX to real names
3. **Confirm with User** - Present findings, get confirmation
4. **Rewrite Transcript** - Replace speaker labels with real names
5. **Decide Output Destination** - Keep in /tmp/, copy to permanent location, or discard

---

## Output Location

**ALL output goes to `/tmp/fast-diarize/` initially.**

This includes:
- Transcripts (transcript.txt, transcript.json)
- Frames extracted for speaker identification
- Named transcripts after speaker identification

**Why?** The user might just want to transcribe something to ask a question about it, not keep files permanently. Claude decides what to do with the output based on context, or asks the user if unclear.

---

## Phase 1: Transcription

### Input Types

The skill accepts:
- **Local files** - Any audio/video format ffmpeg supports
- **YouTube URLs** - youtube.com, youtu.be links

### For YouTube URLs

If the input looks like a YouTube URL (contains `youtube.com` or `youtu.be`):

1. **Download video (for frame extraction):**
   ```bash
   OUTPUT_DIR="/tmp/fast-diarize/$(date +%Y%m%d_%H%M%S)"
   mkdir -p "$OUTPUT_DIR"
   yt-dlp -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" \
     -o "$OUTPUT_DIR/%(title)s.%(ext)s" "<youtube_url>"
   ```

2. **Get the downloaded filename:**
   ```bash
   VIDEO_FILE=$(ls "$OUTPUT_DIR"/*.mp4 "$OUTPUT_DIR"/*.webm "$OUTPUT_DIR"/*.mkv 2>/dev/null | head -1)
   ```

3. Then proceed with transcription using `$VIDEO_FILE` as input.

**Note:** YouTube downloads go to the same /tmp/ location as all other output. Downloading video (not audio-only) preserves the ability to extract frames for speaker identification.

### For Local Files

1. **Get the file duration:**
   ```bash
   ffprobe -v quiet -show_entries format=duration -of csv=p=0 "<file_path>" | awk '{printf "%.1f minutes\n", $1/60}'
   ```

2. **Check if video or audio:**
   ```bash
   ffprobe -v quiet -select_streams v -show_entries stream=codec_type -of csv=p=0 "<file_path>" | head -1
   ```
   (Returns "video" if video stream exists, empty if audio-only)

### Before Running (All Input Types)

**Confirm with user** using AskUserQuestion:
   - File name and duration
   - Estimated processing time (~1 sec per minute + 20s overhead)
   - Whether to attempt speaker identification after
   - Options: "Yes, transcribe + identify speakers" / "Just transcribe" / "Cancel"

### Run Transcription

```bash
cd /Users/david/git/ai-sandbox/projects/fast_mac_transcribe_diarise_local_models_only && \
OUTPUT_DIR="/tmp/fast-diarize/$(date +%Y%m%d_%H%M%S)" && \
mkdir -p "$OUTPUT_DIR" && \
uv run diarise-transcribe \
  --in "<audio_file>" \
  --out "$OUTPUT_DIR/transcript.txt" \
  --out-json "$OUTPUT_DIR/transcript.json" \
  --verbose
```

Note: Frames for speaker identification also go in `$OUTPUT_DIR/frames/`.

---

## Phase 2: Speaker Identification

After transcription completes, identify who each speaker is.

### Step 2a: Parse Transcript for Key Moments

Read the transcript.json and extract:

1. **First appearance of each speaker** (timestamp + first few words)
2. **Speaker change moments** (3-5 instances where speaker switches)
3. **Total speakers detected**

Example analysis:
```
Speakers found: SPEAKER_01, SPEAKER_02, SPEAKER_03
First appearances:
  - SPEAKER_01: 00:14.40 "Hey Isaac. You are muted..."
  - SPEAKER_02: 00:24.16 "Hey, can you hear me now?"
  - SPEAKER_03: 01:47.68 (brief appearance)
```

### Step 2b: Textual Clues

Search the transcript text for name mentions:

**Self-introductions:**
- "I'm [Name]", "I am [Name]", "This is [Name]"
- "[Name] here", "My name is [Name]"
- "Welcome, I'm [Name]"

**Addressing others:**
- "Hey [Name]", "Hi [Name]", "Thanks [Name]"
- "As [Name] said", "Like [Name] mentioned"
- "Good point [Name]", "Over to you [Name]"

**Role indicators:**
- "I'm your host", "Welcome to my show"
- "Thanks for having me"
- "As the guest today"

For each potential name found, note:
- The name
- Which speaker said it OR was addressed
- Timestamp
- Context snippet

### Step 2c: Visual Clues (Video Files Only)

If the input is a video file, extract frames at key moments:

```bash
# Extract frame at specific timestamp (converts MM:SS.ms to seconds)
ffmpeg -ss <seconds> -i "<video_file>" -frames:v 1 -q:v 2 "<output_dir>/frame_<timestamp>.jpg"
```

**Timestamps to capture:**
1. **0:00** - Opening frame (often shows title/intro)
2. **First appearance of each speaker** - From Step 2a timestamps
3. **2-3 speaker change moments** - Mid-conversation

**What to look for in frames (use Claude vision):**
- Video call name overlays (Zoom: bottom-left, Teams: bottom, Meet: bottom)
- Title cards or slides with presenter names
- Any visible text identifying speakers
- Distinctive visual features to correlate speakers

Read each extracted frame with the Read tool and analyze for speaker identification clues.

### Step 2d: Present Speaker Identification Evidence

Present findings to the user with FULL evidence for EACH speaker before asking for verification.

**Format for each speaker:**

```
### SPEAKER_XX → **[Name]** ([CONFIDENCE] confidence)

**Visual evidence:**
- [List frames where this speaker appears with name tags or identifying info]
- [If no visual evidence: "No frames captured at SPEAKER_XX timestamps" + what could be tried]

**Textual evidence:**
| Timestamp | Quote | Why it helps |
|-----------|-------|--------------|
| MM:SS | "[Exact quote from transcript]" | [Explanation of why this identifies them] |
| MM:SS | "[Another quote]" | [Explanation] |

**Conclusion:** [One sentence explaining the reasoning that leads to this identification]
```

**For unknown speakers, also include:**
- What we could try (extract more frames, check other timestamps)
- Recommendation (leave as "Speaker X" or omit if very brief)

**Example output:**

```
## Speaker Identification Evidence - [File Name]

### SPEAKER_01 → **Eleanor Berger** (HIGH confidence)

**Visual evidence:**
- Frame at 00:00 shows name tag "Eleanor Berger" (woman with long hair, glasses)
- Frame at 00:05 shows same person presenting title slide
- Frame at 01:00 shows same person presenting content slides

**Textual evidence:**
| Timestamp | Quote | Why it helps |
|-----------|-------|--------------|
| 00:00 | "Let's get started. As a reminder..." | Main lecturer, matches video |
| 27:30 | "Those of you who maybe follow **Isaac** or myself..." | References Isaac as someone else |

**Conclusion:** Visual name tag + being referenced as "myself" distinct from Isaac = Eleanor.

---

### SPEAKER_02 → **Isaac Flath** (HIGH confidence)

**Visual evidence:**
- No frames captured showing SPEAKER_02 on camera
- Could extract additional frames at SPEAKER_02 timestamps (14:24, 18:18) if needed

**Textual evidence:**
| Timestamp | Quote | Why it helps |
|-----------|-------|--------------|
| 14:24 | "Question from the chat..." | Asking a question (co-host behavior) |
| 31:43 | "One of the things that **Eleanor mentioned**..." | Explicitly references Eleanor as someone else |

**Conclusion:** References "Eleanor mentioned" = SPEAKER_02 is NOT Eleanor = must be Isaac.

---

### SPEAKER_00 → **Unknown** (LOW confidence)

**Visual evidence:**
- No frames captured at SPEAKER_00 timestamps

**Textual evidence:**
- Only 1-2 brief appearances in transcript
- No self-identification or name mentions

**What we could try:**
- Extract frames at SPEAKER_00 timestamps to check for participant name tags

**Recommendation:** Leave as "Speaker 3" or omit if very brief.

---

### Summary

| Speaker | Identified As | Confidence | Key Evidence |
|---------|---------------|------------|--------------|
| SPEAKER_01 | Eleanor | HIGH | Name tag visible + "follow Isaac or myself" |
| SPEAKER_02 | Isaac | HIGH | "One of the things that Eleanor mentioned" |
| SPEAKER_00 | Unknown | LOW | No identifying info, minimal appearances |
```

---

## Phase 3: User Verification

After presenting the full evidence above, offer verification options:

**First, ask if user wants to verify:**
```
Want to verify?

I can open these for you:
- Frames folder: [path]
- Transcript: [path]
```

Use AskUserQuestion with options:
- "Open frames folder" - Open in Finder to check name tags
- "Open transcript" - Open transcript.txt to check quotes
- "Both" - Open frames and transcript
- "Skip - looks good" - Proceed to confirmation

**If user verifies and returns, THEN ask for confirmation:**

Use AskUserQuestion with options:
- "Yes, apply names" - Create transcript_named.txt with real names
- "Edit mappings" - Let user correct identifications
- "Skip naming" - Keep SPEAKER_XX labels as-is

---

## Phase 4: Rewrite Transcript

Once confirmed, create new versions with real names:

### Rewrite Logic

Read transcript.txt and transcript.json, replace all instances:
- `SPEAKER_01` → `Isaac`
- `SPEAKER_02` → `Eleanor`
- etc.

Save as:
- `transcript_named.txt`
- `transcript_named.json`

Keep originals intact.

**Text format becomes:**
```
[00:14.40 - 00:21.44] Eleanor: Hey Isaac. You are muted, I think.
[00:24.16 - 00:28.24] Isaac: Hey, can you hear me now?
```

---

## Phase 5: Decide Output Destination

After transcription and speaker identification are complete, decide what to do with the files.

**All files are currently in `/tmp/fast-diarize/<timestamp>/`**

### Decision Logic

**Claude should infer from context:**

| Context | Action |
|---------|--------|
| User asked a question about the content | Leave in /tmp/, answer the question, done |
| User is building a resource (course notes, meeting archive) | Copy to permanent location next to source file |
| User explicitly said where to save | Copy to that location |
| Unclear | Ask the user |

### If Asking the User

Use AskUserQuestion with options:
- "Save next to source file" - Copy transcript(s) to same folder as the audio/video
- "Save to specific location" - Ask for destination path
- "Keep in /tmp/" - Leave as-is (will be cleaned up eventually)
- "Discard" - Delete the temp folder now

### Copy Command

```bash
# Copy final transcripts to permanent location
cp /tmp/fast-diarize/<timestamp>/transcript_named.txt "<destination>/<filename>_transcript.txt"
cp /tmp/fast-diarize/<timestamp>/transcript_named.json "<destination>/<filename>_transcript.json"
```

If speaker identification wasn't done, copy the original transcript.txt/json instead.

**Do NOT copy frames** - they were only for speaker identification and aren't needed permanently.

---

## CLI Options Reference

| Option | Description |
|--------|-------------|
| `--in`, `-i` | Input audio/video file (any format ffmpeg supports) |
| `--out`, `-o` | Output plain text file with speaker labels |
| `--out-json` | Output JSON with words, segments, and turns |
| `--out-srt` | Output SRT subtitle file with speaker labels |
| `--out-rttm` | Output RTTM file (diarisation segments only) |
| `--num-speakers` | Filter output to top N speakers by activity |
| `--gap-threshold` | Gap threshold (seconds) for turn splitting (default: 0.8) |
| `--verbose`, `-v` | Show progress |

---

## Quality Notes

- **Transcription accuracy:** ~95%+ (excellent)
- **Speaker detection:** Good (occasional turn boundary wobbles)
- **Speaker identification:** Depends on available clues (names in video, self-introductions)

## When to Use

| Use `fast-diarize` | Use `slow-diarize` |
|---------------------|---------------------|
| Most transcription needs | Legal/medical requiring highest accuracy |
| Quick turnaround | Precise speaker boundaries critical |
| Long files (1+ hours) | Already have hours to spare |
| Want speaker names identified | Just need SPEAKER_XX labels |
