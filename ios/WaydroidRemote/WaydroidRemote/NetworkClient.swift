import Foundation
import Network
import SwiftUI

public enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)
}

public final class NetworkClient: ObservableObject {
    @Published public var state: ConnectionState = .disconnected
    @Published public var isConnected: Bool = false
    @Published public var latencyMs: Double = 0.0
    @Published public var fps: Double = 0.0
    @Published public var bitrateMbps: Double = 0.0
    @Published public var videoSize: CGSize = CGSize(width: 1920, height: 1080)
    @Published public var androidResolution: CGSize = CGSize(width: 1920, height: 1080)
    @Published public var deviceModel: String = "Waydroid"
    @Published public var currentPreset: String = "1080p"
    @Published public var availablePresets: [String] = ["720p", "1080p", "native", "native-90fps", "native-120fps"]

    public let decoder = H264Decoder()

    public var host: String = ""
    public var controlPort: UInt16 = 8000
    public var videoPort: UInt16 = 8001

    private var controlConnection: NWConnection?
    private var videoConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.duong303.waydroidremote.network", qos: .userInteractive)

    private var pingTimer: Timer?
    private var pingSendTime: UInt64 = 0

    private var frameCount: Int = 0
    private var bytesReceived: Int = 0
    private var lastStatsTime: TimeInterval = 0

    private var reconnectAttempts: Int = 0
    private var shouldAutoReconnect: Bool = true

    public init() {}

    deinit {
        disconnect()
    }

    public func connect(to host: String, controlPort: UInt16 = 8000, videoPort: UInt16 = 8001) {
        self.host = host
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.shouldAutoReconnect = true
        self.reconnectAttempts = 0

        DispatchQueue.main.async {
            self.state = .connecting
        }

        startConnections()
    }

    public func disconnect() {
        shouldAutoReconnect = false
        stopPingTimer()
        controlConnection?.cancel()
        videoConnection?.cancel()
        controlConnection = nil
        videoConnection = nil
        decoder.invalidateSession()

        DispatchQueue.main.async {
            self.state = .disconnected
            self.isConnected = false
            self.latencyMs = 0
            self.fps = 0
            self.bitrateMbps = 0
        }
    }

    private func startConnections() {
        setupControlConnection()
        setupVideoConnection()
    }

    // MARK: - Control Connection (TCP Port 8000)
    private func setupControlConnection() {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true // Disable Nagle for instant touch injection!

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.serviceClass = .responsiveData

        guard let nwPort = NWEndpoint.Port(rawValue: controlPort) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.controlConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.state = .connected
                    self.reconnectAttempts = 0
                }
                self.startPingTimer()
                self.readControlResponses()
                self.fetchServerStatus()
            case .failed(let err):
                self.handleConnectionFailure(error: err.localizedDescription)
            case .cancelled:
                break
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    // MARK: - Video Stream Connection (TCP Port 8001)
    private func setupVideoConnection() {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.serviceClass = .interactiveVideo

        guard let nwPort = NWEndpoint.Port(rawValue: videoPort) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        self.videoConnection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.readNextVideoHeader()
            case .failed(let err):
                print("[Video] Connection failed: \(err)")
            default:
                break
            }
        }

        conn.start(queue: queue)
    }

    // MARK: - Video Stream Loop (12-byte header + payload)
    private func readNextVideoHeader() {
        guard let conn = videoConnection, conn.state == .ready else { return }

        conn.receive(minimumIncompleteLength: 12, maximumLength: 12) { [weak self] content, _, isComplete, error in
            guard let self = self, let data = content, data.count == 12, error == nil else {
                return
            }

            var bePtsFlags: UInt64 = 0
            var beSize: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &bePtsFlags) { data.copyBytes(to: $0, from: 0..<8) }
            _ = withUnsafeMutableBytes(of: &beSize) { data.copyBytes(to: $0, from: 8..<12) }

            let ptsFlags = UInt64(bigEndian: bePtsFlags)
            let packetSize = Int(UInt32(bigEndian: beSize))

            let isConfig = (ptsFlags & (1 << 62)) != 0
            let isKey = (ptsFlags & (1 << 61)) != 0
            let pts = Int64(ptsFlags & ((1 << 61) - 1))

            self.readVideoPayload(size: packetSize, pts: pts, isConfig: isConfig, isKey: isKey)
        }
    }

    private func readVideoPayload(size: Int, pts: Int64, isConfig: Bool, isKey: Bool) {
        guard let conn = videoConnection, conn.state == .ready, size > 0 else {
            readNextVideoHeader()
            return
        }

        conn.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] content, _, _, error in
            guard let self = self, let payload = content, payload.count == size, error == nil else {
                return
            }

            self.bytesReceived += size
            self.frameCount += 1

            let now = Date().timeIntervalSince1970
            if self.lastStatsTime == 0 { self.lastStatsTime = now }
            let dt = now - self.lastStatsTime
            if dt >= 1.0 {
                let currentFps = Double(self.frameCount) / dt
                let currentBitrate = (Double(self.bytesReceived * 8) / dt) / 1_000_000.0
                self.frameCount = 0
                self.bytesReceived = 0
                self.lastStatsTime = now

                DispatchQueue.main.async {
                    self.fps = round(currentFps * 10) / 10
                    self.bitrateMbps = round(currentBitrate * 10) / 10
                }
            }

            // Decode H.264 packet via VideoToolbox
            self.decoder.decodePacket(data: payload, pts: pts, isConfig: isConfig, isKeyFrame: isKey)

            // Continue reading next frame
            self.readNextVideoHeader()
        }
    }

    // MARK: - Sending Control Packets (Touch / Keys / Text)
    public func sendControlPacket(_ packet: Data) {
        guard let conn = controlConnection, conn.state == .ready else { return }
        conn.send(content: packet, completion: .contentProcessed({ _ in }))
    }

    public func sendText(_ text: String) {
        let packet = ScrcpyProtocol.makeTextPacket(text: text)
        sendControlPacket(packet)
    }

    public func sendKeycode(_ keycode: AndroidKeyCode) {
        let downPacket = ScrcpyProtocol.makeKeycodePacket(action: 0, keycode: keycode.rawValue)
        let upPacket = ScrcpyProtocol.makeKeycodePacket(action: 1, keycode: keycode.rawValue)
        sendControlPacket(downPacket)
        sendControlPacket(upPacket)
    }

    public func sendBack() {
        sendControlPacket(ScrcpyProtocol.makeBackPacket())
    }

    public func sendPanelCommand(_ type: ScrcpyControlMessageType) {
        sendControlPacket(ScrcpyProtocol.makePanelPacket(type: type))
    }

    // MARK: - Ping / Pong Latency Measurement
    private func startPingTimer() {
        stopPingTimer()
        DispatchQueue.main.async {
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        pingSendTime = nowMs
        let packet = ScrcpyProtocol.makePingPacket(timestampMs: nowMs)
        sendControlPacket(packet)
    }

    private func readControlResponses() {
        guard let conn = controlConnection, conn.state == .ready else { return }
        conn.receive(minimumIncompleteLength: 9, maximumLength: 1024) { [weak self] content, _, _, error in
            guard let self = self, let data = content, error == nil else { return }

            if let origTs = ScrcpyProtocol.parsePongPacket(data: data) {
                let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                let rtt = Double(nowMs > origTs ? (nowMs - origTs) : 0)
                DispatchQueue.main.async {
                    self.latencyMs = rtt
                }
            }
            self.readControlResponses()
        }
    }

    // MARK: - HTTP API Fetching for Presets & Status
    public func fetchServerStatus() {
        guard let url = URL(string: "http://\(host):\(controlPort)/api/status") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        if let w = json["width"] as? Int, let h = json["height"] as? Int {
                            self.videoSize = CGSize(width: w, height: h)
                            self.androidResolution = CGSize(width: w, height: h)
                        }
                        if let p = json["preset"] as? String {
                            self.currentPreset = p
                        }
                        if let dev = json["device"] as? String {
                            self.deviceModel = dev
                        }
                    }
                }
            } catch {}
        }.resume()
    }

    public func setPreset(_ presetName: String) {
        guard let url = URL(string: "http://\(host):\(controlPort)/api/presets") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["preset": presetName]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.currentPreset = presetName
                // Reconnect video after preset change
                self?.videoConnection?.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.setupVideoConnection()
                }
            }
        }.resume()
    }

    // MARK: - Auto Reconnect
    private func handleConnectionFailure(error: String) {
        guard shouldAutoReconnect else {
            DispatchQueue.main.async {
                self.state = .failed(error)
                self.isConnected = false
            }
            return
        }

        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts), 4.0)

        DispatchQueue.main.async {
            self.state = .reconnecting
            self.isConnected = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldAutoReconnect else { return }
            print("[Reconnect] Attempt \(self.reconnectAttempts)...")
            self.startConnections()
        }
    }
}
