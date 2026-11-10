import SwiftUI

/// Active lift: every screen here fits a 40 mm Watch without scrolling.
struct LiftFlowView: View {
    @EnvironmentObject var lift: LiftStore
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            if lift.finishedElsewhere != nil {
                FinishedElsewhereView()
            } else if let id = lift.rateFor {
                RateView(exerciseId: id)
            } else if lift.restEnd != nil {
                RestView()
            } else if lift.nextUp, let step = lift.currentStep {
                NextUpView(step: step)
            } else if let step = lift.currentStep {
                ExerciseView(step: step).id(step.id)
            } else {
                FinishView()
            }
        }
        // Handoff: every 10 seconds while the app is on screen, pick up sets logged on the phone.
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                await lift.pullRemote()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .overlay(alignment: .top) {
            if let note = lift.handoffNote {
                Text(note).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.brand)).foregroundStyle(.white)
                    .task { try? await Task.sleep(for: .seconds(2.5)); lift.handoffNote = nil }
            }
        }
    }
}

/// The phone saved this lift. End the Watch workout (its heart rate is added to the phone's copy) and show the summary.
struct FinishedElsewhereView: View {
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var workout: WorkoutManager

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone").font(.system(size: 30)).foregroundStyle(Color.brand)
            Text("Finished on your phone").font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
            ProgressView()
        }
        .task {
            let r = await workout.end()
            let bw = await AppModel.shared.health.latestBodyWeightLb()
            await lift.finishElsewhere(with: r, bodyWeight: bw)
        }
    }
}

struct ExerciseView: View {
    let step: Step
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var sync: SyncStore

    enum Field { case weight, reps }
    @State private var weight: Double = 0
    @State private var reps: Double = 0
    @State private var page = 0
    @FocusState private var focus: Field?

    private var done: [LoggedSet] { lift.sets(for: step.id) }
    private var last: [LoggedSet]? {
        guard let d = lift.draft else { return nil }
        return sync.lastSets(for: step.id, excluding: d.id, before: d.date)?.sets
    }
    private var isPlank: Bool { step.slot.id == "plank" }
    private var isSuperset: Bool {
        guard let i = lift.steps.firstIndex(of: step) else { return false }
        return lift.supersetPartner(of: i) != nil
    }
    /// The next set and its planned target (frozen when the lift started; never changes during the workout).
    private var item: LiftStore.NextItem { lift.nextItem(for: step) }
    private var working: [LoggedSet] { done.filter { !$0.isWarmup } }

    var body: some View {
        TabView(selection: $page) {
            logger.tag(0)
            ExerciseOptions(step: step).tag(1)
        }
        .tabViewStyle(.page)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { prefill(); focus = step.isTimed ? .reps : .weight }
        .onChange(of: done.count) { _, _ in prefill() }
    }

    private var logger: some View {
        VStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                Text(step.name).font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.brand)
                Text(subtitle)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !step.isTimed {
                valueRow(.weight, text: Fmt.weight(weight), unit: lift.planFor(step.id)?.unit.map(Self.shortUnit) ?? step.weightUnit,
                         minus: { weight = max(0, weight - step.slot.weightStep) },
                         plus: { weight = min(1000, weight + step.slot.weightStep) })
                    .digitalCrownRotation(detent: $weight, from: 0, through: 1000, by: 0.25,
                                          sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
            }

            valueRow(.reps, text: "\(Int(reps))", unit: isPlank ? "sec" : "reps",
                     minus: { reps = max(0, reps - Double(step.slot.repStep)) },
                     plus: { reps = min(300, reps + Double(step.slot.repStep)) })
                .digitalCrownRotation(detent: $reps, from: 0, through: 300, by: Double(step.slot.repStep),
                                      sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)

            Button(item.warmup ? "Log Warm-up" : "Log Set") { lift.logSet(w: step.isTimed ? 0 : weight, r: Int(reps)) }
                .buttonStyle(PrimaryButtonStyle(height: 38))
        }
        .padding(.horizontal, 2)
    }

    /// "Set 2 of 4 · Target 45×10", "Warm-up 1 of 2 · 25×8", or without a plan "Set 2 of 4 · 8–12 · Last 45×10".
    private var subtitle: String {
        let it = item, a = step.isAssisted, ss = isSuperset ? "Superset · " : ""
        if it.warmup, let t = it.target { return "Warm-up \(it.index + 1) of \(it.total) · \(Self.text(t, assisted: a))" }
        let n = "Set \(min(it.index + 1, max(it.total, it.index + 1))) of \(it.total)"
        if let t = it.target { return "\(ss)\(n) · Target \(step.isTimed ? "\(t.r) sec" : Self.text(t, assisted: a))\(stale)" }
        if it.index >= it.total { return "\(ss)Extra set · Done " + working.map { $0.text(assisted: a) }.joined(separator: " ") }
        guard let l = last, !l.isEmpty else { return "\(ss)\(n) · \(step.slot.repsText)\(isPlank ? " sec" : "")" }
        return "\(ss)\(n) · Last " + l.filter { !$0.isWarmup }.map { $0.text(assisted: a) }.joined(separator: " ")
    }

    /// The cached plan predates a session logged here since (it could not refresh): say which date it is from.
    private var stale: String {
        guard let d = lift.draft, let based = lift.planFor(step.id)?.basedOn,
              let newer = sync.lastSets(for: step.id, excluding: d.id, before: d.date)?.date, newer > based else { return "" }
        return " · plan from \(based.suffix(5))"
    }

    static func text(_ t: PlanSet, assisted: Bool) -> String {
        guard let w = t.w else { return "\(t.r) reps" }
        return LoggedSet(w: w, r: t.r).text(assisted: assisted)
    }

    static func shortUnit(_ u: String) -> String {
        u == "lb per dumbbell" ? "lb each" : u == "lb per arm" ? "lb / arm" : u
    }

    /// − value + ; tapping the value gives it the Digital Crown (red outline).
    private func valueRow(_ field: Field, text: String, unit: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        let selected = focus == field
        return HStack(spacing: 4) {
            RoundIconButton(symbol: "minus", action: minus)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.brand : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { focus = field }
            RoundIconButton(symbol: "plus", action: plus)
        }
        .focusable()
        .focused($focus, equals: field)
        .focusEffectDisabled()
    }

    /// The planned target (weight from the last set when the plan has none yet), else this session's last set,
    /// else last time's set, else the bottom of the rep range (the web app's initCur order).
    private func prefill() {
        let lastWorking = working.last ?? last?.filter { !$0.isWarmup }.last
        if let t = item.target {
            weight = t.w ?? lastWorking?.w ?? 0; reps = Double(t.r)
        } else if let s = done.last {
            weight = s.w; reps = Double(s.r)
        } else if let l = lastWorking {
            weight = l.w; reps = Double(l.r)
        } else {
            weight = 0; reps = Double(step.slot.reps.lowerBound)
        }
    }
}

/// Second page of the exercise screen: navigation, swap, undo, finish.
struct ExerciseOptions: View {
    let step: Step
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var workout: WorkoutManager
    @State private var confirmDiscard = false

    private var index: Int { lift.draft?.index ?? 0 }

    var body: some View {
        List {
            HStack(spacing: 6) {
                Button { lift.go(to: index - 1) } label: { Label("Prev", systemImage: "chevron.left") }
                    .buttonStyle(PillButtonStyle()).disabled(index == 0)
                Button { lift.go(to: index + 1) } label: { Label("Next", systemImage: "chevron.right") }
                    .buttonStyle(PillButtonStyle())
            }
            .labelStyle(.titleOnly)
            .listRowBackground(Color.clear)
            NavigationLink("Swap exercise") { SwapView(step: step) }
            if lift.nextItem(for: step).warmup {
                Button("Skip warm-ups") { lift.skipWarmups(step) }
            }
            Button("Undo last set") { lift.undoLastSet() }
                .disabled(lift.sets(for: step.id).isEmpty)
            Button("Finish workout") { lift.go(to: lift.steps.count) }
                .foregroundStyle(Color.brand)
            Button("Discard workout", role: .destructive) { confirmDiscard = true }
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard) {
            Button("Discard", role: .destructive) { workout.discard(); lift.discard() }
        }
    }
}

struct SwapView: View {
    let step: Step
    @EnvironmentObject var lift: LiftStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List([PlanAlt(id: step.slot.id, name: step.slot.name)] + step.slot.alts, id: \.id) { a in
            Button {
                lift.swap(slot: step.slot.id, to: a.id)
                dismiss()
            } label: {
                HStack {
                    Text(a.name)
                    Spacer()
                    if a.id == step.id { Image(systemName: "checkmark").foregroundStyle(Color.brand) }
                }
            }
        }
        .navigationTitle("Swap")
    }
}

struct RestView: View {
    @EnvironmentObject var lift: LiftStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let left = max(0, (lift.restEnd ?? ctx.date).timeIntervalSince(ctx.date))
            VStack(spacing: 6) {
                ZStack {
                    Circle().stroke(Color.control, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: lift.restTotal > 0 ? min(1, left / lift.restTotal) : 0)
                        .stroke(Color.brand, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(Fmt.clock(left.rounded(.up)))
                            .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        if let n = lift.afterRest() {
                            Text(n.label)
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                .frame(maxWidth: 90)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                // The weight to grab next, so the timer never has to be skipped to see it.
                if let t = lift.afterRest()?.target {
                    Text(t).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Color.brand)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }

                HStack(spacing: 4) {
                    Button("-15") { lift.adjustRest(-15) }.buttonStyle(PillButtonStyle())
                    Button("Skip") { lift.stopRest() }.buttonStyle(PillButtonStyle(color: .brand))
                    Button("+15") { lift.adjustRest(15) }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .navigationTitle("Rest")
    }
}

struct NextUpView: View {
    let step: Step
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var sync: SyncStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "dumbbell.fill").font(.system(size: 20)).foregroundStyle(Color.brand)
                    .padding(.top, 2)
                Text(step.name).font(.system(size: 19, weight: .semibold)).lineLimit(3).minimumScaleFactor(0.7)
            }
            Text("\(lift.plannedCount(step)) sets").font(.system(size: 16)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Start") { lift.nextUp = false }.buttonStyle(PrimaryButtonStyle(color: .control))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Next Up")
    }
}

struct FinishView: View {
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var workout: WorkoutManager
    @State private var saving = false

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("\(lift.totalSets)").font(.system(size: 40, weight: .semibold, design: .rounded))
            Text("sets logged").font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(saving ? "Saving…" : "Finish") {
                saving = true
                Task {
                    let r = await workout.end()
                    let bw = await AppModel.shared.health.latestBodyWeightLb()
                    lift.finish(with: r, bodyWeight: bw)
                    saving = false
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(saving || lift.totalSets == 0)
        }
        .navigationTitle("Finish")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Back to the last exercise, in the top corner so it never gets cut off at the bottom.
            ToolbarItem(placement: .cancellationAction) {
                Button { lift.go(to: lift.steps.count - 1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Back")
                    .disabled(saving)
            }
        }
    }
}

struct LiftSummaryView: View {
    let summary: LiftStore.Summary
    @EnvironmentObject var lift: LiftStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 36))
                    .symbolRenderingMode(.palette).foregroundStyle(.black, .green)
                Text("Complete").font(.system(size: 22, weight: .semibold))
                Text("\(summary.minutes) min" + (summary.kcal.map { " · \($0) kcal" } ?? ""))
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                NavigationLink { LiftSummaryDetail(summary: summary) } label: { Text("View Summary") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .navigationTitle("Workout")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { lift.summary = nil } }
            }
        }
    }
}

struct LiftSummaryDetail: View {
    let summary: LiftStore.Summary
    @EnvironmentObject var lift: LiftStore
    @EnvironmentObject var sync: SyncStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.name).font(.headline)
                row("Sets", "\(summary.sets)")
                row("Volume", "\(Int(summary.volume)) lb")
                row("Duration", "\(summary.minutes) min")
                row("Avg HR", summary.avgHR.map { "\($0) bpm" } ?? "–")
                row("Energy", summary.kcal.map { "\($0) kcal" } ?? "–")
                Text(sync.statusText.isEmpty ? "Saved" : sync.statusText).font(.footnote).foregroundStyle(.secondary)
                Button("Done") { lift.summary = nil }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
        .navigationTitle("Summary")
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
    }
}

/// Optional "How was it?" for the exercise just finished: three small buttons, easy to ignore (Start skips it).
/// Right after the last set of an exercise: how did it feel? Optional; Skip moves on. The rest timer keeps
/// counting underneath.
struct RateView: View {
    let exerciseId: String
    @EnvironmentObject var lift: LiftStore

    var body: some View {
        let name = lift.steps.first { $0.id == exerciseId }?.name ?? Plan.exerciseName(exerciseId) ?? "it"
        VStack(spacing: 5) {
            Text("How did \(name) feel?").font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                .lineLimit(2).minimumScaleFactor(0.7)
            ForEach([("easy", "Easy"), ("moderate", "Moderate"), ("hard", "Hard")], id: \.0) { v, label in
                Button(label) { lift.rate(exerciseId, v) }.buttonStyle(PrimaryButtonStyle(color: .control, height: 34))
            }
            Button("Skip") { lift.rateFor = nil }.font(.system(size: 14)).foregroundStyle(.secondary).buttonStyle(.plain)
        }
        .navigationTitle("Rate")
        .navigationBarTitleDisplayMode(.inline)
    }
}
