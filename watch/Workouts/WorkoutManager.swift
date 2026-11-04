import CoreLocation
import CoreMotion
import Foundation
import HealthKit

/// HKWorkoutSession + HKLiveWorkoutBuilder for lifts (strength, indoor) and runs (outdoor, GPS route).
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    let store = HKHealthStore()

    @Published private(set) var active = false
    @Published private(set) var paused = false
    @Published private(set) var heartRate: Double = 0
    @Published private(set) var activeKcal: Double = 0
    @Published private(set) var distanceM: Double = 0
    @Published private(set) var elevationGainM: Double = 0
    @Published private(set) var gpsAccuracy: Double?
    @Published private(set) var startDate: Date?
    /// Running without GPS (treadmill): HealthKit measures distance from wrist motion.
    @Published private(set) var indoor = false

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var location: CLLocationManager?
    private var lastAltitude: Double?
    private var routePoints: [CLLocationCoordinate2D] = []
    private(set) var activity: HKWorkoutActivityType = .traditionalStrengthTraining

    struct Result {
        let workout: HKWorkout?
        let start: Date
        let end: Date
        let avgHR: Double?
        let maxHR: Double?
        let kcal: Double?
        let distanceM: Double
        let elevationGainM: Double
        let route: [CLLocationCoordinate2D]
        let indoor: Bool

        var hk: HKInfo? {
            guard let w = workout else { return nil }
            return HKInfo(workoutUUID: w.uuid.uuidString, startedAt: ISO.string(start), endedAt: ISO.string(end),
                          avgHR: avgHR.map { Int($0.rounded()) }, maxHR: maxHR.map { Int($0.rounded()) },
                          activeKcal: kcal.map { Int($0.rounded()) })
        }
    }

    // MARK: Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let quantities: [HKQuantityTypeIdentifier] = [.heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling, .basalEnergyBurned]
        var share: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        var read: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for q in quantities {
            share.insert(HKQuantityType(q))
            read.insert(HKQuantityType(q))
        }
        try? await store.requestAuthorization(toShare: share, read: read)
        // Ask for Motion & Fitness now, not at the end of a run: a tiny pedometer query shows the prompt once.
        if CMPedometer.isDistanceAvailable(), CMPedometer.authorizationStatus() == .notDetermined {
            _ = await pedometerDistance(from: Date().addingTimeInterval(-60), to: Date())
        }
    }

    func requestLocation() {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
        m.activityType = .fitness
        location = m
        m.requestWhenInUseAuthorization()
        m.startUpdatingLocation()
    }

    // MARK: Session lifecycle

    /// GPS fix good enough to record an outdoor run.
    var gpsReady: Bool { (gpsAccuracy ?? .infinity) <= 30 }

    func start(_ type: HKWorkoutActivityType, indoor: Bool = true) async throws {
        if active { return }
        let config = HKWorkoutConfiguration()
        config.activityType = type
        config.locationType = indoor ? .indoor : .outdoor
        let s = try HKWorkoutSession(healthStore: store, configuration: config)
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
        attach(s, b, type: type)
        let now = Date()
        s.startActivity(with: now)
        try await b.beginCollection(at: now)
        startDate = now
        self.indoor = indoor
        if type == .running && !indoor {
            routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
            if location == nil { requestLocation() }
        } else {
            location?.stopUpdatingLocation()
            location = nil
        }
    }

    /// Re-attach to a workout that was running when the app was killed.
    func recover() async {
        guard !active, let s = try? await store.recoverActiveWorkoutSession() else { return }
        let b = s.associatedWorkoutBuilder()
        b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: s.workoutConfiguration)
        attach(s, b, type: s.workoutConfiguration.activityType)
        startDate = b.startDate ?? s.startDate
        paused = s.state == .paused
        indoor = s.workoutConfiguration.locationType != .outdoor
        if activity == .running && !indoor {
            routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
            requestLocation()
        }
        update(from: b)
    }

    private func attach(_ s: HKWorkoutSession, _ b: HKLiveWorkoutBuilder, type: HKWorkoutActivityType) {
        session = s
        builder = b
        activity = type
        s.delegate = self
        b.delegate = self
        active = true
        paused = false
        heartRate = 0; activeKcal = 0; distanceM = 0; elevationGainM = 0; lastAltitude = nil; routePoints = []
    }

    func elapsed(at date: Date = Date()) -> TimeInterval { builder?.elapsedTime(at: date) ?? 0 }

    func pause() { session?.pause() }
    func resume() { session?.resume() }

    /// Ends the session and saves the workout (and route, for runs) to Health.
    func end() async -> Result {
        let end = Date()
        let start = startDate ?? end
        var workout: HKWorkout?
        var avg: Double?, max: Double?, kcal: Double?
        var indoorRun = activity == .running && indoor
        if let s = session, let b = builder {
            // An outdoor run whose GPS never really moved was on a treadmill: save it as an indoor run,
            // with distance from step tracking, and drop the route.
            if activity == .running && !indoor && looksStationary {
                indoorRun = true
                routeBuilder = nil
                routePoints = []
                try? await b.addMetadata([HKMetadataKeyIndoorWorkout: true])
            }
            if indoorRun, let steps = await pedometerDistance(from: start, to: end), steps - distanceM > 50 {
                let extra = HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                                             quantity: HKQuantity(unit: .meter(), doubleValue: steps - distanceM), start: start, end: end)
                await withCheckedContinuation { cont in b.add([extra]) { _, _ in cont.resume() } }
                distanceM = steps
            }
            s.end()
            let bpm = HKUnit.count().unitDivided(by: .minute())
            let hr = b.statistics(for: HKQuantityType(.heartRate))
            avg = hr?.averageQuantity()?.doubleValue(for: bpm)
            max = hr?.maximumQuantity()?.doubleValue(for: bpm)
            kcal = b.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            do {
                try await b.endCollection(at: end)
                workout = try await b.finishWorkout()
                if let w = workout, let rb = routeBuilder {
                    _ = try? await rb.finishRoute(with: w, metadata: nil)
                }
            } catch {
                print("finish workout failed: \(error)")
            }
        }
        location?.stopUpdatingLocation()
        let result = Result(workout: workout, start: start, end: end, avgHR: avg, maxHR: max, kcal: kcal,
                            distanceM: distanceM, elevationGainM: indoorRun ? 0 : elevationGainM, route: indoorRun ? [] : routePoints,
                            indoor: indoorRun)
        session = nil; builder = nil; routeBuilder = nil; location = nil
        active = false; paused = false; startDate = nil; indoor = false
        return result
    }

    /// Fewer than 10 GPS points, or none more than 100 m from the start.
    private var looksStationary: Bool {
        guard routePoints.count >= 10, let first = routePoints.first else { return true }
        let a = CLLocation(latitude: first.latitude, longitude: first.longitude)
        return !routePoints.contains { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: a) > 100 }
    }

    /// Distance from the Watch's step tracking (calibrated by Apple from earlier outdoor runs).
    private func pedometerDistance(from start: Date, to end: Date) async -> Double? {
        guard CMPedometer.isDistanceAvailable() else { return nil }
        return await withCheckedContinuation { cont in
            CMPedometer().queryPedometerData(from: start, to: end) { data, _ in
                cont.resume(returning: data?.distance?.doubleValue)
            }
        }
    }

    /// Throws the workout away without saving it to Health.
    func discard() {
        session?.end()
        builder?.discardWorkout()
        location?.stopUpdatingLocation()
        session = nil; builder = nil; routeBuilder = nil; location = nil
        active = false; paused = false; startDate = nil
    }

    private func update(from b: HKLiveWorkoutBuilder) {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let q = b.statistics(for: HKQuantityType(.heartRate))?.mostRecentQuantity() { heartRate = q.doubleValue(for: bpm) }
        if let q = b.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() { activeKcal = q.doubleValue(for: .kilocalorie()) }
        let dist: HKQuantityTypeIdentifier = activity == .cycling ? .distanceCycling : .distanceWalkingRunning
        if let q = b.statistics(for: HKQuantityType(dist))?.sumQuantity() { distanceM = q.doubleValue(for: .meter()) }
    }

    fileprivate func handle(_ locations: [CLLocation]) {
        gpsAccuracy = locations.last?.horizontalAccuracy
        guard active, !paused, let rb = routeBuilder else { return }
        let good = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 50 }
        guard !good.isEmpty else { return }
        rb.insertRouteData(good) { _, _ in }
        routePoints += good.map(\.coordinate)
        for l in good where l.verticalAccuracy >= 0 && l.verticalAccuracy <= 15 {
            // Ignore GPS altitude noise under 2 m between accepted points.
            if let a = lastAltitude {
                let d = l.altitude - a
                if abs(d) >= 2 { if d > 0 { elevationGainM += d }; lastAltitude = l.altitude }
            } else {
                lastAltitude = l.altitude
            }
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.paused = toState == .paused }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("workout session failed: \(error)")
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in self.update(from: workoutBuilder) }
    }
}

extension WorkoutManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("location failed: \(error)")
    }
}
