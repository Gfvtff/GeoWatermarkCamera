import Foundation

enum WatermarkTemplate: String, Codable, CaseIterable, Identifiable {
    case compact
    case card

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "简约黑底"
        case .card: "白色卡片"
        }
    }
}

enum CoordinateDisplayFormat: String, Codable, CaseIterable, Identifiable {
    case decimal
    case degreesMinutesSeconds
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .decimal: "十进制度"
        case .degreesMinutesSeconds: "度分秒"
        case .both: "两种同时显示"
        }
    }
}

enum TextRecognitionMode: String, Codable, CaseIterable, Identifiable {
    case off
    case suggest
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .suggest: "提示"
        case .automatic: "自动"
        }
    }
}

struct WatermarkPlacement: Codable, Equatable {
    /// Center point in the visible camera preview, normalized to 0...1.
    var x: Double = 0.5
    var y: Double = 0.72
    var scale: Double = 1

    static let `default` = WatermarkPlacement()
}

struct CustomTextPlacement: Codable, Equatable {
    /// Center point in the visible camera preview, normalized to 0...1.
    var x: Double = 0.5
    var y: Double = 0.18
    var scale: Double = 1

    static let `default` = CustomTextPlacement()
}

struct WatermarkConfiguration: Codable, Equatable {
    var template: WatermarkTemplate = .compact
    var showDateTime = true
    var showCoordinates = true
    var showAddress = true
    var showCustomText = true
    var coordinateFormat: CoordinateDisplayFormat = .decimal
    var addressText = "正在获取位置…"
    var customText = "现场记录"
    var usesCustomAddress = false
    var textRecognitionMode: TextRecognitionMode = .suggest
    /// How long the “发现画面文字” banner stays before auto-dismiss, in seconds.
    var recognitionSuggestionDuration: Double = 5 {
        didSet {
            recognitionSuggestionDuration = Self.sanitizedSuggestionDuration(
                recognitionSuggestionDuration,
                fallback: oldValue
            )
        }
    }
    var backgroundOpacity = 0.62 {
        didSet {
            backgroundOpacity = Self.sanitizedBackgroundOpacity(
                backgroundOpacity,
                fallback: oldValue
            )
        }
    }
    var placement = WatermarkPlacement.default
    var customTextPlacement = CustomTextPlacement.default

    static let `default` = WatermarkConfiguration()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case template
        case showDateTime
        case showCoordinates
        case showAddress
        case showCustomText
        case coordinateFormat
        case addressText
        case customText
        case usesCustomAddress
        case textRecognitionMode
        case recognitionSuggestionDuration
        case backgroundOpacity
        case placement
        case customTextPlacement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        template = try container.decodeIfPresent(WatermarkTemplate.self, forKey: .template) ?? .compact
        showDateTime = try container.decodeIfPresent(Bool.self, forKey: .showDateTime) ?? true
        showCoordinates = try container.decodeIfPresent(Bool.self, forKey: .showCoordinates) ?? true
        showAddress = try container.decodeIfPresent(Bool.self, forKey: .showAddress) ?? true
        showCustomText = try container.decodeIfPresent(Bool.self, forKey: .showCustomText) ?? true
        coordinateFormat = try container.decodeIfPresent(CoordinateDisplayFormat.self, forKey: .coordinateFormat) ?? .decimal
        addressText = try container.decodeIfPresent(String.self, forKey: .addressText) ?? "正在获取位置…"
        customText = try container.decodeIfPresent(String.self, forKey: .customText) ?? "现场记录"
        usesCustomAddress = try container.decodeIfPresent(Bool.self, forKey: .usesCustomAddress) ?? false
        textRecognitionMode = try container.decodeIfPresent(TextRecognitionMode.self, forKey: .textRecognitionMode) ?? .suggest
        placement = try container.decodeIfPresent(WatermarkPlacement.self, forKey: .placement) ?? .default
        customTextPlacement = try container.decodeIfPresent(CustomTextPlacement.self, forKey: .customTextPlacement) ?? .default
        recognitionSuggestionDuration = Self.sanitizedSuggestionDuration(
            try container.decodeIfPresent(Double.self, forKey: .recognitionSuggestionDuration) ?? 5,
            fallback: 5
        )

        let legacyOpacity = Self.legacyBackgroundOpacity(for: template)
        let decodedOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        backgroundOpacity = Self.sanitizedBackgroundOpacity(
            decodedOpacity ?? legacyOpacity,
            fallback: legacyOpacity
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(template, forKey: .template)
        try container.encode(showDateTime, forKey: .showDateTime)
        try container.encode(showCoordinates, forKey: .showCoordinates)
        try container.encode(showAddress, forKey: .showAddress)
        try container.encode(showCustomText, forKey: .showCustomText)
        try container.encode(coordinateFormat, forKey: .coordinateFormat)
        try container.encode(addressText, forKey: .addressText)
        try container.encode(customText, forKey: .customText)
        try container.encode(usesCustomAddress, forKey: .usesCustomAddress)
        try container.encode(textRecognitionMode, forKey: .textRecognitionMode)
        try container.encode(recognitionSuggestionDuration, forKey: .recognitionSuggestionDuration)
        try container.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try container.encode(placement, forKey: .placement)
        try container.encode(customTextPlacement, forKey: .customTextPlacement)
    }

    private static func legacyBackgroundOpacity(for template: WatermarkTemplate) -> Double {
        switch template {
        case .compact: 0.62
        case .card: 0.90
        }
    }

    private static func sanitizedBackgroundOpacity(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, 0), 1)
    }

    private static func sanitizedSuggestionDuration(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        // Keep the banner long enough to read, but not sticky forever.
        return min(max(value.rounded(), 2), 15)
    }
}
