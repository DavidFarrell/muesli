"""
Batch reprocessing command for completed meetings.
Re-runs transcription + diarization on existing audio files.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional

from .audio import normalise_audio, is_wav_16k_mono, check_ffmpeg
from .asr import ASRModel, DEFAULT_MODEL
from .diarisation import SortformerDiarizer
from .merge import merge_transcript_with_diarisation
from .senko_diarisation import SenkoDiarizer


STREAM_FILES = {
    "system": "system.wav",
    "mic": "mic.wav",
}


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def emit_status(stage: str, stream: Optional[str] = None) -> None:
    payload = {"type": "status", "stage": stage}
    if stream:
        payload["stream"] = stream
    emit(payload)


def reprocess_stream(
    audio_path: Path,
    stream_name: str,
    diar_backend: str,
    diar_model: str,
    asr_model: str,
    language: Optional[str],
    gap_threshold: float,
    speaker_tolerance: float,
    verbose: bool,
) -> dict:
    def log(msg: str) -> None:
        if verbose:
            print(msg, file=sys.stderr)

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
        emit_status("transcribing", stream_name)
        log(f"Running ASR with {asr_model}...")
        asr = ASRModel(asr_model)
        transcript = asr.transcribe(temp_wav, language=language)

        emit_status("diarizing", stream_name)
        if diar_backend == "senko":
            log("Running Senko diarization (batch)...")
            diarizer = SenkoDiarizer(quiet=not verbose)
            segments = diarizer.diarise(temp_wav)
        else:
            log(f"Running Sortformer diarization ({diar_model})...")
            diarizer = SortformerDiarizer(model_name=diar_model)
            segments = diarizer.diarise(temp_wav)

        emit_status("merging", stream_name)
        merged = merge_transcript_with_diarisation(
            transcript,
            segments,
            gap_threshold=gap_threshold,
            speaker_tolerance=speaker_tolerance,
        )

        turns = []
        speakers = set()
        for turn in merged.turns:
            speaker_id = f"{stream_name}:{turn.speaker}"
            speakers.add(speaker_id)
            turns.append({
                "speaker_id": speaker_id,
                "stream": stream_name,
                "t0": turn.start,
                "t1": turn.end,
                "text": turn.text,
            })

        duration = 0.0
        if transcript.words:
            duration = max(w.end for w in transcript.words)
        elif merged.turns:
            duration = max(t.end for t in merged.turns)

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


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Reprocess meeting audio with batch diarization",
    )
    parser.add_argument(
        "meeting_dir",
        help="Path to meeting directory containing audio/ folder",
    )
    parser.add_argument(
        "--stream",
        choices=["system", "mic", "both"],
        default="system",
        help="Which audio stream(s) to process (default: system)",
    )
    parser.add_argument(
        "--diar-backend",
        choices=["senko", "sortformer"],
        default="senko",
        help="Diarization backend (default: senko)",
    )
    parser.add_argument(
        "--diar-model",
        default="default",
        help="Sortformer diarization model variant (default: default)",
    )
    parser.add_argument(
        "--asr-model",
        default=DEFAULT_MODEL,
        help=f"ASR model (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--language",
        default=None,
        help="Language code (default: auto)",
    )
    parser.add_argument(
        "--gap-threshold",
        type=float,
        default=0.8,
        help="Gap threshold in seconds (default: 0.8)",
    )
    parser.add_argument(
        "--speaker-tolerance",
        type=float,
        default=0.25,
        help="Tolerance in seconds for word-speaker assignment (default: 0.25)",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Verbose output (stderr)",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    meeting_dir = Path(args.meeting_dir).expanduser().resolve()
    audio_dir = meeting_dir / "audio"
    if not audio_dir.exists():
        emit({"type": "error", "message": "audio folder not found"})
        print(f"Audio folder not found: {audio_dir}", file=sys.stderr)
        return 1

    streams = ["system", "mic"] if args.stream == "both" else [args.stream]
    audio_paths = {}
    for stream in streams:
        filename = STREAM_FILES[stream]
        path = audio_dir / filename
        if not path.exists():
            emit({"type": "error", "message": f"missing audio for {stream}"})
            print(f"Missing audio file: {path}", file=sys.stderr)
            return 1
        audio_paths[stream] = path

    emit_status("preparing")

    all_turns = []
    all_speakers = set()
    durations = []

    for stream, path in audio_paths.items():
        result = reprocess_stream(
            path,
            stream,
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
        durations.append(result["duration"])

    all_turns.sort(key=lambda item: (item["t0"], item["stream"], item["speaker_id"]))
    duration = max(durations + [max((t["t1"] for t in all_turns), default=0.0)])

    emit_status("complete")
    emit({
        "type": "result",
        "turns": all_turns,
        "speakers": sorted(all_speakers),
        "duration": duration,
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
