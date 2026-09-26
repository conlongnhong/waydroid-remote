"""Core supervisor for Waydroid and scrcpy-server lifecycle and streaming."""

from __future__ import annotations

import logging
import os
import re
import shutil
import socket
import struct
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Tuple

from protocol import (
    AKEY_EVENT_ACTION_DOWN,
    AKEY_EVENT_ACTION_UP,
    AKEYCODE_BACK,
    SC_CONTROL_MSG_TYPE_BACK_OR_SCREEN_ON,
    SC_CONTROL_MSG_TYPE_COLLAPSE_PANELS,
    SC_CONTROL_MSG_TYPE_EXPAND_NOTIFICATION_PANEL,
    SC_CONTROL_MSG_TYPE_EXPAND_SETTINGS_PANEL,
    TouchEvent,
    VideoPacket,
    serialize_back_or_screen_on,
    serialize_keycode,
    serialize_panel_command,
    serialize_scroll,
    serialize_text,
)

logger = logging.getLogger("scrcpy_core")

WAYDROID_BIN = shutil.which("waydroid") or "/usr/bin/waydroid"
ADB_BIN = shutil.which("adb") or "/usr/bin/adb"
SCRCPY_SERVER_HOST_PATH = "/usr/share/scrcpy/scrcpy-server"
SCRCPY_SERVER_DEVICE_PATH = "/data/local/tmp/scrcpy-server.jar"


@dataclass
class Preset:
    name: str
    max_size: int  # 0 for unlimited / native
    max_fps: int
    bitrate: int  # in bps, e.g. 8_000_000


PRESETS: Dict[str, Preset] = {
    "720p": Preset(name="720p", max_size=720, max_fps=60, bitrate=4_000_000),
    "1080p": Preset(name="1080p", max_size=1080, max_fps=60, bitrate=8_000_000),
    "native": Preset(name="native", max_size=0, max_fps=60, bitrate=12_000_000),
    "native-90fps": Preset(name="native-90fps", max_size=0, max_fps=90, bitrate=16_000_000),
    "native-120fps": Preset(name="native-120fps", max_size=0, max_fps=120, bitrate=20_000_000),
}


def read_exact(sock: socket.socket, count: int) -> bytes:
    """Reads exact number of bytes from socket or raises EOFError."""
    buf = bytearray()
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise EOFError("Socket closed prematurely")
        buf.extend(chunk)
    return bytes(buf)


class ScrcpyCore:
    """Orchestrates Waydroid detection, ADB setup, scrcpy-server connection,

    video demuxing, and binary input injection.
    """

    def __init__(
        self,
        preset_name: str = "1080p",
        adb_serial: Optional[str] = None,
        reverse_port: int = 27183,
    ) -> None:
        self.preset_name = preset_name
        self.preset = PRESETS.get(preset_name, PRESETS["1080p"])
        self.adb_serial = adb_serial
        self.reverse_port = reverse_port
        self.scid = "499b123d"

        self.device_name: str = "Waydroid"
        self.screen_width: int = 1920
        self.screen_height: int = 1080
        self.codec: str = "h264"

        self.cached_config_packet: Optional[VideoPacket] = None  # SPS/PPS
        self._video_sock: Optional[socket.socket] = None
        self._control_sock: Optional[socket.socket] = None
        self._server_proc: Optional[subprocess.Popen] = None
        self._stop_event = threading.Event()
        self._reader_thread: Optional[threading.Thread] = None

        self._frame_subscribers: List[Callable[[VideoPacket], None]] = []
        self._subscribers_lock = threading.Lock()
        self._control_lock = threading.Lock()

    def add_frame_subscriber(self, callback: Callable[[VideoPacket], None]) -> None:
        with self._subscribers_lock:
            if callback not in self._frame_subscribers:
                self._frame_subscribers.append(callback)

    def remove_frame_subscriber(self, callback: Callable[[VideoPacket], None]) -> None:
        with self._subscribers_lock:
            if callback in self._frame_subscribers:
                self._frame_subscribers.remove(callback)

    def detect_waydroid_ip(self) -> str:
        """Finds Waydroid container IP via waydroid status or fallback."""
        try:
            out = subprocess.check_output([WAYDROID_BIN, "status"], text=True, timeout=5)
            for line in out.splitlines():
                if "IP address:" in line:
                    ip = line.split(":", 1)[1].strip()
                    if ip and ip != "None":
                        return ip
        except Exception as e:
            logger.debug("waydroid status IP lookup failed: %s", e)

        # Fallback to default subnet
        return "192.168.240.112"

    def ensure_adb_connected(self) -> str:
        """Ensures ADB server is running and connected to Waydroid."""
        if not self.adb_serial:
            ip = self.detect_waydroid_ip()
            self.adb_serial = f"{ip}:5555"

        # Ensure container is active and not frozen
        try:
            status_out = subprocess.check_output([WAYDROID_BIN, "status"], text=True, timeout=3)
            if "FROZEN" in status_out:
                logger.info("Unfreezing Waydroid container...")
                subprocess.run(["sudo", "-n", WAYDROID_BIN, "container", "unfreeze"], check=False, timeout=3.0)
        except Exception:
            pass

        logger.info("Connecting ADB to %s...", self.adb_serial)
        subprocess.run([ADB_BIN, "start-server"], check=False)
        subprocess.run([ADB_BIN, "connect", self.adb_serial], check=False, stdout=subprocess.DEVNULL)

        # Check authorization
        try:
            devices_out = subprocess.check_output([ADB_BIN, "devices"], text=True, timeout=3.0)
            if f"{self.adb_serial}\tunauthorized" in devices_out:
                logger.warning("ADB device %s is unauthorized. Authorizing via waydroid shell...", self.adb_serial)
                pubkey_path = os.path.expanduser("~/.android/adbkey.pub")
                if os.path.exists(pubkey_path):
                    with open(pubkey_path, "r") as f:
                        key = f.read().strip()
                    auth_cmd = (
                        f"echo '{key}' >> /data/misc/adb/adb_keys && "
                        "chown system:shell /data/misc/adb/adb_keys && "
                        "chmod 640 /data/misc/adb/adb_keys"
                    )
                    subprocess.run(
                        ["sudo", "-n", WAYDROID_BIN, "shell", "--", "sh", "-c", auth_cmd],
                        check=False,
                        timeout=5.0,
                    )
                    subprocess.run(
                        ["sudo", "-n", WAYDROID_BIN, "shell", "--", "killall", "-9", "adbd"],
                        check=False,
                        timeout=3.0,
                    )
                    time.sleep(1)
                    subprocess.run([ADB_BIN, "connect", self.adb_serial], check=False, timeout=3.0)
        except Exception as ex:
            logger.error("Error during ADB check: %s", ex)

        # Ensure scrcpy-server.jar exists on device
        try:
            if os.path.exists(SCRCPY_SERVER_HOST_PATH):
                cat_cmd = f"cat > {SCRCPY_SERVER_DEVICE_PATH} && chmod 644 {SCRCPY_SERVER_DEVICE_PATH}"
                with open(SCRCPY_SERVER_HOST_PATH, "rb") as f:
                    jar_data = f.read()
                p = subprocess.run(
                    ["sudo", "-n", WAYDROID_BIN, "shell", "--", "sh", "-c", cat_cmd],
                    input=jar_data,
                    check=False,
                    timeout=5.0,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                if p.returncode != 0:
                    subprocess.run(
                        [ADB_BIN, "-s", self.adb_serial, "push", SCRCPY_SERVER_HOST_PATH, SCRCPY_SERVER_DEVICE_PATH],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=5.0,
                        check=False,
                    )
        except Exception as e:
            logger.error("Failed to ensure scrcpy-server on device: %s", e)

        return self.adb_serial

    def start(self) -> bool:
        """Starts scrcpy-server and begins reading frames and handling input."""
        self._stop_event.clear()
        self.ensure_adb_connected()

        # 1. Listen on reverse port
        listen_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listen_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listen_sock.bind(("127.0.0.1", self.reverse_port))
        listen_sock.listen(2)
        listen_sock.settimeout(8.0)

        # 2. Setup adb reverse
        reverse_name = f"localabstract:scrcpy_{self.scid}"
        subprocess.run(
            [ADB_BIN, "-s", self.adb_serial, "reverse", reverse_name, f"tcp:{self.reverse_port}"],
            check=True,
        )

        # 3. Construct scrcpy-server launch parameters
        scrcpy_args = [
            f"scid={self.scid}",
            "log_level=info",
            "audio=false",
            "cleanup=false",
            f"video_bit_rate={self.preset.bitrate}",
        ]
        if self.preset.max_size > 0:
            scrcpy_args.append(f"max_size={self.preset.max_size}")
        if self.preset.max_fps > 0:
            scrcpy_args.append(f"max_fps={self.preset.max_fps}")

        cmd = [
            ADB_BIN,
            "-s",
            self.adb_serial,
            "shell",
            f"CLASSPATH={SCRCPY_SERVER_DEVICE_PATH} app_process / com.genymobile.scrcpy.Server 4.1 "
            + " ".join(scrcpy_args),
        ]

        logger.info("Launching scrcpy-server (preset %s)...", self.preset.name)
        self._server_proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # 4. Accept video and control sockets
        try:
            self._video_sock, _ = listen_sock.accept()
            self._control_sock, _ = listen_sock.accept()
            listen_sock.close()
        except Exception as e:
            logger.error("Timed out waiting for scrcpy-server socket connection: %s", e)
            listen_sock.close()
            self.stop()
            return False

        # Set TCP_NODELAY on control socket for lowest touch latency
        self._control_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._video_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        # 5. Handshake on video socket:
        try:
            # 64-byte device name
            dev_bytes = read_exact(self._video_sock, 64)
            self.device_name = dev_bytes.rstrip(b"\x00").decode("utf-8", errors="replace")
            # 4-byte codec name
            codec_bytes = read_exact(self._video_sock, 4)
            self.codec = codec_bytes.decode("ascii", errors="replace")

            # 12-byte session header
            session_hdr = read_exact(self._video_sock, 12)
            if session_hdr[0] & 0x80:
                self.screen_width, self.screen_height = struct.unpack(">II", session_hdr[4:12])
                logger.info(
                    "Connected to %s (%s) resolution: %dx%d",
                    self.device_name,
                    self.codec,
                    self.screen_width,
                    self.screen_height,
                )
        except Exception as e:
            logger.error("Handshake failed with scrcpy-server: %s", e)
            self.stop()
            return False

        # 6. Start frame reader thread
        self._reader_thread = threading.Thread(target=self._read_video_loop, daemon=True)
        self._reader_thread.start()
        return True

    def _read_video_loop(self) -> None:
        """Reads video frames from scrcpy video socket and dispatches to subscribers."""
        logger.info("Video streaming loop active.")
        sock = self._video_sock
        if not sock:
            return

        while not self._stop_event.is_set():
            try:
                # 12-byte packet header
                hdr = read_exact(sock, 12)
                pts_flags, size = struct.unpack(">QI", hdr)

                # Check if it's a session configuration packet (resolution change)
                if hdr[0] & 0x80:
                    self.screen_width, self.screen_height = struct.unpack(">II", hdr[4:12])
                    logger.info("Screen resized dynamically to: %dx%d", self.screen_width, self.screen_height)
                    continue

                is_config = bool(pts_flags & (1 << 62))
                is_key = bool(pts_flags & (1 << 61))
                pts = pts_flags & ((1 << 61) - 1)

                data = read_exact(sock, size)
                packet = VideoPacket(pts=pts, is_config=is_config, is_key_frame=is_key, data=data)

                if is_config:
                    self.cached_config_packet = packet

                with self._subscribers_lock:
                    subscribers = list(self._frame_subscribers)

                for sub in subscribers:
                    try:
                        sub(packet)
                    except Exception as err:
                        logger.debug("Subscriber error: %s", err)

            except (EOFError, ConnectionResetError, BrokenPipeError, OSError):
                if not self._stop_event.is_set():
                    logger.warning("Scrcpy video stream disconnected.")
                break
            except Exception as e:
                logger.error("Unexpected error in video stream: %s", e)
                break

    def inject_touch(self, event: TouchEvent) -> bool:
        """Sends 32-byte binary touch event to scrcpy-server."""
        data = event.serialize()
        with self._control_lock:
            if not self._control_sock:
                return False
            try:
                self._control_sock.sendall(data)
                return True
            except Exception as e:
                logger.debug("Failed to send touch: %s", e)
                return False

    def inject_keycode(self, action: int, keycode: int, repeat: int = 0, metastate: int = 0) -> bool:
        """Sends keycode event (14 bytes)."""
        data = serialize_keycode(action, keycode, repeat, metastate)
        with self._control_lock:
            if not self._control_sock:
                return False
            try:
                self._control_sock.sendall(data)
                return True
            except Exception as e:
                logger.debug("Failed to send keycode: %s", e)
                return False

    def inject_text(self, text: str) -> bool:
        """Sends text injection event."""
        data = serialize_text(text)
        with self._control_lock:
            if not self._control_sock:
                return False
            try:
                self._control_sock.sendall(data)
                return True
            except Exception as e:
                logger.debug("Failed to send text: %s", e)
                return False

    def inject_back(self) -> bool:
        """Injects Back key press and release."""
        with self._control_lock:
            if not self._control_sock:
                return False
            try:
                self._control_sock.sendall(serialize_back_or_screen_on(AKEY_EVENT_ACTION_DOWN))
                self._control_sock.sendall(serialize_back_or_screen_on(AKEY_EVENT_ACTION_UP))
                return True
            except Exception:
                return False

    def inject_panel(self, msg_type: int) -> bool:
        """Expands/collapses notification or settings panels."""
        data = serialize_panel_command(msg_type)
        with self._control_lock:
            if not self._control_sock:
                return False
            try:
                self._control_sock.sendall(data)
                return True
            except Exception:
                return False

    def inject_scroll(self, x: int, y: int, hscroll: int, vscroll: int) -> bool:
        """Injects scroll event."""
        data = serialize_scroll(x, y, self.screen_width, self.screen_height, hscroll, vscroll)
        with self._control_lock:
            if not self._control_sock:
                return False
            try:
                self._control_sock.sendall(data)
                return True
            except Exception:
                return False

    def switch_preset(self, preset_name: str) -> bool:
        """Switches to a different resolution / framerate preset dynamically."""
        if preset_name not in PRESETS:
            return False
        logger.info("Switching preset from %s to %s...", self.preset_name, preset_name)
        self.preset_name = preset_name
        self.preset = PRESETS[preset_name]
        self.stop()
        time.sleep(0.3)
        return self.start()

    def stop(self) -> None:
        """Terminates scrcpy-server and closes sockets."""
        self._stop_event.set()
        with self._control_lock:
            if self._control_sock:
                try:
                    self._control_sock.close()
                except Exception:
                    pass
                self._control_sock = None

        if self._video_sock:
            try:
                self._video_sock.close()
            except Exception:
                pass
            self._video_sock = None

        if self._server_proc:
            try:
                self._server_proc.terminate()
                self._server_proc.wait(timeout=1.0)
            except Exception:
                try:
                    self._server_proc.kill()
                except Exception:
                    pass
            self._server_proc = None

        if self.adb_serial:
            reverse_name = f"localabstract:scrcpy_{self.scid}"
            subprocess.run(
                [ADB_BIN, "-s", self.adb_serial, "reverse", "--remove", reverse_name],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        logger.info("ScrcpyCore stopped.")
