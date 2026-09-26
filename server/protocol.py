"""Binary protocol definitions for scrcpy control channel and video streaming."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Optional, Tuple

# Scrcpy control message types
SC_CONTROL_MSG_TYPE_INJECT_KEYCODE = 0
SC_CONTROL_MSG_TYPE_INJECT_TEXT = 1
SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT = 2
SC_CONTROL_MSG_TYPE_INJECT_SCROLL_EVENT = 3
SC_CONTROL_MSG_TYPE_BACK_OR_SCREEN_ON = 4
SC_CONTROL_MSG_TYPE_EXPAND_NOTIFICATION_PANEL = 5
SC_CONTROL_MSG_TYPE_EXPAND_SETTINGS_PANEL = 6
SC_CONTROL_MSG_TYPE_COLLAPSE_PANELS = 7
SC_CONTROL_MSG_TYPE_GET_CLIPBOARD = 8
SC_CONTROL_MSG_TYPE_SET_CLIPBOARD = 9
SC_CONTROL_MSG_TYPE_SET_DISPLAY_POWER = 10
SC_CONTROL_MSG_TYPE_ROTATE_DEVICE = 11

# Android MotionEvent actions
AMOTION_EVENT_ACTION_DOWN = 0
AMOTION_EVENT_ACTION_UP = 1
AMOTION_EVENT_ACTION_MOVE = 2
AMOTION_EVENT_ACTION_CANCEL = 3
AMOTION_EVENT_ACTION_OUTSIDE = 4
AMOTION_EVENT_ACTION_POINTER_DOWN = 5
AMOTION_EVENT_ACTION_POINTER_UP = 6

# Android KeyEvent actions
AKEY_EVENT_ACTION_DOWN = 0
AKEY_EVENT_ACTION_UP = 1

# Android keycodes
AKEYCODE_HOME = 3
AKEYCODE_BACK = 4
AKEYCODE_VOLUME_UP = 24
AKEYCODE_VOLUME_DOWN = 25
AKEYCODE_POWER = 26
AKEYCODE_TAB = 61
AKEYCODE_ENTER = 66
AKEYCODE_DEL = 67  # Backspace
AKEYCODE_ESCAPE = 111
AKEYCODE_FORWARD_DEL = 112
AKEYCODE_APP_SWITCH = 187  # Recent apps

# Motion event buttons
AMOTION_EVENT_BUTTON_PRIMARY = 1

# Packet sizes
TOUCH_PACKET_SIZE = 32
KEYCODE_PACKET_SIZE = 14
BACK_PACKET_SIZE = 2
VIDEO_HEADER_SIZE = 12

# Custom gateway ping/pong packet type (for latency measurement)
# Format: type (1 byte = 0xFE/0xFF), timestamp_ms (8 bytes uint64) -> 9 bytes total
GATEWAY_MSG_TYPE_PING = 0xFE
GATEWAY_MSG_TYPE_PONG = 0xFF


@dataclass
class TouchEvent:
    action: int
    pointer_id: int
    x: int
    y: int
    screen_width: int
    screen_height: int
    pressure: float = 1.0
    action_button: int = AMOTION_EVENT_BUTTON_PRIMARY
    buttons: int = AMOTION_EVENT_BUTTON_PRIMARY

    def serialize(self) -> bytes:
        """Serializes touch event into 32-byte scrcpy binary format.

        Byte layout:
        0: Type (2 = INJECT_TOUCH_EVENT)
        1: Action (DOWN, UP, MOVE, POINTER_DOWN, POINTER_UP)
        2..9: Pointer ID (uint64 big-endian)
        10..13: X coordinate (uint32 big-endian)
        14..17: Y coordinate (uint32 big-endian)
        18..19: Screen Width (uint16 big-endian)
        20..21: Screen Height (uint16 big-endian)
        22..23: Pressure (uint16 big-endian, 0..65535)
        24..27: Action button (uint32 big-endian)
        28..31: Buttons (uint32 big-endian)
        """
        clamped_pressure = max(0.0, min(1.0, self.pressure))
        pressure_int = int(clamped_pressure * 0xFFFF)

        return struct.pack(
            ">BBQIIHHHII",
            SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT,
            self.action & 0xFF,
            self.pointer_id,
            self.x,
            self.y,
            self.screen_width,
            self.screen_height,
            pressure_int,
            self.action_button,
            self.buttons,
        )

    @classmethod
    def deserialize(cls, data: bytes) -> Optional[TouchEvent]:
        if len(data) < TOUCH_PACKET_SIZE:
            return None
        msg_type, action, pointer_id, x, y, width, height, pressure_int, action_btn, btns = struct.unpack(
            ">BBQIIHHHII", data[:TOUCH_PACKET_SIZE]
        )
        if msg_type != SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT:
            return None
        return cls(
            action=action,
            pointer_id=pointer_id,
            x=x,
            y=y,
            screen_width=width,
            screen_height=height,
            pressure=pressure_int / 65535.0,
            action_button=action_btn,
            buttons=btns,
        )


def serialize_keycode(action: int, keycode: int, repeat: int = 0, metastate: int = 0) -> bytes:
    """Serializes keycode event into 14-byte scrcpy binary format."""
    return struct.pack(
        ">BBIII",
        SC_CONTROL_MSG_TYPE_INJECT_KEYCODE,
        action & 0xFF,
        keycode,
        repeat,
        metastate,
    )


def serialize_text(text: str) -> bytes:
    """Serializes UTF-8 text injection into scrcpy binary format (1 + 4 + N bytes)."""
    raw_bytes = text.encode("utf-8")[:300]
    return struct.pack(">BI", SC_CONTROL_MSG_TYPE_INJECT_TEXT, len(raw_bytes)) + raw_bytes


def serialize_back_or_screen_on(action: int = AKEY_EVENT_ACTION_UP) -> bytes:
    """Serializes Back / Screen On command (2 bytes)."""
    return struct.pack(">BB", SC_CONTROL_MSG_TYPE_BACK_OR_SCREEN_ON, action & 0xFF)


def serialize_panel_command(msg_type: int) -> bytes:
    """Serializes 1-byte panel/system commands (e.g. expand/collapse notification)."""
    return struct.pack(">B", msg_type & 0xFF)


def serialize_scroll(x: int, y: int, width: int, height: int, hscroll: int, vscroll: int, buttons: int = 0) -> bytes:
    """Serializes scroll event into 21-byte scrcpy format."""
    return struct.pack(
        ">BIIHHhhI",
        SC_CONTROL_MSG_TYPE_INJECT_SCROLL_EVENT,
        x,
        y,
        width,
        height,
        hscroll,
        vscroll,
        buttons,
    )


def serialize_ping(timestamp_ms: int) -> bytes:
    return struct.pack(">BQ", GATEWAY_MSG_TYPE_PING, timestamp_ms)


def serialize_pong(timestamp_ms: int) -> bytes:
    return struct.pack(">BQ", GATEWAY_MSG_TYPE_PONG, timestamp_ms)


@dataclass
class VideoPacket:
    pts: int
    is_config: bool
    is_key_frame: bool
    data: bytes

    @property
    def packet_size(self) -> int:
        return len(self.data)

    def serialize_with_header(self) -> bytes:
        """Serializes 12-byte header + raw NAL payload.

        Header:
        - 8 bytes: PTS (bits 0..60), config flag (bit 62), keyframe flag (bit 61)
        - 4 bytes: packet size (uint32 big-endian)
        Followed by raw packet payload.
        """
        pts_flags = self.pts & ((1 << 61) - 1)
        if self.is_config:
            pts_flags |= (1 << 62)
        if self.is_key_frame:
            pts_flags |= (1 << 61)

        header = struct.pack(">QI", pts_flags, len(self.data))
        return header + self.data
