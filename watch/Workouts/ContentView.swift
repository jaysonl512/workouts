import HealthKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sync: SyncStore
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var run: RunStore
    @EnvironmentObject var timed: TimedStore
    @EnvironmentObject var workout: WorkoutManager

    var body: some View {
        Group {
            if let row = sync.toRate {
                EffortView(name: row.name)
            } else if let s = lift.summary {
                LiftSummaryView(summary: s)
            } else if let s = run.summary {
                RunSummaryView(summary: s)
            } else if let s = timed.summary {
                TimedSummaryView(summary: s)
            } else if lift.draft != nil {
                LiftFlowView()
            } else if run.key != nil {
                RunView()
            } else if timed.workout != nil {
                TimedView()
            } else {
                TodayView()
            }
        }
        .task {
            #if DEBUG
            // Layout checks in the simulator: launch with `-demo today|lift|rest|next|finish|done`.
            if let demo = UserDefaults.standard.string(forKey: "demo") {
                if demo == "today" { return }
                if demo == "done" {
                    lift.summary = .init(name: "Upper A · heavy", sets: 19, volume: 12_400, minutes: 43, avgHR: 128, kcal: 422)
                    return
                }
                lift.begin("lowerA")
                if demo == "rest" { lift.startRest(90) }
                if demo == "next" { lift.go(to: 1); lift.nextUp = true }
                if demo == "finish" { lift.go(to: lift.steps.count) }
                return
            }
            #endif
            await workout.requestAuthorization()
            await workout.recover()
            // A recovered running workout with no lift draft is a run.
            if workout.active, workout.activity == .running, lift.draft == nil { run.resumeIfNeeded() }
            // Anything else that is not a lift is a timed workout (HIIT, walk, ...).
            if workout.active, workout.activity != .running, workout.activity != .traditionalStrengthTraining, lift.draft == nil {
                timed.resumeIfNeeded()
            }
            // A lift draft without a live workout (for example after a reboot): restart HealthKit for it.
            if lift.draft != nil, !workout.active { try? await workout.start(.traditionalStrengthTraining) }
            sync.publishWeek()
            await AppGroup.updateGymRelevance()
            sync.flush()
            sync.refreshHistory()
            await run.backfillRoutes(from: workout.store)
        }
    }
}

struct TodayView: View {
    @EnvironmentObject var sync: SyncStore
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var run: RunStore
    @EnvironmentObject var timed: TimedStore
    @EnvironmentObject var workout: WorkoutManager
    @EnvironmentObject var gym: GymStore

    var body: some View {
        let week = WeekPlan(rows: sync.week)
        NavigationStack {
            ScrollView {
                VStack(spacing: 6) {
                    hero(week)

                    header("This week", "\(week.doneCount) of 5")
                    ForEach(week.slots) { slot in
                        if let r = slot.done {
                            doneRow(r)
                        } else {
                            tile(title: slot.optional ? "Run 2" : Plan.name(slot.key),
                                 subtitle: slot.optional ? "Optional" : subtitle(slot.key, short: true)) { start(week.key(for: slot)) }
                        }
                    }
                    ForEach(week.extras, id: \.id) { doneRow($0) }

                    header("Other", nil)
                    ForEach(Plan.others) { o in
                        Button { startOther(o) } label: {
                            Label(o.name, systemImage: o.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
                        }
                        .buttonStyle(.plain)
                    }

                    header("Gym", nil)
                    gymRow

                    if !sync.statusText.isEmpty {
                        Text(sync.statusText).font(.footnote).foregroundStyle(.secondary)
                            .onTapGesture { sync.flush() }
                    }
                }
            }
            .navigationTitle("Today")
        }
    }

    /// The suggested workout with a Start button, or a rest-day / week-done note.
    @ViewBuilder private func hero(_ week: WeekPlan) -> some View {
        if let key = week.next {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Up next").font(.caption2).foregroundStyle(Color.brand)
                    Text(Plan.name(key)).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    Text(subtitle(key)).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                Button(Plan.session(key)?.type == .run ? "Start Run" : "Start Workout") { start(key) }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.card))
        } else {
            let rest = Plan.todayKey() == "rest"
            let n = week.left.count
            VStack(alignment: .leading, spacing: 2) {
                Text(rest ? "Rest day" : "Week complete").font(.system(size: 18, weight: .semibold))
                Text(rest ? (n > 0 ? "\(n) left this week. Tap one to do it today." : "All 5 done this week.") : "All 5 done. Anything below is a bonus.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
        }
    }

    /// Saves the gym's location so the Smart Stack can show the widget there. Tap it while at the gym.
    @ViewBuilder private var gymRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(gym.locating ? "Finding you…" : gym.isSet ? "Update gym to here" : "Set gym to here") { gym.setHere() }
                .buttonStyle(PillButtonStyle()).disabled(gym.locating)
            Text(gym.message ?? (gym.isSet ? "The Smart Stack can show Workouts when you get there." : "Tap this at your gym so the Smart Stack can show Workouts there."))
                .font(.caption2).foregroundStyle(.secondary)
            if gym.isSet && !gym.locating {
                Button("Forget gym") { gym.clear() }.font(.caption2).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func header(_ title: String, _ trailing: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(.footnote).foregroundStyle(.secondary).padding(.top, 6).padding(.horizontal, 2)
    }

    private func tile(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
        }
        .buttonStyle(.plain)
    }

    private func doneRow(_ r: WeekRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
            VStack(alignment: .leading, spacing: 0) {
                Text(r.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text("Done \(WeekPlan.weekday(r.date))").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// "6 exercises · ~45 min" for lifts (sets × (40 s work + rest)); just "~45 min" in the list.
    private func subtitle(_ key: String, short: Bool = false) -> String {
        guard let s = Plan.session(key) else { return "" }
        if s.type == .run { return "GPS or treadmill" }
        let secs = s.exercises.reduce(0) { $0 + $1.sets * (40 + $1.restSeconds) }
        let mins = "~\(Int((Double(secs) / 300).rounded()) * 5) min"
        return short ? mins : "\(s.exercises.count) exercises · \(mins)"
    }

    private func start(_ key: String) {
        guard let s = Plan.session(key) else { return }
        if s.type == .run {
            workout.requestLocation()
            run.begin(key)
        } else {
            lift.begin(key)
            Task { try? await workout.start(.traditionalStrengthTraining) }
        }
    }

    private func startOther(_ o: OtherWorkout) {
        timed.begin(o)
        Task {
            do {
                try await workout.start(o.activity, indoor: !o.outdoor)
                timed.started()
            } catch {
                timed.discard()
            }
        }
    }
}
