import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

struct CameraScreen: View {
    @StateObject private var camera = CameraService()
    @StateObject private var location = LocationService()
    @StateObject private var settings = WatermarkSettingsStore()

    @Environment(\.scenePhase) private var scenePhase
    @State private var previewSize: CGSize = .zero
    @State private var isProcessing = false
    @State private var editorPresented = false
    @State private var lastThumbnail: UIImage?
    @State private var message: CameraMessage?
    @State private var suggestedRecognizedText: String?
    @State private var ignoredRecognizedTextKeys: Set<String> = []
    @State private var lastAutomaticRecognitionFingerprint: String?
    @State private var suggestionDismissToken = UUID()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                GeometryReader { previewProxy in
                    ZStack {
                        CameraPreview(
                            session: camera.session,
                            cameraPosition: camera.cameraPosition,
                            videoOrientationChanged: camera.setVideoOrientation
                        )
                        .frame(width: previewProxy.size.width, height: previewProxy.size.height)

                        if camera.authorizationStatus == .authorized {
                            DraggableWatermarkCanvas(
                                configuration: $settings.configuration,
                                latitude: location.location?.coordinate.latitude,
                                longitude: location.location?.coordinate.longitude
                            )
                        } else {
                            cameraPermissionOverlay
                        }
                    }
                    .frame(width: previewProxy.size.width, height: previewProxy.size.height)
                    .onAppear { previewSize = previewProxy.size }
                    .onChange(of: previewProxy.size) { previewSize = $0 }
                }
                .ignoresSafeArea()

                cameraChrome

                if isProcessing {
                    processingOverlay
                }

                if let message {
                    toast(message)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $editorPresented) {
            WatermarkEditorSheet(
                configuration: $settings.configuration,
                automaticAddress: location.resolvedAddress,
                refreshLocation: location.refreshLocation
            )
        }
        .onAppear {
            camera.setTextRecognitionEnabled(settings.configuration.textRecognitionMode != .off)
            camera.prepare()
            location.requestAuthorizationAndLocation()
        }
        .onDisappear {
            camera.setTextRecognitionEnabled(false)
            camera.stop()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                camera.start()
                location.requestAuthorizationAndLocation()
            } else if newPhase == .background {
                camera.stop()
            }
        }
        .onReceive(location.$resolvedAddress) { address in
            settings.useAutomaticAddress(address)
        }
        .onReceive(camera.$errorMessage.compactMap { $0 }) { text in
            showMessage(text, kind: .error)
        }
        .onReceive(camera.$recognizedTextCandidates) { candidates in
            handleRecognizedCandidates(candidates)
        }
        .onChange(of: settings.configuration.textRecognitionMode) { mode in
            camera.setTextRecognitionEnabled(mode != .off)
            if mode == .off {
                resetRecognitionPresentation()
            } else {
                lastAutomaticRecognitionFingerprint = nil
                handleRecognizedCandidates(camera.recognizedTextCandidates)
            }
        }
        .onChange(of: settings.configuration.customText) { _ in
            handleRecognizedCandidates(camera.recognizedTextCandidates)
        }
    }

    private var cameraChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                locationStatus
                Spacer()
                circleButton(
                    icon: camera.flashMode == .off ? "bolt.slash.fill" : "bolt.fill",
                    accessibility: "切换闪光灯",
                    action: camera.toggleFlash
                )
                .disabled(camera.isCapturing || isProcessing)
                .opacity(camera.isCapturing || isProcessing ? 0.45 : 1)
                circleButton(
                    icon: "arrow.triangle.2.circlepath.camera.fill",
                    accessibility: "切换前后摄像头",
                    action: camera.switchCamera
                )
                .disabled(camera.isCapturing || isProcessing)
                .opacity(camera.isCapturing || isProcessing ? 0.45 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            recognitionSuggestionBanner

            Spacer()

            VStack(spacing: 14) {
                zoomControl

                HStack {
                    Group {
                        if let lastThumbnail {
                            Image(uiImage: lastThumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(width: 52, height: 52)
                    .background(.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.25)))

                    Spacer()

                    Button(action: capture) {
                        ZStack {
                            Circle().fill(.white)
                            Circle().stroke(.white.opacity(0.85), lineWidth: 4).padding(-7)
                            if camera.isCapturing || isProcessing {
                                ProgressView().tint(.black)
                            }
                        }
                        .frame(width: 70, height: 70)
                    }
                    .disabled(
                        camera.authorizationStatus != .authorized ||
                        !camera.isRunning ||
                        camera.isCapturing ||
                        isProcessing
                    )
                    .accessibilityLabel("拍照")

                    Spacer()

                    Button {
                        editorPresented = true
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "textformat.alt")
                                .font(.title2)
                            Text("水印").font(.caption2)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                    }
                    .accessibilityLabel("编辑水印")
                    .disabled(camera.isCapturing || isProcessing)
                    .opacity(camera.isCapturing || isProcessing ? 0.45 : 1)
                }
                .padding(.horizontal, 26)

                Text("照片模式 · 拖动水印调整位置")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.top, 14)
            .padding(.bottom, 14)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
    }

    private var locationStatus: some View {
        Button(action: location.refreshLocation) {
            HStack(spacing: 7) {
                Image(systemName: location.isLocating ? "location" : "location.fill")
                Text(locationStatusText)
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.black.opacity(0.46), in: Capsule())
        }
        .accessibilityLabel("刷新定位")
    }

    @ViewBuilder
    private var recognitionSuggestionBanner: some View {
        if let suggestedRecognizedText {
            HStack(spacing: 12) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("发现画面文字")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(suggestedRecognizedText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Button("加入水印") {
                    acceptRecognizedText(suggestedRecognizedText)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    dismissRecognizedText(suggestedRecognizedText)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("忽略识别文字")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(5)
        }
    }

    private var locationStatusText: String {
        if location.isLocating { return "正在定位" }
        if let accuracy = location.location?.horizontalAccuracy, accuracy >= 0 {
            return "定位 ±\(Int(accuracy))m"
        }
        return location.isAuthorized ? "点击重试定位" : "位置不可用"
    }

    private var zoomControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
            Slider(
                value: Binding(
                    get: { Double(camera.zoomFactor) },
                    set: { camera.setZoom(CGFloat($0)) }
                ),
                in: 1...Double(max(camera.maximumZoomFactor, 1))
            )
            .tint(.white)
            Text(String(format: "%.1f×", camera.zoomFactor))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 40)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: 250, height: 36)
        .background(.black.opacity(0.42), in: Capsule())
        .disabled(camera.isCapturing || isProcessing)
        .opacity(camera.isCapturing || isProcessing ? 0.45 : 1)
    }

    private var cameraPermissionOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 38))
            Text(permissionTitle)
                .font(.headline)
            Text("需要相机权限才能拍摄；定位权限可选，拒绝后仍可使用时间和自定义文字水印。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            if camera.authorizationStatus == .denied || camera.authorizationStatus == .restricted {
                Button("前往系统设置") { openSystemSettings() }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    private var permissionTitle: String {
        switch camera.authorizationStatus {
        case .denied, .restricted: "相机权限未开启"
        default: "正在准备相机"
        }
    }

    private var processingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("正在合成水印并保存…")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func toast(_ message: CameraMessage) -> some View {
        HStack(spacing: 9) {
            Image(systemName: message.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(message.kind == .success ? .green : .orange)
            Text(message.text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func circleButton(icon: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.46), in: Circle())
        }
        .accessibilityLabel(accessibility)
    }

    private func capture() {
        guard !isProcessing else { return }
        isProcessing = true
        let capturedAt = Date()
        var frozenConfiguration = settings.configuration
        if !frozenConfiguration.usesCustomAddress,
           location.location == nil {
            frozenConfiguration.addressText = location.resolvedAddress ?? "未获取位置"
        }
        let coordinate = location.location?.coordinate
        let snapshot = WatermarkSnapshot(
            configuration: frozenConfiguration,
            capturedAt: capturedAt,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        )
        let frozenPreviewSize = previewSize

        camera.capturePhoto { result in
            switch result {
            case .success(let capturedPhoto):
                PhotoProcessingService.renderAndSave(
                    capturedPhoto: capturedPhoto,
                    snapshot: snapshot,
                    previewSize: frozenPreviewSize
                ) { processingResult in
                    isProcessing = false
                    switch processingResult {
                    case .success(let processed):
                        lastThumbnail = processed.thumbnail
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        showMessage("已保存带水印照片", kind: .success)
                    case .failure(let error):
                        showMessage(error.localizedDescription, kind: .error)
                    }
                }
            case .failure(let error):
                isProcessing = false
                showMessage(error.localizedDescription, kind: .error)
            }
        }
    }

    private func handleRecognizedCandidates(_ rawCandidates: [String]) {
        let candidates = rawCandidates.compactMap(cleanRecognizedText)

        guard settings.configuration.textRecognitionMode != .off else {
            resetRecognitionPresentation()
            return
        }

        guard !candidates.isEmpty else {
            withAnimation { suggestedRecognizedText = nil }
            lastAutomaticRecognitionFingerprint = nil
            return
        }

        switch settings.configuration.textRecognitionMode {
        case .off:
            break
        case .suggest:
            if let current = suggestedRecognizedText,
               candidates.contains(where: { recognitionKey($0) == recognitionKey(current) }),
               !customTextContains(current) {
                return
            }

            let next = candidates.first {
                let key = recognitionKey($0)
                return !ignoredRecognizedTextKeys.contains(key) && !customTextContains($0)
            }
            presentRecognitionSuggestion(next)

        case .automatic:
            withAnimation { suggestedRecognizedText = nil }
            let fingerprint = candidates
                .map(recognitionKey)
                .sorted()
                .joined(separator: "|")
            guard fingerprint != lastAutomaticRecognitionFingerprint else { return }
            lastAutomaticRecognitionFingerprint = fingerprint

            guard let candidate = candidates.first(where: { !customTextContains($0) }),
                  appendRecognizedText(candidate) else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showMessage("已自动加入：\(recognitionSummary(candidate))", kind: .success)
        }
    }

    private func acceptRecognizedText(_ text: String) {
        guard appendRecognizedText(text) else { return }
        ignoredRecognizedTextKeys.insert(recognitionKey(text))
        suggestionDismissToken = UUID()
        withAnimation { suggestedRecognizedText = nil }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showMessage("已加入水印：\(recognitionSummary(text))", kind: .success)
    }

    private func dismissRecognizedText(_ text: String) {
        ignoredRecognizedTextKeys.insert(recognitionKey(text))
        suggestionDismissToken = UUID()
        withAnimation { suggestedRecognizedText = nil }
    }

    @discardableResult
    private func appendRecognizedText(_ text: String) -> Bool {
        guard let cleaned = cleanRecognizedText(text) else { return false }

        settings.configuration.showCustomText = true
        if customTextContains(cleaned) {
            return true
        }

        let existing = settings.configuration.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = existing.isEmpty ? cleaned : "\(existing)\n\(cleaned)"
        guard combined.count <= 300 else {
            showMessage("自定义文字过长，请先在水印编辑中整理", kind: .error)
            return false
        }
        settings.configuration.customText = combined
        return true
    }

    private func customTextContains(_ candidate: String) -> Bool {
        let key = recognitionKey(candidate)
        return settings.configuration.customText
            .components(separatedBy: .newlines)
            .contains { recognitionKey($0) == key }
    }

    private func cleanRecognizedText(_ text: String) -> String? {
        let cleaned = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2, cleaned.count <= 80 else { return nil }
        return cleaned
    }

    private func recognitionKey(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .filter { !$0.isWhitespace }
    }

    private func recognitionSummary(_ text: String) -> String {
        guard text.count > 18 else { return text }
        return "\(text.prefix(18))…"
    }


    private func presentRecognitionSuggestion(_ text: String?) {
        withAnimation { suggestedRecognizedText = text }
        guard let text else { return }
        let token = UUID()
        suggestionDismissToken = token
        let duration = settings.configuration.recognitionSuggestionDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard suggestionDismissToken == token,
                  suggestedRecognizedText == text else { return }
            withAnimation { suggestedRecognizedText = nil }
        }
    }

    private func resetRecognitionPresentation() {
        suggestionDismissToken = UUID()
        withAnimation { suggestedRecognizedText = nil }
        ignoredRecognizedTextKeys.removeAll()
        lastAutomaticRecognitionFingerprint = nil
    }

    private func showMessage(_ text: String, kind: CameraMessage.Kind) {
        withAnimation { message = CameraMessage(text: text, kind: kind) }
        let shownMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if message == shownMessage {
                withAnimation { message = nil }
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct CameraMessage: Equatable {
    enum Kind: Equatable { case success, error }
    let text: String
    let kind: Kind
}
