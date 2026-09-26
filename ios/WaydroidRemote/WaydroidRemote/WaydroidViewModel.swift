import Combine
import Foundation
import UIKit

@MainActor
final class WaydroidViewModel: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "waydroid.host") ?? "http://192.168.1.100:8765"
    @Published var apiKey = UserDefaults.standard.string(forKey: "waydroid.apiKey") ?? "change-me"
    @Published private(set) var status: WaydroidStatus?
    @Published private(set) var apps: [WaydroidApp] = []
    @Published private(set) var screenshot: UIImage?
    @Published private(set) var connected = false
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    private var api: WaydroidAPI?

    var statusLabel: String {
        guard let status else { return "Chưa kết nối" }
        return status.isRunning ? "Đang chạy" : "Đã dừng"
    }

    func connect() async {
        do {
            let newAPI = try WaydroidAPI(endpoint: host, apiKey: apiKey)
            api = newAPI
            UserDefaults.standard.set(host, forKey: "waydroid.host")
            UserDefaults.standard.set(apiKey, forKey: "waydroid.apiKey")
            await refresh()
        } catch {
            connected = false
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard let api else {
            connected = false
            return
        }

        isBusy = true
        defer { isBusy = false }

        do {
            status = try await api.status()
            connected = true
            apps = (try? await api.apps()) ?? apps
            await refreshScreenshot()
        } catch {
            connected = false
            lastError = error.localizedDescription
        }
    }

    func startPolling() async {
        while !Task.isCancelled {
            if api != nil {
                await refresh()
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    func refreshScreenshot() async {
        guard let api else { return }

        do {
            let data = try await api.screenshot()
            if let image = UIImage(data: data) {
                screenshot = image
            }
        } catch {
            // The runtime can be healthy while screencap is briefly unavailable.
        }
    }

    func perform(_ action: String) async {
        guard let api else {
            lastError = RemoteError.disconnected.localizedDescription
            return
        }

        do {
            try await api.action(action)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func launch(_ app: WaydroidApp) async {
        guard let api else {
            lastError = RemoteError.disconnected.localizedDescription
            return
        }

        do {
            try await api.launch(packageName: app.packageName)
            await refreshScreenshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendKey(_ key: String) async {
        await sendInput(type: "keyevent", values: ["key": key])
    }

    func sendText(_ text: String) async {
        guard !text.isEmpty else { return }
        await sendInput(type: "text", values: ["text": text])
    }

    func sendTap(x: Int, y: Int) async {
        await sendInput(type: "tap", values: ["x": x, "y": y])
        await refreshScreenshot()
    }

    func sendSwipe(from: CGPoint, to: CGPoint, duration: Int = 350) async {
        await sendInput(type: "swipe", values: [
            "x1": Int(from.x), "y1": Int(from.y),
            "x2": Int(to.x), "y2": Int(to.y),
            "duration": duration
        ])
        await refreshScreenshot()
    }

    private func sendInput(type: String, values: [String: Any]) async {
        guard let api else {
            lastError = RemoteError.disconnected.localizedDescription
            return
        }

        do {
            try await api.sendInput(type: type, values: values)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
