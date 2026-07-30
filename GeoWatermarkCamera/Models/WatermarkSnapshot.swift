import Foundation

struct WatermarkSnapshot: Equatable {
    enum LineKind: Equatable {
        case dateTime
        case coordinates
        case address
        case custom
    }

    struct Line: Equatable, Identifiable {
        let kind: LineKind
        let text: String

        var id: String { "\(kind)-\(text)" }
    }

    let configuration: WatermarkConfiguration
    let capturedAt: Date
    let latitude: Double?
    let longitude: Double?

    var lines: [Line] {
        primaryLines + customTextLines
    }

    /// Time / coordinates / address block that follows the selected template style.
    var primaryLines: [Line] {
        var result: [Line] = []

        if configuration.showDateTime {
            result.append(Line(kind: .dateTime, text: DateTextFormatter.watermark.string(from: capturedAt)))
        }

        if configuration.showCoordinates {
            let text: String
            if let latitude, let longitude {
                text = CoordinateTextFormatter.string(
                    latitude: latitude,
                    longitude: longitude,
                    format: configuration.coordinateFormat
                )
            } else {
                text = "坐标：未获取位置"
            }
            result.append(Line(kind: .coordinates, text: text))
        }

        if configuration.showAddress {
            let trimmed = configuration.addressText.trimmingCharacters(in: .whitespacesAndNewlines)
            let address = trimmed.isEmpty ? "未获取位置" : trimmed
            result.append(Line(kind: .address, text: "地点：\(address)"))
        }

        return result
    }

    /// Independent custom-text badge content. Empty when the module is off or blank.
    var customTextLines: [Line] {
        guard configuration.showCustomText else { return [] }
        let trimmed = configuration.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [Line(kind: .custom, text: trimmed)]
    }

    var hasPrimaryContent: Bool { !primaryLines.isEmpty }
    var hasCustomTextContent: Bool { !customTextLines.isEmpty }
}

enum CoordinateTextFormatter {
    static func string(
        latitude: Double,
        longitude: Double,
        format: CoordinateDisplayFormat
    ) -> String {
        let decimal = String(format: "%.6f, %.6f", latitude, longitude)
        let dms = "\(dmsString(latitude, positive: "N", negative: "S"))  \(dmsString(longitude, positive: "E", negative: "W"))"

        switch format {
        case .decimal:
            return "坐标：\(decimal)"
        case .degreesMinutesSeconds:
            return "坐标：\(dms)"
        case .both:
            return "坐标：\(decimal)\n\(dms)"
        }
    }

    private static func dmsString(_ value: Double, positive: String, negative: String) -> String {
        let absolute = abs(value)
        let degrees = Int(absolute)
        let minutesValue = (absolute - Double(degrees)) * 60
        let minutes = Int(minutesValue)
        let seconds = (minutesValue - Double(minutes)) * 60
        let direction = value >= 0 ? positive : negative
        return String(format: "%d°%02d′%05.2f″%@", degrees, minutes, seconds, direction)
    }
}

private enum DateTextFormatter {
    static let watermark: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy年MM月dd日 EEEE HH:mm:ss"
        return formatter
    }()
}
