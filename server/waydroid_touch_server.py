#!/usr/bin/env python3
"""High-performance server daemon bridging Waydroid H.264 video and multi-touch to iOS client."""

from __future__ import annotations

import argparse
import json
import logging
import os
import queue
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from typing import Any, Dict, List, Optional, Set

from discovery import BonjourPublisher, get_lan_ip
from protocol import (
    GATEWAY_MSG_TYPE_PING,
    GATEWAY_MSG_TYPE_PONG,
    SC_CONTROL_MSG_TYPE_BACK_OR_SCREEN_ON,
    SC_CONTROL_MSG_TYPE_COLLAPSE_PANELS,
    SC_CONTROL_MSG_TYPE_EXPAND_NOTIFICATION_PANEL,
    SC_CONTROL_MSG_TYPE_EXPAND_SETTINGS_PANEL,
    SC_CONTROL_MSG_TYPE_INJECT_KEYCODE,
    SC_CONTROL_MSG_TYPE_INJECT_SCROLL_EVENT,
    SC_CONTROL_MSG_TYPE_INJECT_TEXT,
    SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT,
    TOUCH_PACKET_SIZE,
    TouchEvent,
    VideoPacket,
    serialize_pong,
)
from scrcpy_core import PRESETS, ScrcpyCore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("server")

WAYDROID_BIN = shutil.which("waydroid") or "/usr/bin/waydroid"


class WaydroidTouchServer:
    def __init__(
        self,
        host: str = "0.0.0.0",
        control_port: int = 8000,
        video_port: int = 8001,
        preset: str = "1080p",
        adb_target: Optional[str] = None,
    ) -> None:
        self.host = host
        self.control_port = control_port
        self.video_port = video_port
        self.preset = preset
        self.adb_target = adb_target

        self.core = ScrcpyCore(preset_name=preset, adb_serial=adb_target)
        self.publisher: Optional[BonjourPublisher] = None

        self._running = False
        self._control_server_sock: Optional[socket.socket] = None
        self._video_server_sock: Optional[socket.socket] = None

        self._video_clients: Set[socket.socket] = set()
        self._video_queues: Dict[socket.socket, queue.Queue] = {}
        self._clients_lock = threading.Lock()

        # Telemetry
        self.fps_counter = 0
        self.fps_last_time = time.time()
        self.current_fps = 0.0

    def start(self) -> None:
        self._running = True
        logger.info("Initializing Waydroid Touch Server...")

        # 1. Start ScrcpyCore
        if not self.core.start():
            logger.error("Failed to start ScrcpyCore. Retrying in background...")

        self.core.add_frame_subscriber(self._on_video_frame)

        # 2. Start Video Stream Server immediately
        self._video_server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._video_server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._video_server_sock.bind((self.host, self.video_port))
        self._video_server_sock.listen(5)
        threading.Thread(target=self._video_accept_loop, daemon=True).start()

        # 3. Start Control & HTTP Server immediately
        self._control_server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._control_server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._control_server_sock.bind((self.host, self.control_port))
        self._control_server_sock.listen(10)
        threading.Thread(target=self._control_accept_loop, daemon=True).start()

        # 4. Start Bonjour Publisher in background thread
        lan_ip = get_lan_ip()
        self.publisher = BonjourPublisher(
            service_name="Waydroid Remote",
            port=self.control_port,
            video_port=self.video_port,
            properties={
                "width": str(self.core.screen_width),
                "height": str(self.core.screen_height),
                "preset": self.preset,
            },
        )
        threading.Thread(target=self.publisher.start, daemon=True).start()

        logger.info("=" * 60)
        logger.info(" Waydroid Touch Server is ACTIVE!")
        logger.info(" LAN IP:        %s", lan_ip)
        logger.info(" Control/Touch: http://%s:%d", lan_ip, self.control_port)
        logger.info(" Video Stream:  tcp://%s:%d", lan_ip, self.video_port)
        logger.info(" Preset:        %s (%dx%d @ %dfps)", self.preset, self.core.screen_width, self.core.screen_height, self.core.preset.max_fps)
        logger.info(" Bonjour:       _waydroid-remote._tcp.local.")
        logger.info("=" * 60)

    def _on_video_frame(self, packet: VideoPacket) -> None:
        """Called by ScrcpyCore for every new H.264 frame."""
        # Calculate live FPS
        self.fps_counter += 1
        now = time.time()
        if now - self.fps_last_time >= 1.0:
            self.current_fps = self.fps_counter / (now - self.fps_last_time)
            self.fps_counter = 0
            self.fps_last_time = now

        data = packet.serialize_with_header()
        with self._clients_lock:
            for client_sock, q in list(self._video_queues.items()):
                try:
                    # Non-blocking put; drop old non-keyframes if client is slow to keep latency < 30ms!
                    if q.full():
                        try:
                            # Drop oldest frame
                            old_pkt = q.get_nowait()
                        except queue.Empty:
                            pass
                    q.put_nowait(data)
                except Exception as e:
                    logger.debug("Failed to queue video frame for client: %s", e)

    def _video_accept_loop(self) -> None:
        while self._running and self._video_server_sock:
            try:
                client_sock, addr = self._video_server_sock.accept()
                client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                # Minimize send buffer to avoid kernel socket buffering latency
                client_sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
                logger.info("New video client connected: %s", addr)

                q: queue.Queue = queue.Queue(maxsize=3)
                # Send cached SPS/PPS config frame first if available
                if self.core.cached_config_packet:
                    q.put(self.core.cached_config_packet.serialize_with_header())

                with self._clients_lock:
                    self._video_clients.add(client_sock)
                    self._video_queues[client_sock] = q

                threading.Thread(target=self._video_sender_worker, args=(client_sock, q), daemon=True).start()
            except Exception as e:
                if self._running:
                    logger.debug("Video accept error: %s", e)
                break

    def _video_sender_worker(self, client_sock: socket.socket, q: queue.Queue) -> None:
        """Pushes queued frames over TCP to iOS client as fast as network permits."""
        try:
            while self._running:
                data = q.get(timeout=2.0)
                client_sock.sendall(data)
        except (socket.timeout, queue.Empty):
            pass
        except Exception as e:
            logger.debug("Video client disconnected: %s", e)
        finally:
            with self._clients_lock:
                self._video_clients.discard(client_sock)
                self._video_queues.pop(client_sock, None)
            try:
                client_sock.close()
            except Exception:
                pass

    def _control_accept_loop(self) -> None:
        """Accepts control socket connections (both binary packet stream and HTTP REST requests)."""
        while self._running and self._control_server_sock:
            try:
                client_sock, addr = self._control_server_sock.accept()
                client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                threading.Thread(target=self._handle_control_client, args=(client_sock, addr), daemon=True).start()
            except Exception as e:
                if self._running:
                    logger.debug("Control accept error: %s", e)
                break

    def _handle_control_client(self, sock: socket.socket, addr: Any) -> None:
        """Determines if client is sending HTTP requests or binary packets."""
        sock.settimeout(None)
        try:
            # Peek first 4 bytes to check if it's an HTTP verb
            peek_data = sock.recv(4, socket.MSG_PEEK)
            if not peek_data:
                return

            if peek_data.startswith(b"GET ") or peek_data.startswith(b"POST"):
                self._handle_http_client(sock)
                return

            # Otherwise, it's a persistent low-latency binary control channel!
            logger.info("Active binary touch stream connected from %s", addr)
            buf = bytearray()
            while self._running:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)

                # Process all complete packets in buffer
                while len(buf) > 0:
                    msg_type = buf[0]

                    if msg_type == SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT:
                        if len(buf) < TOUCH_PACKET_SIZE:
                            break  # wait for full packet
                        packet_data = bytes(buf[:TOUCH_PACKET_SIZE])
                        del buf[:TOUCH_PACKET_SIZE]
                        event = TouchEvent.deserialize(packet_data)
                        if event:
                            self.core.inject_touch(event)

                    elif msg_type == SC_CONTROL_MSG_TYPE_INJECT_KEYCODE:
                        if len(buf) < 14:
                            break
                        action, keycode, repeat, metastate = struct.unpack(">BIII", buf[1:14])
                        del buf[:14]
                        self.core.inject_keycode(action, keycode, repeat, metastate)

                    elif msg_type == SC_CONTROL_MSG_TYPE_INJECT_TEXT:
                        if len(buf) < 5:
                            break
                        text_len = struct.unpack(">I", buf[1:5])[0]
                        if len(buf) < 5 + text_len:
                            break
                        text_bytes = bytes(buf[5 : 5 + text_len])
                        del buf[: 5 + text_len]
                        try:
                            text_str = text_bytes.decode("utf-8")
                            self.core.inject_text(text_str)
                        except UnicodeDecodeError:
                            pass

                    elif msg_type == SC_CONTROL_MSG_TYPE_BACK_OR_SCREEN_ON:
                        if len(buf) < 2:
                            break
                        action = buf[1]
                        del buf[:2]
                        self.core.inject_back()

                    elif msg_type in (
                        SC_CONTROL_MSG_TYPE_EXPAND_NOTIFICATION_PANEL,
                        SC_CONTROL_MSG_TYPE_EXPAND_SETTINGS_PANEL,
                        SC_CONTROL_MSG_TYPE_COLLAPSE_PANELS,
                    ):
                        del buf[:1]
                        self.core.inject_panel(msg_type)

                    elif msg_type == SC_CONTROL_MSG_TYPE_INJECT_SCROLL_EVENT:
                        if len(buf) < 21:
                            break
                        x, y, w, h, hscroll, vscroll, btns = struct.unpack(">BIIHHhhI", buf[:21])[1:]
                        del buf[:21]
                        self.core.inject_scroll(x, y, hscroll, vscroll)

                    elif msg_type == GATEWAY_MSG_TYPE_PING:
                        # Ping packet: 1 byte type + 8 bytes timestamp_ms
                        if len(buf) < 9:
                            break
                        ts = struct.unpack(">Q", buf[1:9])[0]
                        del buf[:9]
                        # Immediately echo back Pong packet for RTT latency measurement
                        sock.sendall(serialize_pong(ts))

                    else:
                        # Unknown packet type, skip 1 byte
                        del buf[:1]

        except (ConnectionResetError, BrokenPipeError, OSError):
            pass
        except Exception as e:
            logger.debug("Control client handler error: %s", e)
        finally:
            try:
                sock.close()
            except Exception:
                pass

    def _handle_http_client(self, sock: socket.socket) -> None:
        """Simple, fast HTTP handler for REST discovery and preset management."""
        try:
            req_data = sock.recv(8192).decode("utf-8", errors="replace")
            lines = req_data.split("\r\n")
            if not lines:
                return

            req_line = lines[0].split()
            if len(req_line) < 2:
                return

            method, path = req_line[0], req_line[1]

            def send_json(status_code: int, data: Any) -> None:
                body = json.dumps(data, ensure_ascii=False).encode("utf-8")
                header = (
                    f"HTTP/1.1 {status_code} OK\r\n"
                    f"Content-Type: application/json; charset=utf-8\r\n"
                    f"Content-Length: {len(body)}\r\n"
                    f"Access-Control-Allow-Origin: *\r\n"
                    f"Connection: close\r\n\r\n"
                ).encode("ascii")
                sock.sendall(header + body)

            if method == "GET" and path == "/api/status":
                status_info = self.get_status_info()
                send_json(200, status_info)

            elif method == "GET" and path == "/api/presets":
                presets_list = [
                    {"name": k, "max_size": v.max_size, "max_fps": v.max_fps, "bitrate": v.bitrate}
                    for k, v in PRESETS.items()
                ]
                send_json(200, {"current": self.preset, "available": presets_list})

            elif method == "POST" and path == "/api/presets":
                # Find body
                body_idx = req_data.find("\r\n\r\n")
                if body_idx != -1:
                    payload = json.loads(req_data[body_idx + 4 :])
                    target_preset = payload.get("preset")
                    if target_preset in PRESETS:
                        success = self.core.switch_preset(target_preset)
                        if success:
                            self.preset = target_preset
                            if self.publisher:
                                self.publisher.update_properties({"preset": self.preset})
                            send_json(200, {"ok": True, "preset": self.preset})
                            return
                send_json(400, {"error": "Invalid preset"})

            elif method == "GET" and path == "/api/apps":
                apps = self.get_installed_apps()
                send_json(200, {"apps": apps})

            elif method == "POST" and path == "/api/apps/launch":
                body_idx = req_data.find("\r\n\r\n")
                if body_idx != -1:
                    payload = json.loads(req_data[body_idx + 4 :])
                    pkg = payload.get("package")
                    if pkg:
                        subprocess.run([WAYDROID_BIN, "app", "launch", pkg], check=False)
                        send_json(200, {"ok": True, "launched": pkg})
                        return
                send_json(400, {"error": "Invalid package"})

            elif method == "POST" and path == "/api/power":
                body_idx = req_data.find("\r\n\r\n")
                if body_idx != -1:
                    payload = json.loads(req_data[body_idx + 4 :])
                    action = payload.get("action")
                    if action in ("start", "stop", "open"):
                        cmd = {"start": ["session", "start"], "stop": ["session", "stop"], "open": ["show-full-ui"]}[action]
                        subprocess.run([WAYDROID_BIN, *cmd], check=False)
                        send_json(200, {"ok": True, "action": action})
                        return
                send_json(400, {"error": "Invalid power action"})

            else:
                send_json(404, {"error": "Not Found"})

        except Exception as e:
            logger.debug("HTTP handle error: %s", e)
        finally:
            try:
                sock.close()
            except Exception:
                pass

    def get_status_info(self) -> Dict[str, Any]:
        """Returns server runtime status."""
        waydroid_status = "UNKNOWN"
        try:
            out = subprocess.check_output([WAYDROID_BIN, "status"], text=True, timeout=3)
            for line in out.splitlines():
                if "Session:" in line:
                    waydroid_status = line.split(":", 1)[1].strip()
        except Exception:
            pass

        return {
            "ok": True,
            "device": self.core.device_name,
            "session": waydroid_status,
            "width": self.core.screen_width,
            "height": self.core.screen_height,
            "preset": self.preset,
            "fps": round(self.current_fps, 1),
            "bitrate": self.core.preset.bitrate,
            "video_clients": len(self._video_clients),
            "video_port": self.video_port,
            "control_port": self.control_port,
        }

    def get_installed_apps(self) -> List[Dict[str, str]]:
        """Parses installed Waydroid apps."""
        apps: List[Dict[str, str]] = []
        try:
            out = subprocess.check_output([WAYDROID_BIN, "app", "list"], text=True, timeout=5)
            pattern = re.compile(r"^\s*(?:name|app)\s*:\s*(.*?)\s*\(([^()]+)\)\s*$", re.I)
            for line in out.splitlines():
                m = pattern.match(line)
                if m:
                    apps.append({"name": m.group(1), "package": m.group(2)})
        except Exception as e:
            logger.debug("Error listing apps: %s", e)
        return sorted(apps, key=lambda a: a["name"].lower())

    def stop(self) -> None:
        """Stops server and cleans up resources."""
        self._running = False
        if self.publisher:
            self.publisher.stop()
        self.core.stop()

        if self._video_server_sock:
            try:
                self._video_server_sock.close()
            except Exception:
                pass

        if self._control_server_sock:
            try:
                self._control_server_sock.close()
            except Exception:
                pass

        with self._clients_lock:
            for s in self._video_clients:
                try:
                    s.close()
                except Exception:
                    pass
            self._video_clients.clear()
            self._video_queues.clear()

        logger.info("Waydroid Touch Server stopped.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Waydroid Low-Latency Touch & Stream Server")
    parser.add_argument("--host", default="0.0.0.0", help="Bind address (default 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8000, help="Control & Touch port (default 8000)")
    parser.add_argument("--video-port", type=int, default=8001, help="Video stream port (default 8001)")
    parser.add_argument("--preset", default="1080p", choices=list(PRESETS.keys()), help="Default preset")
    parser.add_argument("--adb", default=None, help="ADB target e.g. 192.168.240.112:5555")
    args = parser.parse_args()

    server = WaydroidTouchServer(
        host=args.host,
        control_port=args.port,
        video_port=args.video_port,
        preset=args.preset,
        adb_target=args.adb,
    )

    def handle_sig(sig: int, frame: Any) -> None:
        print("\nShutting down server...")
        server.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    server.start()

    while True:
        try:
            time.sleep(1)
        except (KeyboardInterrupt, SystemExit):
            break

    server.stop()


if __name__ == "__main__":
    main()
