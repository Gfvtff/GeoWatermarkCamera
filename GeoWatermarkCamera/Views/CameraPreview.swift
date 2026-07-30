import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let cameraPosition: AVCaptureDevice.Position
    let videoOrientationChanged: (AVCaptureVideoOrientation) -> Void

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.videoOrientationChanged = videoOrientationChanged
        view.previewLayer.session = session
        view.updateCameraPosition(cameraPosition)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.videoOrientationChanged = videoOrientationChanged
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.updateCameraPosition(cameraPosition)
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var videoOrientationChanged: ((AVCaptureVideoOrientation) -> Void)?

    private var cameraPosition: AVCaptureDevice.Position = .back
    private var videoOrientation: AVCaptureVideoOrientation = .portrait
    private var reportedVideoOrientation: AVCaptureVideoOrientation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        configureConnection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureConnection()
    }

    func updateCameraPosition(_ position: AVCaptureDevice.Position) {
        cameraPosition = position
        configureConnection()
    }

    private func configureConnection() {
        if let interfaceOrientation = window?.windowScene?.interfaceOrientation,
           let resolvedOrientation = Self.videoOrientation(from: interfaceOrientation) {
            videoOrientation = resolvedOrientation
        }

        if reportedVideoOrientation != videoOrientation {
            reportedVideoOrientation = videoOrientation
            videoOrientationChanged?(videoOrientation)
        }

        guard let connection = previewLayer.connection else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraPosition == .front
        }
    }

    private static func videoOrientation(
        from interfaceOrientation: UIInterfaceOrientation
    ) -> AVCaptureVideoOrientation? {
        switch interfaceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        case .unknown:
            return nil
        @unknown default:
            return nil
        }
    }
}
