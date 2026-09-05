"""Offline dependency policy, installed before any model libraries import.

This blocks Python networking and Hub requests. It is not an OS sandbox for
arbitrary native extensions; release qualification also tests with OS networking
denied. Provisioning is a separate explicit command, never a recording fallback.
"""
import os
import sys


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
        if event in {"socket.getaddrinfo", "socket.gethostbyname", "socket.gethostbyaddr", "socket.getnameinfo"}:
            raise OfflineNetworkError("Network name resolution is disabled during local inference.")
        if event in {"socket.connect", "socket.bind", "socket.sendto", "socket.sendmsg"}:
            # AF_UNIX IPC used by local model runtimes remains available.
            if args and getattr(args[0], "family", None) in (2, 30, 10):
                raise OfflineNetworkError("Network connections are disabled during local inference.")

    sys.addaudithook(deny_network)
