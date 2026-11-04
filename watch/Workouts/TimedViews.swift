import SwiftUI

/// Live screen for a timed workout: clock, heart rate, calories (and distance for walks and rides).
struct TimedView: View {
    @EnvironmentObject var timed: TimedStore
    @EnvironmentObject var workout: WorkoutManager
    @State private var confirmEnd = false
    @State private var ending = false

    var body: some View {
        if let w = timed.workout {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let t = workout.elapsed(at: ctx.date)
                VStack(alignment: .leading, spacing: 2) {
                    Label(w.name, systemImage: w.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.brand)
                        .lineLimit(1)
                    Text(Fmt.clock(t)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(workout.paused ? Color.secondary : Color.white)
                    Text(workout.heartRate > 0 ? "\(Int(workout.heartRate)) bpm" : "-- bpm").font(.title3).monospacedDigit()
                        .foregroundStyle(.red)
                    if w.tracksDistance {
                        Text(String(format: "%.2f km", workout.distanceM / 1000)).font(.title3).monospacedDigit()
                    } else {
                        Text("\(Int(workout.activeKcal)) kcal").font(.title3).monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        Button(workout.paused ? "Resume" : "Pause") { workout.paused ? workout.resume() : workout.pause() }
                            .buttonStyle(PillButtonStyle(color: workout.paused ? .brand : .control))
                        Button("End") { confirmEnd = true }.buttonStyle(PillButtonStyle(color: .red)).disabled(ending)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("End \(w.name)?", isPresented: $confirmEnd) {
                Button("End and save") {
                    ending = true
                    Task {
                        let secs = workout.elapsed()
                        let r = await workout.end()
                        timed.finish(with: r, seconds: secs)
                        ending = false
                    }
                }
                Button("Discard", role: .destructive) { workout.discard(); timed.discard() }
            }
        }
    }
}

struct TimedSummaryView: View {
    let summary: TimedStore.Summary
    @EnvironmentObject var timed: TimedStore
    @EnvironmentObject var sync: SyncStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(summary.name) saved").font(.headline)
                row("Time", "\(summary.minutes) min")
                if let km = summary.distanceKm { row("Distance", String(format: "%.2f km", km)) }
                row("Avg HR", summary.avgHR.map { "\($0) bpm" } ?? "–")
                row("Calories", summary.kcal.map { "\($0) kcal" } ?? "–")
                Text(sync.statusText.isEmpty ? "Saved" : sync.statusText).font(.footnote).foregroundStyle(.secondary)
                Button("Done") { timed.summary = nil }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
    }
}
