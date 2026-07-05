"""
Batch reprocessing command for completed meetings.
Re-runs transcription + diarization on existing audio files.
"""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path
from typing import List, Optional

from .audio import normalise_audio, is_wav_16k_mono, check_ffmpeg, get_audio_duration, slice_wav_to_temp
from .asr import ASRModel, DEFAULT_MODEL, TranscriptResult, Word
from .constants import DEFAULT_GAP_THRESHOLD_SECONDS, DEFAULT_SPEAKER_TOLERANCE_SECONDS
from .diarisation import DiarSegment, SortformerDiarizer
from .merge import merge_transcript_with_diarisation
from .recovery import (
    cluster_recovery_windows,
    filter_words_in_window,
    find_wordless_segments,
    offset_words,
    splice_words,
)
from .senko_diarisation import SenkoDiarizer


STREAM_FILES = {
    "system": "system.wav",
    "mic": "mic.wav",
}


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def emit_status(stage: str, stream: Optional[str] = None, **extra) -> None:
    payload = {"type": "status", "stage": stage}
    if stream:
        payload["stream"] = stream
    payload.update(extra)
    emit(payload)


def format_exception_message(error: Exception) -> str:
    detail = str(error).strip()
    if detail:
        return f"{type(error).__name__}: {detail}"
    return type(error).__name__


def _discover_session_audio_dirs(meeting_dir: Path, verbose: bool) -> list[Path]:
    def log(msg: str) -> None:
        if verbose:
            print(msg, file=sys.stderr)

    session_dirs: list[Path] = []
    seen: set[str] = set()

    metadata_path = meeting_dir / "meeting.json"
    if metadata_path.exists():
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except Exception as error:
            log(f"Warning: failed to parse meeting.json ({format_exception_message(error)})")
        else:
            raw_sessions = metadata.get("sessions")
            if isinstance(raw_sessions, list):
                ordered_sessions: list[tuple[tuple[int, int, int], str]] = []
                for idx, session in enumerate(raw_sessions):
                    if not isinstance(session, dict):
                        continue
                    folder = session.get("audio_folder")
                    if not isinstance(folder, str):
                        continue
                    folder = folder.strip()
                    if not folder:
                        continue
                    session_id = session.get("session_id")
                    if isinstance(session_id, int):
                        sort_key = (0, session_id, idx)
                    else:
                        sort_key = (1, idx, idx)
                    ordered_sessions.append((sort_key, folder))

                for _, folder in sorted(ordered_sessions, key=lambda item: item[0]):
                    path = meeting_dir / folder
                    resolved = str(path.resolve())
                    if resolved in seen:
                        continue
                    seen.add(resolved)
                    if not path.exists() or not path.is_dir():
                        log(f"Warning: session audio folder missing: {path}")
                        continue
                    session_dirs.append(path)

    if session_dirs:
        return session_dirs

    fallback_dirs: list[Path] = []
    default_audio = meeting_dir / "audio"
    if default_audio.exists() and default_audio.is_dir():
        fallback_dirs.append(default_audio)
        seen.add(str(default_audio.resolve()))

    try:
        entries = sorted(meeting_dir.iterdir(), key=lambda p: p.name)
    except FileNotFoundError:
        entries = []

    for entry in entries:
        if not entry.is_dir():
            continue
        if not entry.name.lower().startswith("audio"):
            continue
        resolved = str(entry.resolve())
        if resolved in seen:
            continue
        seen.add(resolved)
        fallback_dirs.append(entry)

    return fallback_dirs


def _run_recovery_pass(
    asr: ASRModel,
    wav_path: str,
    transcript: TranscriptResult,
    segments: List[DiarSegment],
    language: Optional[str],
    file_duration: float,
    log,
    stream_name: str,
) -> tuple[TranscriptResult, int]:
    """
    Detect diarised segments the main ASR pass produced little or no text
    for, re-run ASR on just those spans (reusing `asr`'s cached model), and
    splice any recovered words back into the transcript.

    Runs a single recovery round: if a window still comes back empty, that
    gap is logged and left as-is rather than retried, so we can't loop on a
    span the model genuinely can't transcribe.
    """
    wordless = find_wordless_segments(segments, transcript.words)
    if not wordless:
        log("Recovery pass: no wordless segments detected.")
        emit_status("recovering", stream_name, windows=0)
        return transcript, 0

    windows = cluster_recovery_windows(wordless, file_duration=file_duration)
    window_spans = ", ".join(f"[{w.start:.2f}-{w.end:.2f}]" for w in windows)
    log(
        f"Recovery pass: {len(wordless)} wordless segment(s) clustered into "
        f"{len(windows)} window(s): {window_spans}"
    )
    emit_status("recovering", stream_name, windows=len(windows), spans=window_spans)

    recovered_words: List[Word] = []
    for window in windows:
        slice_path = slice_wav_to_temp(wav_path, window.start, window.end)
        try:
            slice_transcript = asr.transcribe(slice_path, language=language)
        finally:
            Path(slice_path).unlink(missing_ok=True)

        shifted = offset_words(slice_transcript.words, window.start)
        kept = filter_words_in_window(shifted, window)
        if kept:
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                f"recovered {len(kept)} word(s)"
            )
        else:
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                "still empty after recovery attempt"
            )
        recovered_words.extend(kept)

    if not recovered_words:
        return transcript, 0

    augmented_words = splice_words(transcript.words, recovered_words)
    augmented_transcript = TranscriptResult(text=transcript.text, words=augmented_words)
    return augmented_transcript, len(recovered_words)


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
    recovery: bool = True,
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

        if recovery:
            file_duration = get_audio_duration(temp_wav)
            augmented_transcript, recovered_count = _run_recovery_pass(
                asr,
                temp_wav,
                transcript,
                segments,
                language,
                file_duration,
                log,
                stream_name,
            )
            if recovered_count:
                log(f"Recovery pass added {recovered_count} word(s); re-merging...")
                transcript = augmented_transcript
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
        help="Path to meeting directory containing audio session folders",
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
        default=DEFAULT_GAP_THRESHOLD_SECONDS,
        help=f"Gap threshold in seconds (default: {DEFAULT_GAP_THRESHOLD_SECONDS})",
    )
    parser.add_argument(
        "--speaker-tolerance",
        type=float,
        default=DEFAULT_SPEAKER_TOLERANCE_SECONDS,
        help=f"Tolerance in seconds for word-speaker assignment (default: {DEFAULT_SPEAKER_TOLERANCE_SECONDS})",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Verbose output (stderr)",
    )
    parser.add_argument(
        "--no-recovery",
        action="store_true",
        help="Disable the ASR recovery pass for voiced-but-wordless diar segments",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        meeting_dir = Path(args.meeting_dir).expanduser().resolve()
        session_audio_dirs = _discover_session_audio_dirs(meeting_dir, verbose=args.verbose)
        if not session_audio_dirs:
            emit({"type": "error", "message": "audio folder not found"})
            print(f"No audio folders found in: {meeting_dir}", file=sys.stderr)
            return 1

        streams = ["system", "mic"] if args.stream == "both" else [args.stream]

        emit_status("preparing")

        all_turns = []
        all_speakers = set()
        running_offset = 0.0

        for session_audio_dir in session_audio_dirs:
            session_duration = 0.0
            for stream in streams:
                filename = STREAM_FILES[stream]
                path = session_audio_dir / filename
                if not path.exists():
                    emit({"type": "error", "message": f"missing audio for {stream}"})
                    print(f"Missing audio file: {path}", file=sys.stderr)
                    return 1

                try:
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
                        recovery=not args.no_recovery,
                    )
                except Exception as error:
                    message = f"{stream} reprocess failed ({format_exception_message(error)})"
                    emit({"type": "error", "message": message})
                    print(message, file=sys.stderr)
                    traceback.print_exc(file=sys.stderr)
                    return 1

                local_max_t1 = 0.0
                for turn in result["turns"]:
                    local_max_t1 = max(local_max_t1, turn["t1"])
                    turn["t0"] += running_offset
                    turn["t1"] += running_offset

                all_turns.extend(result["turns"])
                all_speakers.update(result["speakers"])
                session_duration = max(session_duration, result["duration"], local_max_t1)

            running_offset += session_duration

        all_turns.sort(key=lambda item: (item["t0"], item["stream"], item["speaker_id"]))
        duration = max(running_offset, max((t["t1"] for t in all_turns), default=0.0))

        emit_status("complete")
        emit({
            "type": "result",
            "turns": all_turns,
            "speakers": sorted(all_speakers),
            "duration": duration,
        })
        return 0
    except Exception as error:
        message = f"batch reprocess failed ({format_exception_message(error)})"
        emit({"type": "error", "message": message})
        print(message, file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
