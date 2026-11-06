import Foundation
import Security

/// Supabase over plain REST, like the web app: password sign-in, refresh token in Keychain,
/// upserts keyed by (user_id, id). Uses the publishable key only.
actor Supabase {
    static let shared = Supabase()

    struct Config {
        let url: String, key: String, email: String, password: String
        static let main: Config = {
            let info = Bundle.main.infoDictionary ?? [:]
            func v(_ k: String) -> String { (info[k] as? String ?? "").trimmingCharacters(in: .whitespaces) }
            return Config(url: v("SUPABASE_URL"), key: v("SUPABASE_ANON_KEY"), email: v("SUPABASE_EMAIL"), password: v("SUPABASE_PASSWORD"))
        }()
        var isComplete: Bool { url.hasPrefix("https://") && !key.isEmpty && !email.isEmpty && !password.isEmpty }
    }

    enum SBError: LocalizedError {
        case notConfigured, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Secrets.xcconfig is missing values"
            case let .http(code, msg): return "HTTP \(code) \(msg)"
            }
        }
    }

    private let cfg = Config.main
    private var access: String?
    private var expiry = Date.distantPast
    private(set) var userId: String?

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double?
        struct User: Decodable { let id: String }
        let user: User?
    }

    private func authRequest(grant: String, body: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: cfg.url + "/auth/v1/token?grant_type=" + grant)!)
        req.httpMethod = "POST"
        req.setValue(cfg.key, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SBError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(_ t: TokenResponse) {
        access = t.access_token
        expiry = Date().addingTimeInterval((t.expires_in ?? 3600) - 60)
        userId = t.user?.id ?? Self.jwtSub(t.access_token)
        Keychain.set(t.refresh_token, for: "sb.refresh")
    }

    /// A valid access token: cached, refreshed from the Keychain token, or a fresh password sign-in.
    func token() async throws -> String {
        guard cfg.isComplete else { throw SBError.notConfigured }
        if let a = access, Date() < expiry { return a }
        if let r = Keychain.get("sb.refresh") {
            do {
                store(try await authRequest(grant: "refresh_token", body: ["refresh_token": r]))
                return access!
            } catch SBError.http(let code, _) where code == 400 || code == 401 {
                Keychain.delete("sb.refresh")
            }
        }
        store(try await authRequest(grant: "password", body: ["email": cfg.email, "password": cfg.password]))
        return access!
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, prefer: String? = nil) async throws -> Data {
        let t = try await token()
        var req = URLRequest(url: URL(string: cfg.url + path)!)
        req.httpMethod = method
        req.setValue(cfg.key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { access = nil }
        guard (200..<300).contains(code) else { throw SBError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    /// Insert or replace sessions by (user_id, id). Safe to retry.
    func upsert(_ rows: [SessionRow]) async throws {
        _ = try await token()
        guard let uid = userId else { throw SBError.http(0, "no user id") }
        let body = try JSONEncoder().encode(rows.map { var r = $0; r.userId = uid; return r })
        _ = try await request("/rest/v1/sessions?on_conflict=user_id,id", method: "POST", body: body,
                              prefer: "resolution=merge-duplicates,return=minimal")
    }

    /// A lift in progress: update the row only while it is still in progress, and insert it if there is none,
    /// so a late upload from this Watch never reopens a workout already finished on the phone.
    func upsertLive(_ row: SessionRow) async throws {
        _ = try await token()
        guard let uid = userId else { throw SBError.http(0, "no user id") }
        struct Patch: Encodable { let data: SessionData; let source: String; let name: String }
        let out = try await request("/rest/v1/sessions?id=eq.\(Self.q(row.id))&status=eq.in_progress", method: "PATCH",
                                    body: try JSONEncoder().encode(Patch(data: row.data, source: row.source, name: row.name)),
                                    prefer: "return=representation")
        if let rows = try? JSONSerialization.jsonObject(with: out) as? [Any], !rows.isEmpty { return }
        var r = row
        r.userId = uid
        _ = try await request("/rest/v1/sessions?on_conflict=user_id,id", method: "POST", body: try JSONEncoder().encode([r]),
                              prefer: "resolution=ignore-duplicates,return=minimal")
    }

    /// Plans for every lift from the "plans" Edge Function (the same progression rules as the web app).
    func plans(today: String) async throws -> PlansResponse {
        let data = try await request("/functions/v1/plans?today=\(today)")
        return try JSONDecoder().decode(PlansResponse.self, from: data)
    }

    /// One session by id, any status (to see what the phone did with a lift in progress).
    func session(id: String) async throws -> SessionRow? {
        let data = try await request("/rest/v1/sessions?select=id,date,session,name,type,status,source,saved_at,data&id=eq.\(Self.q(id))")
        return try JSONDecoder().decode([SessionRow].self, from: data).first
    }

    /// Removes a discarded lift's in-progress row (a finished one is never touched).
    func deleteInProgress(id: String) async throws {
        _ = try await request("/rest/v1/sessions?id=eq.\(Self.q(id))&status=eq.in_progress", method: "DELETE", prefer: "return=minimal")
    }

    /// Adds keys the stored `data` does not have yet (for example the Watch's heart rate on a workout finished on the phone).
    func addMissing(id: String, _ extra: [String: Any]) async throws {
        let raw = try await request("/rest/v1/sessions?select=data&id=eq.\(Self.q(id))")
        var d = ((try JSONSerialization.jsonObject(with: raw) as? [[String: Any]])?.first?["data"] as? [String: Any]) ?? [:]
        for (k, v) in extra where d[k] == nil || d[k] is NSNull { d[k] = v }
        d["updatedAt"] = ISO.string()
        try await replaceData(id: id, data: d)
    }

    private static func q(_ id: String) -> String { id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_~."))) ?? id }

    /// Insert or merge daily Health values by (user_id, date). Rows are grouped by which values they carry,
    /// because PostgREST needs the same keys in every row of a request; missing values keep what is stored.
    func upsertHealth(_ days: [HealthDay]) async throws {
        _ = try await token()
        guard let uid = userId else { throw SBError.http(0, "no user id") }
        for group in Dictionary(grouping: days, by: \.keySignature).values {
            let body = try JSONEncoder().encode(group.map { var d = $0; d.userId = uid; return d })
            _ = try await request("/rest/v1/health_daily?on_conflict=user_id,date", method: "POST", body: body,
                                  prefer: "resolution=merge-duplicates,return=minimal")
        }
    }

    /// Recent completed lift sessions, newest first, for "last time".
    func recentLifts() async throws -> [HistoryRow] {
        let data = try await request("/rest/v1/sessions?select=id,date,data&type=eq.lift&status=eq.complete&order=date.desc&limit=60")
        return try JSONDecoder().decode([HistoryRow].self, from: data)
    }

    /// Watch runs saved before routes were synced: id plus the raw `data` object, newest first.
    /// Completed sessions on or after a date (YYYY-MM-DD), for this week's checklist.
    func sessions(since date: String) async throws -> [WeekRow] {
        let data = try await request("/rest/v1/sessions?select=id,date,session,name,type&status=eq.complete&date=gte.\(date)&order=date.asc")
        return try JSONDecoder().decode([WeekRow].self, from: data)
    }

    func runsWithoutRoute() async throws -> [(id: String, data: [String: Any])] {
        let raw = try await request("/rest/v1/sessions?select=id,data&type=eq.run&status=eq.complete&source=eq.watch&data->>route=is.null&order=date.desc&limit=10")
        let rows = (try JSONSerialization.jsonObject(with: raw) as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let d = r["data"] as? [String: Any] else { return nil }
            return (id, d)
        }
    }

    /// Replaces one session's `data` (the caller passes the full object, with a fresh updatedAt).
    func replaceData(id: String, data: [String: Any]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": data])
        let q = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        _ = try await request("/rest/v1/sessions?id=eq.\(q)", method: "PATCH", body: body, prefer: "return=minimal")
    }

    static func jwtSub(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var b = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["sub"] as? String
    }
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "workouts", kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
