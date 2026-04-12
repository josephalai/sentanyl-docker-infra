#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════════════════════
# SENTANYL — Outbound Webhook Receiver
#
# Standalone HTTP server that captures outbound webhook POSTs from the Sentanyl
# engine.  Designed to run alongside the API server and MailHog during e2e
# testing with scripts/e2e-outbound-webhooks.sh.
#
# HOW TO USE:
#   Terminal 1:  ./go.sh              (API + MailHog)
#   Terminal 2:  python3 scripts/webhook-receiver.py
#   Terminal 3:  bash scripts/e2e-outbound-webhooks.sh
#
# ENV OVERRIDES:
#   WEBHOOK_PORT   Listening port           (default: 19876)
#   WEBHOOK_LOG    Log file path            (default: /tmp/sentanyl-webhooks.log)
#   WEBHOOK_HOST   Bind address             (default: 0.0.0.0)
# ═══════════════════════════════════════════════════════════════════════════════

import http.server
import sys
import json
import datetime
import os
import signal
import threading

# ── Configuration ──────────────────────────────────────────────────────────────
PORT     = int(os.environ.get("WEBHOOK_PORT", 19876))
HOST     = os.environ.get("WEBHOOK_HOST",    "0.0.0.0")
LOG_FILE = os.environ.get("WEBHOOK_LOG",     "/tmp/sentanyl-webhooks.log")

# ── Colour helpers (ANSI — same palette as the e2e shell scripts) ──────────────
RED  = "\033[0;31m"
GRN  = "\033[0;32m"
YLW  = "\033[1;33m"
CYN  = "\033[1;36m"
BLD  = "\033[1m"
RST  = "\033[0m"

_event_lock  = threading.Lock()
_event_count = 0


def _log(msg: str) -> None:
    """Write a line to stdout (always) and to LOG_FILE."""
    print(msg, flush=True)
    try:
        with open(LOG_FILE, "a") as fh:
            fh.write(msg + "\n")
    except OSError as exc:
        print(f"{RED}[warn] Could not write to {LOG_FILE}: {exc}{RST}", flush=True)


# ── Request handler ────────────────────────────────────────────────────────────
class WebhookHandler(http.server.BaseHTTPRequestHandler):
    """Accept any POST, parse JSON, log the event, return HTTP 200."""

    def do_POST(self) -> None:
        global _event_count

        length = int(self.headers.get("Content-Length", 0))
        raw    = self.rfile.read(length) if length else b""

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"status":"ok"}')

        ts = datetime.datetime.now().strftime("%H:%M:%S")

        try:
            body       = json.loads(raw)
            event_type = body.get("event_type", "unknown")
            line       = f"[{ts}] EVENT={event_type} PAYLOAD={json.dumps(body)}"
        except (json.JSONDecodeError, ValueError):
            line = f"[{ts}] RAW={raw.decode('utf-8', errors='replace')}"
            event_type = "RAW"

        with _event_lock:
            _event_count += 1
            num = _event_count

        _log(line)
        print(
            f"  {GRN}●{RST} Event #{num}: {BLD}{event_type}{RST}",
            flush=True,
        )

    # ── Silence the default "GET /... 200" access log ──────────────────────────
    def log_message(self, fmt: str, *args) -> None:  # noqa: ARG002
        pass


# ── Startup banner ─────────────────────────────────────────────────────────────
def _banner() -> None:
    url = f"http://localhost:{PORT}/hook"
    print(f"\n{CYN}{BLD}╔══ Sentanyl Webhook Receiver ══╗{RST}")
    print(f"  {GRN}✓{RST} Listening on  {BLD}http://{HOST}:{PORT}{RST}")
    print(f"  {GRN}✓{RST} Hook endpoint  {BLD}{url}{RST}")
    print(f"  {GRN}✓{RST} Log file       {BLD}{LOG_FILE}{RST}")
    print(f"  {YLW}ℹ{RST} Press Ctrl+C to stop\n")


# ── Clean shutdown ─────────────────────────────────────────────────────────────
def _make_shutdown(server: http.server.HTTPServer):
    def _handler(signum, frame):  # noqa: ARG001
        print(f"\n  {YLW}ℹ{RST} Signal received — shutting down gracefully…")
        threading.Thread(target=server.shutdown, daemon=True).start()
        sys.exit(0)
    return _handler


# ── Main ───────────────────────────────────────────────────────────────────────
def main() -> None:
    # Truncate log file at startup so each test run starts clean.
    try:
        open(LOG_FILE, "w").close()
    except OSError:
        pass

    try:
        server = http.server.HTTPServer((HOST, PORT), WebhookHandler)
    except OSError as exc:
        print(
            f"{RED}✗ Could not bind to {HOST}:{PORT} — {exc}{RST}\n"
            f"  Try: WEBHOOK_PORT=19877 python3 scripts/webhook-receiver.py",
            file=sys.stderr,
        )
        sys.exit(1)

    signal.signal(signal.SIGTERM, _make_shutdown(server))
    signal.signal(signal.SIGINT,  _make_shutdown(server))

    _banner()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        total = _event_count
        print(
            f"\n  {GRN}✓{RST} Stopped. "
            f"Total events captured: {BLD}{total}{RST}"
        )
        print(f"  {YLW}ℹ{RST} Log saved to: {LOG_FILE}\n")


if __name__ == "__main__":
    main()
