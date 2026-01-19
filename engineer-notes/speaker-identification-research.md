# Speaker Identification from Screenshots - Research & Learnings

**Date:** 2026-01-19
**Status:** Research complete, ready for implementation

## Overview

This document captures research into using local vision models (Ollama) to identify speakers in meeting recordings by correlating screenshots with diarized transcripts.

## The Problem

Given:
- Diarized transcript with anonymous labels: `SPEAKER_00`, `SPEAKER_01`, etc.
- Screenshots captured every ~5 seconds during recording
- Screenshots may show video call UI with participant names, YouTube videos, presentations, etc.

Goal: Map `SPEAKER_XX` → real person name

## Solution: Local Ollama Vision Model

### Setup

David has Ollama running locally with `gemma3:27b` (a vision-capable model). Ollama v0.14.0+ supports the Anthropic Messages API natively.

```bash
# Check Ollama is running
ollama serve

# Check version (need 0.14.0+)
ollama --version

# Model used for testing
gemma3:27b
```

### API Syntax (Anthropic-Compatible)

```python
import anthropic
import base64
from pathlib import Path

# Point to local Ollama (Anthropic-compatible API since v0.14.0)
client = anthropic.Anthropic(
    base_url="http://localhost:11434",  # NOT /v1 - just the base URL
    api_key="ollama"  # Required but ignored locally
)

def analyze_image(image_path: Path, prompt: str) -> str:
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
        ".gif": "image/gif",
        ".webp": "image/webp"
    }.get(suffix, "image/png")

    # Send to model
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

### Multi-Image Support

The model accepts multiple images in a single request:

```python
def analyze_multiple_images(image_paths: list[Path], prompt: str) -> str:
    """Send multiple images to model."""

    content = []

    # Add each image
    for img_path in image_paths[:5]:  # Limit to 5 images
        with open(img_path, "rb") as f:
            image_data = base64.standard_b64encode(f.read()).decode("utf-8")

        content.append({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/png",
                "data": image_data
            }
        })

    # Add the prompt
    content.append({"type": "text", "text": prompt})

    response = client.messages.create(
        model="gemma3:27b",
        max_tokens=1024,
        messages=[{"role": "user", "content": content}]
    )

    return response.content[0].text
```

## Test Results

Tested across 3 different courses with 7 total lessons:

| Course | Speakers | Results |
|--------|----------|---------|
| Solve It with Code (3 lessons) | Jeremy Howard, Johnno | 100% |
| LLM Evals (2 lessons) | Shreya Shankar, Hamel Hussain | 100% |
| Elite AI Coding (2 lessons) | Eleanor Berger, Isaac Flath | 100% |

**Overall: 14/14 speakers correctly identified (100%)**

## What Works Well

### 1. Name Extraction from Screenshots (100% reliable)

Simple prompt that consistently extracts visible names:

```python
prompt = """List all participant names visible in this screenshot.
Just the names, one per line. Nothing else."""
```

The model reliably finds:
- Video tile name labels (Zoom, Teams, Meet, etc.)
- YouTube channel names
- Presenter names on slides
- Names in chat windows

### 2. Aggregate Approach (Most Reliable)

Send multiple screenshots + transcript excerpt together:

```python
prompt = f"""I'm sending you screenshots from a video recording.

Here is an excerpt from the transcript with anonymous speaker labels:

{transcript_excerpt}

Your task:
1. Look at the screenshots to identify participants (name labels, video tiles, presenter names)
2. Use context clues in transcript (introductions, who addresses whom)
3. Map each SPEAKER_XX to their real name

Answer format:
SPEAKER_00 = [name]
SPEAKER_01 = [name]
(etc.)"""
```

### 3. Direct Transcript Clues

These patterns are picked up reliably:
- `"And this is that, Johnny"` → Speaker is talking TO Johnny
- `"Hi, I'm Hamel"` → Speaker IS Hamel
- `"I studied computer science... I'm a CS researcher"` → Helps identify via role

## What Requires Careful Prompting

### Indirect Clues Need Explicit Reasoning

When someone says "Hamel and I went through the prompt", the model sometimes gets confused about who is speaking.

**Problem:** The model may incorrectly reason that SPEAKER_01 is Hamel.

**Solution:** Provide explicit step-by-step reasoning:

```python
prompt = f"""Two instructors are in this video. From the screenshots, I can see their names are displayed.

Transcript:
{transcript_excerpt}

KEY OBSERVATION: In the transcript, SPEAKER_01 says "if Hamel and I went through the prompt"

When someone says "Hamel and I", they are referring to Hamel as another person.
Therefore, the person saying this IS NOT Hamel - they are someone else talking ABOUT Hamel.

So:
- SPEAKER_01 says "Hamel and I" → SPEAKER_01 is NOT Hamel
- The two people are Hamel and Shreya
- If SPEAKER_01 is not Hamel, then SPEAKER_01 must be Shreya
- Therefore SPEAKER_00 must be Hamel

Confirm by looking at the screenshots for name labels, then provide:
SPEAKER_00 = [name]
SPEAKER_01 = [name]"""
```

## What Doesn't Work Well

### 1. Single-Frame Active Speaker Detection (60% accuracy)

Asking "who is speaking right now?" from a single frame is unreliable:
- Visual cues (mouth open, speaking indicators) are subtle
- Compressed video frames lose detail
- Platform-specific indicators (highlighted borders) aren't always present

### 2. Transcript Context Without Guidance

Adding transcript text without explicit reasoning instructions doesn't help much. The model needs guidance on HOW to use the clues.

## Recommended Algorithm for Muesli

### Phase 1: Extract Names (High Confidence)

```python
def extract_names_from_screenshots(screenshots: list[Path]) -> set[str]:
    """Extract all unique participant names from screenshots."""

    all_names = set()

    prompt = """List all participant names visible in this screenshot.
Just the names, one per line. Nothing else."""

    for screenshot in screenshots:
        result = analyze_image(screenshot, prompt)
        for line in result.strip().split('\n'):
            name = line.strip().strip('-').strip('*').strip()
            if name and name.lower() not in ('none', 'unknown', 'n/a'):
                all_names.add(name)

    return all_names
```

### Phase 2: Find Transcript Clues

Look for patterns in transcript:

```python
DIRECT_ADDRESS_PATTERNS = [
    r"this is (?:that,? )?(\w+)",        # "this is Johnny" or "this is that, Johnny"
    r"(?:hi|hello),? I'm (\w+)",          # "Hi, I'm Hamel"
    r"thanks,? (\w+)",                     # "Thanks, Jeremy"
    r"(\w+),? (?:you want to|can you)",   # "Jeremy, you want to..."
]

INDIRECT_PATTERNS = [
    r"(\w+) and I",                        # "Hamel and I" - speaker is NOT this person
    r"as (\w+) (?:said|mentioned)",        # "as Hamel said" - speaker is NOT this person
]
```

### Phase 3: Build Speaker Mapping

```python
def identify_speakers(
    screenshots: list[Path],
    transcript: str,
    speaker_ids: list[str]
) -> dict[str, str]:
    """Map speaker IDs to names using screenshots + transcript."""

    # Extract names from screenshots
    visible_names = extract_names_from_screenshots(screenshots)

    # Extract first ~50 lines of transcript
    lines = transcript.strip().split('\n')[:50]
    transcript_excerpt = '\n'.join(lines)

    # Build prompt with explicit reasoning guidance
    prompt = f"""I'm sending you screenshots from a video recording.

Visible participant names from screenshots: {', '.join(visible_names)}

Transcript excerpt:
{transcript_excerpt}

Your task: Map each SPEAKER_XX to their real name.

REASONING GUIDE:
- If someone says "X and I did something" → the speaker is NOT X
- If someone says "Hi, I'm X" → the speaker IS X
- If someone says "Thanks, X" → they're talking TO X
- Look at which names appear in the screenshots

Provide your mapping:
{chr(10).join(f'{sid} = [name]' for sid in speaker_ids)}"""

    result = analyze_multiple_images(screenshots, prompt)

    # Parse result
    mapping = {}
    for speaker_id in speaker_ids:
        pattern = rf'{speaker_id}\s*=\s*(.+?)(?:\n|$)'
        match = re.search(pattern, result, re.IGNORECASE)
        if match:
            mapping[speaker_id] = match.group(1).strip().strip('[]')

    return mapping
```

### Phase 4: User Confirmation

For uncertain mappings, present to user for confirmation:

```swift
// In MeetingViewer, show a confirmation dialog
struct SpeakerMappingView: View {
    let proposedMapping: [String: String]
    let onConfirm: ([String: String]) -> Void

    var body: some View {
        VStack {
            Text("Confirm Speaker Identification")

            ForEach(proposedMapping.sorted(by: { $0.key < $1.key }), id: \.key) { speaker, name in
                HStack {
                    Text(speaker)
                    TextField("Name", text: binding(for: speaker))
                }
            }

            Button("Confirm") {
                onConfirm(editedMapping)
            }
        }
    }
}
```

## Handling Different Content Types

The model correctly identifies content type and adjusts:

| Content Type | Name Source |
|--------------|-------------|
| Video call (Zoom/Teams/Meet) | Participant tile labels |
| YouTube video | Channel name, video title |
| Presentation | Presenter name on slides |
| Screen share | Names in visible windows |

## OCR Variations

The model may return slightly different spellings:
- "Johnno" vs "JohnO" vs "Jono" vs "John O"
- "Hamel Hussain" vs "Hamel Husain"

**Solution:** Fuzzy matching in evaluation:

```python
def names_match(predicted: str, actual: str) -> bool:
    pred_lower = predicted.lower().replace(" ", "")
    actual_lower = actual.lower().replace(" ", "")
    actual_first = actual.split()[0].lower()

    return (
        actual_lower in pred_lower or
        pred_lower in actual_lower or
        actual_first in pred_lower or
        # Handle Johnno/Jono/John variations
        (actual_first == "johnno" and ("jono" in pred_lower or "john" in pred_lower))
    )
```

## Performance Notes

- Model: `gemma3:27b` (17GB, Q4_K_M quantization)
- Response time: ~5-15 seconds per request (depending on image count)
- Memory: Requires ~20GB RAM when loaded

## Files Created During Testing

Test scripts saved in `/tmp/`:
- `test_ollama_vision.py` - Basic single-image test
- `test_names_only.py` - Name extraction test
- `test_active_speaker.py` - Active speaker detection test
- `test_with_transcript.py` - Transcript context test
- `speaker_id_framework.py` - Comprehensive test framework
- `comprehensive_test.py` - Batch testing across courses

## Next Steps for Implementation

1. **Add "Identify Speakers" button** to MeetingViewer
2. **Extract frames** from meeting recording at key timestamps
3. **Call local Ollama** with screenshots + transcript
4. **Show confirmation dialog** with proposed mappings
5. **Update transcript** with real names
6. **Save mapping** to meeting metadata for future reference

## Key Takeaways

1. **Name extraction is reliable** - The model consistently reads visible name labels
2. **Context clues help** - Transcript patterns improve accuracy
3. **Explicit reasoning is sometimes needed** - For indirect clues like "X and I"
4. **Aggregate approach wins** - Multiple screenshots + transcript > single frame
5. **Local model works well** - No API costs, full privacy, good accuracy
