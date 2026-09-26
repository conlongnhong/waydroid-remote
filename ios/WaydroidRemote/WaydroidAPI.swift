import Foundation

struct WaydroidAPI {
    let baseURL: URL
    let apiKey: String

    init(endpoint: String, apiKey: String) throws {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "http://\(trimmed)"

        guard let url = URL(string: value), url.host != nil else {
            throw RemoteError.invalidEndpoint
        }

        self.baseURL = url
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func status() async throws -> WaydroidStatus {
        try await get("/api/status", as: WaydroidStatus.self)
    }

    func apps() async throws -> [WaydroidApp] {
        try await get("/api/apps", as: [WaydroidApp].self)
    }

    func action(_ action: String) async throws {
        try await post("/api/power", body: ["action": action])
    }

    func launch(packageName: String) async throws {
        try await post("/api/apps/launch", body: ["package": packageName])
    }

    func sendInput(type: String, values: [String: Any]) async throws {
        var body: [String: Any] = ["type": type]
        values.forEach { body[$0.key] = $0.value }
        try await postJSON("/api/input", body: body)
    }

    func screenshot() async throws -> Data {
        try await request("/api/screenshot", method: "GET", body: nil, contentType: nil)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await request(path, method: "GET", body: nil, contentType: nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, body: [String: String]) async throws {
        try await postJSON(path, body: body)
    }

    private func postJSON(_ path: String, body: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: body)
        _ = try await request(path, method: "POST", body: data, contentType: "application/json")
    }

    private func request(
        _ path: String,
        method: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteError.server(statusCode: -1, message: "Phản hồi không hợp lệ.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Không rõ lỗi."
            throw RemoteError.server(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }
}
