import CoreImage
import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct ProcessedPhoto {
    let thumbnail: UIImage
}

enum PhotoProcessingError: LocalizedError {
    case cannotDecodeImage
    case cannotCreateCanvas
    case cannotEncodeJPEG
    case photoLibraryDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .cannotDecodeImage: "无法读取拍摄的照片"
        case .cannotCreateCanvas: "无法创建水印画布"
        case .cannotEncodeJPEG: "无法生成带水印的照片"
        case .photoLibraryDenied: "没有添加照片到相册的权限"
        case .saveFailed: "照片保存失败"
        }
    }
}

enum PhotoProcessingService {
    private static let processingQueue = DispatchQueue(
        label: "com.example.GeoWatermarkCamera.photo-processing",
        qos: .userInitiated
    )

    static func renderAndSave(
        capturedPhoto: CapturedPhoto,
        snapshot: WatermarkSnapshot,
        previewSize: CGSize,
        completion: @escaping (Result<ProcessedPhoto, Error>) -> Void
    ) {
        processingQueue.async {
            do {
                let artifact = try WatermarkRenderer.render(
                    sourceData: capturedPhoto.data,
                    snapshot: snapshot,
                    previewSize: previewSize
                )
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("GeoWatermark-\(UUID().uuidString)")
                    .appendingPathExtension("jpg")
                try artifact.jpegData.write(to: fileURL, options: .atomic)

                PhotoLibraryWriter.savePhoto(at: fileURL) { result in
                    try? FileManager.default.removeItem(at: fileURL)
                    DispatchQueue.main.async {
                        switch result {
                        case .success:
                            completion(.success(ProcessedPhoto(thumbnail: artifact.thumbnail)))
                        case .failure(let error):
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

private struct RenderedPhotoArtifact {
    let jpegData: Data
    let thumbnail: UIImage
}

private enum WatermarkRenderer {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func render(
        sourceData: Data,
        snapshot: WatermarkSnapshot,
        previewSize: CGSize
    ) throws -> RenderedPhotoArtifact {
        guard let orientedCIImage = CIImage(
            data: sourceData,
            options: [.applyOrientationProperty: true]
        ) else {
            throw PhotoProcessingError.cannotDecodeImage
        }

        let originalExtent = orientedCIImage.extent.integral
        let normalizedCIImage = orientedCIImage.transformed(
            by: CGAffineTransform(
                translationX: -originalExtent.minX,
                y: -originalExtent.minY
            )
        )
        let normalizedExtent = normalizedCIImage.extent.integral
        guard let sourceCGImage = ciContext.createCGImage(normalizedCIImage, from: normalizedExtent) else {
            throw PhotoProcessingError.cannotDecodeImage
        }

        let imageSize = CGSize(width: sourceCGImage.width, height: sourceCGImage.height)
        let canvasFormat = UIGraphicsImageRendererFormat()
        canvasFormat.scale = 1
        canvasFormat.opaque = true
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: canvasFormat)
        let outputImage = renderer.image { rendererContext in
            UIImage(cgImage: sourceCGImage).draw(in: CGRect(origin: .zero, size: imageSize))
            drawWatermark(
                snapshot: snapshot,
                previewSize: previewSize,
                imageSize: imageSize,
                in: rendererContext.cgContext
            )
        }

        guard let outputCGImage = outputImage.cgImage else {
            throw PhotoProcessingError.cannotCreateCanvas
        }
        let encoded = try encodeJPEG(
            sourceData: sourceData,
            outputImage: outputCGImage,
            snapshot: snapshot
        )
        return RenderedPhotoArtifact(
            jpegData: encoded,
            thumbnail: makeThumbnail(from: outputImage)
        )
    }

    private static func drawWatermark(
        snapshot: WatermarkSnapshot,
        previewSize rawPreviewSize: CGSize,
        imageSize: CGSize,
        in context: CGContext
    ) {
        let previewSize: CGSize
        if rawPreviewSize.width > 1, rawPreviewSize.height > 1 {
            previewSize = rawPreviewSize
        } else {
            previewSize = CGSize(width: 390, height: 844)
        }

        let pixelsPerPreviewPoint = PreviewGeometryMapper.pixelsPerPreviewPoint(
            previewSize: previewSize,
            imageSize: imageSize
        )
        let margin = 6 * pixelsPerPreviewPoint

        if snapshot.hasPrimaryContent {
            let primaryScale = pixelsPerPreviewPoint * CGFloat(snapshot.configuration.placement.scale)
            let maximumTextWidth = min(
                imageSize.width * 0.82,
                previewSize.width * 0.78 * pixelsPerPreviewPoint * CGFloat(snapshot.configuration.placement.scale)
            )
            let drawing = WatermarkDrawing(
                lines: snapshot.primaryLines,
                style: .primary(template: snapshot.configuration.template),
                backgroundOpacity: CGFloat(snapshot.configuration.backgroundOpacity),
                scale: primaryScale,
                maximumTextWidth: maximumTextWidth
            )
            let origin = origin(
                for: drawing.size,
                normalizedX: snapshot.configuration.placement.x,
                normalizedY: snapshot.configuration.placement.y,
                previewSize: previewSize,
                imageSize: imageSize,
                margin: margin
            )
            drawing.draw(at: origin, in: context)
        }

        if snapshot.hasCustomTextContent {
            let customScale = pixelsPerPreviewPoint * CGFloat(snapshot.configuration.customTextPlacement.scale)
            let maximumTextWidth = min(
                imageSize.width * 0.78,
                previewSize.width * 0.72 * pixelsPerPreviewPoint * CGFloat(snapshot.configuration.customTextPlacement.scale)
            )
            let drawing = WatermarkDrawing(
                lines: snapshot.customTextLines,
                style: .customText,
                backgroundOpacity: 0.88,
                scale: customScale,
                maximumTextWidth: maximumTextWidth
            )
            let origin = origin(
                for: drawing.size,
                normalizedX: snapshot.configuration.customTextPlacement.x,
                normalizedY: snapshot.configuration.customTextPlacement.y,
                previewSize: previewSize,
                imageSize: imageSize,
                margin: margin
            )
            drawing.draw(at: origin, in: context)
        }
    }

    private static func origin(
        for size: CGSize,
        normalizedX: Double,
        normalizedY: Double,
        previewSize: CGSize,
        imageSize: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let center = PreviewGeometryMapper.imagePoint(
            normalizedX: CGFloat(normalizedX).clamped(to: 0...1),
            normalizedY: CGFloat(normalizedY).clamped(to: 0...1),
            previewSize: previewSize,
            imageSize: imageSize
        )
        let proposedOrigin = CGPoint(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2
        )
        let maximumX = max(imageSize.width - size.width - margin, margin)
        let maximumY = max(imageSize.height - size.height - margin, margin)
        return CGPoint(
            x: proposedOrigin.x.clamped(to: margin...maximumX),
            y: proposedOrigin.y.clamped(to: margin...maximumY)
        )
    }

    private static func encodeJPEG(
        sourceData: Data,
        outputImage: CGImage,
        snapshot: WatermarkSnapshot
    ) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoProcessingError.cannotEncodeJPEG
        }

        var metadata: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
           let copied = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            metadata = copied
        }

        metadata[kCGImagePropertyOrientation] = 1
        metadata[kCGImagePropertyPixelWidth] = outputImage.width
        metadata[kCGImagePropertyPixelHeight] = outputImage.height
        metadata[kCGImageDestinationLossyCompressionQuality] = 0.95

        var tiff = metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        metadata[kCGImagePropertyTIFFDictionary] = tiff

        var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = outputImage.width
        exif[kCGImagePropertyExifPixelYDimension] = outputImage.height
        metadata[kCGImagePropertyExifDictionary] = exif

        if let latitude = snapshot.latitude, let longitude = snapshot.longitude {
            metadata[kCGImagePropertyGPSDictionary] = gpsMetadata(
                latitude: latitude,
                longitude: longitude,
                capturedAt: snapshot.capturedAt
            )
        }

        CGImageDestinationAddImage(destination, outputImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoProcessingError.cannotEncodeJPEG
        }
        return mutableData as Data
    }

    private static func gpsMetadata(
        latitude: Double,
        longitude: Double,
        capturedAt: Date
    ) -> [CFString: Any] {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timeFormatter.dateFormat = "HH:mm:ss.SSSSSS"

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyy:MM:dd"

        return [
            kCGImagePropertyGPSLatitude: abs(latitude),
            kCGImagePropertyGPSLatitudeRef: latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(longitude),
            kCGImagePropertyGPSLongitudeRef: longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSTimeStamp: timeFormatter.string(from: capturedAt),
            kCGImagePropertyGPSDateStamp: dateFormatter.string(from: capturedAt)
        ]
    }

    private static func makeThumbnail(from image: UIImage) -> UIImage {
        let maximumDimension: CGFloat = 420
        let scale = min(maximumDimension / max(image.size.width, image.size.height), 1)
        guard scale < 1 else { return image }
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private struct WatermarkDrawing {
    enum Style {
        case primary(template: WatermarkTemplate)
        case customText
    }

    private struct MeasuredLine {
        let line: WatermarkSnapshot.Line
        let attributes: [NSAttributedString.Key: Any]
        let size: CGSize
    }

    let size: CGSize
    private let style: Style
    private let backgroundOpacity: CGFloat
    private let scale: CGFloat
    private let padding: UIEdgeInsets
    private let lineSpacing: CGFloat
    private let lines: [MeasuredLine]
    private let showsCustomCaption: Bool

    init(
        lines sourceLines: [WatermarkSnapshot.Line],
        style: Style,
        backgroundOpacity: CGFloat,
        scale: CGFloat,
        maximumTextWidth: CGFloat
    ) {
        self.style = style
        self.backgroundOpacity = backgroundOpacity
        self.scale = scale
        self.showsCustomCaption = {
            if case .customText = style { return true }
            return false
        }()

        let horizontalInset: CGFloat
        let verticalInset: CGFloat
        switch style {
        case .primary(let template):
            horizontalInset = (template == .card ? 17 : 12) * scale
            verticalInset = (template == .card ? 13 : 10) * scale
        case .customText:
            horizontalInset = 12 * scale
            verticalInset = 10 * scale
        }
        self.padding = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
        self.lineSpacing = 5 * scale

        let constrainedWidth = max(maximumTextWidth, 120 * scale)
        var measured: [MeasuredLine] = []
        var widest: CGFloat = 0
        var totalHeight: CGFloat = 0

        if showsCustomCaption {
            let caption = "自定义"
            let attributes = Self.captionAttributes(scale: scale)
            let bounds = (caption as NSString).boundingRect(
                with: CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            ).integral
            let lineSize = CGSize(width: min(bounds.width, constrainedWidth), height: bounds.height)
            measured.append(
                MeasuredLine(
                    line: .init(kind: .custom, text: caption),
                    attributes: attributes,
                    size: lineSize
                )
            )
            widest = max(widest, lineSize.width)
            totalHeight += lineSize.height + (2 * scale)
        }

        for line in sourceLines {
            let attributes = Self.attributes(for: line, style: style, scale: scale)
            let bounds = (line.text as NSString).boundingRect(
                with: CGSize(width: constrainedWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            ).integral
            let lineSize = CGSize(width: min(bounds.width, constrainedWidth), height: bounds.height)
            measured.append(MeasuredLine(line: line, attributes: attributes, size: lineSize))
            widest = max(widest, lineSize.width)
            totalHeight += lineSize.height
        }

        totalHeight += CGFloat(max(measured.count - 1, 0)) * lineSpacing
        self.lines = measured
        self.size = CGSize(
            width: ceil(widest + padding.left + padding.right),
            height: ceil(totalHeight + padding.top + padding.bottom)
        )
    }

    func draw(at origin: CGPoint, in context: CGContext) {
        context.saveGState()
        let rect = CGRect(origin: origin, size: size)

        switch style {
        case .primary(let template):
            let cornerRadius = (template == .card ? 12 : 9) * scale
            let backgroundColor: UIColor = template == .card
                ? UIColor.white.withAlphaComponent(backgroundOpacity)
                : UIColor.black.withAlphaComponent(backgroundOpacity)
            context.setFillColor(backgroundColor.cgColor)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).cgPath)
            context.fillPath()

            if template == .card {
                let barRect = CGRect(
                    x: origin.x,
                    y: origin.y + 10 * scale,
                    width: 4 * scale,
                    height: max(size.height - 20 * scale, 4 * scale)
                )
                context.setFillColor(UIColor.systemBlue.withAlphaComponent(backgroundOpacity).cgColor)
                context.addPath(UIBezierPath(roundedRect: barRect, cornerRadius: 2 * scale).cgPath)
                context.fillPath()
            }

        case .customText:
            let cornerRadius = 10 * scale
            let backgroundColor = UIColor(red: 0.12, green: 0.28, blue: 0.55, alpha: backgroundOpacity)
            context.setFillColor(backgroundColor.cgColor)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).cgPath)
            context.fillPath()
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
            context.setLineWidth(1)
            context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).cgPath)
            context.strokePath()
        }

        var y = origin.y + padding.top
        for measured in lines {
            let drawRect = CGRect(
                x: origin.x + padding.left,
                y: y,
                width: measured.size.width,
                height: measured.size.height
            )
            (measured.line.text as NSString).draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: measured.attributes,
                context: nil
            )
            y += measured.size.height + lineSpacing
        }
        context.restoreGState()
    }

    private static func attributes(
        for line: WatermarkSnapshot.Line,
        style: Style,
        scale: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5 * scale

        switch style {
        case .primary(let template):
            let isHeading = line.kind == .dateTime
            let fontSize = (isHeading ? 16 : 12.5) * scale
            let font: UIFont = isHeading
                ? .systemFont(ofSize: fontSize, weight: .bold)
                : .systemFont(ofSize: fontSize, weight: .regular)
            let color: UIColor
            if template == .compact {
                color = .white
            } else if isHeading {
                color = UIColor(white: 0.08, alpha: 1)
            } else {
                color = UIColor(white: 0.24, alpha: 1)
            }
            return [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]

        case .customText:
            return [
                .font: UIFont.systemFont(ofSize: 13.5 * scale, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
        }
    }

    private static func captionAttributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: UIFont.systemFont(ofSize: 10 * scale, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.72),
            .paragraphStyle: paragraph
        ]
    }
}

private enum PhotoLibraryWriter {
    static func savePhoto(at fileURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            performSave(fileURL: fileURL, completion: completion)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                guard newStatus == .authorized || newStatus == .limited else {
                    completion(.failure(PhotoProcessingError.photoLibraryDenied))
                    return
                }
                performSave(fileURL: fileURL, completion: completion)
            }
        case .restricted, .denied:
            completion(.failure(PhotoProcessingError.photoLibraryDenied))
        @unknown default:
            completion(.failure(PhotoProcessingError.photoLibraryDenied))
        }
    }

    private static func performSave(
        fileURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "定位水印-\(Int(Date().timeIntervalSince1970)).jpg"
            request.addResource(with: .photo, fileURL: fileURL, options: options)
        } completionHandler: { success, error in
            if success {
                completion(.success(()))
            } else {
                completion(.failure(error ?? PhotoProcessingError.saveFailed))
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
