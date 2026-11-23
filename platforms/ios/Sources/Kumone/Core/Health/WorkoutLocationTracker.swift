import Combine
import CoreLocation
import Foundation

/// 锻炼时的定位与路线。全局会话持有它，离开锻炼页后仍继续记录。
@MainActor
final class WorkoutLocationTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var route: [CLLocationCoordinate2D] = []
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 4
        manager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = manager.authorizationStatus
    }

    func start() {
        wantsUpdates = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }

    func reset() {
        route.removeAll()
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard wantsUpdates else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 60 else { return }
        if let last = route.last {
            let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
            guard location.distance(from: previous) >= 4 else { return }
        }
        route.append(location.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
