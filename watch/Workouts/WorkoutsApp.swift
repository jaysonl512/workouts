import SwiftUI
import WatchKit

@main
struct WorkoutsApp: App {
    @WKApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppModel.shared.sync)
                .environmentObject(AppModel.shared.lift)
                .environmentObject(AppModel.shared.workout)
                .environmentObject(AppModel.shared.run)
                .environmentObject(AppModel.shared.timed)
                .environmentObject(AppModel.shared.gym)
        }
        .onChange(of: phase) { _, p in
            if p == .active {
                AppModel.shared.sync.flush()
                AppModel.shared.sync.refreshHistory()
                Task { await AppModel.shared.health.syncIfDue() }
                Task { await AppModel.shared.plans.refresh() }
            }
        }
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()
    let sync = SyncStore()
    let workout = WorkoutManager()
    let plans = PlanCache()
    lazy var lift = LiftStore(sync: sync, plans: plans)
    lazy var run = RunStore(sync: sync)
    lazy var timed = TimedStore(sync: sync)
    let gym = GymStore()
    let health = HealthSync()
}

extension AppModel {
    /// What a background wake does: upload queued workouts, refresh this week (which also reloads the
    /// complication), and upload new Health values.
    func backgroundRefresh() async {
        await sync.flushNow()
        await sync.refreshWeek()
        await health.syncIfDue()
        await plans.refresh()
    }

    /// Asks watchOS to wake the app in about an hour. With the complication on the watch face the app
    /// gets enough background budget for this; watchOS may still run it later.
    static func scheduleBackgroundRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(60 * 60), userInfo: nil) { _ in }
    }
}

final class AppDelegate: NSObject, WKApplicationDelegate {
    /// Runs on every launch, foreground or background.
    func applicationDidFinishLaunching() {
        Task { @MainActor in
            AppModel.shared.health.startObserving()
            AppModel.scheduleBackgroundRefresh()
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task { @MainActor in
                    await AppModel.shared.backgroundRefresh()
                    AppModel.scheduleBackgroundRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    /// Called after a crash or kill while a workout was running.
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in await AppModel.shared.workout.recover() }
    }
}
