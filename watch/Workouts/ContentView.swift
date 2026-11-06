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
            await AppModel.shared.plans.refresh()
            await AppModel.shared.health.syncIfDue()
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
    @EnvironmentObject var plans: PlanCache
    /// A finished lift tapped to do again today.
    @State private var again: WeekRow?

    var body: some View {
        let week = WeekPlan(rows: sync.week)
        // The training program's schedule from the server when it is cached for this week, else the built-in plan.
        let sch = Schedule(occs: plans.plans?.occs, rows: sync.week)
        NavigationStack {
            ScrollView {
                VStack(spacing: 6) {
                    if let sch {
                        hero(sch)
                        header("This week", "\(sch.doneCount) of \(sch.goal)")
                        // A skipped workout leaves the schedule (the web keeps it in History and the Plan tab).
                        ForEach(sch.items.filter { $0.status != "skipped" }) { it in
                            if let r = it.done {
                                doneRow(r)
                            } else {
                                tile(title: it.occ.name, subtitle: itemSubtitle(it)) { start(it) }
                            }
                        }
                        ForEach(sch.extras, id: \.id) { doneRow($0) }
                    } else {
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
                    }

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
            .confirmationDialog("Do \(again?.name ?? "it") again today?", isPresented: Binding(get: { again != nil }, set: { if !$0 { again = nil } })) {
                Button("Start") { if let r = again { start(r.session) }; again = nil }
            } message: { Text("It counts as an extra this week.") }
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

    /// The scheduled workout for now, from the served schedule.
    @ViewBuilder private func hero(_ sch: Schedule) -> some View {
        if let it = sch.next {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(it.occ.date == sch.today ? "Today" : "Up next").font(.caption2).foregroundStyle(Color.brand)
                    Text(it.occ.name).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    Text(itemSubtitle(it, long: true)).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                Button(it.isLift ? "Start Workout" : "Start Run") { start(it) }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.card))
        } else {
            let n = sch.open.count
            let recovery = sch.items.contains { $0.occ.date == sch.today && $0.status == "recovery" }
            VStack(alignment: .leading, spacing: 2) {
                Text(recovery ? "Recovery day" : n > 0 ? "Rest day" : "Week complete").font(.system(size: 18, weight: .semibold))
                Text(recovery ? "A walk or some mobility if you like." : n > 0 ? "\(n) left this week. Tap one to do it today." : "All \(sch.goal) done. Anything below is a bonus.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
        }
    }

    /// "Thu · ~45 min" (plus "Reduced" / "Skipped" / "Missed") for a scheduled workout.
    private func itemSubtitle(_ it: Schedule.Item, long: Bool = false) -> String {
        let day = WeekPlan.weekday(it.occ.date)
        if !it.isLift { return [day, it.optional ? "Optional" : (it.occ.runKind.map { $0 == "long" ? "Long run" : $0 == "intervals" ? "Intervals" : "Easy run" } ?? "Run")].joined(separator: " · ") }
        let tag = it.status == "skipped" ? "Skipped" : it.status == "recovery" ? "Recovery day" : it.status == "missed" ? "Missed" : it.occ.reduced == true ? "Reduced" : nil
        guard let s = Plan.session(it.occ.key) else { return day }
        let ex = it.occ.ex.map { only in only.compactMap { o in s.exercises.first { $0.id == o.id }?.with(sets: o.sets) } } ?? s.exercises
        let secs = ex.reduce(0) { $0 + $1.sets * (40 + $1.restSeconds) }
        let mins = "~\(Int((Double(secs) / 300).rounded()) * 5) min"
        return ([long ? "\(ex.count) exercises" : day, mins] + (tag.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private func start(_ it: Schedule.Item) {
        if it.isLift {
            lift.begin(it.occ.key, occ: it.occ)
            Task { try? await workout.start(.traditionalStrengthTraining) }
        } else {
            // A run takes whichever run key is still free today.
            let used = Set(sync.week.filter { $0.date == Day.string() }.map(\.session))
            let key = [it.occ.key, "run", "run2", "run3"].first { !used.contains($0) } ?? it.occ.key
            workout.requestLocation()
            run.begin(key)
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

    /// A finished workout. A lift done on an earlier day can be tapped to do it again today; one done today cannot
    /// (a second copy on the same day would replace the first).
    private func doneRow(_ r: WeekRow) -> some View {
        let today = Day.string()
        let canRepeat = r.type == "lift" && r.date != today && !sync.week.contains { $0.date == today && $0.session == r.session }
        return Button { if canRepeat { again = r } } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Text(canRepeat ? "Done \(WeekPlan.weekday(r.date)) · tap to repeat" : "Done \(WeekPlan.weekday(r.date))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRepeat)
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
