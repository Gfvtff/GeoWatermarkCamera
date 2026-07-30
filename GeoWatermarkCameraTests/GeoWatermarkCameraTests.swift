import CoreGraphics
import XCTest
@testable import GeoWatermarkCamera

final class GeoWatermarkCameraTests: XCTestCase {
    func testDecimalCoordinateFormatting() {
        let text = CoordinateTextFormatter.string(
            latitude: 31.230416,
            longitude: 121.473701,
            format: .decimal
        )
        XCTAssertEqual(text, "坐标：31.230416, 121.473701")
    }

    func testDMSCoordinateFormattingIncludesDirections() {
        let text = CoordinateTextFormatter.string(
            latitude: -31.230416,
            longitude: -121.473701,
            format: .degreesMinutesSeconds
        )
        XCTAssertTrue(text.contains("S"))
        XCTAssertTrue(text.contains("W"))
        XCTAssertTrue(text.contains("31°13′49.50″"))
    }

    func testSnapshotFallsBackWhenLocationIsMissing() {
        let snapshot = WatermarkSnapshot(
            configuration: .default,
            capturedAt: Date(timeIntervalSince1970: 0),
            latitude: nil,
            longitude: nil
        )
        XCTAssertTrue(snapshot.lines.contains(where: { $0.text == "坐标：未获取位置" }))
    }

    func testAspectFillCenterMapsToPhotoCenter() {
        let point = PreviewGeometryMapper.imagePoint(
            normalizedX: 0.5,
            normalizedY: 0.5,
            previewSize: CGSize(width: 390, height: 844),
            imageSize: CGSize(width: 3000, height: 4000)
        )
        XCTAssertEqual(point.x, 1500, accuracy: 0.001)
        XCTAssertEqual(point.y, 2000, accuracy: 0.001)
    }

    func testConfigurationRoundTrip() throws {
        var expected = WatermarkConfiguration.default
        expected.addressText = "公司"
        expected.usesCustomAddress = true
        expected.textRecognitionMode = .automatic
        expected.recognitionSuggestionDuration = 8
        expected.backgroundOpacity = 0.35
        expected.placement = WatermarkPlacement(x: 0.2, y: 0.8, scale: 1.25)
        expected.customTextPlacement = CustomTextPlacement(x: 0.35, y: 0.2, scale: 1.1)

        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(WatermarkConfiguration.self, from: data)
        XCTAssertEqual(decoded, expected)
    }

    func testLegacyConfigurationWithoutBackgroundOpacityStillDecodes() throws {
        let legacyDefaults: [(WatermarkTemplate, Double)] = [
            (.compact, 0.62),
            (.card, 0.90)
        ]

        for (template, expectedOpacity) in legacyDefaults {
            var legacySource = WatermarkConfiguration.default
            legacySource.template = template
            legacySource.addressText = "旧配置地址"

            let encoded = try JSONEncoder().encode(legacySource)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object.removeValue(forKey: "backgroundOpacity")
            let legacyData = try JSONSerialization.data(withJSONObject: object)

            let decoded = try JSONDecoder().decode(WatermarkConfiguration.self, from: legacyData)
            XCTAssertEqual(decoded.template, template)
            XCTAssertEqual(decoded.addressText, "旧配置地址")
            XCTAssertEqual(decoded.backgroundOpacity, expectedOpacity, accuracy: 0.000_001)
        }
    }

    func testLegacyConfigurationWithoutTextRecognitionModeDefaultsToSuggestion() throws {
        var source = WatermarkConfiguration.default
        source.textRecognitionMode = .off

        let encoded = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "textRecognitionMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WatermarkConfiguration.self, from: legacyData)
        XCTAssertEqual(decoded.textRecognitionMode, .suggest)
    }

    func testBackgroundOpacityStaysWithinSupportedRange() {
        var configuration = WatermarkConfiguration.default

        configuration.backgroundOpacity = -0.5
        XCTAssertEqual(configuration.backgroundOpacity, 0)

        configuration.backgroundOpacity = 1.5
        XCTAssertEqual(configuration.backgroundOpacity, 1)
    }

    func testLegacyConfigurationWithoutSuggestionDurationDefaultsToFiveSeconds() throws {
        var source = WatermarkConfiguration.default
        source.recognitionSuggestionDuration = 12

        let encoded = try JSONEncoder().encode(source)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "recognitionSuggestionDuration")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WatermarkConfiguration.self, from: legacyData)
        XCTAssertEqual(decoded.recognitionSuggestionDuration, 5, accuracy: 0.000_001)
    }

    func testSuggestionDurationIsClamped() {
        var configuration = WatermarkConfiguration.default
        configuration.recognitionSuggestionDuration = 1
        XCTAssertEqual(configuration.recognitionSuggestionDuration, 2)
        configuration.recognitionSuggestionDuration = 30
        XCTAssertEqual(configuration.recognitionSuggestionDuration, 15)
    }

    func testCustomTextIsIndependentFromPrimaryLines() {
        var configuration = WatermarkConfiguration.default
        configuration.showDateTime = true
        configuration.showCoordinates = false
        configuration.showAddress = false
        configuration.showCustomText = true
        configuration.customText = "执法备注"

        let snapshot = WatermarkSnapshot(
            configuration: configuration,
            capturedAt: Date(timeIntervalSince1970: 0),
            latitude: nil,
            longitude: nil
        )

        XCTAssertTrue(snapshot.hasPrimaryContent)
        XCTAssertTrue(snapshot.hasCustomTextContent)
        XCTAssertFalse(snapshot.primaryLines.contains(where: { $0.kind == .custom }))
        XCTAssertEqual(snapshot.customTextLines.map { $0.text }, ["执法备注"])
    }

    func testHiddenCustomTextLeavesPrimaryWatermarkAlone() {
        var configuration = WatermarkConfiguration.default
        configuration.showCustomText = false
        configuration.customText = "执法备注"

        let snapshot = WatermarkSnapshot(
            configuration: configuration,
            capturedAt: Date(timeIntervalSince1970: 0),
            latitude: 31.2,
            longitude: 121.4
        )

        XCTAssertTrue(snapshot.hasPrimaryContent)
        XCTAssertFalse(snapshot.hasCustomTextContent)
        XCTAssertTrue(snapshot.customTextLines.isEmpty)
    }

}
