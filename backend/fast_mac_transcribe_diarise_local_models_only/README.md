# Fast Mac Transcribe + Diarise (Local Models Only)

Blazing fast offline transcription + speaker diarisation for Apple Silicon Macs. Processes 69 minutes of audio in ~4 seconds for diarisation.

## Features

- **ASR**: NVIDIA Parakeet via [parakeet-mlx](https://github.com/senstella/parakeet-mlx) (MLX-accelerated)
- **Diarisation**: [Senko](https://github.com/narcotic-sh/senko) using pyannote + CAM++ (CoreML, runs on Neural Engine)
- **Output**: Speaker-labelled transcripts in TXT, JSON, SRT, and RTTM formats
- **Fully offline** after initial model downloads
- **100% local** - no data leaves your machine

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- Python 3.10+
- ffmpeg (`brew install ffmpeg`)

### Optional (for Claude Code skill integration)

- **ffmpeg** - Also used to extract video frames for speaker identification
- **yt-dlp** (`brew install yt-dlp`) - Required for transcribing YouTube URLs

## Installation

### Option 1: Using UV (recommended)

```bash
# Clone the repo
git clone git@github.com:DavidFarrell/fast_mac_transcribe_diarise_local_models_only.git
cd fast_mac_transcribe_diarise_local_models_only

# Run directly with uv (handles venv automatically)
uv run diarise-transcribe --in audio.mp4 --out transcript.txt
```

### Option 2: Traditional pip

```bash
# Clone the repo
git clone git@github.com:DavidFarrell/fast_mac_transcribe_diarise_local_models_only.git
cd fast_mac_transcribe_diarise_local_models_only

# Create and activate virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install the package (includes Senko)
pip install -e .
```

## Usage

### With UV (no venv activation needed)

```bash
uv run diarise-transcribe --in audio.mp4 --out transcript.txt
```

### With pip/venv

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

Muesli streams framed PCM audio to stdin and expects JSONL events on stdout.
Run the adapter like this:

```bash
uv run muesli-backend --output-dir /tmp/muesli --emit-meters
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
| `--diar-backend` | `senko` (default, recommended) or `sortformer` |
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

### Model download issues
Models are downloaded from HuggingFace on first use. Ensure you have internet access for the initial download. After that, everything runs offline.

### CoreML errors
Ensure you're on macOS with Apple Silicon. Intel Macs are not supported.

## License

MIT
