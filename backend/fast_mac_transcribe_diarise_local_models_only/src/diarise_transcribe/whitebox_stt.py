"""Client for the owner's shared STT service on the whitebox (whitebox-audio#10).

`reprocess --transcriber whitebox` sends each owned, normalised track here instead of
running Parakeet + Senko on the Mac. The rules this module exists to keep:

- TAILNET ONLY. The host is resolved here and the connection goes to a Tailscale
  address (100.64.0.0/10 or fd7a:115c:a1e0::/48), never anywhere else. No proxy is
  consulted and redirects are not followed (http.client does neither), so meeting
  audio cannot leave the owner's own machines.
- NO ENGINE NAMED. The request carries `diarize=true` and no `engine`, so the
  service's own default applies (Whisper, per whitebox-audio#9). With no engine
  named the response has speaker turns in `segments` but no `engine`/`model` keys,
  so those are read from /healthz instead.
- VAD ON. `vad=true` makes Whisper skip non-speech. Without it Whisper writes
  "Thank you." into long silences (measured 19 Nov on a synthetic track: 8
  invented turns in 5 minutes), and one side of a meeting is often silent.
- NEVER A HALF RESULT. Anything unusable (unreachable, HTTP error, `diarize_error`
  on a track with speech, an unlabelled turn) raises WhiteboxUnavailable, and the
  caller redoes the whole meeting locally. A track with no speech (the silent
  refusal, or no words at all) is an empty stream, not a failure.
- `incomplete` IS A WARNING, NOT A FAILURE. The service's coverage check is a
  timing heuristic: it flags a transcript that ends more than 90 s before the
  audio, which a meeting track does whenever that side goes quiet near the end.
  The transcript is kept and the reason is reported.
"""

from __future__ import annotations

import http.client
import ipaddress
import json
import math
import os
import socket
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from .local_runtime import permit_connection

DEFAULT_URL = "http://whiteboxlinux.tail0d0f20.ts.net:8081"
URL_ENV = "MUESLI_WHITEBOX_URL"
TAILNET_NETWORKS = (ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48"))
HEALTH_TIMEOUT_S = 5.0
# The service drops a job whose caller disconnects: the read timeout must outlast
# a long meeting's transcription, but not hang for hours if the whitebox vanishes,
# so the read timeout is a base allowance plus the track's own length.
REQUEST_TIMEOUT_BASE_S = 30 * 60.0
BUSY_WAIT_LIMIT_S = 30 * 60.0
UPLOAD_CAP_BYTES = 95 * 1024 * 1024   # the service refuses over 100 MB (STT_MAX_MB)
SILENT_ERROR_PREFIX = "no speech detected"


class WhiteboxUnavailable(RuntimeError):
    """The whitebox cannot give a usable transcript for this run."""


def tailnet_address(host: str, port: int) -> str:
    """The first Tailscale address `host` resolves to. Refuses everything else."""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError as error:
        raise WhiteboxUnavailable(f"whitebox unreachable: cannot resolve {host} ({error})") from error
    for info in infos:
        address = info[4][0]
        if any(ipaddress.ip_address(address) in net for net in TAILNET_NETWORKS):
            return address
    raise WhiteboxUnavailable(f"{host} is not a Tailscale address; refusing to send audio there")


class WhiteboxSTT:
    def __init__(self, url: str):
        parts = urlsplit(url)
        if parts.scheme != "http" or not parts.hostname:
            raise WhiteboxUnavailable(f"whitebox URL must be http://<tailnet host>:<port>, got {url!r}")
        self.url = url.rstrip("/")
        self.host = parts.hostname
        self.port = parts.port or 80
        self.identity: dict | None = None
        self.coverage_warnings: list[dict] = []

    # -- transport ---------------------------------------------------------
    def _request(self, method: str, path: str, timeout: float, body=None, headers=None):
        # The package's offline guard blocks all Python networking; open exactly
        # the name lookup, then exactly the checked tailnet address, and no more.
        with permit_connection(None, 0, name=self.host):
            address = tailnet_address(self.host, self.port)
        with permit_connection(address, self.port):
            return self._exchange(address, method, path, timeout, body, headers)

    def _exchange(self, address, method, path, timeout, body, headers):
        connection = http.client.HTTPConnection(address, self.port, timeout=timeout)
        try:
            headers = dict(headers or {})
            # Host names the service, while the socket goes to the checked address.
            headers["Host"] = f"{self.host}:{self.port}"
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        except (OSError, http.client.HTTPException) as error:
            raise WhiteboxUnavailable(f"whitebox unreachable at {self.url} ({error})") from error
        finally:
            connection.close()

    # -- health ------------------------------------------------------------
    def check(self) -> dict:
        """Confirm the service can take a diarised job with its default engine."""
        status, _, raw = self._request("GET", "/healthz", HEALTH_TIMEOUT_S)
        if status != 200:
            raise WhiteboxUnavailable(f"whitebox health check failed: HTTP {status}")
        try:
            health = json.loads(raw)
        except ValueError as error:
            raise WhiteboxUnavailable("whitebox health check returned non-JSON") from error
        engine = health.get("default_engine") or "whisper"
        info = (health.get("engines") or {}).get(engine) or {}
        if not health.get("ok"):
            raise WhiteboxUnavailable("whitebox health check says not ok")
        if info.get("ready") is False:
            raise WhiteboxUnavailable(f"whitebox default engine {engine} not ready ({info.get('reason')})")
        if health.get("diarize_enabled") is False:
            raise WhiteboxUnavailable("whitebox speaker detection is disabled")
        self.identity = {"machine": "whitebox", "engine": engine,
                         "model": info.get("model") or health.get("model"), "service": self.url,
                         "coverage_warnings": self.coverage_warnings}
        return self.identity

    # -- transcription -----------------------------------------------------
    def transcribe(self, wav_path: str, stream_name: str, language: str | None = None) -> dict:
        """Diarised turns for one normalised track, in reprocess's turn shape."""
        with tempfile.TemporaryDirectory(prefix="muesli-whitebox-") as temporary:
            upload = _encode_for_upload(wav_path, Path(temporary), stream_name)
            fields = {"diarize": "true", "vad": "true"}
            if language:
                fields["language"] = language
            body_path, content_type = _multipart(Path(temporary), upload, fields)
            seconds = max(0, Path(wav_path).stat().st_size - 44) / 32000   # 16 kHz mono PCM16
            payload = self._post(body_path, content_type, REQUEST_TIMEOUT_BASE_S + seconds)
        return self._turns(payload, stream_name)

    def _post(self, body_path: Path, content_type: str, timeout: float) -> dict:
        deadline = time.monotonic() + BUSY_WAIT_LIMIT_S
        while True:
            with body_path.open("rb") as body:
                status, headers, raw = self._request(
                    "POST", "/stt", timeout, body=body,
                    headers={"Content-Type": content_type,
                             "Content-Length": str(body_path.stat().st_size)})
            if status == 503:
                wait = _retry_after(headers)
                if time.monotonic() + wait > deadline:
                    raise WhiteboxUnavailable("whitebox stayed busy for too long")
                time.sleep(wait)
                continue
            if status != 200:
                raise WhiteboxUnavailable(f"whitebox answered HTTP {status}: {raw[:200].decode(errors='replace')}")
            try:
                return json.loads(raw)
            except ValueError as error:
                raise WhiteboxUnavailable("whitebox returned non-JSON") from error

    def _turns(self, payload: dict, stream_name: str) -> dict:
        error = payload.get("error")
        speech = any(str(s.get("text") or "").strip() for s in payload.get("segments") or [])
        if error and str(error).startswith(SILENT_ERROR_PREFIX) and not speech:
            return {"turns": [], "segments": 0, "coverage_warning": None}
        if error:
            raise WhiteboxUnavailable(f"whitebox error: {error}")
        if payload.get("diarize_error") and not speech and not str(payload.get("text") or "").strip():
            # Noise but no words: nothing to label, so an empty stream.
            return {"turns": [], "segments": 0, "coverage_warning": None}
        if payload.get("diarize_error"):
            raise WhiteboxUnavailable(f"whitebox speaker detection failed: {payload['diarize_error']}")
        turns = []
        for segment in payload.get("segments") or []:
            speaker = segment.get("speaker")
            if not speaker:
                raise WhiteboxUnavailable("whitebox returned a turn with no speaker")
            start, end = float(segment["start"]), float(segment["end"])
            if not (math.isfinite(start) and math.isfinite(end) and 0 <= start <= end):
                raise WhiteboxUnavailable("whitebox returned an invalid turn time")
            text = str(segment.get("text") or "").strip()
            if text:
                turns.append({"speaker_id": f"{stream_name}:{speaker}", "stream": stream_name,
                              "t0": start, "t1": end, "text": text})
        if payload.get("engine") and self.identity is not None:
            self.identity["engine"] = payload["engine"]
            self.identity["model"] = payload.get("model") or self.identity["model"]
        warning = None
        if payload.get("incomplete") and turns:
            warning = (payload.get("coverage") or {}).get("reason") or "flagged incomplete"
            self.coverage_warnings.append({"stream": stream_name, "reason": warning})
        return {"turns": turns, "segments": len(payload.get("segments") or []),
                "coverage_warning": warning}


def _retry_after(headers: dict) -> float:
    for key, value in headers.items():
        if key.lower() == "retry-after":
            try:
                return max(1.0, min(float(value), 300.0))
            except ValueError:
                break
    return 30.0


def _encode_for_upload(wav_path: str, folder: Path, stream_name: str) -> Path:
    """Lossless FLAC; Opus at 48 kbit/s only when FLAC would pass the upload cap."""
    flac = folder / f"{stream_name}.flac"
    _ffmpeg(["-i", wav_path, "-c:a", "flac", str(flac)])
    if flac.stat().st_size <= UPLOAD_CAP_BYTES:
        return flac
    opus = folder / f"{stream_name}.ogg"
    _ffmpeg(["-i", wav_path, "-c:a", "libopus", "-b:a", "48k", str(opus)])
    if opus.stat().st_size > UPLOAD_CAP_BYTES:
        raise WhiteboxUnavailable("track too long for the whitebox upload cap")
    return opus


def _ffmpeg(args: list[str]) -> None:
    try:
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", *args],
                       check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise WhiteboxUnavailable(f"could not encode the upload ({error})") from error


def _multipart(folder: Path, upload: Path, fields: dict) -> tuple[Path, str]:
    boundary = uuid.uuid4().hex
    body = folder / "body.multipart"
    with body.open("wb") as out:
        for name, value in fields.items():
            out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
                      f"{value}\r\n".encode())
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
                  f'filename="{upload.name}"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode())
        with upload.open("rb") as source:
            while chunk := source.read(1 << 20):
                out.write(chunk)
        out.write(f"\r\n--{boundary}--\r\n".encode())
    return body, f"multipart/form-data; boundary={boundary}"


def default_url() -> str:
    return os.environ.get(URL_ENV) or DEFAULT_URL
