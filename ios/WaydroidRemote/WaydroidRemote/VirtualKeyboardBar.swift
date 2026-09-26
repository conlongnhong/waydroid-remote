import SwiftUI

public struct VirtualKeyboardBar: View {
    @ObservedObject var client: NetworkClient
    @State private var inputText: String = ""
    @State private var showTextInput: Bool = false
    @FocusState private var isFieldFocused: Bool

    public init(client: NetworkClient) {
        self.client = client
    }

    public var body: some View {
        VStack(spacing: 8) {
            // Optional expanded text field
            if showTextInput {
                HStack(spacing: 8) {
                    TextField("Nhập văn bản gửi vào Android...", text: $inputText)
                        .focused($isFieldFocused)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(Color.white.opacity(0.15))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onSubmit {
                            submitText()
                        }

                    Button {
                        submitText()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.cyan)
                    }
                    .disabled(inputText.isEmpty)

                    Button {
                        client.sendKeycode(.backspace)
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isFieldFocused = false
                        showTextInput = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }

            // Compact Floating Navigation Pill
            HStack(spacing: 16) {
                // Back Button
                Button {
                    client.sendBack()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 16, weight: .bold))
                }

                // Home Button
                Button {
                    client.sendKeycode(.home)
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 18, weight: .bold))
                }

                // Recent Apps Button
                Button {
                    client.sendKeycode(.appSwitch)
                } label: {
                    Image(systemName: "square")
                        .font(.system(size: 16, weight: .bold))
                }

                Divider()
                    .frame(height: 18)
                    .background(Color.white.opacity(0.3))

                // Notification Panel Button
                Button {
                    client.sendPanelCommand(.expandNotificationPanel)
                } label: {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 15))
                }

                // Keyboard Toggle Button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTextInput.toggle()
                        if showTextInput {
                            isFieldFocused = true
                        } else {
                            isFieldFocused = false
                        }
                    }
                } label: {
                    Image(systemName: showTextInput ? "keyboard.fill" : "keyboard")
                        .font(.system(size: 16))
                        .foregroundStyle(showTextInput ? .cyan : .white)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
        }
        .padding(.bottom, 6)
    }

    private func submitText() {
        guard !inputText.isEmpty else { return }
        client.sendText(inputText)
        inputText = ""
    }
}
