#!/usr/bin/env python3
"""Small LAN server that exposes safe Waydroid controls to the iOS client."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


WAYDROID = shutil.which("waydroid") or "/usr/bin/waydroid"
SUDO = shutil.which("sudo")
DEFAULT_KEY = os.environ.get("WAYDROID_REMOTE_API_KEY", "change-me")
MAX_BODY_BYTES = 32 * 1024
KEY_PATTERN = re.compile(r"^[A-Z0-9_]+$")


class CommandError(RuntimeError):
    def __init__(self, message: str, output: str = "") -> None:
        super().__init__(message)
        self.output = output


def run_waydroid(args: list[str], timeout: float = 15.0, binary: str = WAYDROID) -> bytes:
    command = [binary, *args]
    if args and args[0] == "shell":
        # `waydroid shell` enters the container through LXC and requires root
        # on many distributions. The Android command must come after `--`,
        # otherwise flags such as screencap's `-p` are parsed by Waydroid.
        shell_command = ["shell", "--", *args[1:]]
        if os.geteuid() == 0:
            command = [binary, *shell_command]
        elif SUDO:
            command = [SUDO, "-n", binary, *shell_command]
        else:
            command = [binary, *shell_command]
    try:
        completed = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CommandError(str(exc)) from exc

    if completed.returncode != 0:
        output = completed.stdout.decode("utf-8", errors="replace").strip()
        raise CommandError(f"waydroid exited with {completed.returncode}", output)
    return completed.stdout


def parse_status(output: bytes) -> dict[str, Any]:
    values: dict[str, str] = {}
    for line in output.decode("utf-8", errors="replace").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip().lower().replace(" ", "_")] = value.strip()

    return {
        "session": values.get("session", "UNKNOWN"),
        "container": values.get("container", "UNKNOWN"),
        "vendor_type": values.get("vendor_type", "UNKNOWN"),
        "ip_address": values.get("ip_address"),
        "session_user": values.get("session_user"),
        "wayland_display": values.get("wayland_display"),
    }


def parse_apps(output: bytes) -> list[dict[str, str]]:
    apps: list[dict[str, str]] = []
    pattern = re.compile(r"^\s*(?:name|app)\s*:\s*(.*?)\s*\(([^()]+)\)\s*$", re.I)
    for line in output.decode("utf-8", errors="replace").splitlines():
        match = pattern.match(line)
        if match:
            apps.append({"display_name": match.group(1), "package_name": match.group(2)})

    return sorted(apps, key=lambda item: item["display_name"].lower())


def android_text(value: str) -> str:
    # Android's input utility uses %s for spaces and interprets a small set of
    # shell-like characters. Keep this deliberately conservative.
    return (
        value[:500]
        .replace("%", "%25")
        .replace(" ", "%s")
        .replace("&", "%26")
        .replace("<", "%3C")
        .replace(">", "%3E")
        .replace("'", "%27")
        .replace('"', "%22")
    )


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "WaydroidRemote/1.0"

    @property
    def config(self) -> dict[str, Any]:
        return self.server.config  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        print(f"[{self.address_string()}] {format % args}")

    def send_json(self, status: int, payload: Any) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json(status, {"error": message})

    def authorized(self) -> bool:
        expected = str(self.config["api_key"])
        supplied = self.headers.get("X-API-Key", "")
        return bool(expected) and supplied == expected

    def read_json(self) -> dict[str, Any]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("Content-Length không hợp lệ") from exc
        if length <= 0 or length > MAX_BODY_BYTES:
            raise ValueError("Body quá lớn hoặc trống")
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise ValueError("JSON không hợp lệ") from exc
        if not isinstance(payload, dict):
            raise ValueError("JSON phải là object")
        return payload

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self.send_json(HTTPStatus.OK, {"ok": True, "service": "waydroid-remote"})
            return
        if not self.authorized():
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "API key không đúng")
            return

        try:
            if self.path == "/api/status":
                self.send_json(HTTPStatus.OK, parse_status(run_waydroid(["status"])))
            elif self.path == "/api/apps":
                self.send_json(HTTPStatus.OK, parse_apps(run_waydroid(["app", "list"])))
            elif self.path == "/api/screenshot":
                raw = run_waydroid(["shell", "screencap", "-p"], timeout=20)
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(raw)
            else:
                self.send_error_json(HTTPStatus.NOT_FOUND, "Endpoint không tồn tại")
        except CommandError as exc:
            self.send_error_json(HTTPStatus.BAD_GATEWAY, f"Waydroid: {exc.output or exc}")

    def do_POST(self) -> None:  # noqa: N802
        if not self.authorized():
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "API key không đúng")
            return

        try:
            payload = self.read_json()
            if self.path == "/api/power":
                self.handle_power(payload)
            elif self.path == "/api/apps/launch":
                self.handle_launch(payload)
            elif self.path == "/api/input":
                self.handle_input(payload)
            else:
                self.send_error_json(HTTPStatus.NOT_FOUND, "Endpoint không tồn tại")
        except ValueError as exc:
            self.send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
        except CommandError as exc:
            self.send_error_json(HTTPStatus.BAD_GATEWAY, f"Waydroid: {exc.output or exc}")

    def handle_power(self, payload: dict[str, Any]) -> None:
        action = payload.get("action")
        commands = {
            "start": ["session", "start"],
            "stop": ["session", "stop"],
            "open": ["show-full-ui"],
        }
        if action not in commands:
            raise ValueError("action phải là start, stop hoặc open")
        run_waydroid(commands[action], timeout=30)
        self.send_json(HTTPStatus.OK, {"ok": True, "action": action})

    def handle_launch(self, payload: dict[str, Any]) -> None:
        package = payload.get("package")
        if not isinstance(package, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", package):
            raise ValueError("package không hợp lệ")
        run_waydroid(["app", "launch", package], timeout=30)
        self.send_json(HTTPStatus.OK, {"ok": True, "package": package})

    def handle_input(self, payload: dict[str, Any]) -> None:
        input_type = payload.get("type")
        args: list[str]

        if input_type == "tap":
            x, y = self.coordinate_pair(payload, "x", "y")
            args = ["shell", "input", "tap", str(x), str(y)]
        elif input_type == "swipe":
            x1, y1 = self.coordinate_pair(payload, "x1", "y1")
            x2, y2 = self.coordinate_pair(payload, "x2", "y2")
            duration = self.integer(payload, "duration", minimum=1, maximum=10_000)
            args = ["shell", "input", "swipe", str(x1), str(y1), str(x2), str(y2), str(duration)]
        elif input_type == "keyevent":
            key = payload.get("key")
            if not isinstance(key, str):
                raise ValueError("key không hợp lệ")
            key = key.upper()
            if not KEY_PATTERN.fullmatch(key):
                raise ValueError("key không hợp lệ")
            args = ["shell", "input", "keyevent", key]
        elif input_type == "text":
            text = payload.get("text")
            if not isinstance(text, str) or not text:
                raise ValueError("text không được trống")
            args = ["shell", "input", "text", android_text(text)]
        else:
            raise ValueError("type phải là tap, swipe, keyevent hoặc text")

        run_waydroid(args, timeout=15)
        self.send_json(HTTPStatus.OK, {"ok": True})

    @staticmethod
    def integer(payload: dict[str, Any], key: str, minimum: int = 0, maximum: int = 100_000) -> int:
        value = payload.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
            raise ValueError(f"{key} không hợp lệ")
        return value

    def coordinate_pair(self, payload: dict[str, Any], x_key: str, y_key: str) -> tuple[int, int]:
        return self.integer(payload, x_key), self.integer(payload, y_key)


def main() -> None:
    parser = argparse.ArgumentParser(description="LAN API để điều khiển Waydroid từ iPhone")
    parser.add_argument("--host", default="0.0.0.0", help="Interface bind, mặc định 0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--api-key", default=DEFAULT_KEY)
    args = parser.parse_args()

    if args.api_key == "change-me":
        print("Cảnh báo: đang dùng API key mặc định 'change-me'. Hãy dùng --api-key hoặc WAYDROID_REMOTE_API_KEY.")

    server = ThreadingHTTPServer((args.host, args.port), RequestHandler)
    server.config = {"api_key": args.api_key}  # type: ignore[attr-defined]
    print(f"Waydroid Remote listening on http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
