import Foundation

// MARK: - Scrcpy Control Message Types
public enum ScrcpyControlMessageType: UInt8 {
    case injectKeycode = 0
    case injectText = 1
    case injectTouchEvent = 2
    case injectScrollEvent = 3
    case backOrScreenOn = 4
    case expandNotificationPanel = 5
    case expandSettingsPanel = 6
    case collapsePanels = 7
    case getClipboard = 8
    case setClipboard = 9
    case setDisplayPower = 10
    case rotateDevice = 11
}

// MARK: - Android MotionEvent Actions
public enum AndroidMotionEventAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
    case cancel = 3
    case outside = 4
    case pointerDown = 5
    case pointerUp = 6
}

// MARK: - Android KeyCodes
public enum AndroidKeyCode: UInt32 {
    case home = 3
    case back = 4
    case volumeUp = 24
    case volumeDown = 25
    case power = 26
    case tab = 61
    case enter = 66
    case backspace = 67
    case escape = 111
    case forwardDel = 112
    case appSwitch = 187 // Recent apps
}

// MARK: - Gateway Ping/Pong Types
public let GATEWAY_MSG_TYPE_PING: UInt8 = 0xFE
public let GATEWAY_MSG_TYPE_PONG: UInt8 = 0xFF

public enum ScrcpyProtocol {
    /// Creates a 32-byte binary touch packet for direct Android InputManager injection.
    ///
    /// Layout:
    /// - 0: type (2 = INJECT_TOUCH_EVENT)
    /// - 1: action (DOWN, UP, MOVE, POINTER_DOWN, POINTER_UP)
    /// - 2..9: pointer_id (UInt64 big endian)
    /// - 10..13: x (UInt32 big endian)
    /// - 14..17: y (UInt32 big endian)
    /// - 18..19: screen width (UInt16 big endian)
    /// - 20..21: screen height (UInt16 big endian)
    /// - 22..23: pressure (UInt16 big endian, 0..0xFFFF)
    /// - 24..27: action button (UInt32 big endian, 1 for primary)
    /// - 28..31: buttons (UInt32 big endian, 1 for primary)
    public static func makeTouchPacket(
        action: UInt8,
        pointerId: UInt64,
        x: UInt32,
        y: UInt32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        pressure: Float = 1.0,
        actionButton: UInt32 = 1,
        buttons: UInt32 = 1
    ) -> Data {
        var data = Data(capacity: 32)
        let type = ScrcpyControlMessageType.injectTouchEvent.rawValue
        data.append(type)
        data.append(action)

        var bePointerId = pointerId.bigEndian
        data.append(Data(bytes: &bePointerId, count: MemoryLayout<UInt64>.size))

        var beX = x.bigEndian
        data.append(Data(bytes: &beX, count: MemoryLayout<UInt32>.size))

        var beY = y.bigEndian
        data.append(Data(bytes: &beY, count: MemoryLayout<UInt32>.size))

        var beWidth = screenWidth.bigEndian
        data.append(Data(bytes: &beWidth, count: MemoryLayout<UInt16>.size))

        var beHeight = screenHeight.bigEndian
        data.append(Data(bytes: &beHeight, count: MemoryLayout<UInt16>.size))

        let clampedPressure = max(0.0, min(1.0, pressure))
        let pressureInt = UInt16(clampedPressure * Float(UInt16.max))
        var bePressure = pressureInt.bigEndian
        data.append(Data(bytes: &bePressure, count: MemoryLayout<UInt16>.size))

        var beActionButton = actionButton.bigEndian
        data.append(Data(bytes: &beActionButton, count: MemoryLayout<UInt32>.size))

        var beButtons = buttons.bigEndian
        data.append(Data(bytes: &beButtons, count: MemoryLayout<UInt32>.size))

        return data
    }

    /// Creates a 14-byte keycode packet.
    public static func makeKeycodePacket(
        action: UInt8,
        keycode: UInt32,
        repeatCount: UInt32 = 0,
        metastate: UInt32 = 0
    ) -> Data {
        var data = Data(capacity: 14)
        data.append(ScrcpyControlMessageType.injectKeycode.rawValue)
        data.append(action)

        var beKeycode = keycode.bigEndian
        data.append(Data(bytes: &beKeycode, count: MemoryLayout<UInt32>.size))

        var beRepeat = repeatCount.bigEndian
        data.append(Data(bytes: &beRepeat, count: MemoryLayout<UInt32>.size))

        var beMetastate = metastate.bigEndian
        data.append(Data(bytes: &beMetastate, count: MemoryLayout<UInt32>.size))

        return data
    }

    /// Creates a text injection packet (1 + 4 + N bytes).
    public static func makeTextPacket(text: String) -> Data {
        let utf8 = Array(text.utf8.prefix(300))
        var data = Data(capacity: 5 + utf8.count)
        data.append(ScrcpyControlMessageType.injectText.rawValue)

        var length = UInt32(utf8.count).bigEndian
        data.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        data.append(contentsOf: utf8)

        return data
    }

    /// Creates a Back or ScreenOn packet (2 bytes).
    public static func makeBackPacket(action: UInt8 = 1) -> Data {
        var data = Data(capacity: 2)
        data.append(ScrcpyControlMessageType.backOrScreenOn.rawValue)
        data.append(action)
        return data
    }

    /// Creates a 1-byte panel action packet (Notification, Settings, Collapse).
    public static func makePanelPacket(type: ScrcpyControlMessageType) -> Data {
        return Data([type.rawValue])
    }

    /// Creates a 9-byte ping packet for RTT latency measurement.
    public static func makePingPacket(timestampMs: UInt64) -> Data {
        var data = Data(capacity: 9)
        data.append(GATEWAY_MSG_TYPE_PING)
        var beTimestamp = timestampMs.bigEndian
        data.append(Data(bytes: &beTimestamp, count: MemoryLayout<UInt64>.size))
        return data
    }

    /// Parses a 9-byte pong packet and returns the original timestamp.
    public static func parsePongPacket(data: Data) -> UInt64? {
        guard data.count >= 9, data[0] == GATEWAY_MSG_TYPE_PONG else { return nil }
        var beTimestamp: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &beTimestamp) { bytes in
            data.copyBytes(to: bytes, from: 1..<9)
        }
        return UInt64(bigEndian: beTimestamp)
    }
}
