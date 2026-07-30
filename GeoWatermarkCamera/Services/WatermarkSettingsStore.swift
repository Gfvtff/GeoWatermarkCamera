import Foundation

@MainActor
final class WatermarkSettingsStore: ObservableObject {
    @Published var configuration: WatermarkConfiguration {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let storageKey = "watermark.configuration.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(WatermarkConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = .default
        }
    }

    func useAutomaticAddress(_ address: String?) {
        guard !configuration.usesCustomAddress,
              let address,
              !address.isEmpty else { return }
        configuration.addressText = address
    }

    func resetToAutomaticAddress(_ address: String?) {
        configuration.usesCustomAddress = false
        configuration.addressText = address ?? "未获取位置"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
