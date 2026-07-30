@preconcurrency import CoreLocation
import Foundation

@MainActor
final class LocationService: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var location: CLLocation?
    @Published private(set) var resolvedAddress: String?
    @Published private(set) var isLocating = false
    @Published private(set) var errorMessage: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private static let maximumAcceptedLocationAge: TimeInterval = 30
    private static let addressReuseDistance: CLLocationDistance = 25
    private var lastGeocodedLocation: CLLocation?
    private var activeGeocodeLocation: CLLocation?
    private var geocodeGeneration = 0

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    func requestAuthorizationAndLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            isLocating = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdating()
        case .restricted, .denied:
            applyUnavailableState(message: "定位权限未开启，水印仍可使用时间和自定义文字")
        @unknown default:
            applyUnavailableState(message: "暂时无法获取位置")
        }
    }

    func refreshLocation() {
        guard isAuthorized else {
            requestAuthorizationAndLocation()
            return
        }
        startUpdating()
    }

    private func startUpdating() {
        isLocating = true
        errorMessage = nil
        manager.startUpdatingLocation()
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status

        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdating()
        case .restricted, .denied:
            applyUnavailableState(message: "定位权限未开启，水印仍可使用时间和自定义文字")
        case .notDetermined:
            break
        @unknown default:
            applyUnavailableState(message: "暂时无法获取位置")
        }
    }

    private func handleLocationUpdates(_ locations: [CLLocation], receivedAt: Date) {
        let newestFreshLocation = locations
            .filter { location in
                location.horizontalAccuracy >= 0
                    && CLLocationCoordinate2DIsValid(location.coordinate)
                    && abs(location.timestamp.timeIntervalSince(receivedAt)) <= Self.maximumAcceptedLocationAge
            }
            .max { first, second in
                first.timestamp < second.timestamp
            }

        guard let newestFreshLocation else {
            // Core Location commonly emits a cached point before obtaining a fresh fix.
            // Keep updating and do not let that cached point clear the locating state.
            return
        }

        handleLocationUpdate(newestFreshLocation)
    }

    private func handleLocationUpdate(_ newest: CLLocation) {
        guard isAuthorized else {
            applyUnavailableState(message: "定位权限未开启，水印仍可使用时间和自定义文字")
            return
        }

        location = newest
        isLocating = false
        errorMessage = nil
        reverseGeocode(newest)

        if newest.horizontalAccuracy <= 50 {
            manager.stopUpdatingLocation()
        }
    }

    private func handleLocationFailure(code: CLError.Code?) {
        if code == .denied {
            authorizationStatus = manager.authorizationStatus
            applyUnavailableState(message: "定位权限未开启，水印仍可使用时间和自定义文字")
        } else {
            applyUnavailableState(message: "定位失败，请稍后重试")
        }
    }

    private func applyUnavailableState(message: String) {
        geocodeGeneration &+= 1
        geocoder.cancelGeocode()
        location = nil
        lastGeocodedLocation = nil
        activeGeocodeLocation = nil
        isLocating = false
        errorMessage = message
        resolvedAddress = "未获取位置"
        manager.stopUpdatingLocation()
    }

    private func reverseGeocode(_ newLocation: CLLocation) {
        if let previous = lastGeocodedLocation,
           newLocation.distance(from: previous) < Self.addressReuseDistance {
            return
        }

        if let active = activeGeocodeLocation,
           newLocation.distance(from: active) < Self.addressReuseDistance {
            return
        }

        geocodeGeneration &+= 1
        let generation = geocodeGeneration
        activeGeocodeLocation = newLocation
        resolvedAddress = "正在解析地址…"
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(newLocation, preferredLocale: Locale(identifier: "zh_CN")) { [weak self] placemarks, error in
            Task { @MainActor in
                guard let self,
                      self.geocodeGeneration == generation else { return }

                self.activeGeocodeLocation = nil
                if let placemark = placemarks?.first {
                    self.lastGeocodedLocation = newLocation
                    self.resolvedAddress = Self.addressText(from: placemark)
                    self.errorMessage = nil
                } else if error != nil {
                    self.resolvedAddress = "地址解析失败"
                    self.errorMessage = "已获取坐标，但暂时无法解析地址"
                }
            }
        }
    }

    private static func addressText(from placemark: CLPlacemark) -> String {
        let candidates = [
            placemark.administrativeArea,
            placemark.locality,
            placemark.subLocality,
            placemark.thoroughfare,
            placemark.subThoroughfare
        ]

        var components: [String] = []
        for candidate in candidates.compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if !components.contains(candidate) {
                components.append(candidate)
            }
        }

        if components.isEmpty, let name = placemark.name, !name.isEmpty {
            return name
        }
        let result = components.joined()
        return result.isEmpty ? "未获取位置" : result
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleAuthorizationChange(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let receivedAt = Date()
        Task { @MainActor [weak self] in
            self?.handleLocationUpdates(locations, receivedAt: receivedAt)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        Task { @MainActor [weak self] in
            self?.handleLocationFailure(code: code)
        }
    }
}
