import Foundation

struct WaydroidStatus: Codable, Equatable {
    let session: String
    let container: String
    let vendorType: String
    let ipAddress: String?
    let sessionUser: String?
    let waylandDisplay: String?

    enum CodingKeys: String, CodingKey {
        case session
        case container
        case vendorType = "vendor_type"
        case ipAddress = "ip_address"
        case sessionUser = "session_user"
        case waylandDisplay = "wayland_display"
    }

    var isRunning: Bool {
        session.uppercased() == "RUNNING" && container.uppercased() == "RUNNING"
    }
}

struct WaydroidApp: Codable, Equatable, Identifiable {
    let packageName: String
    let displayName: String

    var id: String { packageName }

    enum CodingKeys: String, CodingKey {
        case packageName = "package_name"
        case displayName = "display_name"
    }
}

enum RemoteError: LocalizedError {
    case invalidEndpoint
    case server(statusCode: Int, message: String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Địa chỉ server không hợp lệ."
        case let .server(statusCode, message):
            return "Server lỗi (\(statusCode)): \(message)"
        case .disconnected:
            return "Chưa kết nối tới server Waydroid."
        }
    }
}
