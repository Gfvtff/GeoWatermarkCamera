import CoreGraphics

enum PreviewGeometryMapper {
    /// Maps a normalized point from an aspect-fill preview into an upright output image.
    static func imagePoint(
        normalizedX: CGFloat,
        normalizedY: CGFloat,
        previewSize: CGSize,
        imageSize: CGSize
    ) -> CGPoint {
        guard previewSize.width > 0,
              previewSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            return CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)
        }

        let aspectFillScale = max(
            previewSize.width / imageSize.width,
            previewSize.height / imageSize.height
        )
        let displayedImageSize = CGSize(
            width: imageSize.width * aspectFillScale,
            height: imageSize.height * aspectFillScale
        )
        let croppedOffset = CGPoint(
            x: max((displayedImageSize.width - previewSize.width) / 2, 0),
            y: max((displayedImageSize.height - previewSize.height) / 2, 0)
        )
        return CGPoint(
            x: (min(max(normalizedX, 0), 1) * previewSize.width + croppedOffset.x) / aspectFillScale,
            y: (min(max(normalizedY, 0), 1) * previewSize.height + croppedOffset.y) / aspectFillScale
        )
    }

    static func pixelsPerPreviewPoint(previewSize: CGSize, imageSize: CGSize) -> CGFloat {
        guard previewSize.width > 0,
              previewSize.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else { return 1 }
        return 1 / max(
            previewSize.width / imageSize.width,
            previewSize.height / imageSize.height
        )
    }
}
