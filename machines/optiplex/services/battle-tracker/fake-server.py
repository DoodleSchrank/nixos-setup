#!@python@/bin/python3
# Stand-in for the app's sync server in the deploy VM test (battle-tracker.nix, fakeApp). It speaks
# just enough: GET /health (200 and a marker file in the data dir, or 503 in mode "unhealthy"), and
# GET/PUT /v1/groups/<key>. The mode is the file `mode` next to the real path of this script.
import http.server
import os

here = os.path.dirname(os.path.realpath(__file__))
mode = open(os.path.join(here, "mode")).read().strip()
data = os.environ["BT_SYNC_DATA_DIR"]


class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b"{}"):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            if mode == "unhealthy":
                return self.reply(503, b'{"status":"degraded"}')
            with open(os.path.join(data, ".fake-health"), "w") as f:
                f.write(mode)
            return self.reply(200, b'{"status":"ok"}')
        self.reply(404)

    def log_message(self, *args):
        pass


http.server.HTTPServer(
    (os.environ["BT_SYNC_HOST"], int(os.environ["BT_SYNC_PORT"])), Handler
).serve_forever()
