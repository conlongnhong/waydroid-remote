import Foundation
import Network
import SwiftUI

public struct DiscoveredServer: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let host: String
    public let controlPort: UInt16
    public let videoPort: UInt16
    public let preset: String
    public let resolution: String

    public init(
        name: String,
        host: String,
        controlPort: UInt16 = 8000,
        videoPort: UInt16 = 8001,
        preset: String = "1080p",
        resolution: String = "1920x1080"
    ) {
        self.id = "\(host):\(controlPort)"
        self.name = name
        self.host = host
        self.controlPort = controlPort
        self.videoPort = videoPort
        self.preset = preset
        self.resolution = resolution
    }
}

public final class ServerDiscovery: ObservableObject {
    @Published public var discoveredServers: [DiscoveredServer] = []
    @Published public var isSearching: Bool = false

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.duong303.waydroidremote.discovery")

    public init() {}

    public func startBrowsing() {
        stopBrowsing()

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_waydroid-remote._tcp", domain: nil)
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: parameters)
        self.browser = b

        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            var servers: [DiscoveredServer] = []

            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    var hostStr = ""
                    var controlPort: UInt16 = 8000
                    var videoPort: UInt16 = 8001
                    var preset = "1080p"
                    var res = "1920x1080"

                    // Parse TXT records if available
                    if case .bonjour(let txtRecord) = result.metadata {
                        let dict = txtRecord.dictionary
                        if let vPortStr = dict["video_port"], let vp = UInt16(vPortStr) {
                            videoPort = vp
                        }
                        if let cPortStr = dict["control_port"], let cp = UInt16(cPortStr) {
                            controlPort = cp
                        }
                        if let p = dict["preset"] {
                            preset = p
                        }
                        if let w = dict["width"], let h = dict["height"] {
                            res = "\(w)x\(h)"
                        }
                    }

                    // Resolve IP from endpoint interface or endpoint description
                    let endpointDesc = "\(result.endpoint)"
                    // Extract IP if present in endpoint
                    let components = endpointDesc.components(separatedBy: ":")
                    if components.count >= 2, let ip = components.first, !ip.isEmpty {
                        hostStr = ip
                    } else {
                        hostStr = "\(name).local"
                    }

                    let server = DiscoveredServer(
                        name: name,
                        host: hostStr,
                        controlPort: controlPort,
                        videoPort: videoPort,
                        preset: preset,
                        resolution: res
                    )
                    servers.append(server)
                }
            }

            DispatchQueue.main.async {
                self.discoveredServers = servers
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        b.start(queue: queue)
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        DispatchQueue.main.async {
            self.isSearching = false
        }
    }
}
