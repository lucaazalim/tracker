#!/usr/bin/env python3
"""Minimal Tracker/Overland receiver for local development, with a live dashboard.

Accepts uploads, answers {"result": "ok"} so the app removes the batch from its queue,
and streams everything it receives to a web page with a live feed and a map.

    python3 scripts/dev-receiver.py [--port 8080] [--token SECRET] [--set '{"send_interval": "1m"}']

Point Tracker at http://<your-mac-ip>:8080/ (or http://localhost:8080/ from the Simulator),
then open the same address in a browser to watch data arrive.

The dashboard has no authentication and shows your location to anyone who can reach this
port. Use --host 127.0.0.1 to keep it to this machine.
"""

from __future__ import annotations

import argparse
import json
import socket
import threading
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_EVENTS = 300
MAX_BODY_PREVIEW = 20_000
KEEPALIVE_SECONDS = 15
DASHBOARD_HTML = Path(__file__).with_name("dev-receiver.html")


class EventHub:
    """Keeps recent requests and wakes up streaming clients when a new one arrives."""

    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._events: deque[dict] = deque(maxlen=MAX_EVENTS)
        self._sequence = 0

    def publish(self, event: dict) -> None:
        with self._condition:
            self._sequence += 1
            event["id"] = self._sequence
            self._events.append(event)
            self._condition.notify_all()

    def after(self, last_id: int, timeout: float) -> list[dict]:
        """Events newer than last_id, waiting up to timeout seconds for one to arrive."""
        with self._condition:
            if self._sequence <= last_id:
                self._condition.wait(timeout)
            return [event for event in self._events if event["id"] > last_id]


def extract_points(payload: object) -> tuple[list[dict], dict | None]:
    """Normalizes GeoJSON batches and OwnTracks objects into simple point dicts."""
    if isinstance(payload, dict) and payload.get("_type") == "location":
        return [owntracks_point(payload)], None
    if isinstance(payload, dict) and isinstance(payload.get("locations"), list):
        points = [geojson_point(record) for record in payload["locations"] if isinstance(record, dict)]
        current = payload.get("current")
        return points, geojson_point(current) if isinstance(current, dict) else None
    return [], None


def geojson_point(feature: dict) -> dict:
    properties = feature.get("properties") or {}
    coordinates = (feature.get("geometry") or {}).get("coordinates") or [None, None]
    return {
        "kind": properties.get("action") or "location",
        "lat": coordinates[1] if len(coordinates) > 1 else None,
        "lon": coordinates[0],
        "time": properties.get("timestamp"),
        "accuracy": properties.get("horizontal_accuracy"),
        "speed": properties.get("speed"),
        "battery": properties.get("battery_level"),
        "motion": properties.get("motion"),
        "device": properties.get("device_id"),
    }


def owntracks_point(location: dict) -> dict:
    timestamp = location.get("tst")
    speed = location.get("vel")
    battery = location.get("batt")
    return {
        "kind": "location",
        "lat": location.get("lat"),
        "lon": location.get("lon"),
        "time": datetime.fromtimestamp(timestamp, timezone.utc).isoformat() if isinstance(timestamp, (int, float)) else None,
        "accuracy": location.get("acc"),
        "speed": speed / 3.6 if isinstance(speed, (int, float)) else None,
        "battery": battery / 100 if isinstance(battery, (int, float)) else None,
        "motion": None,
        "device": location.get("topic"),
    }


def local_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 80))  # No packets are sent; this just picks the outgoing interface.
            return probe.getsockname()[0]
    except OSError:
        return "localhost"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0", help="Interface to listen on (default: all)")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--token", help="Require 'Authorization: Bearer <token>'")
    parser.add_argument("--set", help="JSON object returned as 'set' to test remote configuration")
    parser.add_argument("--fail", action="store_true", help="Answer with an error to test retries")
    args = parser.parse_args()
    remote_set = json.loads(args.set) if args.set else None
    hub = EventHub()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = self.path.split("?")[0]
            if path == "/events":
                return self.stream_events()
            if path in ("/", "/index.html"):
                return self.respond_bytes(200, DASHBOARD_HTML.read_bytes(), "text/html; charset=utf-8")
            self.respond(404, {"error": "not found"})

        def do_POST(self) -> None:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            stamp = datetime.now().strftime("%H:%M:%S")
            event = {
                "received": datetime.now(timezone.utc).isoformat(),
                "path": self.path,
                "client": self.client_address[0],
                "bytes": len(body),
                "points": [],
                "current": None,
                "body": body[:MAX_BODY_PREVIEW].decode("utf-8", "replace"),
            }

            if args.token and self.headers.get("Authorization") != f"Bearer {args.token}":
                print(f"[{stamp}] {self.path} rejected: bad or missing token")
                return self.finish_request(event, 401, {"error": "unauthorized"})

            try:
                payload = json.loads(body or b"null")
            except json.JSONDecodeError:
                print(f"[{stamp}] {self.path} invalid JSON: {body[:200]!r}")
                return self.finish_request(event, 400, {"error": "invalid JSON"})

            event["points"], event["current"] = extract_points(payload)
            event["body"] = json.dumps(payload, indent=2)[:MAX_BODY_PREVIEW]
            extras = ["current"] if event["current"] else []
            print(f"[{stamp}] {self.path} {len(event['points'])} records {extras or ''}")

            if args.fail:
                return self.finish_request(event, 500, {"error": "simulated failure"})
            response = {"result": "ok"}
            if remote_set:
                response["set"] = remote_set
            self.finish_request(event, 200, response)

        def finish_request(self, event: dict, status: int, response: dict) -> None:
            event["status"] = status
            event["response"] = response
            hub.publish(event)
            self.respond(status, response)

        def stream_events(self) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            last_id = int(self.headers.get("Last-Event-ID") or 0)
            try:
                while True:
                    events = hub.after(last_id, KEEPALIVE_SECONDS)
                    if not events:
                        self.wfile.write(b": keepalive\n\n")
                    for event in events:
                        last_id = event["id"]
                        self.wfile.write(f"id: {last_id}\ndata: {json.dumps(event)}\n\n".encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

        def respond(self, status: int, payload: object) -> None:
            self.respond_bytes(status, json.dumps(payload).encode(), "application/json")

        def respond_bytes(self, status: int, data: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *_: object) -> None:
            pass

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    host = local_ip() if args.host == "0.0.0.0" else args.host
    print(f"Receiving on http://{host}:{args.port}/  (dashboard at the same address)")
    server.serve_forever()


if __name__ == "__main__":
    main()
