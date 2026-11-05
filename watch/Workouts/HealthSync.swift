import Foundation
import HealthKit

/// One day of Apple Health values for the web app's Health Trends. Nil values are left out of the upload,
/// so they never overwrite a value stored earlier (or added later by another device).
struct HealthDay: Encodable {
    var date: String
    var rhr: Double?
    var hrv: Double?
    var vo2max: Double?
    var hrRecovery: Double?
    var weightKg: Double?
    var userId: String?

    enum CodingKeys: String, CodingKey {
        case date, rhr, hrv, vo2max, hrRecovery = "hr_recovery", weightKg = "weight_kg", userId = "user_id"
    }

    var isEmpty: Bool { rhr == nil && hrv == nil && vo2max == nil && hrRecovery == nil && weightKg == nil }
    /// Which values are present. PostgREST needs every row in one request to have the same keys.
    var keySignature: String {
        [rhr, hrv, vo2max, hrRecovery, weightKg].map { $0 == nil ? "0" : "1" }.joined()
    }
}

/// Reads daily resting heart rate, HRV, cardio fitness, heart rate recovery and weight from HealthKit
/// and upserts them to Supabase: when the app opens, when HealthKit wakes it with new values, and on background refresh. The Watch keeps only a few weeks of this history, which is fine:
/// once a day is uploaded it stays in the cloud.
@MainActor
final class HealthSync {
    private let store = HKHealthStore()
    private var running = false
    private let lastKey = "health.lastSync"

    private struct Metric {
        let id: HKQuantityTypeIdentifier
        let option: HKStatisticsOptions
        let unit: HKUnit
        let digits: Double
        let path: WritableKeyPath<HealthDay, Double?>
    }

    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let metrics: [Metric] = [
        Metric(id: .restingHeartRate, option: .discreteAverage, unit: bpm, digits: 10, path: \.rhr),
        Metric(id: .heartRateVariabilitySDNN, option: .discreteAverage, unit: .secondUnit(with: .milli), digits: 10, path: \.hrv),
        Metric(id: .vo2Max, option: .mostRecent, unit: HKUnit(from: "ml/kg*min"), digits: 10, path: \.vo2max),
        Metric(id: .heartRateRecoveryOneMinute, option: .discreteMax, unit: bpm, digits: 1, path: \.hrRecovery),
        Metric(id: .bodyMass, option: .mostRecent, unit: .gramUnit(with: .kilo), digits: 100, path: \.weightKg),
    ]

    /// Types the app asks to read for Health Trends (added to the workout authorization request).
    static var readTypes: Set<HKObjectType> { Set(metrics.map { HKQuantityType($0.id) }) }

    private var observing = false

    /// Asks watchOS to wake the app (at most hourly) when the Watch saves a new value for any metric,
    /// then uploads. Must run at every launch, including background launches, so the queries exist when woken.
    func startObserving() {
        guard HKHealthStore.isHealthDataAvailable(), !observing else { return }
        observing = true
        for m in Self.metrics {
            let type = HKQuantityType(m.id)
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, done, error in
                guard error == nil else { done(); return }
                Task { @MainActor in
                    await self?.syncIfDue()
                    done()
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Uploads at most every 45 minutes. The first upload sends 90 days, later ones the last 3 weeks
    /// (recent days can still change, e.g. a VO2 max estimate after an outdoor walk).
    func syncIfDue() async {
        guard HKHealthStore.isHealthDataAvailable(), !running else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: lastKey) as? Date
        if let last, Date().timeIntervalSince(last) < 45 * 60 { return }
        running = true
        defer { running = false }
        let days = await read(days: last == nil ? 90 : 21)
        guard !days.isEmpty else { return }
        do {
            try await Supabase.shared.upsertHealth(days)
            defaults.set(Date(), forKey: lastKey)
        } catch {
            // Table missing or offline: try again next time the app opens.
        }
    }

    private func read(days: Int) async -> [HealthDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        var byDate: [String: HealthDay] = [:]

        for m in Self.metrics {
            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil)
            let query = HKStatisticsCollectionQueryDescriptor(
                predicate: .quantitySample(type: HKQuantityType(m.id), predicate: predicate),
                options: m.option, anchorDate: today, intervalComponents: DateComponents(day: 1))
            guard let collection = try? await query.result(for: store) else { continue }
            for stats in collection.statistics() where stats.startDate >= start {
                let q: HKQuantity?
                switch m.option {
                case .discreteAverage: q = stats.averageQuantity()
                case .discreteMax: q = stats.maximumQuantity()
                default: q = stats.mostRecentQuantity()
                }
                guard let q else { continue }
                let v = (q.doubleValue(for: m.unit) * m.digits).rounded() / m.digits
                guard v.isFinite, v > 0 else { continue }
                let key = fmt.string(from: stats.startDate)
                var day = byDate[key] ?? HealthDay(date: key)
                day[keyPath: m.path] = v
                byDate[key] = day
            }
        }
        return byDate.values.filter { !$0.isEmpty }.sorted { $0.date < $1.date }
    }
}
