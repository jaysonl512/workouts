import CoreLocation
import Foundation

/// "Set gym to here": saves the current location as the gym so the Smart Stack can raise the widget there.
@MainActor
final class GymStore: NSObject, ObservableObject {
    @Published private(set) var isSet = AppGroup.gym != nil
    @Published private(set) var locating = false
    @Published private(set) var message: String?
    private var manager: CLLocationManager?

    func setHere() {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        manager = m
        locating = true
        message = nil
        m.requestWhenInUseAuthorization()
        m.requestLocation()
    }

    func clear() {
        AppGroup.gym = nil
        isSet = false
        message = nil
        Task { await AppGroup.updateGymRelevance() }
    }

    fileprivate func got(_ loc: CLLocation?) {
        locating = false
        manager = nil
        guard let loc, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 100 else {
            message = "Couldn't get a good fix. Try again outside or near a window."
            return
        }
        AppGroup.gym = loc.coordinate
        isSet = true
        message = "Gym saved"
        Task { await AppGroup.updateGymRelevance() }
    }
}

extension GymStore: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let best = locations.min { $0.horizontalAccuracy < $1.horizontalAccuracy }
        Task { @MainActor in self.got(best) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.got(nil) }
    }
}
