import HealthKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sync: SyncStore
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var run: RunStore
    @EnvironmentObject var workout: WorkoutManager

    var body: some View {
        Group {
            if let s = lift.summary {
                LiftSummaryView(summary: s)
            } else if let s = run.summary {
                RunSummaryView(summary: s)
            } else if lift.draft != nil {
                LiftFlowView()
            } else if run.key != nil {
                RunView()
            } else {
                TodayView()
            }
        }
        .task {
            #if DEBUG
            // Layout checks in the simulator: launch with `-demo lift|rest|next|finish|done`.
            if let demo = UserDefaults.standard.string(forKey: "demo") {
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
            // A lift draft without a live workout (for example after a reboot): restart HealthKit for it.
            if lift.draft != nil, !workout.active { try? await workout.start(.traditionalStrengthTraining) }
            sync.flush()
            sync.refreshHistory()
        }
    }
}

struct TodayView: View {
    @EnvironmentObject var sync: SyncStore
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var run: RunStore
    @EnvironmentObject var workout: WorkoutManager

    private var todayKey: String { Plan.todayKey() }

    private var runKey: String { todayKey == "run2" ? "run2" : "run" }
    private var others: [String] {
        Plan.liftKeys.filter { $0 != todayKey } + (["run", "run2"].contains(todayKey) ? [] : [runKey])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    if todayKey == "rest" {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rest day").font(.system(size: 18, weight: .semibold))
                            Text("Pick a session below").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.card))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Plan.name(todayKey)).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                                Text(subtitle(todayKey)).font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                            Button(Plan.session(todayKey)?.type == .run ? "Start Run" : "Start Workout") { start(todayKey) }.buttonStyle(PrimaryButtonStyle())
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.card))
                    }

                    Text("Other").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    ForEach(others, id: \.self) { k in
                        Button { start(k) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Plan.name(k)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                Text(subtitle(k)).font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.card))
                        }
                        .buttonStyle(.plain)
                    }

                    if !sync.statusText.isEmpty {
                        Text(sync.statusText).font(.footnote).foregroundStyle(.secondary)
                            .onTapGesture { sync.flush() }
                    }
                }
            }
            .navigationTitle("Today")
        }
    }

    /// "6 exercises · ~45 min" for lifts (sets × (40 s work + rest)), "Outdoor · GPS" for runs.
    private func subtitle(_ key: String) -> String {
        guard let s = Plan.session(key) else { return "" }
        if s.type == .run { return "Outdoor · GPS" }
        let secs = s.exercises.reduce(0) { $0 + $1.sets * (40 + $1.restSeconds) }
        return "\(s.exercises.count) exercises · ~\(Int((Double(secs) / 300).rounded()) * 5) min"
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
}
