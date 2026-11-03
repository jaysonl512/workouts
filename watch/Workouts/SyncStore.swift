import Foundation

/// Offline queue plus "last time" history. Every write lands on disk first and is uploaded when
/// Supabase is reachable (the Watch has no cellular). Only the newest copy of each session is kept.
@MainActor
final class SyncStore: ObservableObject {
    @Published private(set) var pending: [String: SessionRow] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var lastSynced: Date?
    @Published private(set) var history: [HistoryRow] = []

    private var flushing = false
    private var retryTask: Task<Void, Never>?

    private static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let queueURL = dir.appendingPathComponent("queue.json")
    private let historyURL = dir.appendingPathComponent("history.json")

    init() {
        if let d = try? Data(contentsOf: queueURL), let q = try? JSONDecoder().decode([String: SessionRow].self, from: d) { pending = q }
        if let d = try? Data(contentsOf: historyURL), let h = try? JSONDecoder().decode([HistoryRow].self, from: d) { history = h }
    }

    var statusText: String {
        if !pending.isEmpty { return "\(pending.count) waiting to sync" }
        if let lastError { return "Sync: \(lastError)" }
        if lastSynced != nil { return "Synced" }
        return ""
    }

    func enqueue(_ row: SessionRow) {
        pending[row.id] = row
        persistQueue()
        if row.status == "complete", row.type == .lift { remember(row) }
        flush()
    }

    func flush() {
        guard !flushing, !pending.isEmpty else { return }
        flushing = true
        Task {
            defer { flushing = false; scheduleRetry() }
            for row in pending.values.sorted(by: { $0.data.updatedAt < $1.data.updatedAt }) {
                do {
                    try await Supabase.shared.upsert([row])
                    // Keep it if a newer copy was queued while this one was uploading.
                    if pending[row.id]?.data.updatedAt == row.data.updatedAt { pending[row.id] = nil }
                    persistQueue()
                    lastError = nil
                    lastSynced = Date()
                } catch {
                    lastError = Self.short(error)
                    return
                }
            }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard !pending.isEmpty else { return }
        retryTask = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { flush() }
        }
    }

    func refreshHistory() {
        Task {
            do {
                let rows = try await Supabase.shared.recentLifts()
                let ids = Set(rows.map(\.id))
                // Keep locally finished sessions that have not reached the server yet.
                history = (rows + history.filter { !ids.contains($0.id) && pending[$0.id] != nil }).sorted { $0.date > $1.date }
                persistHistory()
                lastError = nil
            } catch {
                lastError = Self.short(error)
            }
        }
    }

    private func remember(_ row: SessionRow) {
        history.removeAll { $0.id == row.id }
        history.insert(HistoryRow(id: row.id, date: row.date, data: .init(entries: row.data.entries)), at: 0)
        history.sort { $0.date > $1.date }
        persistHistory()
    }

    /// Like the web app's lastFor: the most recent earlier session that has sets for this exercise id.
    func lastSets(for exerciseId: String, excluding sessionId: String, before date: String) -> (date: String, sets: [LoggedSet])? {
        for s in history where s.id != sessionId && s.date <= date {
            if let e = s.data.entries?.first(where: { $0.id == exerciseId }), !e.sets.isEmpty { return (s.date, e.sets) }
        }
        return nil
    }

    private func persistQueue() { try? JSONEncoder().encode(pending).write(to: queueURL, options: .atomic) }
    private func persistHistory() { try? JSONEncoder().encode(history).write(to: historyURL, options: .atomic) }

    private static func short(_ e: Error) -> String {
        if (e as? URLError) != nil { return "offline" }
        return String((e as? LocalizedError)?.errorDescription?.prefix(60) ?? "\(e)".prefix(60))
    }
}
