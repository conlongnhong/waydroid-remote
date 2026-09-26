import SwiftUI

public struct RemoteTouchView: View {
    @ObservedObject var client: NetworkClient
    var onDisconnect: () -> Void

    public init(client: NetworkClient, onDisconnect: @escaping () -> Void) {
        self.client = client
        self.onDisconnect = onDisconnect
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                // 1. Hardware Video Stream Layer
                SampleBufferVideoView(client: client)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                // 2. Transparent Multi-Touch Tracker Layer
                TouchTrackingRepresentable(
                    client: client,
                    videoSize: client.videoSize,
                    androidResolution: client.androidResolution
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

                // 3. Top HUD Overlay
                HUDOverlayView(client: client)

                // 4. Exit / Disconnect Button (Top-left corner)
                VStack {
                    HStack {
                        Button {
                            onDisconnect()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.white.opacity(0.6))
                                .padding(12)
                        }
                        Spacer()
                    }
                    Spacer()
                }

                // 5. Bottom Virtual Keyboard & Android Navigation Controls
                VStack {
                    Spacer()
                    VirtualKeyboardBar(client: client)
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}
