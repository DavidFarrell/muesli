"""Offline dependency policy, installed before any model libraries import.

This blocks Python networking and Hub requests. It is not an OS sandbox for
arbitrary native extensions; release qualification also tests with OS networking
denied. Provisioning is a separate explicit command, never a recording fallback.

ONE DESCRIBED EXCEPTION: the whitebox transcriber (whitebox-audio#10). When the
owner asks for `reprocess --transcriber whitebox`, the whitebox client opens two
narrow, per-thread grants, one after the other, and nothing else:

- `permit_lookup(name)`: resolve that one host name. No connection.
- `permit_connection(address, port)`: connect to that one address and port. The
  client grants only an address it has checked is on the owner's tailnet.

Every other thread, name, address and port stays blocked, and local-only runs
open no grant at all. This is a separately described boundary, not a loosening
of the offline policy: see engineer-notes/production-audit-2026-09-05/
offline-runtime.md.
"""
import os
import sys
import threading
from contextlib import contextmanager

_grant = threading.local()


@contextmanager
def _granting(grant: tuple):
    previous = getattr(_grant, "value", None)
    _grant.value = grant
    try:
        yield
    finally:
        _grant.value = previous


def permit_lookup(name: str):
    """While held, this thread may resolve `name` and nothing else; it may not
    connect anywhere."""
    return _granting(("lookup", name))


def permit_connection(address: str, port: int):
    """While held, this thread may connect to `address`:`port` (and resolve the
    numeric address itself, which http.client does) and nothing else."""
    return _granting(("connect", address, port))


def _granted(event, args) -> bool:
    grant = getattr(_grant, "value", None)
    if grant is None or not args:
        return False
    if grant[0] == "lookup":
        return event == "socket.getaddrinfo" and args[0] is not None and args[0] == grant[1]
    _, address, port = grant
    if event == "socket.getaddrinfo":
        return args[0] == address
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
