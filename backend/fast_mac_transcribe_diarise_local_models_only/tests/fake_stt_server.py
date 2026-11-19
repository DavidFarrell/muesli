"""A stand-in for the whitebox's shared STT service, run as its own process.

The package's offline guard blocks sockets in the test process, so the fake lives
outside it. Usage: fake_stt_server.py <config.json> <uploads.jsonl>. The config has
`health` (the /healthz body) and `replies`: per stream (mic/system), a list of
{"status", "body", "headers"} used in order, the last one repeating.
Prints the port it listens on, then serves until killed.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

config = json.load(open(sys.argv[1]))
log_path = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _send(self, status, payload, headers=()):
        body = json.dumps(payload).encode()
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, config["health"])

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        stream = "mic" if b'filename="mic.' in body else "system"
        with open(log_path, "a") as log:
            log.write(json.dumps({
                "stream": stream, "host": self.headers["Host"],
                "engine_field": b'name="engine"' in body,
                "diarize_true": b'name="diarize"\r\n\r\ntrue' in body,
                "flac": b"fLaC" in body}) + "\n")
        queue = config["replies"][stream]
        reply = queue.pop(0) if len(queue) > 1 else queue[0]
        self._send(reply["status"], reply["body"], reply.get("headers", ()))

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
