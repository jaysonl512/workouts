import SwiftUI

struct RunView: View {
    @EnvironmentObject var run: RunStore
    @EnvironmentObject var workout: WorkoutManager
    @State private var confirmEnd = false
    @State private var ending = false

    var body: some View {
        if workout.active {
            live
        } else {
            ready
        }
    }

    private var ready: some View {
        VStack(spacing: 8) {
            Text(Plan.name(run.key ?? "run")).font(.headline)
            Text(gpsText).font(.footnote).foregroundStyle(workout.gpsReady ? .green : .secondary)
            Button {
                Task {
                    try? await workout.start(.running, indoor: !workout.gpsReady)
                    run.started()
                }
            } label: {
                Text("Start Run")
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Cancel") { workout.discard(); run.discard() }.buttonStyle(PillButtonStyle())
        }
        .onAppear { workout.requestLocation() }
    }

    /// Starting now records outdoor (GPS) or indoor (treadmill, distance from motion).
    private var gpsText: String {
        if workout.gpsReady { return "Outdoor · GPS ready" }
        guard let a = workout.gpsAccuracy, a >= 0 else { return "Indoor · no GPS yet" }
        return "Indoor · GPS ±\(Int(a)) m"
    }

    private var live: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let t = workout.elapsed(at: ctx.date)
            let km = workout.distanceM / 1000
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.clock(t)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(workout.paused ? Color.secondary : Color.brand)
                    if workout.indoor { Text("Indoor").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(String(format: "%.2f km", km)).font(.title3).monospacedDigit()
                Text("\(Fmt.pace(secPerKm: km > 0.05 ? t / km : nil)) /km").font(.title3).monospacedDigit()
                Text(workout.heartRate > 0 ? "\(Int(workout.heartRate)) bpm" : "-- bpm").font(.title3).monospacedDigit()
                    .foregroundStyle(.red)
                HStack(spacing: 4) {
                    Button(workout.paused ? "Resume" : "Pause") { workout.paused ? workout.resume() : workout.pause() }
                        .buttonStyle(PillButtonStyle(color: workout.paused ? .brand : .control))
                    Button("End") { confirmEnd = true }.buttonStyle(PillButtonStyle(color: .red)).disabled(ending)
                }
            }
        }
        .confirmationDialog("End run?", isPresented: $confirmEnd) {
            Button("End and save") {
                ending = true
                Task {
                    let moving = workout.elapsed()
                    let r = await workout.end()
                    run.finish(with: r, movingSeconds: moving)
                    ending = false
                }
            }
            Button("Discard", role: .destructive) { workout.discard(); run.discard() }
        }
    }
}

struct RunSummaryView: View {
    let summary: RunStore.Summary
    @EnvironmentObject var run: RunStore
    @EnvironmentObject var sync: SyncStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.indoor ? "Indoor run saved" : "Run saved").font(.headline)
                row("Distance", String(format: "%.2f km", summary.distanceKm))
                row("Time", Fmt.clock(summary.minutes * 60))
                row("Pace", Fmt.pace(secPerKm: summary.paceSecPerKm) + " /km")
                row("Avg HR", summary.avgHR.map { "\($0) bpm" } ?? "–")
                if !summary.indoor { row("Climb", "\(Int(summary.elevationGainM)) m") }
                Text(sync.statusText.isEmpty ? "Saved" : sync.statusText).font(.footnote).foregroundStyle(.secondary)
                Button("Done") { run.summary = nil }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
    }
}
