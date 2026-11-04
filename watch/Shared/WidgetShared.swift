import AppIntents
import CoreLocation
import Foundation

/// Data the app shares with its watch-face complication / Smart Stack widget through the app group.
enum AppGroup {
    static let id = "group.com.jaysonlong.workouts"
    static let widgetKind = "WorkoutsWidget"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    /// This week's completed sessions, written by the app whenever they change.
    static var week: [WeekRow] {
        get { (defaults.data(forKey: "week")).flatMap { try? JSONDecoder().decode([WeekRow].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "week") }
    }

    /// Where the gym is, set from the app ("Set gym to here"). Used as a Smart Stack hint.
    static var gym: CLLocationCoordinate2D? {
        get {
            guard defaults.object(forKey: "gymLat") != nil else { return nil }
            return CLLocationCoordinate2D(latitude: defaults.double(forKey: "gymLat"), longitude: defaults.double(forKey: "gymLon"))
        }
        set {
            if let c = newValue {
                defaults.set(c.latitude, forKey: "gymLat")
                defaults.set(c.longitude, forKey: "gymLon")
            } else {
                defaults.removeObject(forKey: "gymLat")
                defaults.removeObject(forKey: "gymLon")
            }
        }
    }

    /// Tells watchOS the widget is relevant at the gym, so the Smart Stack can raise it there. A hint, not a guarantee.
    static func updateGymRelevance() async {
        var intents: [RelevantIntent] = []
        if let g = gym {
            let region = CLCircularRegion(center: g, radius: 150, identifier: "gym")
            intents.append(RelevantIntent(WorkoutsWidgetIntent(), widgetKind: widgetKind, relevance: .location(region)))
        }
        try? await RelevantIntentManager.shared.updateRelevantIntents(intents)
    }
}

/// The widget has no settings; the intent exists so the widget can carry location relevance.
struct WorkoutsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Workouts"
    static var description = IntentDescription("This week's progress and the next workout.")
    init() {}
}
