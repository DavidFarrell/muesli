"""
Batch reprocessing command for completed meetings.
Re-runs transcription + diarization on existing audio files.
"""

from __future__ import annotations

import argparse
from contextlib import redirect_stdout
import json
import math
import tempfile
import wave
import sys
import traceback
from pathlib import Path
from typing import List, Optional
from .meeting_lease import validate_source_path, add_parser_argument, require_app_admission

# Model imports can emit diagnostics; reserve stdout for protocol events.
with redirect_stdout(sys.stderr):
    from .audio import normalise_audio, is_wav_16k_mono, check_ffmpeg, get_audio_duration, slice_wav_to_temp
    from .asr import ASRModel, DEFAULT_MODEL, TranscriptResult, Word
    from .constants import DEFAULT_GAP_THRESHOLD_SECONDS, DEFAULT_SPEAKER_TOLERANCE_SECONDS
    from .diarisation import DiarSegment
    from .merge import merge_transcript_with_diarisation
    from .recovery import (
        RecoveryWindow,
        cluster_recovery_windows,
        drop_words_in_windows,
        filter_words_in_window,
        find_wordless_segments,
        offset_words,
        splice_words,
    )
    from .senko_diarisation import SenkoDiarizer
    from .source_recording import MANIFEST_NAME, CommittedSource, committed_sources



STREAM_FILES = {
    "system": "system.wav",
    "mic": "mic.wav",
}


_protocol_stdout = None


def emit(obj: dict) -> None:
    print(json.dumps(obj), file=_protocol_stdout or sys.stdout, flush=True)


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
                        raise ValueError(f"Session audio folder missing; its media extent is unknown: {path}")
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



def _legacy_session_duration(audio_dir: Path) -> float:
    """Measure both physical source files, regardless of selected ASR streams.

    Word/turn ends cannot establish source duration: quiet tails and an omitted
    system stream still occupy meeting time. No file mtime or wall-clock gap is
    a media duration.
    """
    durations = []
    for filename in STREAM_FILES.values():
        path = audio_dir / filename
        if not path.exists():
            continue
        duration = float(get_audio_duration(str(path)))
        if not math.isfinite(duration) or duration < 0:
            raise ValueError(f"Invalid audio duration: {path}")
        durations.append(duration)
    if not durations:
        raise ValueError(f"No readable source audio in {audio_dir}")
    return max(durations)


def _committed_wav(source: CommittedSource, destination: Path) -> Path:
    """Export a frozen committed prefix to an owned temporary file only.

    Compatibility WAVs can be absent, stale, or include an uncommitted tail.
    Neither those files nor the authoritative PCM/manifest are modified.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    remaining = source.size_bytes
    with source.path.with_suffix(".pcm").open("rb") as pcm, wave.open(str(destination), "wb") as wav:
        wav.setnchannels(source.channels)
        wav.setsampwidth(2)
        wav.setframerate(source.sample_rate)
        while remaining:
            chunk = pcm.read(min(remaining, 64 * 1024))
            if not chunk:
                raise ValueError(f"Truncated committed source: {source.path.with_suffix('.pcm')}")
            wav.writeframesraw(chunk)
            remaining -= len(chunk)
    return destination


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

    Recovery is best-effort: each window is isolated in its own try/except,
    so a slicing or ASR failure on one window (e.g. a zero-frame slice from
    a clamped-empty range) is logged and skipped rather than losing the
    other windows' recoveries or the already-good main transcript.
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
    windows_with_recovered_words: List[RecoveryWindow] = []
    for window in windows:
        try:
            slice_path = slice_wav_to_temp(wav_path, window.start, window.end)
            try:
                slice_transcript = asr.transcribe(slice_path, language=language)
            finally:
                Path(slice_path).unlink(missing_ok=True)

            shifted = offset_words(slice_transcript.words, window.start)
            kept = filter_words_in_window(shifted, window)
        except Exception as error:
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                f"failed ({format_exception_message(error)}); skipping this window"
            )
            continue

        if kept:
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                f"recovered {len(kept)} word(s)"
            )
            windows_with_recovered_words.append(window)
        else:
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                "still empty after recovery attempt"
            )
        recovered_words.extend(kept)

    if not recovered_words:
        return transcript, 0

    # Drop original words inside windows that actually recovered replacement
    # words, so partial-coverage segments don't end up with their few
    # original words duplicated alongside the recovered ones. Windows that
    # recovered nothing are excluded, so their originals are untouched.
    surviving_words = drop_words_in_windows(transcript.words, windows_with_recovered_words)
    augmented_words = splice_words(surviving_words, recovered_words)
    augmented_transcript = TranscriptResult(text=transcript.text, words=augmented_words)
    return augmented_transcript, len(recovered_words)


def reprocess_stream(
    audio_path: Path,
    stream_name: str,
    diar_backend: str,
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
    owned_normalization = None

    if is_wav_16k_mono(str(audio_path)):
        temp_wav = str(audio_path)
    else:
        if not check_ffmpeg():
            raise RuntimeError("ffmpeg not found")
        log("Normalizing audio...")
        owned_normalization = tempfile.TemporaryDirectory(prefix="muesli-normalized-")
        temp_wav = str(Path(owned_normalization.name) / "normalized.wav")
        try:
            normalise_audio(str(audio_path), output_path=temp_wav)
        except Exception:
            owned_normalization.cleanup()
            raise

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
            raise ValueError(
                f"Unknown diar_backend {diar_backend!r}: only 'senko' is supported "
                "(the Sortformer backend was retired)."
            )

        emit_status("merging", stream_name)
        merged = merge_transcript_with_diarisation(
            transcript,
            segments,
            gap_threshold=gap_threshold,
            speaker_tolerance=speaker_tolerance,
        )

        if recovery:
            try:
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
            except Exception as error:
                # Recovery is best-effort on top of an already-good merged
                # result - a bug here must never fail the whole stream.
                log(f"Recovery pass failed entirely ({format_exception_message(error)}); keeping main transcript")
                augmented_transcript, recovered_count = transcript, 0
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
        if owned_normalization is not None:
            owned_normalization.cleanup()


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
        choices=["senko"],
        default="senko",
        help="Diarization backend (default: senko; the Sortformer backend was retired)",
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
    add_parser_argument(parser)
    return parser


def _main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    require_app_admission(args)

    try:
        meeting_dir = validate_source_path(Path(args.meeting_dir), meeting_root=True)
        session_audio_dirs = _discover_session_audio_dirs(meeting_dir, verbose=args.verbose)
        if not session_audio_dirs:
            emit({"type": "error", "message": "audio folder not found"})
            print(f"No audio folders found in: {meeting_dir}", file=sys.stderr)
            return 1

        streams = ["system", "mic"] if args.stream == "both" else [args.stream]

        emit_status("preparing")
        from .runtime_identity import prepare_observation
        runtime_identity, args.asr_model = prepare_observation(
            args.asr_model, diarisation=args.diar_backend == "senko")

        all_turns = []
        all_speakers = set()
        source_inventory = []
        running_offset = 0.0

        # This invocation owns only its temporary exports. Default reprocess
        # never overwrites or deletes source PCM, manifests, or existing WAVs.
        with tempfile.TemporaryDirectory(prefix="muesli-reprocess-") as temporary:
            for session_index, session_audio_dir in enumerate(session_audio_dirs):
                sources = None
                if (session_audio_dir / MANIFEST_NAME).exists():
                    sources = committed_sources(session_audio_dir)
                    reference = sources["mic"]
                    session_offset = reference.timeline_offset_us / 1_000_000
                    session_duration = max(source.size_bytes / 32_000 for source in sources.values())
                else:
                    session_offset = running_offset
                    session_duration = _legacy_session_duration(session_audio_dir)

                source_identity = sources["mic"].session_id if sources is not None else str(session_audio_dir.relative_to(meeting_dir))
                source_inventory.append({
                    "source_session_id": source_identity,
                    "audio_folder": str(session_audio_dir.relative_to(meeting_dir)),
                    "timeline_offset_seconds": session_offset,
                    "duration_seconds": session_duration,
                    "storage_kind": "committed_pcm" if sources is not None else "legacy_wav",
                })

                for stream in streams:
                    if sources is not None:
                        source = sources[stream]
                        # Empty committed streams are legitimate (e.g. system
                        # silence). Do not ask ASR to decode a zero-frame WAV.
                        if source.size_bytes == 0:
                            continue
                        path = _committed_wav(
                            source, Path(temporary) / str(session_index) / STREAM_FILES[stream])
                    else:
                        path = session_audio_dir / STREAM_FILES[stream]
                        if not path.exists():
                            emit({"type": "error", "message": f"missing audio for {stream}"})
                            print(f"Missing audio file: {path}", file=sys.stderr)
                            return 1

                    try:
                        result = reprocess_stream(
                            path,
                            stream,
                            diar_backend=args.diar_backend,
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

                    for turn in result["turns"]:
                        turn["source_session_id"] = source_identity
                        turn["t0"] += session_offset
                        turn["t1"] += session_offset
                    all_turns.extend(result["turns"])
                    all_speakers.update(result["speakers"])

                # A manifest's explicit offset is authoritative even when
                # sessions contain pauses/gaps or only one stream is selected.
                running_offset = max(running_offset, session_offset + session_duration)

        all_turns.sort(key=lambda item: (item["t0"], item["stream"], item["speaker_id"]))
        duration = running_offset

        emit_status("complete")
        emit({
            "type": "result",
            "turns": all_turns,
            "speakers": sorted(all_speakers),
            "duration": duration,
            "sources": source_inventory,
            "runtime_identity": runtime_identity,
        })
        return 0
    except Exception as error:
        message = f"batch reprocess failed ({format_exception_message(error)})"
        emit({"type": "error", "message": message})
        print(message, file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 1


def main() -> int:
    global _protocol_stdout
    previous = _protocol_stdout
    _protocol_stdout = sys.stdout
    try:
        # Third-party inference prints belong to stderr, including nested
        # calls. emit() retains the original stdout for JSONL result delivery.
        with redirect_stdout(sys.stderr):
            return _main()
    finally:
        _protocol_stdout = previous


if __name__ == "__main__":
    raise SystemExit(main())
