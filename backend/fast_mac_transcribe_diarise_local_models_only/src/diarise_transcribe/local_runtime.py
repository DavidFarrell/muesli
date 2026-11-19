"""Offline dependency policy, installed before any model libraries import.

This blocks Python networking and Hub requests. It is not an OS sandbox for
arbitrary native extensions; release qualification also tests with OS networking
denied. Provisioning is a separate explicit command, never a recording fallback.
"""
import os
import sys
import threading
from contextlib import contextmanager

# A narrow, per-thread exception for the whitebox transcriber (whitebox-audio#10):
# while held, this thread may resolve one name and connect to one address and
# port. The whitebox client grants only addresses it has checked are on the
# owner's tailnet. Nothing else, on any thread, is opened.
_grant = threading.local()


@contextmanager
def permit_connection(address: str, port: int, name: str | None = None):
    previous = getattr(_grant, "value", None)
    _grant.value = (name, address, port)
    try:
        yield
    finally:
        _grant.value = previous


def _granted(event, args) -> bool:
    grant = getattr(_grant, "value", None)
    if grant is None or not args:
        return False
    name, address, port = grant
    if event == "socket.getaddrinfo":
        return args[0] in (name, address) and args[0] is not None
    if event == "socket.connect":
        target = args[1] if len(args) > 1 else None
        return isinstance(target, tuple) and tuple(target[:2]) == (address, port)
    return False


class OfflineNetworkError(RuntimeError):
    pass


def configure() -> None:
    if os.environ.get("MUESLI_ALLOW_MODEL_DOWNLOADS") == "1":
        return
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    os.environ["DO_NOT_TRACK"] = "1"

    def deny_network(event, args):
        if _granted(event, args):
            return
        if event in {"socket.getaddrinfo", "socket.gethostbyname", "socket.gethostbyaddr", "socket.getnameinfo"}:
            raise OfflineNetworkError("Network name resolution is disabled during local inference.")
        if event in {"socket.connect", "socket.bind", "socket.sendto", "socket.sendmsg"}:
            # AF_UNIX IPC used by local model runtimes remains available.
            if args and getattr(args[0], "family", None) in (2, 30, 10):
                raise OfflineNetworkError("Network connections are disabled during local inference.")

    sys.addaudithook(deny_network)
