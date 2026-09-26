import CoreGraphics
import SwiftUI
import UIKit

public protocol TouchEventDelegate: AnyObject {
    func onTouchPacketGenerated(packet: Data)
}

/// Native UIKit multi-touch tracker that converts iOS touches into scrcpy 32-byte binary packets.
public final class TouchTrackerUIView: UIView {
    public weak var delegate: TouchEventDelegate?
    public var videoSize: CGSize = CGSize(width: 1920, height: 1080)
    public var androidResolution: CGSize = CGSize(width: 1920, height: 1080)

    // Tracks UITouch to unique pointer ID mapping
    private var touchToId: [ObjectIdentifier: UInt64] = [:]
    private var freeIds: [UInt64] = (0..<10).map { UInt64($0) }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    private func getMapper() -> CoordinateMapper {
        return CoordinateMapper(
            viewSize: bounds.size,
            videoSize: videoSize,
            androidResolution: androidResolution
        )
    }

    private func allocatePointerId(for touch: UITouch) -> UInt64 {
        let key = ObjectIdentifier(touch)
        if let existing = touchToId[key] {
            return existing
        }
        let nextId = freeIds.isEmpty ? UInt64(touchToId.count) : freeIds.removeFirst()
        touchToId[key] = nextId
        return nextId
    }

    private func releasePointerId(for touch: UITouch) -> UInt64 {
        let key = ObjectIdentifier(touch)
        let id = touchToId.removeValue(forKey: key) ?? 0
        if !freeIds.contains(id) {
            freeIds.append(id)
            freeIds.sort()
        }
        return id
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let mapper = getMapper()

        for touch in touches {
            let pointerId = allocatePointerId(for touch)
            let isFirst = (touchToId.count == 1)
            let pointerIndex = UInt8(pointerId & 0xFF)

            // Scrcpy/Android: DOWN for first pointer; POINTER_DOWN | (index << 8) for subsequent
            let action: UInt8 = isFirst
                ? AndroidMotionEventAction.down.rawValue
                : (AndroidMotionEventAction.pointerDown.rawValue | (pointerIndex << 8))

            let loc = touch.location(in: self)
            let (ax, ay, _) = mapper.mapToAndroid(point: loc)

            let pressure: Float = (touch.maximumPossibleForce > 0)
                ? Float(touch.force / touch.maximumPossibleForce)
                : 1.0

            let packet = ScrcpyProtocol.makeTouchPacket(
                action: action,
                pointerId: pointerId,
                x: ax,
                y: ay,
                screenWidth: UInt16(mapper.androidResolution.width),
                screenHeight: UInt16(mapper.androidResolution.height),
                pressure: pressure
            )
            delegate?.onTouchPacketGenerated(packet: packet)
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let mapper = getMapper()

        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let pointerId = touchToId[key] else { continue }

            let loc = touch.location(in: self)
            let (ax, ay, _) = mapper.mapToAndroid(point: loc)

            let pressure: Float = (touch.maximumPossibleForce > 0)
                ? Float(touch.force / touch.maximumPossibleForce)
                : 1.0

            let packet = ScrcpyProtocol.makeTouchPacket(
                action: AndroidMotionEventAction.move.rawValue,
                pointerId: pointerId,
                x: ax,
                y: ay,
                screenWidth: UInt16(mapper.androidResolution.width),
                screenHeight: UInt16(mapper.androidResolution.height),
                pressure: pressure
            )
            delegate?.onTouchPacketGenerated(packet: packet)
        }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let mapper = getMapper()

        for touch in touches {
            let isLast = (touchToId.count <= 1)
            let pointerId = releasePointerId(for touch)
            let pointerIndex = UInt8(pointerId & 0xFF)

            // Scrcpy/Android: UP for last pointer; POINTER_UP | (index << 8) for non-last
            let action: UInt8 = isLast
                ? AndroidMotionEventAction.up.rawValue
                : (AndroidMotionEventAction.pointerUp.rawValue | (pointerIndex << 8))

            let loc = touch.location(in: self)
            let (ax, ay, _) = mapper.mapToAndroid(point: loc)

            let packet = ScrcpyProtocol.makeTouchPacket(
                action: action,
                pointerId: pointerId,
                x: ax,
                y: ay,
                screenWidth: UInt16(mapper.androidResolution.width),
                screenHeight: UInt16(mapper.androidResolution.height),
                pressure: 0.0
            )
            delegate?.onTouchPacketGenerated(packet: packet)
        }
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

public struct TouchTrackingRepresentable: UIViewRepresentable {
    @ObservedObject var client: NetworkClient
    var videoSize: CGSize
    var androidResolution: CGSize

    public init(client: NetworkClient, videoSize: CGSize, androidResolution: CGSize) {
        self.client = client
        self.videoSize = videoSize
        self.androidResolution = androidResolution
    }

    public func makeUIView(context: Context) -> TouchTrackerUIView {
        let view = TouchTrackerUIView()
        view.delegate = context.coordinator
        view.videoSize = videoSize
        view.androidResolution = androidResolution
        return view
    }

    public func updateUIView(_ uiView: TouchTrackerUIView, context: Context) {
        uiView.videoSize = videoSize
        uiView.androidResolution = androidResolution
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(client: client)
    }

    public final class Coordinator: TouchEventDelegate {
        let client: NetworkClient

        init(client: NetworkClient) {
            self.client = client
        }

        public func onTouchPacketGenerated(packet: Data) {
            client.sendControlPacket(packet)
        }
    }
}
