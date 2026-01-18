import sys
import json
import struct
import wave
from dataclasses import dataclass
from typing import BinaryIO, Optional

MSG_AUDIO = 1
MSG_SCREENSHOT_EVENT = 2
MSG_MEETING_START = 3
MSG_MEETING_STOP = 4

STREAM_SYSTEM = 0
STREAM_MIC = 1

HDR_STRUCT = struct.Struct("<BBqI")  # type, stream, pts_us, payload_len


@dataclass
class Meeting:
    sample_rate: int = 48000
    channels: int = 1
    system_wav: Optional[wave.Wave_write] = None
    mic_wav: Optional[wave.Wave_write] = None


def read_exact(f: BinaryIO, n: int) -> bytes:
    data = f.read(n)
    if len(data) != n:
        raise EOFError
    return data


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


def open_wav(path: str, sr: int, ch: int) -> wave.Wave_write:
    w = wave.open(path, "wb")
    w.setnchannels(ch)
    w.setsampwidth(2)  # int16
    w.setframerate(sr)
    return w


def emit_jsonl(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> int:
    meeting = Meeting()
    stdin = sys.stdin.buffer

    while True:
        try:
            hdr = read_exact(stdin, HDR_STRUCT.size)
        except EOFError:
            break

        msg_type, stream_id, pts_us, payload_len = HDR_STRUCT.unpack(hdr)
        payload = read_exact(stdin, payload_len) if payload_len else b""

        if msg_type == MSG_MEETING_START:
            meta = json.loads(payload.decode("utf-8"))
            meeting.sample_rate = int(meta.get("sample_rate", 48000))
            meeting.channels = int(meta.get("channels", 1))

            meeting.system_wav = open_wav("system.wav", meeting.sample_rate, meeting.channels)
            meeting.mic_wav = open_wav("mic.wav", meeting.sample_rate, meeting.channels)

            emit_jsonl({"type": "status", "message": "meeting_started", "meta": meta})

        elif msg_type == MSG_AUDIO:
            t = pts_us / 1_000_000.0
            level = rms_int16(payload)

            if stream_id == STREAM_SYSTEM and meeting.system_wav:
                meeting.system_wav.writeframes(payload)
                emit_jsonl({"type": "meter", "stream": "system", "t": t, "rms": level})

            elif stream_id == STREAM_MIC and meeting.mic_wav:
                meeting.mic_wav.writeframes(payload)
                emit_jsonl({"type": "meter", "stream": "mic", "t": t, "rms": level})

            if int(t) % 10 == 0 and abs(t - round(t)) < 0.02:
                emit_jsonl({
                    "type": "partial",
                    "speaker_id": "spk0",
                    "t0": t,
                    "text": f"(demo) audio at {t:.1f}s",
                })

        elif msg_type == MSG_SCREENSHOT_EVENT:
            evt = json.loads(payload.decode("utf-8"))
            emit_jsonl({"type": "screenshot", **evt})

        elif msg_type == MSG_MEETING_STOP:
            emit_jsonl({"type": "status", "message": "meeting_stopped"})
            break

    if meeting.system_wav:
        meeting.system_wav.close()
    if meeting.mic_wav:
        meeting.mic_wav.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
