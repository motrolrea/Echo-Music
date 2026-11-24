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
    private var lastAccepted: CLLocation?

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
        lastAccepted = nil
    }

    /// 丢掉室内乱跳和瞬移点。精度放宽到 100 米，但两点之间的速度不合理就不画。
    static func shouldAccept(_ location: CLLocation, after previous: CLLocation?) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else { return false }
        guard let previous else { return true }
        let meters = location.distance(from: previous)
        let seconds = location.timestamp.timeIntervalSince(previous.timestamp)
        guard meters >= 4 else { return false }
        guard seconds >= 0.8 else { return false }
        // 户外骑行上限约 25 米/秒。超过就是定位跳点，不写入路线。
        return meters / seconds <= 25
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
        for location in locations {
            guard Self.shouldAccept(location, after: lastAccepted) else { continue }
            lastAccepted = location
            route.append(location.coordinate)
            if route.count > 2400 { route.removeFirst(route.count - 2400) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
