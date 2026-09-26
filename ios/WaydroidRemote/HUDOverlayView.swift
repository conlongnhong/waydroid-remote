import SwiftUI

public struct HUDOverlayView: View {
    @ObservedObject var client: NetworkClient
    @State private var showPresetMenu: Bool = false
    @State private var isCollapsed: Bool = false

    public init(client: NetworkClient) {
        self.client = client
    }

    private var latencyColor: Color {
        if client.latencyMs <= 30.0 {
            return .green
        } else if client.latencyMs <= 50.0 {
            return .orange
        } else {
            return .red
        }
    }

    public var body: some View {
        VStack {
            HStack(spacing: 8) {
                if !isCollapsed {
                    // Latency Badge
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text(String(format: "%.0f ms", client.latencyMs))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(latencyColor.opacity(0.2))
                    .foregroundStyle(latencyColor)
                    .clipShape(Capsule())

                    // FPS Badge
                    HStack(spacing: 3) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 10))
                        Text(String(format: "%.0f fps", client.fps))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())

                    // Bitrate Badge
                    Text(String(format: "%.1f M", client.bitrateMbps))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())

                    // Preset Menu Trigger
                    Menu {
                        ForEach(client.availablePresets, id: \.self) { preset in
                            Button {
                                client.setPreset(preset)
                            } label: {
                                HStack {
                                    Text(preset)
                                    if client.currentPreset == preset {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(client.currentPreset)
                                .font(.system(size: 11, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.3))
                        .foregroundStyle(.cyan)
                        .clipShape(Capsule())
                    }
                }

                // Collapse/Expand toggle button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isCollapsed ? "gauge.with.dots.needle.bottom.50percent" : "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .padding(5)
                        .background(Color.black.opacity(0.5))
                        .foregroundStyle(.white.opacity(0.8))
                        .clipShape(Circle())
                }
            }
            .padding(4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)

            if case .reconnecting = client.state {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                    Text("Đang kết nối lại...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.9))
                .clipShape(Capsule())
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()
        }
        .padding(.top, 8)
    }
}
