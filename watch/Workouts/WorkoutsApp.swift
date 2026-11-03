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
        }
        .onChange(of: phase) { _, p in
            if p == .active { AppModel.shared.sync.flush() }
        }
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()
    let sync = SyncStore()
    let workout = WorkoutManager()
    lazy var lift = LiftStore(sync: sync)
    lazy var run = RunStore(sync: sync)
}

final class AppDelegate: NSObject, WKApplicationDelegate {
    /// Called after a crash or kill while a workout was running.
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in await AppModel.shared.workout.recover() }
    }
}
