import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

public final class SampleBufferContainerView: UIView {
    override public static var layerClass: AnyClass {
        return AVSampleBufferDisplayLayer.self
    }

    public var displayLayer: AVSampleBufferDisplayLayer {
        return layer as! AVSampleBufferDisplayLayer
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }

    private func setupLayer() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }

    public func flush() {
        displayLayer.flush()
    }
}

public struct SampleBufferVideoView: UIViewRepresentable {
    @ObservedObject var client: NetworkClient

    public init(client: NetworkClient) {
        self.client = client
    }

    public func makeUIView(context: Context) -> SampleBufferContainerView {
        let view = SampleBufferContainerView()
        context.coordinator.setup(view: view, client: client)
        return view
    }

    public func updateUIView(_ uiView: SampleBufferContainerView, context: Context) {
        // Dynamic resize is handled by layer videoGravity
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator {
        private var sampleBufferObserver: ((CMSampleBuffer) -> Void)?

        func setup(view: SampleBufferContainerView, client: NetworkClient) {
            client.decoder.onSampleBuffer = { [weak view] sampleBuffer in
                DispatchQueue.main.async {
                    view?.enqueue(sampleBuffer)
                }
            }
        }
    }
}
