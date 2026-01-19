"""
Backend adapter for Muesli framed audio protocol -> diarise/transcribe pipeline.

Reads framed messages on stdin and writes JSONL events to stdout.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
import tempfile
import threading
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Optional

from .audio import check_ffmpeg, normalise_audio
from .asr import ASRModel, DEFAULT_MODEL
from .diarisation import SortformerDiarizer, MODEL_CONFIGS
from .merge import merge_transcript_with_diarisation

MSG_AUDIO = 1
MSG_SCREENSHOT_EVENT = 2
MSG_MEETING_START = 3
MSG_MEETING_STOP = 4

STREAM_SYSTEM = 0
STREAM_MIC = 1

HDR_STRUCT = struct.Struct("<BBqI")  # type, stream, pts_us, payload_len
BYTES_PER_SAMPLE = 2  # int16
RUN_PIPELINE_LOCK = threading.Lock()


@dataclass
class StreamWriter:
    path: Path
    wav: wave.Wave_write
    pcm: BinaryIO
    last_sample_index: int = 0
    bytes_written: int = 0


@dataclass
class StreamSnapshot:
    pcm_path: Path
    sample_rate: int
    channels: int
    size_bytes: int


def read_exact(f: BinaryIO, n: int) -> bytes:
    data = f.read(n)
    if len(data) != n:
        raise EOFError
    return data


def emit_jsonl(obj: dict, lock: Optional[threading.Lock] = None) -> None:
    line = json.dumps(obj, ensure_ascii=False) + "\n"
    try:
        if lock:
            with lock:
                sys.stdout.write(line)
                sys.stdout.flush()
        else:
            sys.stdout.write(line)
            sys.stdout.flush()
    except Exception:
        return


def log(msg: str, verbose: bool) -> None:
    if verbose:
        try:
            print(msg, file=sys.stderr)
        except Exception:
            return


def open_stream_writer(path: Path, sample_rate: int, channels: int) -> StreamWriter:
    wav = wave.open(str(path), "wb")
    wav.setnchannels(channels)
    wav.setsampwidth(BYTES_PER_SAMPLE)
    wav.setframerate(sample_rate)
    pcm_path = path.with_suffix(".pcm")
    pcm = open(pcm_path, "wb")
    return StreamWriter(path=path, wav=wav, pcm=pcm)


def close_stream_writer(writer: StreamWriter) -> None:
    try:
        writer.wav.close()
    finally:
        writer.pcm.close()


def rms_int16(pcm: bytes) -> float:
    if len(pcm) < 2:
        return 0.0
    count = len(pcm) // 2
    ints = struct.unpack("<" + "h" * count, pcm)
    acc = 0.0
    for v in ints:
        x = v / 32768.0
        acc += x * x
    return (acc / count) ** 0.5


def write_aligned_audio(
    writer: StreamWriter,
    payload: bytes,
    pts_us: int,
    sample_rate: int,
    channels: int,
) -> None:
    if not payload:
        return

    bytes_per_frame = BYTES_PER_SAMPLE * channels
    usable = (len(payload) // bytes_per_frame) * bytes_per_frame
    if usable <= 0:
        return
    payload = payload[:usable]

    # PTS is in microseconds since meeting start; align to sample index.
    start_sample = int(round(pts_us * sample_rate / 1_000_000.0))
    if start_sample < 0:
        start_sample = 0

    if start_sample > writer.last_sample_index:
        gap_frames = start_sample - writer.last_sample_index
        silence = b"\x00" * (gap_frames * bytes_per_frame)
        writer.wav.writeframes(silence)
        writer.pcm.write(silence)
        writer.last_sample_index += gap_frames
        writer.bytes_written += len(silence)
    elif start_sample < writer.last_sample_index:
        overlap_frames = writer.last_sample_index - start_sample
        drop_bytes = overlap_frames * bytes_per_frame
        if drop_bytes >= len(payload):
            return
        payload = payload[drop_bytes:]

    writer.wav.writeframes(payload)
    writer.pcm.write(payload)
    writer.pcm.flush()
    writer.last_sample_index += len(payload) // bytes_per_frame
    writer.bytes_written += len(payload)


def snapshot_stream(writer: StreamWriter, sample_rate: int, channels: int) -> StreamSnapshot:
    pcm_path = writer.path.with_suffix(".pcm")
    size = pcm_path.stat().st_size if pcm_path.exists() else 0
    return StreamSnapshot(
        pcm_path=pcm_path,
        sample_rate=sample_rate,
        channels=channels,
        size_bytes=size,
    )


def write_wav_from_pcm(snapshot: StreamSnapshot, temp_dir: Path) -> Optional[Path]:
    if snapshot.size_bytes <= 0:
        return None

    temp = tempfile.NamedTemporaryFile(suffix=".wav", prefix="muesli_live_", dir=temp_dir, delete=False)
    temp_path = Path(temp.name)
    temp.close()

    bytes_per_frame = BYTES_PER_SAMPLE * snapshot.channels
    remaining = snapshot.size_bytes - (snapshot.size_bytes % bytes_per_frame)

    with wave.open(str(temp_path), "wb") as wav_out:
        wav_out.setnchannels(snapshot.channels)
        wav_out.setsampwidth(BYTES_PER_SAMPLE)
        wav_out.setframerate(snapshot.sample_rate)

        with open(snapshot.pcm_path, "rb") as pcm:
            while remaining > 0:
                chunk = pcm.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                wav_out.writeframes(chunk)
                remaining -= len(chunk)

    return temp_path


def run_pipeline(
    input_path: Path,
    diar_backend: str,
    diar_model: str,
    asr_model: str,
    language: Optional[str],
    gap_threshold: float,
    speaker_tolerance: float,
    verbose: bool,
) -> "MergedTranscript":
    if not check_ffmpeg():
        raise RuntimeError("ffmpeg is not installed or not in PATH")

    log("Normalising audio to 16kHz mono WAV...", verbose)
    temp_wav = normalise_audio(str(input_path))

    try:
        log(f"Running ASR with {asr_model}...", verbose)
        asr = ASRModel(asr_model)
        transcript = asr.transcribe(temp_wav, language=language)

        if diar_backend == "senko":
            log("Running diarisation with Senko...", verbose)
            from .senko_diarisation import SenkoDiarizer
            diarizer = SenkoDiarizer(quiet=not verbose)
            segments = diarizer.diarise(temp_wav)
        else:
            log(f"Running diarisation with Sortformer {diar_model}...", verbose)
            diarizer = SortformerDiarizer(model_name=diar_model)
            segments = diarizer.diarise(temp_wav)

        merged = merge_transcript_with_diarisation(
            transcript,
            segments,
            gap_threshold=gap_threshold,
            speaker_tolerance=speaker_tolerance,
        )
        return merged
    finally:
        try:
            Path(temp_wav).unlink(missing_ok=True)
        except Exception:
            pass


class TranscriptEmitter:
    def __init__(self, stdout_lock: threading.Lock, finalize_lag: float) -> None:
        self._stdout_lock = stdout_lock
        self._finalize_lag = finalize_lag
        self._last_emitted_t1_by_stream = {}
        self._last_partial_by_stream = {}
        self._seen_speakers = set()
        self._lock = threading.Lock()

    def emit_transcript(
        self,
        merged: "MergedTranscript",
        current_duration: float,
        finalize: bool,
        stream_name: Optional[str] = None,
    ) -> None:
        if not merged.turns:
            return

        with self._lock:
            stream_key = stream_name or "default"
            last_emitted_t1 = self._last_emitted_t1_by_stream.get(stream_key, 0.0)
            last_partial = self._last_partial_by_stream.get(stream_key)

            new_speakers = False
            for turn in merged.turns:
                speaker_id = f"{stream_name}:{turn.speaker}" if stream_name else turn.speaker
                if speaker_id not in self._seen_speakers:
                    self._seen_speakers.add(speaker_id)
                    new_speakers = True

            if new_speakers:
                known = [{"speaker_id": s, "name": s} for s in sorted(self._seen_speakers)]
                emit_jsonl({"type": "speakers", "known": known}, self._stdout_lock)

            cutoff = current_duration if finalize else max(0.0, current_duration - self._finalize_lag)
            for turn in merged.turns:
                if turn.end <= cutoff and turn.end > last_emitted_t1 + 0.02:
                    speaker_id = f"{stream_name}:{turn.speaker}" if stream_name else turn.speaker
                    emit_jsonl({
                        "type": "segment",
                        "speaker": turn.speaker,
                        "speaker_id": speaker_id,
                        "stream": stream_name,
                        "t0": turn.start,
                        "t1": turn.end,
                        "text": turn.text,
                    }, self._stdout_lock)
                    last_emitted_t1 = max(last_emitted_t1, turn.end)

            if not finalize:
                last_turn = merged.turns[-1]
                if last_turn.end > cutoff:
                    partial = (last_turn.speaker, last_turn.start, last_turn.text)
                    if partial != last_partial:
                        speaker_id = f"{stream_name}:{last_turn.speaker}" if stream_name else last_turn.speaker
                        emit_jsonl({
                            "type": "partial",
                            "speaker_id": speaker_id,
                            "stream": stream_name,
                            "t0": last_turn.start,
                            "text": last_turn.text,
                        }, self._stdout_lock)
                        last_partial = partial

            self._last_emitted_t1_by_stream[stream_key] = last_emitted_t1
            self._last_partial_by_stream[stream_key] = last_partial


class LiveProcessor:
    def __init__(
        self,
        stream_name: str,
        state: "BackendState",
        emitter: TranscriptEmitter,
        output_dir: Path,
        diar_backend: str,
        diar_model: str,
        asr_model: str,
        language: Optional[str],
        gap_threshold: float,
        speaker_tolerance: float,
        live_interval: float,
        live_min_seconds: float,
        verbose: bool,
    ) -> None:
        self._stream_name = stream_name
        self._state = state
        self._emitter = emitter
        self._output_dir = output_dir
        self._diar_backend = diar_backend
        self._diar_model = diar_model
        self._asr_model = asr_model
        self._language = language
        self._gap_threshold = gap_threshold
        self._speaker_tolerance = speaker_tolerance
        self._live_interval = live_interval
        self._live_min_seconds = live_min_seconds
        self._verbose = verbose

        self._current_duration = 0.0
        self._last_processed_duration = 0.0
        self._event = threading.Event()
        self._stop_event = threading.Event()
        self._finalize_requested = False
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def notify_duration(self, duration: float) -> None:
        self._current_duration = duration
        if duration >= self._live_min_seconds and (duration - self._last_processed_duration) >= self._live_interval:
            self._event.set()

    def stop(self, finalize: bool) -> None:
        self._finalize_requested = finalize
        self._stop_event.set()
        self._event.set()
        self._thread.join()

    def _snapshot(self) -> Optional[StreamSnapshot]:
        with self._state.lock:
            writer = self._state.get_stream(self._stream_name)
            sample_rate = self._state.sample_rate
            channels = self._state.channels
        if not writer:
            return None
        return snapshot_stream(writer, sample_rate, channels)

    def _run(self) -> None:
        while not self._stop_event.is_set():
            self._event.wait(timeout=0.5)
            self._event.clear()
            if self._maybe_process(finalize=False):
                continue
        if self._finalize_requested:
            self._maybe_process(finalize=True)

    def _maybe_process(self, finalize: bool) -> bool:
        snapshot = self._snapshot()
        if not snapshot or snapshot.size_bytes <= 0:
            return False

        bytes_per_frame = BYTES_PER_SAMPLE * snapshot.channels
        duration = snapshot.size_bytes / float(bytes_per_frame * snapshot.sample_rate)

        if not finalize:
            if duration < self._live_min_seconds:
                return False
            if duration - self._last_processed_duration < self._live_interval:
                return False

        emit_jsonl({
            "type": "status",
            "message": "live_process_start",
            "stream": self._stream_name,
            "duration": duration,
            "finalize": finalize,
        }, self._state.stdout_lock)

        temp_wav = write_wav_from_pcm(snapshot, self._output_dir)
        if not temp_wav:
            return False

        try:
            with RUN_PIPELINE_LOCK:
                merged = run_pipeline(
                    input_path=temp_wav,
                    diar_backend=self._diar_backend,
                    diar_model=self._diar_model,
                    asr_model=self._asr_model,
                    language=self._language,
                    gap_threshold=self._gap_threshold,
                    speaker_tolerance=self._speaker_tolerance,
                    verbose=self._verbose,
                )
        except Exception as exc:
            emit_jsonl({"type": "error", "message": str(exc)}, self._state.stdout_lock)
            return False
        finally:
            temp_wav.unlink(missing_ok=True)

        emit_jsonl({
            "type": "status",
            "message": "live_process_done",
            "stream": self._stream_name,
            "duration": duration,
            "turns": len(merged.turns),
            "finalize": finalize,
        }, self._state.stdout_lock)

        self._emitter.emit_transcript(merged, duration, finalize=finalize, stream_name=self._stream_name)
        self._last_processed_duration = max(self._last_processed_duration, duration)
        return True


class BackendState:
    def __init__(self, stdout_lock: threading.Lock) -> None:
        self.lock = threading.Lock()
        self.stdout_lock = stdout_lock
        self.system_writer: Optional[StreamWriter] = None
        self.mic_writer: Optional[StreamWriter] = None
        self.sample_rate: int = 48000
        self.channels: int = 1

    def get_stream(self, name: str) -> Optional[StreamWriter]:
        if name == "system":
            return self.system_writer
        if name == "mic":
            return self.mic_writer
        return None


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Muesli backend adapter for diarise-transcribe.",
    )
    parser.add_argument(
        "--output-dir",
        default=".",
        help="Directory to write capture artifacts (default: current directory)",
    )
    parser.add_argument(
        "--transcribe-stream",
        choices=["system", "mic", "both"],
        default="system",
        help="Which stream to transcribe (system, mic, both; default: system)",
    )
    parser.add_argument(
        "--diar-backend",
        choices=["senko", "sortformer"],
        default="senko",
        help="Diarisation backend (default: senko)",
    )
    parser.add_argument(
        "--diar-model",
        choices=list(MODEL_CONFIGS.keys()),
        default="default",
        help="Sortformer model variant (default: %(default)s)",
    )
    parser.add_argument(
        "--asr-model",
        default=DEFAULT_MODEL,
        help=f"ASR model ID (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--language",
        default=None,
        help="Language code for ASR (auto-detected if not specified)",
    )
    parser.add_argument(
        "--gap-threshold",
        type=float,
        default=0.8,
        help="Gap threshold seconds for speaker turns (default: 0.8)",
    )
    parser.add_argument(
        "--speaker-tolerance",
        type=float,
        default=0.25,
        help="Tolerance seconds for word-speaker assignment (default: 0.25)",
    )
    parser.add_argument(
        "--live-interval",
        type=float,
        default=15.0,
        help="Seconds between live transcript updates (default: 15)",
    )
    parser.add_argument(
        "--live-min-seconds",
        type=float,
        default=10.0,
        help="Minimum audio seconds before first live update (default: 10)",
    )
    parser.add_argument(
        "--finalize-lag",
        type=float,
        default=5.0,
        help="Seconds to hold back final segments (default: 5)",
    )
    parser.add_argument(
        "--emit-meters",
        action="store_true",
        help="Emit RMS meter events for incoming audio",
    )
    parser.add_argument(
        "--keep-wav",
        action="store_true",
        help="Keep captured WAV files after processing",
    )
    parser.add_argument(
        "--keep-pcm",
        action="store_true",
        help="Keep captured PCM files after processing",
    )
    parser.add_argument(
        "--no-live",
        action="store_true",
        help="Disable live transcript updates (process only on stop)",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Verbose logs to stderr",
    )
    return parser


def main() -> int:
    args = create_parser().parse_args()

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    stdout_lock = threading.Lock()
    state = BackendState(stdout_lock)
    emitter = TranscriptEmitter(stdout_lock, finalize_lag=args.finalize_lag)

    transcribe_streams = ["system", "mic"] if args.transcribe_stream == "both" else [args.transcribe_stream]
    live_processors = {}

    if not args.no_live:
        for stream_name in transcribe_streams:
            live_processor = LiveProcessor(
                stream_name=stream_name,
                state=state,
                emitter=emitter,
                output_dir=output_dir,
                diar_backend=args.diar_backend,
                diar_model=args.diar_model,
                asr_model=args.asr_model,
                language=args.language,
                gap_threshold=args.gap_threshold,
                speaker_tolerance=args.speaker_tolerance,
                live_interval=args.live_interval,
                live_min_seconds=args.live_min_seconds,
                verbose=args.verbose,
            )
            live_processor.start()
            live_processors[stream_name] = live_processor

    stdin = sys.stdin.buffer

    while True:
        try:
            hdr = read_exact(stdin, HDR_STRUCT.size)
        except EOFError:
            break

        msg_type, stream_id, pts_us, payload_len = HDR_STRUCT.unpack(hdr)
        payload = read_exact(stdin, payload_len) if payload_len else b""

        if msg_type == MSG_MEETING_START:
            meeting_meta = json.loads(payload.decode("utf-8")) if payload else {}
            with state.lock:
                state.sample_rate = int(meeting_meta.get("sample_rate", 48000))
                state.channels = int(meeting_meta.get("channels", 1))

                state.system_writer = open_stream_writer(output_dir / "system.wav", state.sample_rate, state.channels)
                state.mic_writer = open_stream_writer(output_dir / "mic.wav", state.sample_rate, state.channels)

            emit_jsonl({"type": "status", "message": "meeting_started", "meta": meeting_meta}, stdout_lock)

        elif msg_type == MSG_AUDIO:
            t = pts_us / 1_000_000.0
            with state.lock:
                if stream_id == STREAM_SYSTEM and state.system_writer:
                    write_aligned_audio(state.system_writer, payload, pts_us, state.sample_rate, state.channels)
                    if args.emit_meters:
                        emit_jsonl({"type": "meter", "stream": "system", "t": t, "rms": rms_int16(payload)}, stdout_lock)
                    if not args.no_live and "system" in live_processors:
                        duration = state.system_writer.last_sample_index / float(state.sample_rate)
                        live_processors["system"].notify_duration(duration)
                elif stream_id == STREAM_MIC and state.mic_writer:
                    write_aligned_audio(state.mic_writer, payload, pts_us, state.sample_rate, state.channels)
                    if args.emit_meters:
                        emit_jsonl({"type": "meter", "stream": "mic", "t": t, "rms": rms_int16(payload)}, stdout_lock)
                    if not args.no_live and "mic" in live_processors:
                        duration = state.mic_writer.last_sample_index / float(state.sample_rate)
                        live_processors["mic"].notify_duration(duration)

        elif msg_type == MSG_SCREENSHOT_EVENT:
            if payload:
                evt = json.loads(payload.decode("utf-8"))
                emit_jsonl({"type": "screenshot", **evt}, stdout_lock)

        elif msg_type == MSG_MEETING_STOP:
            emit_jsonl({"type": "status", "message": "meeting_stopped"}, stdout_lock)
            break

    if not args.no_live:
        for live_processor in live_processors.values():
            live_processor.stop(finalize=True)

    with state.lock:
        system_writer = state.system_writer
        mic_writer = state.mic_writer

    if system_writer:
        close_stream_writer(system_writer)
    if mic_writer:
        close_stream_writer(mic_writer)

    writers = {"system": system_writer, "mic": mic_writer}
    had_audio = False
    for stream_name in transcribe_streams:
        writer = writers.get(stream_name)
        if not writer or writer.bytes_written == 0:
            emit_jsonl({
                "type": "error",
                "message": f"no_audio_for_stream_{stream_name}",
            }, stdout_lock)
            continue
        had_audio = True

    if not had_audio:
        return 1

    if args.no_live:
        for stream_name in transcribe_streams:
            writer = writers.get(stream_name)
            if not writer or writer.bytes_written == 0:
                continue
            snapshot = snapshot_stream(writer, state.sample_rate, state.channels)
            temp_wav = write_wav_from_pcm(snapshot, output_dir)
            if not temp_wav:
                emit_jsonl({"type": "error", "message": "failed_to_build_wav"}, stdout_lock)
                continue

            try:
                with RUN_PIPELINE_LOCK:
                    merged = run_pipeline(
                        input_path=temp_wav,
                        diar_backend=args.diar_backend,
                        diar_model=args.diar_model,
                        asr_model=args.asr_model,
                        language=args.language,
                        gap_threshold=args.gap_threshold,
                        speaker_tolerance=args.speaker_tolerance,
                        verbose=args.verbose,
                    )
            except Exception as exc:
                emit_jsonl({"type": "error", "message": str(exc)}, stdout_lock)
                continue
            finally:
                temp_wav.unlink(missing_ok=True)

            duration = writer.last_sample_index / float(state.sample_rate)
            emitter.emit_transcript(merged, duration, finalize=True, stream_name=stream_name)

    if not args.keep_wav:
        if system_writer:
            system_writer.path.unlink(missing_ok=True)
        if mic_writer:
            mic_writer.path.unlink(missing_ok=True)

    if not args.keep_pcm:
        if system_writer:
            system_writer.path.with_suffix(".pcm").unlink(missing_ok=True)
        if mic_writer:
            mic_writer.path.with_suffix(".pcm").unlink(missing_ok=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
