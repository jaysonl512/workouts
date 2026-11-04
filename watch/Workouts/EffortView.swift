import SwiftUI
import WatchKit

/// Right after a workout: how hard was it? Saved as data.effort, shown in the web app.
struct EffortView: View {
    let name: String
    @EnvironmentObject var sync: SyncStore

    var body: some View {
        // Fits a 40 mm screen; the scroll view is only a safety net on smaller text sizes.
        ScrollView {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                Text("How did it go?").font(.system(size: 17, weight: .semibold))
                Text(name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            choice("Easy", "easy", .green)
            choice("Medium", "medium", .orange)
            choice("Hard", "hard", .brand)
            Button("Skip") { sync.rate(nil) }.font(.footnote).foregroundStyle(.secondary).buttonStyle(.plain)
        }
        }
    }

    private func choice(_ label: String, _ value: String, _ color: Color) -> some View {
        Button(label) {
            WKInterfaceDevice.current().play(.click)
            sync.rate(value)
        }
        .buttonStyle(PrimaryButtonStyle(color: color, height: 32))
    }
}
