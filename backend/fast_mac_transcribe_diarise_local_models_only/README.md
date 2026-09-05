# Fast Mac Transcribe + Diarise (Local Models Only)

Blazing fast offline transcription + speaker diarisation for Apple Silicon Macs. Processes 69 minutes of audio in ~4 seconds for diarisation.

## Features

- **ASR**: NVIDIA Parakeet via [parakeet-mlx](https://github.com/senstella/parakeet-mlx) (MLX-accelerated)
- **Diarisation**: [Senko](https://github.com/narcotic-sh/senko) using pyannote + CAM++ (CoreML, runs on Neural Engine)
- **Output**: Speaker-labelled transcripts in TXT, JSON, SRT, and RTTM formats
- **Local inference** with model assets prepared before recording
- **Offline runtime policy**: no automatic model downloads; Python networking and Hub requests are disabled during inference

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- Python 3.12.13 for reproducible installation (the library metadata permits older versions, which are not this release qualification target)
- ffmpeg (`brew install ffmpeg`)

### Optional (for Claude Code skill integration)

- **ffmpeg** - Also used to extract video frames for speaker identification
- **yt-dlp** (`brew install yt-dlp`) - Required for transcribing YouTube URLs

## Installation

Use uv **0.11.3** and Python **3.12.13** for the qualified dependency set. From this repository's backend directory:

```bash
uv sync --locked --python 3.12.13
```

This is an explicit online dependency preparation step. The lock pins package versions and Senko's source commit. Prepare model assets separately using the exact-revision command below before recording. Runtime commands must not resolve or install dependencies:

```bash
.venv/bin/python -m diarise_transcribe --in audio.mp4 --out transcript.txt
```

For developer/CI verification, use `uv sync --locked --extra dev --python 3.12.13`. The root `scripts/verify.sh` creates its own fresh environment, checks the lock remains unchanged, runs the backend and Swift tests, compiles Release and records runtime/build provenance. It requires an Apple Silicon Mac with Xcode 26.6 and uv 0.11.3. It does not replace or modify the app's selected runtime.

## Usage

### With UV (no venv activation needed)

```bash
uv run --no-sync diarise-transcribe --in audio.mp4 --out transcript.txt
```

### With the prepared environment

```bash
source .venv/bin/activate
diarise-transcribe --in audio.mp4 --out transcript.txt

# All output formats
python -m diarise_transcribe --in recording.mp4 \
    --out transcript.txt \
    --out-json transcript.json \
    --out-srt subtitles.srt \
    --out-rttm diarisation.rttm

# Verbose output to see progress
python -m diarise_transcribe --in audio.mp4 --out transcript.txt --verbose
```


## Muesli Backend (framed stdin)

The app owns source PCM and a committed-byte manifest independently of inference. It launches the adapter with `--source-recording`; Python reads verified source prefixes and never deletes or overwrites them. Framed stdin carries controls in this mode and stdout carries JSONL events. The legacy framed-PCM adapter remains available for compatibility:
Run the adapter like this:

```bash
uv run --no-sync muesli-backend --output-dir /tmp/muesli --emit-meters
```

By default it transcribes the system stream. Use `--transcribe-stream mic` to target mic audio.
Live partial/segment updates run every ~15s; tune with `--live-interval` or disable with `--no-live`.
Captured audio is aligned by PTS and written to `system.wav`/`mic.wav` plus raw `system.pcm`/`mic.pcm`.
Use `--keep-wav` or `--keep-pcm` to retain capture files.

## CLI Options

| Option | Description |
|--------|-------------|
| `--in`, `-i` | Input audio/video file (any format ffmpeg supports) |
| `--out`, `-o` | Output plain text file with speaker labels |
| `--out-json` | Output JSON file with words, segments, and turns |
| `--out-srt` | Output SRT subtitle file with speaker labels |
| `--out-rttm` | Output RTTM file (diarisation segments only) |
| `--diar-backend` | `senko` (only supported backend; Sortformer was retired) |
| `--asr-model` | ASR model ID (default: mlx-community/parakeet-tdt-0.6b-v3) |
| `--language` | Language code for ASR (auto-detected if not specified) |
| `--num-speakers` | Filter output to top N speakers by activity |
| `--gap-threshold` | Gap threshold (seconds) for turn splitting (default: 0.8) |
| `--verbose`, `-v` | Verbose output |

## Output Formats

### Plain Text (`--out`)
```
[00:00.12 - 00:03.45] SPEAKER_01: Hello, how are you today?
[00:03.67 - 00:06.89] SPEAKER_02: I'm doing great, thanks for asking.
```

### JSON (`--out-json`)
```json
{
  "turns": [
    {
      "speaker": "SPEAKER_01",
      "start": 0.12,
      "end": 3.45,
      "text": "Hello, how are you today?",
      "words": [...]
    }
  ],
  "segments": [...]
}
```

### SRT (`--out-srt`)
```
1
00:00:00,120 --> 00:00:03,450
[SPEAKER_01] Hello, how are you today?

2
00:00:03,670 --> 00:00:06,890
[SPEAKER_02] I'm doing great, thanks for asking.
```

## How It Works

1. **Audio Normalisation**: Converts input to 16kHz mono WAV using ffmpeg
2. **ASR**: Parakeet-MLX transcribes audio with word-level timestamps
3. **Diarisation**: Senko identifies speakers using pyannote VAD + CAM++ embeddings (CoreML)
4. **Merge**: Words are assigned to speakers based on timestamp overlap
5. **Output**: Formatted as requested (TXT/JSON/SRT/RTTM)

## Performance

On Apple Silicon (tested on M-series Macs):
- **Diarisation**: ~4 seconds for 69 minutes of audio
- **Transcription**: Roughly real-time (depends on model)

## Troubleshooting

### ffmpeg not found
```bash
brew install ffmpeg
```

### Missing model assets
Recording never downloads missing models. Use the explicit preparation command below before recording; it saves the exact model selection used by both the app and reprocessing. An incomplete installation reports inference unavailable while the app preserves source audio.

### CoreML errors
Ensure you're on macOS with Apple Silicon. Intel Macs are not supported.

## License

MIT


## Local asset readiness

Recording and reprocessing now resolve model files locally and fail explicitly if required assets are absent. They do not download during a recording. Verify the selected Python environment with:

```bash
PYTHONPATH=src .venv/bin/python -m diarise_transcribe.local_assets --diarisation --hashes
```

Preparing missing ASR assets is a separate online operation requiring an exact upstream model commit:

```bash
.venv/bin/python scripts/prepare-local-models.py --allow-download --revision EXACT_40_CHARACTER_MODEL_COMMIT
```

Keep the returned model directory and generated file hashes with a release. The environment must also contain Senko's native libraries and CoreML assets. The default runtime blocks Python DNS/IP sockets and Hub requests; local Unix IPC remains available. These controls do not sandbox arbitrary native extensions. Whole-process network isolation and signed-build qualification remain explicit release gates in `engineer-notes/production-audit-2026-09-05/offline-runtime.md` at the repository root. The external Claude Merge workflow has a separate network and permission boundary.
