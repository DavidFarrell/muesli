"""
Batch reprocessing command for completed meetings.
Re-runs transcription + diarization on existing audio files.
"""

from __future__ import annotations

import argparse
import hashlib
from contextlib import redirect_stdout
import json
import math
import os
import tempfile
import wave
import sys
import traceback
from pathlib import Path
from typing import List, Optional
from .processing_evidence import (
    ProcessingEntry, ProcessingEvidence, RecoveryEvidence, SnapshotBudget,
    SourceDirectory, OwnedFile, ModelInput, InputChanged, bounded_count, legacy_wav_details, MAX_SESSIONS,
    MAX_METADATA_BYTES, MAX_FILE_BYTES,
)
from .wav_derivation import ProducedWAV, canonical_pcm_header
from .meeting_lease import validate_source_path, add_parser_argument, require_app_admission

# Model imports can emit diagnostics; reserve stdout for protocol events.
with redirect_stdout(sys.stderr):
    from .audio import normalise_audio, check_ffmpeg, get_audio_duration, slice_wav_to_temp
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


MAX_PROTOCOL_BYTES = 4 * 1024 * 1024
_protocol_stdout = None


def _encoded_event(obj: dict) -> str:
    encoded = json.dumps(obj, allow_nan=False, ensure_ascii=False)
    if len(encoded.encode("utf-8")) + 1 > MAX_PROTOCOL_BYTES:
        raise ValueError("Batch result exceeds the supported 4 MiB protocol record size")
    return encoded


def emit(obj: dict) -> None:
    print(_encoded_event(obj), file=_protocol_stdout or sys.stdout, flush=True)


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
    # Only a truly absent index permits legacy discovery. A damaged index cannot
    # certify that an omitted source was empty or that the inventory is complete.
    with SourceDirectory(meeting_dir) as directory:
        raw = directory.read_optional("meeting.json", MAX_METADATA_BYTES)
        folders = []
        if raw is not None:
            metadata = json.loads(raw)
            if not isinstance(metadata, dict):
                raise ValueError("Invalid meeting metadata")
            sessions = metadata.get("sessions")
            if sessions is not None:
                if not isinstance(sessions, list) or len(sessions) > MAX_SESSIONS:
                    raise ValueError("Invalid or excessive source sessions")
                ordered = []
                for index, session in enumerate(sessions):
                    if not isinstance(session, dict) or not isinstance(session.get("audio_folder"), str):
                        raise ValueError("Invalid indexed source session")
                    folder = session["audio_folder"]
                    directory.parts(folder)
                    session_id = session.get("session_id")
                    order = (0, session_id, index) if type(session_id) is int else (1, index, index)
                    ordered.append((order, folder))
                folders = [folder for _, folder in sorted(ordered)]
        if not folders:
            folders = sorted(name for name in directory.names() if name.lower().startswith("audio"))
        if len(folders) > MAX_SESSIONS:
            raise ValueError("Source session count exceeds the supported limit")
        seen = set()
        result = []
        for folder in folders:
            try:
                fd = directory.open(folder, directory=True)
            except FileNotFoundError as error:
                raise ValueError("Session audio folder missing; its media extent is unknown") from error
            try:
                info = os.fstat(fd)
                identity = (info.st_dev, info.st_ino)
                if identity in seen:
                    raise ValueError("Duplicate source directory identity")
                seen.add(identity)
                result.append(meeting_dir / folder)
            finally:
                os.close(fd)
        return result


def _committed_wav(source: CommittedSource, pcm: Path, destination: Path,
                   budget: SnapshotBudget, expected_pcm_sha256: str) -> tuple[Path, str]:
    """Wrap the frozen prefix and bind the generated WAV to its source digest."""
    budget.reserve_bytes(source.size_bytes + 44)
    header = canonical_pcm_header(source.size_bytes, source.sample_rate, source.channels, 2)
    pcm_digest, wav_digest = hashlib.sha256(), hashlib.sha256(header)
    with SourceDirectory(pcm.parent) as owner:
        fd = owner.open(pcm.name)
        try:
            before = os.fstat(fd)
            if before.st_size != source.size_bytes:
                raise InputChanged("Owned PCM prefix length changed")
            with wave.open(str(destination), "wb") as wav:
                wav.setnchannels(source.channels)
                wav.setsampwidth(2)
                wav.setframerate(source.sample_rate)
                remaining = source.size_bytes
                while remaining:
                    chunk = os.read(fd, min(remaining, 65536))
                    if not chunk:
                        raise InputChanged("Owned PCM prefix truncated")
                    pcm_digest.update(chunk)
                    wav_digest.update(chunk)
                    wav.writeframesraw(chunk)
                    remaining -= len(chunk)
            owner.verify(pcm.name, fd, before)
            if pcm_digest.hexdigest() != expected_pcm_sha256:
                raise InputChanged("Owned PCM prefix bytes changed")
        finally:
            os.close(fd)
    return destination, wav_digest.hexdigest()


def _normalized_pcm(path: Path) -> bool:
    try:
        with wave.open(str(path), "rb") as wav:
            return (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getcomptype()) == (16000, 1, 2, "NONE")
    except (wave.Error, EOFError):
        return False


def _run_recovery_pass(
    asr: ASRModel,
    wav_path: str,
    transcript: TranscriptResult,
    segments: List[DiarSegment],
    language: Optional[str],
    file_duration: float,
    log,
    stream_name: str,
    evidence: RecoveryEvidence,
    budget: SnapshotBudget,
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
        evidence.outcome = "not_needed"
        log("Recovery pass: no wordless segments detected.")
        emit_status("recovering", stream_name, windows=0)
        return transcript, 0

    windows = cluster_recovery_windows(wordless, file_duration=file_duration)
    evidence.planned_window_count = bounded_count(len(windows))
    for window in windows:
        if not (math.isfinite(window.start) and math.isfinite(window.end) and
                0 <= window.start < window.end <= file_duration):
            raise ValueError("Invalid recovery window")
    budget.reserve_windows(len(windows))
    evidence.outcome = "completed" if windows else "not_needed"
    window_spans = ", ".join(f"[{w.start:.2f}-{w.end:.2f}]" for w in windows)
    log(
        f"Recovery pass: {len(wordless)} wordless segment(s) clustered into "
        f"{len(windows)} window(s): {window_spans}"
    )
    emit_status("recovering", stream_name, windows=len(windows), spans=window_spans)

    recovered_words: List[Word] = []
    windows_with_recovered_words: List[RecoveryWindow] = []
    for window in windows:
        evidence.attempted_window_count += 1
        record = {"start_seconds": window.start, "end_seconds": window.end,
                  "status": "failed", "model_input": None, "asr_word_count": None,
                  "recovered_word_count": None, "failure_code": None}
        evidence.windows.append(record)
        try:
            if not (math.isfinite(window.start) and math.isfinite(window.end) and
                    0 <= window.start < window.end <= file_duration):
                raise ValueError("Invalid recovery window")
            expected_slice_bytes = (round(window.end * 16000) - round(window.start * 16000)) * 2 + 44
            if expected_slice_bytes > MAX_FILE_BYTES:
                raise ValueError("Recovery slice exceeds size limit")
            budget.reserve_bytes(expected_slice_bytes)
            produced = slice_wav_to_temp(wav_path, window.start, window.end, return_evidence=True)
            if not isinstance(produced, ProducedWAV):
                raise InputChanged("Recovery producer did not return its derivation evidence")
            slice_path = os.fspath(produced)
            try:
                expected_frames = (expected_slice_bytes - 44) // 2
                if produced.frame_count != expected_frames or produced.byte_count != expected_slice_bytes:
                    raise InputChanged("Recovery output does not match the requested source range")
                with ModelInput(Path(slice_path), expected=produced) as owned_slice:
                    record["model_input"] = owned_slice.payload()
                    if owned_slice.frame_count == 0:
                        raise ValueError("Empty recovery slice")
                    try:
                        slice_transcript = asr.transcribe(slice_path, language=language)
                    finally:
                        owned_slice.verify()
                    record["asr_word_count"] = bounded_count(len(slice_transcript.words))
            finally:
                Path(slice_path).unlink(missing_ok=True)

            shifted = offset_words(slice_transcript.words, window.start)
            kept = filter_words_in_window(shifted, window)
        except InputChanged:
            evidence.failed_window_count += 1
            evidence.outcome = "failed"
            record["failure_code"] = "InputChanged"
            # A mutated model input invalidates the result, not just recovery.
            raise
        except Exception as error:
            evidence.failed_window_count += 1
            record["failure_code"] = type(error).__name__[:64]
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                f"failed ({format_exception_message(error)}); skipping this window"
            )
            continue

        record["recovered_word_count"] = bounded_count(len(kept))
        record["status"] = "recovered" if kept else "processed_without_words"
        if kept:
            evidence.recovered_window_count += 1
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                f"recovered {len(kept)} word(s)"
            )
            windows_with_recovered_words.append(window)
        else:
            evidence.empty_window_count += 1
            log(
                f"Recovery window [{window.gap_start:.2f}-{window.gap_end:.2f}]: "
                "still empty after recovery attempt"
            )
        recovered_words.extend(kept)
        bounded_count(len(recovered_words))

    evidence.recovered_word_count = len(recovered_words)
    if evidence.failed_window_count:
        evidence.outcome = ("failed" if evidence.failed_window_count == evidence.attempted_window_count
                            else "partial_failure")
    if not recovered_words:
        return transcript, 0

    # Drop original words inside windows that actually recovered replacement
    # words, so partial-coverage segments don't end up with their few
    # original words duplicated alongside the recovered ones. Windows that
    # recovered nothing are excluded, so their originals are untouched.
    surviving_words = drop_words_in_windows(transcript.words, windows_with_recovered_words)
    augmented_words = splice_words(surviving_words, recovered_words)
    bounded_count(len(augmented_words))
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
    evidence: ProcessingEntry | None = None,
    budget: SnapshotBudget | None = None,
    expected_snapshot_sha256: str | None = None,
) -> dict:
    def log(msg: str) -> None:
        if verbose:
            print(msg, file=sys.stderr)

    evidence = evidence or ProcessingEntry(None, "direct", stream_name, "not_processed")
    budget = budget or SnapshotBudget()
    evidence.recovery = RecoveryEvidence("not_run" if recovery else "not_requested")
    # Even direct callers receive the same owned-input guarantee. A normalized
    # legacy WAV must not bypass snapshotting merely because no ffmpeg is needed.
    with tempfile.TemporaryDirectory(prefix="muesli-model-input-") as temporary:
        copied = Path(temporary) / audio_path.name
        with SourceDirectory(audio_path.parent) as source:
            snapshot = source.copy(audio_path.name, copied, budget)
            if expected_snapshot_sha256 is not None and snapshot["sha256"] != expected_snapshot_sha256:
                raise InputChanged("Owned source snapshot changed before model admission")
        with OwnedFile(copied, snapshot["sha256"]) as owned_source:
            try:
                produced = None
                if _normalized_pcm(copied):
                    temp_wav = str(copied)
                else:
                    if not check_ffmpeg():
                        raise RuntimeError("ffmpeg not found")
                    temp_wav = str(Path(temporary) / "normalized.wav")
                    if Path(temp_wav) == copied:
                        temp_wav = str(Path(temporary) / "model.wav")
                    duration = float(get_audio_duration(str(copied)))
                    if not math.isfinite(duration) or not 0 <= duration <= 86400:
                        raise ValueError("Invalid source duration for normalization")
                    # Reserve the output before ffmpeg writes it. Include ample WAV
                    # header/encoder-packet headroom, with an independent file-size gate.
                    output_limit = min(MAX_FILE_BYTES, math.ceil(duration * 32000) + 1024 * 1024)
                    budget.reserve_bytes(output_limit)
                    produced = normalise_audio(str(copied), output_path=temp_wav,
                                               max_output_bytes=output_limit, return_evidence=True)
                    if not isinstance(produced, ProducedWAV):
                        raise InputChanged("Normalization producer did not return its derivation evidence")
                owned_source.verify()
                with ModelInput(Path(temp_wav), expected=produced) as owned_input:
                    evidence.model_input = owned_input.payload()
                    return _process_owned_stream(temp_wav, stream_name, diar_backend, asr_model,
                                                 language, gap_threshold, speaker_tolerance,
                                                 verbose, recovery, evidence, budget, owned_input)

            finally:
                owned_source.verify()


def _process_owned_stream(temp_wav, stream_name, diar_backend, asr_model, language,
                          gap_threshold, speaker_tolerance, verbose, recovery,
                          evidence, budget, owned_input):
    def log(msg):
        if verbose:
            print(msg, file=sys.stderr)

    try:
        emit_status("transcribing", stream_name)
        log(f"Running ASR with {asr_model}...")
        asr = ASRModel(asr_model)
        owned_input.verify()
        try:
            transcript = asr.transcribe(temp_wav, language=language)
        finally:
            owned_input.verify()
        evidence.asr_word_count = bounded_count(len(transcript.words))

        emit_status("diarizing", stream_name)
        if diar_backend == "senko":
            log("Running Senko diarization (batch)...")
            diarizer = SenkoDiarizer(quiet=not verbose)
            owned_input.verify()
            try:
                segments = diarizer.diarise(temp_wav)
            finally:
                owned_input.verify()
            evidence.diarization_segment_count = bounded_count(len(segments))
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
                file_duration = owned_input.frame_count / 16000
                augmented_transcript, recovered_count = _run_recovery_pass(
                    asr,
                    temp_wav,
                    transcript,
                    segments,
                    language,
                    file_duration,
                    log,
                    stream_name,
                    evidence.recovery,
                    budget,
                )
            except InputChanged:
                raise
            except Exception as error:
                evidence.recovery.outcome = "failed"
                evidence.recovery.failure_code = type(error).__name__[:64]
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

        evidence.turn_count = bounded_count(len(merged.turns))
        evidence.status = "processed" if merged.turns else "processed_without_turns"
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
            "processing": evidence,
        }
    finally:
        owned_input.verify()


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

    streams = ["system", "mic"] if args.stream == "both" else [args.stream]
    processing = ProcessingEvidence(streams, not args.no_recovery)
    active = None
    try:
        meeting_dir = validate_source_path(Path(args.meeting_dir), meeting_root=True)
        session_audio_dirs = _discover_session_audio_dirs(meeting_dir, verbose=args.verbose)
        if not session_audio_dirs:
            raise ValueError("audio folder not found")
        for folder in session_audio_dirs:
            for stream in STREAM_FILES:
                processing.entries.append(ProcessingEntry(
                    None, str(folder.relative_to(meeting_dir)), stream,
                    "not_processed" if stream in streams else "not_requested",
                    recovery=RecoveryEvidence("not_run" if processing.recovery_requested else "not_requested")))

        emit_status("preparing")
        from .runtime_identity import prepare_observation
        runtime_identity, args.asr_model = prepare_observation(
            args.asr_model, diarisation=args.diar_backend == "senko")
        all_turns, all_speakers, source_inventory = [], set(), []
        running_offset = 0.0
        budget = SnapshotBudget()
        seen_source_ids = set()

        with SourceDirectory(meeting_dir) as directory, tempfile.TemporaryDirectory(prefix="muesli-reprocess-") as temporary:
            for session_index, session_audio_dir in enumerate(session_audio_dirs):
                entries = processing.entries[session_index * 2:session_index * 2 + 2]
                folder = entries[0].audio_folder
                manifest_bytes = directory.read_optional(folder + "/" + MANIFEST_NAME, 1024 * 1024)
                sources = None
                if manifest_bytes is not None:
                    try:
                        sources = committed_sources(session_audio_dir, manifest_bytes=manifest_bytes, validate_files=False)
                    except Exception:
                        for entry in entries:
                            entry.availability = "invalid"
                            if entry.stream in streams:
                                entry.status = "failed"
                                entry.failure_code = "invalid_manifest"
                        raise
                source_identity = sources["mic"].session_id if sources else folder
                if source_identity in seen_source_ids:
                    raise ValueError("Duplicate source session identity")
                seen_source_ids.add(source_identity)
                session_offset = sources["mic"].timeline_offset_us / 1_000_000 if sources else running_offset
                durations = []
                paths = {}
                snapshot_hashes = {}
                for entry in entries:
                    active = entry
                    entry.source_session_id = source_identity
                    stream = entry.stream
                    relative = folder + "/" + stream + (".pcm" if sources else ".wav")
                    copied = Path(temporary) / folder / (stream + (".pcm" if sources else ".wav"))
                    try:
                        details = directory.copy(relative, copied, budget,
                                                 committed_bytes=sources[stream].size_bytes if sources else None)
                    except FileNotFoundError:
                        entry.availability = "missing"
                        if stream in streams or sources is not None:
                            raise ValueError("Missing indexed source stream")
                        continue
                    except Exception:
                        entry.availability = "invalid"
                        raise
                    details["storage_kind"] = "committed_pcm" if sources else "legacy_wav"
                    entry.source_input = details
                    if sources:
                        source = sources[stream]
                        details.update({"manifest_sha256": source.manifest_sha256,
                                        "manifest_revision": source.manifest_revision,
                                        "committed_bytes": source.size_bytes,
                                        "session_id": source.session_id,
                                        "timeline_offset_us": source.timeline_offset_us,
                                        "completed": source.completed, "sample_rate": 16000, "channels": 1,
                                        "frame_count": source.size_bytes // 2, "encoding": "PCM_16"})
                        duration = source.size_bytes / 32000
                        path, snapshot_hash = _committed_wav(
                            source, copied, copied.with_suffix(".wav"), budget, details["sha256"])
                    else:
                        path = copied
                        snapshot_hash = details["sha256"]
                        try:
                            details.update(legacy_wav_details(path))
                        except Exception:
                            entry.availability = "invalid"
                            raise
                        duration = details["frame_count"] / details["sample_rate"]
                        if not math.isfinite(duration) or not 0 <= duration <= 86400:
                            raise ValueError("Invalid or excessive source duration")
                    entry.availability = "empty" if duration == 0 else "present"
                    if duration == 0 and stream in streams:
                        entry.status = "empty"
                    durations.append(duration)
                    paths[stream] = path
                    snapshot_hashes[stream] = snapshot_hash
                if not durations:
                    raise ValueError("No readable source audio")
                session_duration = max(durations)
                source_inventory.append({
                    "source_session_id": source_identity, "audio_folder": folder,
                    "timeline_offset_seconds": session_offset, "duration_seconds": session_duration,
                    "storage_kind": "committed_pcm" if sources else "legacy_wav",
                })
                for entry in entries:
                    active = entry
                    if entry.stream not in streams or entry.status == "empty":
                        continue
                    result = reprocess_stream(
                        paths[entry.stream], entry.stream, diar_backend=args.diar_backend,
                        asr_model=args.asr_model, language=args.language,
                        gap_threshold=args.gap_threshold, speaker_tolerance=args.speaker_tolerance,
                        verbose=args.verbose, recovery=not args.no_recovery, evidence=entry, budget=budget,
                        expected_snapshot_sha256=snapshot_hashes[entry.stream])
                    for turn in result["turns"]:
                        turn["source_session_id"] = source_identity
                        turn["t0"] += session_offset
                        turn["t1"] += session_offset
                    all_turns.extend(result["turns"])
                    bounded_count(len(all_turns))
                    all_speakers.update(result["speakers"])
                active = None
                running_offset = max(running_offset, session_offset + session_duration)

        all_turns.sort(key=lambda item: (item["t0"], item["stream"], item["speaker_id"]))
        processing.complete = True
        payload = processing.payload()
        result_event = {"type": "result", "turns": all_turns, "speakers": sorted(all_speakers),
              "duration": running_offset, "sources": source_inventory,
              "runtime_identity": runtime_identity, "processing": payload}
        _encoded_event(result_event)  # Match the native reader before claiming success.
        emit_status("complete")
        emit(result_event)
        return 0
    except Exception as error:
        processing.complete = False
        if active is not None:
            active.status = "failed"
            active.failure_code = type(error).__name__[:64]
        message = f"batch reprocess failed ({format_exception_message(error)[:512]})"
        emit({"type": "error", "message": message, "processing": processing.payload()})
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
