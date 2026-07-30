import AVFoundation
import Foundation
import ImageIO
import Vision

struct CapturedPhoto {
    let data: Data
    let cameraPosition: AVCaptureDevice.Position
}

enum CameraServiceError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case cannotAddVideoDataOutput
    case captureFailed
    case photoDataUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "未找到可用摄像头"
        case .cannotAddInput: "无法连接摄像头输入"
        case .cannotAddOutput: "无法创建照片输出"
        case .cannotAddVideoDataOutput: "无法启动实时文字识别"
        case .captureFailed: "拍摄失败，请重试"
        case .photoDataUnavailable: "未能生成照片文件"
        }
    }
}

final class CameraService: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    @Published private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isConfigured = false
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var cameraPosition: AVCaptureDevice.Position = .back
    @Published private(set) var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var maximumZoomFactor: CGFloat = 5
    @Published private(set) var recognizedTextCandidates: [String] = []
    @Published var errorMessage: String?

    private let sessionQueue = DispatchQueue(label: "com.example.GeoWatermarkCamera.capture-session")
    private let videoFrameQueue = DispatchQueue(
        label: "com.example.GeoWatermarkCamera.video-frames",
        qos: .userInitiated
    )
    private let textRecognitionQueue = DispatchQueue(
        label: "com.example.GeoWatermarkCamera.text-recognition",
        qos: .utility
    )
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var sessionObservers: [NSObjectProtocol] = []
    private var configured = false
    private var shouldBeRunning = false
    private var sessionIsInterrupted = false
    private var captureInProgress = false
    private var activeFlashMode: AVCaptureDevice.FlashMode = .off
    private var videoOrientation: AVCaptureVideoOrientation = .portrait

    // Access only from videoFrameQueue.
    private var textRecognitionEnabled = false
    private var textRecognitionSuspensions: Set<TextRecognitionSuspension> = []
    private var textRecognitionGeneration: UInt = 0
    private var activeTextRecognitionRequest: VNRecognizeTextRequest?
    private var lastTextRecognitionTime: TimeInterval = 0
    private var recognitionVideoOrientation: AVCaptureVideoOrientation = .portrait
    private var recognitionVideoMirrored = false
    private var consecutiveCandidateHits: [String: Int] = [:]
    private var framesWithoutStableCandidates = 0
    private var lastPublishedTextCandidates: [String] = []

    private static let textRecognitionInterval: TimeInterval = 1.0
    private static let minimumTextConfidence: VNConfidence = 0.55
    private static let maximumTextCandidateCount = 8

    override init() {
        super.init()
        observeSessionNotifications()
    }

    deinit {
        sessionObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func prepare() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        publish { self.authorizationStatus = status }

        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.publish { self.authorizationStatus = granted ? .authorized : .denied }
                if granted {
                    self.configureAndStart()
                }
            }
        case .restricted, .denied:
            publish { self.errorMessage = "相机权限未开启" }
        @unknown default:
            publish { self.errorMessage = "无法访问相机" }
        }
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        publish { self.authorizationStatus = status }
        guard status == .authorized else { return }
        configureAndStart()
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldBeRunning = false
            self.setTextRecognitionSuspension(
                .session,
                active: true,
                clearPublishedCandidates: true,
                synchronously: true
            )
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.publishRunningState()
        }
    }

    func toggleFlash() {
        sessionQueue.async { [weak self] in
            guard let self, !self.captureInProgress else { return }
            guard let device = self.videoInput?.device, device.hasFlash else {
                self.activeFlashMode = .off
                self.publish { self.flashMode = .off }
                return
            }

            self.activeFlashMode = self.activeFlashMode == .off ? .on : .off
            let flashMode = self.activeFlashMode
            self.publish { self.flashMode = flashMode }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self,
                  !self.captureInProgress,
                  !self.sessionIsInterrupted,
                  let oldInput = self.videoInput else { return }
            let newPosition: AVCaptureDevice.Position = oldInput.device.position == .back ? .front : .back

            do {
                guard let device = Self.camera(position: newPosition) else {
                    throw CameraServiceError.cameraUnavailable
                }
                let newInput = try AVCaptureDeviceInput(device: device)

                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.videoInput = newInput
                } else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraServiceError.cannotAddInput
                }
                self.session.commitConfiguration()

                self.activeFlashMode = .off
                self.configurePhotoConnection(cameraPosition: newPosition)
                self.configureVideoDataConnection(cameraPosition: newPosition)
                self.updateTextRecognitionGeometry(
                    orientation: self.videoOrientation,
                    mirrored: newPosition == .front
                )
                let maxZoom = min(max(device.activeFormat.videoMaxZoomFactor, 1), 5)
                self.publish {
                    self.cameraPosition = newPosition
                    self.flashMode = .off
                    self.zoomFactor = 1
                    self.maximumZoomFactor = maxZoom
                }
            } catch {
                self.publish { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func setZoom(_ requestedFactor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self,
                  !self.captureInProgress,
                  !self.sessionIsInterrupted,
                  let device = self.videoInput?.device else { return }
            let factor = min(max(requestedFactor, 1), min(device.activeFormat.videoMaxZoomFactor, 5))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = factor
                device.unlockForConfiguration()
                self.publish { self.zoomFactor = factor }
            } catch {
                self.publish { self.errorMessage = "无法调整变焦" }
            }
        }
    }

    func setVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoOrientation = orientation
            guard !self.captureInProgress else { return }
            self.configurePhotoConnection()
            self.configureVideoDataConnection()
            self.updateTextRecognitionGeometry(
                orientation: orientation,
                mirrored: self.videoInput?.device.position == .front
            )
        }
    }

    func setTextRecognitionEnabled(_ enabled: Bool) {
        videoFrameQueue.async { [weak self] in
            guard let self else { return }
            if self.textRecognitionEnabled != enabled {
                self.textRecognitionEnabled = enabled
            } else if enabled {
                return
            }
            self.invalidateTextRecognition(clearPublishedCandidates: true)
        }
    }

    private func setTextRecognitionSuspension(
        _ reason: TextRecognitionSuspension,
        active: Bool,
        clearPublishedCandidates: Bool,
        synchronously: Bool = false
    ) {
        let update = { [weak self] in
            guard let self else { return }
            let changed: Bool
            if active {
                changed = self.textRecognitionSuspensions.insert(reason).inserted
            } else {
                changed = self.textRecognitionSuspensions.remove(reason) != nil
            }
            guard changed else { return }
            self.invalidateTextRecognition(
                clearPublishedCandidates: clearPublishedCandidates
            )
        }

        if synchronously {
            // Callers using this path are on sessionQueue. videoFrameQueue never
            // synchronously calls sessionQueue, so this short state flip cannot deadlock.
            videoFrameQueue.sync(execute: update)
        } else {
            videoFrameQueue.async(execute: update)
        }
    }

    func capturePhoto(completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self,
                  self.configured,
                  self.session.isRunning,
                  !self.sessionIsInterrupted,
                  !self.captureInProgress else {
                DispatchQueue.main.async { completion(.failure(CameraServiceError.cameraUnavailable)) }
                return
            }

            self.captureInProgress = true
            self.setTextRecognitionSuspension(
                .photoCapture,
                active: true,
                clearPublishedCandidates: false,
                synchronously: true
            )

            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.photoQualityPrioritization = .quality

            let currentPosition = self.videoInput?.device.position ?? .back
            if let device = self.videoInput?.device,
               device.hasFlash,
               self.photoOutput.supportedFlashModes.contains(self.activeFlashMode) {
                settings.flashMode = self.activeFlashMode
            }

            self.configurePhotoConnection(cameraPosition: currentPosition)

            let delegate = PhotoCaptureDelegate(
                cameraPosition: currentPosition,
                completion: completion,
                didFinish: { [weak self] uniqueID in
                    guard let self else { return }
                    self.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        self.photoDelegates[uniqueID] = nil
                        self.captureInProgress = false
                        self.configurePhotoConnection()
                        self.configureVideoDataConnection()
                        self.updateTextRecognitionGeometry(
                            orientation: self.videoOrientation,
                            mirrored: self.videoInput?.device.position == .front
                        )
                        self.setTextRecognitionSuspension(
                            .photoCapture,
                            active: false,
                            clearPublishedCandidates: false
                        )
                        self.publish { self.isCapturing = false }
                    }
                }
            )
            self.photoDelegates[settings.uniqueID] = delegate
            self.publish { self.isCapturing = true }
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard output === videoDataOutput,
              textRecognitionEnabled,
              textRecognitionSuspensions.isEmpty,
              activeTextRecognitionRequest == nil else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTextRecognitionTime >= Self.textRecognitionInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lastTextRecognitionTime = now
        let request = Self.makeTextRecognitionRequest()
        let generation = textRecognitionGeneration
        let imageOrientation = Self.visionImageOrientation(
            videoOrientation: recognitionVideoOrientation,
            mirrored: recognitionVideoMirrored
        )
        activeTextRecognitionRequest = request

        // Capturing the CVPixelBuffer retains this sampled frame. Vision runs on
        // its own serial queue, so neither frame delivery nor photo capture waits.
        let retainedPixelBuffer = pixelBuffer
        textRecognitionQueue.async { [weak self] in
            let candidates: [TextRecognitionCandidate]?
            do {
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: retainedPixelBuffer,
                    orientation: imageOrientation,
                    options: [:]
                )
                try handler.perform([request])
                candidates = Self.filteredTextCandidates(from: request)
            } catch {
                candidates = nil
            }

            self?.videoFrameQueue.async { [weak self] in
                guard let self else { return }
                if self.activeTextRecognitionRequest === request {
                    self.activeTextRecognitionRequest = nil
                }
                guard self.textRecognitionEnabled,
                      self.textRecognitionGeneration == generation,
                      let candidates else { return }
                self.updateTextCandidateStability(with: candidates)
            }
        }
    }

    private static func makeTextRecognitionRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.015
        return request
    }

    private static func filteredTextCandidates(
        from request: VNRecognizeTextRequest
    ) -> [TextRecognitionCandidate] {
        var bestCandidateByKey: [String: TextRecognitionCandidate] = [:]

        for observation in request.results ?? [] {
            guard let recognizedText = observation.topCandidates(1).first,
                  recognizedText.confidence >= minimumTextConfidence,
                  let text = sanitizedCandidateText(recognizedText.string),
                  let key = normalizedCandidateKey(text) else { continue }

            let area = observation.boundingBox.width * observation.boundingBox.height
            let areaScore = min(sqrt(Double(area)) / 0.35, 1)
            let rankScore = Double(recognizedText.confidence) * 0.75 + areaScore * 0.25
            let candidate = TextRecognitionCandidate(
                text: text,
                key: key,
                rankScore: rankScore
            )
            if let existing = bestCandidateByKey[key], existing.rankScore >= rankScore {
                continue
            }
            bestCandidateByKey[key] = candidate
        }

        return bestCandidateByKey.values
            .sorted { lhs, rhs in
                if lhs.rankScore == rhs.rankScore {
                    return lhs.text.localizedStandardCompare(rhs.text) == .orderedAscending
                }
                return lhs.rankScore > rhs.rankScore
            }
            .prefix(maximumTextCandidateCount)
            .map { $0 }
    }

    private static func sanitizedCandidateText(_ rawText: String) -> String? {
        let text = rawText
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...48).contains(text.count) else { return nil }

        let scalars = text.unicodeScalars
        let meaningfulCount = scalars.reduce(into: 0) { count, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                count += 1
            }
        }
        guard meaningfulCount > 0,
              Double(meaningfulCount) / Double(max(scalars.count, 1)) >= 0.5 else { return nil }
        return text
    }

    private static func normalizedCandidateKey(_ text: String) -> String? {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "zh-Hans")
        )
        let key = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return key.isEmpty ? nil : key
    }

    private static func visionImageOrientation(
        videoOrientation: AVCaptureVideoOrientation,
        mirrored: Bool
    ) -> CGImagePropertyOrientation {
        // The video-data connection physically rotates buffers to the current
        // AVCaptureVideoOrientation. Vision therefore only needs to account for
        // whether that already-upright buffer was physically mirrored.
        switch videoOrientation {
        case .portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight:
            return mirrored ? .upMirrored : .up
        @unknown default:
            return mirrored ? .upMirrored : .up
        }
    }

    private func updateTextCandidateStability(
        with candidates: [TextRecognitionCandidate]
    ) {
        var nextHits: [String: Int] = [:]
        for candidate in candidates {
            nextHits[candidate.key] = min((consecutiveCandidateHits[candidate.key] ?? 0) + 1, 3)
        }
        consecutiveCandidateHits = nextHits

        let stableCandidates = candidates
            .filter { nextHits[$0.key, default: 0] >= 2 }
            .map(\.text)
        if stableCandidates.isEmpty {
            framesWithoutStableCandidates += 1
            if framesWithoutStableCandidates >= 2 {
                publishRecognizedTextCandidates([])
            }
        } else {
            framesWithoutStableCandidates = 0
            publishRecognizedTextCandidates(stableCandidates)
        }
    }

    private func invalidateTextRecognition(clearPublishedCandidates: Bool) {
        textRecognitionGeneration &+= 1
        activeTextRecognitionRequest?.cancel()
        lastTextRecognitionTime = 0
        consecutiveCandidateHits = [:]
        framesWithoutStableCandidates = 0
        if clearPublishedCandidates {
            publishRecognizedTextCandidates([])
        }
    }

    private func publishRecognizedTextCandidates(_ candidates: [String]) {
        guard lastPublishedTextCandidates != candidates else { return }
        lastPublishedTextCandidates = candidates
        publish { self.recognizedTextCandidates = candidates }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.shouldBeRunning = true
            do {
                if !self.configured {
                    try self.configureSession()
                }
                self.startSessionIfNeeded()
            } catch {
                self.setTextRecognitionSuspension(
                    .session,
                    active: true,
                    clearPublishedCandidates: true,
                    synchronously: true
                )
                self.publishRunningState()
                self.publish { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func startSessionIfNeeded() {
        guard shouldBeRunning, !sessionIsInterrupted else {
            setTextRecognitionSuspension(
                .session,
                active: true,
                clearPublishedCandidates: true,
                synchronously: true
            )
            publishRunningState()
            return
        }

        if !session.isRunning {
            session.startRunning()
        }
        setTextRecognitionSuspension(
            .session,
            active: !session.isRunning,
            clearPublishedCandidates: !session.isRunning,
            synchronously: true
        )
        publishRunningState()
    }

    private func configureSession() throws {
        session.beginConfiguration()
        var addedInput: AVCaptureDeviceInput?
        var addedPhotoOutput = false

        do {
            session.sessionPreset = .photo
            guard let device = Self.camera(position: .back) else {
                throw CameraServiceError.cameraUnavailable
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CameraServiceError.cannotAddInput
            }
            session.addInput(input)
            addedInput = input
            videoInput = input

            guard session.canAddOutput(photoOutput) else {
                throw CameraServiceError.cannotAddOutput
            }
            session.addOutput(photoOutput)
            addedPhotoOutput = true
            photoOutput.maxPhotoQualityPrioritization = .quality
            configurePhotoConnection(cameraPosition: device.position)

            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoFrameQueue)
            guard session.canAddOutput(videoDataOutput) else {
                throw CameraServiceError.cannotAddVideoDataOutput
            }
            session.addOutput(videoDataOutput)
            configureVideoDataConnection(cameraPosition: device.position)

            session.commitConfiguration()

            updateTextRecognitionGeometry(
                orientation: videoOrientation,
                mirrored: device.position == .front
            )
            configured = true
            activeFlashMode = .off
            let maxZoom = min(max(device.activeFormat.videoMaxZoomFactor, 1), 5)
            publish {
                self.isConfigured = true
                self.cameraPosition = device.position
                self.maximumZoomFactor = maxZoom
            }
        } catch {
            if addedPhotoOutput {
                session.removeOutput(photoOutput)
            }
            if let addedInput {
                session.removeInput(addedInput)
            }
            videoDataOutput.setSampleBufferDelegate(nil, queue: nil)
            videoInput = nil
            configured = false
            session.commitConfiguration()
            throw error
        }
    }

    private func configurePhotoConnection(
        cameraPosition: AVCaptureDevice.Position? = nil
    ) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        if connection.isVideoMirroringSupported {
            let position = cameraPosition ?? videoInput?.device.position ?? .back
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
    }

    private func configureVideoDataConnection(
        cameraPosition: AVCaptureDevice.Position? = nil
    ) {
        guard let connection = videoDataOutput.connection(with: .video) else { return }

        // VideoDataOutput physically applies these settings. Vision can then
        // process an upright buffer using .up or .upMirrored without relying on
        // camera-sensor mounting conventions that vary across hardware.
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        if connection.isVideoMirroringSupported {
            let position = cameraPosition ?? videoInput?.device.position ?? .back
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
    }

    private func updateTextRecognitionGeometry(
        orientation: AVCaptureVideoOrientation,
        mirrored: Bool
    ) {
        videoFrameQueue.async { [weak self] in
            guard let self,
                  self.recognitionVideoOrientation != orientation ||
                    self.recognitionVideoMirrored != mirrored else { return }
            self.recognitionVideoOrientation = orientation
            self.recognitionVideoMirrored = mirrored
            self.invalidateTextRecognition(clearPublishedCandidates: true)
        }
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default

        sessionObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionRuntimeError,
                object: session,
                queue: nil
            ) { [weak self] notification in
                self?.sessionQueue.async { [weak self] in
                    self?.handleRuntimeError(notification)
                }
            }
        )

        sessionObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionWasInterrupted,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    self?.handleSessionInterruption()
                }
            }
        )

        sessionObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionInterruptionEnded,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    self?.handleSessionInterruptionEnded()
                }
            }
        )

        sessionObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionDidStartRunning,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    self?.publishRunningState()
                }
            }
        )

        sessionObservers.append(
            center.addObserver(
                forName: .AVCaptureSessionDidStopRunning,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    self?.publishRunningState()
                }
            }
        )
    }

    private func handleRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        setTextRecognitionSuspension(
            .session,
            active: true,
            clearPublishedCandidates: true,
            synchronously: true
        )
        publishRunningState()

        guard error?.code == .mediaServicesWereReset else {
            if shouldBeRunning {
                publish {
                    self.errorMessage = error?.localizedDescription ?? "相机会话发生错误"
                }
            }
            return
        }

        guard shouldBeRunning else { return }
        startSessionIfNeeded()
        if !session.isRunning {
            publish { self.errorMessage = "相机服务恢复失败，请稍后重试" }
        }
    }

    private func handleSessionInterruption() {
        sessionIsInterrupted = true
        setTextRecognitionSuspension(
            .session,
            active: true,
            clearPublishedCandidates: true,
            synchronously: true
        )
        publishRunningState()
        if shouldBeRunning {
            publish { self.errorMessage = "相机暂时不可用，将在中断结束后自动恢复" }
        }
    }

    private func handleSessionInterruptionEnded() {
        sessionIsInterrupted = false
        startSessionIfNeeded()
        if shouldBeRunning, !session.isRunning {
            publish { self.errorMessage = "相机未能自动恢复，请稍后重试" }
        }
    }

    private func publishRunningState() {
        let running = shouldBeRunning && session.isRunning && !sessionIsInterrupted
        publish { self.isRunning = running }
    }

    private static func camera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }

    private func publish(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}

private struct TextRecognitionCandidate {
    let text: String
    let key: String
    let rankScore: Double
}

private enum TextRecognitionSuspension: Hashable {
    case session
    case photoCapture
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let cameraPosition: AVCaptureDevice.Position
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private let didFinish: (Int64) -> Void
    private var result: Result<CapturedPhoto, Error>?

    init(
        cameraPosition: AVCaptureDevice.Position,
        completion: @escaping (Result<CapturedPhoto, Error>) -> Void,
        didFinish: @escaping (Int64) -> Void
    ) {
        self.cameraPosition = cameraPosition
        self.completion = completion
        self.didFinish = didFinish
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation() {
            result = .success(CapturedPhoto(data: data, cameraPosition: cameraPosition))
        } else {
            result = .failure(CameraServiceError.photoDataUnavailable)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let finalResult = result ?? .failure(error ?? CameraServiceError.captureFailed)
        DispatchQueue.main.async { [completion] in completion(finalResult) }
        didFinish(resolvedSettings.uniqueID)
    }
}
