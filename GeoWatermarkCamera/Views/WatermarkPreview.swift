import SwiftUI

struct WatermarkPreview: View {
    let snapshot: WatermarkSnapshot
    let scale: CGFloat
    let maximumTextWidth: CGFloat
    var showsCloseControl: Bool = false
    var onCloseCustomText: (() -> Void)? = nil

    private var isCard: Bool { snapshot.configuration.template == .card }

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            if snapshot.hasPrimaryContent {
                primaryBlock
            }

            if snapshot.hasCustomTextContent {
                customTextBlock
            }

            if !snapshot.hasPrimaryContent && !snapshot.hasCustomTextContent {
                emptyBlock
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("水印预览")
    }

    private var primaryBlock: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            ForEach(snapshot.primaryLines) { line in
                Text(line.text)
                    .font(font(for: line))
                    .foregroundStyle(foregroundColor(for: line))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: maximumTextWidth, alignment: .leading)
        .padding(.horizontal, (isCard ? 17 : 12) * scale)
        .padding(.vertical, (isCard ? 13 : 10) * scale)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: (isCard ? 12 : 9) * scale, style: .continuous)
                    .fill(
                        isCard
                            ? Color.white.opacity(snapshot.configuration.backgroundOpacity)
                            : Color.black.opacity(snapshot.configuration.backgroundOpacity)
                    )
                if isCard {
                    Capsule()
                        .fill(Color.blue.opacity(snapshot.configuration.backgroundOpacity))
                        .frame(width: 4 * scale)
                        .padding(.vertical, 10 * scale)
                }
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(isCard ? 0.18 : 0.08), radius: 6 * scale, y: 2 * scale)
    }

    private var customTextBlock: some View {
        HStack(alignment: .top, spacing: 8 * scale) {
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("自定义")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                ForEach(snapshot.customTextLines) { line in
                    Text(line.text)
                        .font(.system(size: 13.5 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsCloseControl {
                Button {
                    onCloseCustomText?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background(Color.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭自定义文字")
            }
        }
        .frame(maxWidth: maximumTextWidth, alignment: .leading)
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .background {
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Color(red: 0.12, green: 0.28, blue: 0.55).opacity(0.88))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 6 * scale, y: 2 * scale)
    }

    private var emptyBlock: some View {
        Text("水印内容已关闭")
            .font(.system(size: 12.5 * scale, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 10 * scale)
            .background(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
    }

    private func font(for line: WatermarkSnapshot.Line) -> Font {
        let isHeading = line.kind == .dateTime
        return .system(
            size: (isHeading ? 16 : 12.5) * scale,
            weight: isHeading ? .bold : .regular
        )
    }

    private func foregroundColor(for line: WatermarkSnapshot.Line) -> Color {
        if !isCard { return .white }
        return line.kind == .dateTime
            ? Color(white: 0.08)
            : Color(white: 0.24)
    }
}

struct CustomTextBadgePreview: View {
    let text: String
    let scale: CGFloat
    let maximumTextWidth: CGFloat
    var showsCloseControl: Bool = true
    var onClose: (() -> Void)? = nil

    var body: some View {
        let snapshot = WatermarkSnapshot(
            configuration: {
                var configuration = WatermarkConfiguration.default
                configuration.showDateTime = false
                configuration.showCoordinates = false
                configuration.showAddress = false
                configuration.showCustomText = true
                configuration.customText = text
                return configuration
            }(),
            capturedAt: Date(),
            latitude: nil,
            longitude: nil
        )

        WatermarkPreview(
            snapshot: snapshot,
            scale: scale,
            maximumTextWidth: maximumTextWidth,
            showsCloseControl: showsCloseControl,
            onCloseCustomText: onClose
        )
    }
}

struct DraggableWatermarkCanvas: View {
    @Binding var configuration: WatermarkConfiguration
    let latitude: Double?
    let longitude: Double?

    @State private var activeDragTarget: WatermarkDragTarget?
    @State private var dragStart: CGPoint?
    @State private var dragTranslation: CGSize = .zero
    @State private var primarySize: CGSize = .zero
    @State private var customSize: CGSize = .zero
    @State private var verticalGuide: CGFloat?
    @State private var horizontalGuide: CGFloat?
    @State private var magnificationStart: Double?
    @State private var magnificationTarget: WatermarkDragTarget?

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let snapshot = WatermarkSnapshot(
                    configuration: configuration,
                    capturedAt: timeline.date,
                    latitude: latitude,
                    longitude: longitude
                )

                ZStack {
                    guides(in: proxy.size)

                    if snapshot.hasPrimaryContent {
                        let primarySnapshot = WatermarkSnapshot(
                            configuration: {
                                var value = configuration
                                value.showCustomText = false
                                return value
                            }(),
                            capturedAt: timeline.date,
                            latitude: latitude,
                            longitude: longitude
                        )

                        WatermarkPreview(
                            snapshot: primarySnapshot,
                            scale: CGFloat(configuration.placement.scale),
                            maximumTextWidth: proxy.size.width * 0.78 * CGFloat(configuration.placement.scale)
                        )
                        .background(SizeReporter(target: .primary))
                        .onPreferenceChange(PrimarySizePreferenceKey.self) { primarySize = $0 }
                        .position(displayedCenter(for: .primary, in: proxy.size))
                        .contentShape(Rectangle())
                        .gesture(dragGesture(for: .primary, in: proxy.size))
                        .simultaneousGesture(magnificationGesture(for: .primary))
                        .accessibilityHint("拖动可移动主水印，双指可缩放")
                    }

                    if snapshot.hasCustomTextContent {
                        let customSnapshot = WatermarkSnapshot(
                            configuration: {
                                var value = configuration
                                value.showDateTime = false
                                value.showCoordinates = false
                                value.showAddress = false
                                return value
                            }(),
                            capturedAt: timeline.date,
                            latitude: nil,
                            longitude: nil
                        )

                        WatermarkPreview(
                            snapshot: customSnapshot,
                            scale: CGFloat(configuration.customTextPlacement.scale),
                            maximumTextWidth: proxy.size.width * 0.72 * CGFloat(configuration.customTextPlacement.scale),
                            showsCloseControl: true,
                            onCloseCustomText: {
                                configuration.showCustomText = false
                            }
                        )
                        .background(SizeReporter(target: .customText))
                        .onPreferenceChange(CustomSizePreferenceKey.self) { customSize = $0 }
                        .position(displayedCenter(for: .customText, in: proxy.size))
                        .contentShape(Rectangle())
                        .gesture(dragGesture(for: .customText, in: proxy.size))
                        .simultaneousGesture(magnificationGesture(for: .customText))
                        .accessibilityHint("拖动可移动自定义文字，点叉可关闭")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func guides(in size: CGSize) -> some View {
        if let verticalGuide {
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: 1, height: size.height)
                .position(x: verticalGuide, y: size.height / 2)
                .allowsHitTesting(false)
        }
        if let horizontalGuide {
            Rectangle()
                .fill(Color.yellow.opacity(0.9))
                .frame(width: size.width, height: 1)
                .position(x: size.width / 2, y: horizontalGuide)
                .allowsHitTesting(false)
        }
    }

    private func displayedCenter(for target: WatermarkDragTarget, in size: CGSize) -> CGPoint {
        let saved = savedCenter(for: target, in: size)
        guard activeDragTarget == target else { return clamped(saved, for: target, in: size) }
        let source = dragStart ?? saved
        return clamped(
            CGPoint(
                x: source.x + dragTranslation.width,
                y: source.y + dragTranslation.height
            ),
            for: target,
            in: size
        )
    }

    private func savedCenter(for target: WatermarkDragTarget, in size: CGSize) -> CGPoint {
        switch target {
        case .primary:
            return CGPoint(
                x: CGFloat(configuration.placement.x) * size.width,
                y: CGFloat(configuration.placement.y) * size.height
            )
        case .customText:
            return CGPoint(
                x: CGFloat(configuration.customTextPlacement.x) * size.width,
                y: CGFloat(configuration.customTextPlacement.y) * size.height
            )
        }
    }

    private func dragGesture(for target: WatermarkDragTarget, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if activeDragTarget != target {
                    activeDragTarget = target
                    dragStart = savedCenter(for: target, in: size)
                    dragTranslation = .zero
                }
                dragTranslation = value.translation
                updateGuides(for: displayedCenter(for: target, in: size), in: size)
            }
            .onEnded { _ in
                let proposed = displayedCenter(for: target, in: size)
                let snapped = snappedCenter(proposed, for: target, in: size)
                switch target {
                case .primary:
                    configuration.placement.x = Double(snapped.x / max(size.width, 1))
                    configuration.placement.y = Double(snapped.y / max(size.height, 1))
                case .customText:
                    configuration.customTextPlacement.x = Double(snapped.x / max(size.width, 1))
                    configuration.customTextPlacement.y = Double(snapped.y / max(size.height, 1))
                }
                activeDragTarget = nil
                dragStart = nil
                dragTranslation = .zero
                verticalGuide = nil
                horizontalGuide = nil
            }
    }

    private func magnificationGesture(for target: WatermarkDragTarget) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if magnificationTarget != target {
                    magnificationTarget = target
                    switch target {
                    case .primary:
                        magnificationStart = configuration.placement.scale
                    case .customText:
                        magnificationStart = configuration.customTextPlacement.scale
                    }
                }
                let base: Double
                switch target {
                case .primary:
                    base = magnificationStart ?? configuration.placement.scale
                    configuration.placement.scale = min(max(base * Double(value), 0.65), 1.65)
                case .customText:
                    base = magnificationStart ?? configuration.customTextPlacement.scale
                    configuration.customTextPlacement.scale = min(max(base * Double(value), 0.65), 1.65)
                }
            }
            .onEnded { _ in
                magnificationStart = nil
                magnificationTarget = nil
            }
    }

    private func updateGuides(for point: CGPoint, in size: CGSize) {
        let threshold: CGFloat = 13
        let xTargets = [size.width / 3, size.width / 2, size.width * 2 / 3]
        let yTargets = [size.height / 3, size.height / 2, size.height * 2 / 3]
        verticalGuide = xTargets.min(by: { abs($0 - point.x) < abs($1 - point.x) })
            .flatMap { abs($0 - point.x) <= threshold ? $0 : nil }
        horizontalGuide = yTargets.min(by: { abs($0 - point.y) < abs($1 - point.y) })
            .flatMap { abs($0 - point.y) <= threshold ? $0 : nil }
    }

    private func snappedCenter(_ point: CGPoint, for target: WatermarkDragTarget, in size: CGSize) -> CGPoint {
        let threshold: CGFloat = 13
        let watermarkSize = measuredSize(for: target)
        let halfWidth = watermarkSize.width / 2
        let halfHeight = watermarkSize.height / 2
        let xTargets = [
            halfWidth + 10,
            size.width / 3,
            size.width / 2,
            size.width * 2 / 3,
            size.width - halfWidth - 10
        ]
        let yTargets = [
            halfHeight + 10,
            size.height / 3,
            size.height / 2,
            size.height * 2 / 3,
            size.height - halfHeight - 10
        ]
        let snappedX = xTargets.min(by: { abs($0 - point.x) < abs($1 - point.x) })
            .flatMap { abs($0 - point.x) <= threshold ? $0 : nil } ?? point.x
        let snappedY = yTargets.min(by: { abs($0 - point.y) < abs($1 - point.y) })
            .flatMap { abs($0 - point.y) <= threshold ? $0 : nil } ?? point.y
        return clamped(CGPoint(x: snappedX, y: snappedY), for: target, in: size)
    }

    private func clamped(_ point: CGPoint, for target: WatermarkDragTarget, in size: CGSize) -> CGPoint {
        let watermarkSize = measuredSize(for: target)
        let halfWidth = min(watermarkSize.width / 2, size.width / 2)
        let halfHeight = min(watermarkSize.height / 2, size.height / 2)
        return CGPoint(
            x: min(max(point.x, halfWidth + 6), max(size.width - halfWidth - 6, halfWidth + 6)),
            y: min(max(point.y, halfHeight + 6), max(size.height - halfHeight - 6, halfHeight + 6))
        )
    }

    private func measuredSize(for target: WatermarkDragTarget) -> CGSize {
        switch target {
        case .primary: primarySize
        case .customText: customSize
        }
    }
}

private enum WatermarkDragTarget {
    case primary
    case customText
}

private struct SizeReporter: View {
    let target: WatermarkDragTarget

    var body: some View {
        GeometryReader { proxy in
            Group {
                if target == .primary {
                    Color.clear.preference(key: PrimarySizePreferenceKey.self, value: proxy.size)
                } else {
                    Color.clear.preference(key: CustomSizePreferenceKey.self, value: proxy.size)
                }
            }
        }
    }
}

private struct PrimarySizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct CustomSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
