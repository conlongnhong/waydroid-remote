import SwiftUI

public struct ContentView: View {
    @StateObject private var client = NetworkClient()
    @StateObject private var discovery = ServerDiscovery()

    @AppStorage("lastHost") private var manualHost: String = ""
    @AppStorage("controlPort") private var controlPort: Int = 8000
    @AppStorage("videoPort") private var videoPort: Int = 8001
    @AppStorage("selectedPreset") private var selectedPreset: String = "1080p"

    public init() {}

    public var body: some View {
        Group {
            if client.isConnected {
                RemoteTouchView(client: client) {
                    client.disconnect()
                }
            } else {
                connectionView
            }
        }
        .onAppear {
            discovery.startBrowsing()
            if manualHost.isEmpty {
                manualHost = "192.168.1.21"
            }
        }
        .onDisappear {
            discovery.stopBrowsing()
        }
    }

    private var connectionView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerView

                    // 1. Auto-Discovered Servers Section
                    discoveredServersSection

                    // 2. Manual IP Connection Section
                    manualConnectionSection

                    // 3. Performance & Architecture Info Card
                    architectureInfoSection
                }
                .padding()
            }
            .navigationTitle("Waydroid Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        discovery.startBrowsing()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(discovery.isSearching)
                }
            }
        }
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 48))
                .foregroundStyle(.cyan.gradient)

            Text("Màn hình Cảm ứng Từ xa")
                .font(.title2.bold())

            Text("Độ trễ siêu thấp cho Waydroid trên Arch Linux + Hyprland")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 10)
    }

    private var discoveredServersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tự động tìm kiếm trên LAN", systemImage: "bonjour")
                    .font(.headline)
                Spacer()
                if discovery.isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if discovery.discoveredServers.isEmpty {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    Text("Đang quét tìm server Bonjour trên mạng nội bộ...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(discovery.discoveredServers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(server.name)
                                .font(.body.weight(.semibold))
                            Text("\(server.host) · \(server.resolution) · \(server.preset)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Kết nối") {
                            client.connect(
                                to: server.host,
                                controlPort: server.controlPort,
                                videoPort: server.videoPort
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var manualConnectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Kết nối thủ công qua IP", systemImage: "network")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Địa chỉ IP máy Linux:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Ví dụ: 192.168.1.21", text: $manualHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cổng Control:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("8000", value: $controlPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cổng Video:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("8001", value: $videoPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Preset khởi tạo:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Preset", selection: $selectedPreset) {
                    Text("720p (Siêu mượt 60fps)").tag("720p")
                    Text("1080p (Chuẩn nét 60fps)").tag("1080p")
                    Text("Native (Tối đa phân giải)").tag("native")
                    Text("Native 90 FPS").tag("native-90fps")
                    Text("Native 120 FPS").tag("native-120fps")
                }
                .pickerStyle(.segmented)
            }

            Button {
                client.connect(
                    to: manualHost.trimmingCharacters(in: .whitespacesAndNewlines),
                    controlPort: UInt16(controlPort),
                    videoPort: UInt16(videoPort)
                )
            } label: {
                HStack {
                    Spacer()
                    if case .connecting = client.state {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 6)
                    }
                    Text("Kết nối tới Waydroid")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(manualHost.isEmpty)

            if case .failed(let error) = client.state {
                Text("Lỗi: \(error)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var architectureInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Công nghệ tối ưu độ trễ", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))

            bulletPoint(icon: "bolt.fill", title: "Touch <30ms", desc: "Binary packet 32-byte tiêm trực tiếp vào Android InputManager qua scrcpy.")
            bulletPoint(icon: "tv.fill", title: "Visual <50ms", desc: "VideoToolbox hardware decode, không buffer frame cũ.")
            bulletPoint(icon: "hand.tap.fill", title: "Multi-Touch & Pinch", desc: "Hỗ trợ vuốt, chạm, giữ, thu phóng đa điểm 2-10 ngón.")
            bulletPoint(icon: "keyboard.fill", title: "Bàn phím tiếng Việt", desc: "Gõ Telex, VNI, Emoji từ iPhone trực tiếp vào Android.")
        }
        .padding()
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func bulletPoint(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(desc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
