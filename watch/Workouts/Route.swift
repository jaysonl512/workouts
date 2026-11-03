import CoreLocation
import Foundation
import HealthKit

/// Run routes as stored in Supabase (`data.route`): simplified, then a Google encoded polyline (precision 5),
/// which the web app decodes to draw the map.
enum Route {
    /// Keep the shape, drop redundant points: Douglas-Peucker, loosening the tolerance until at most `maxPoints` remain.
    static func encode(_ coords: [CLLocationCoordinate2D], maxPoints: Int = 400) -> String? {
        guard coords.count >= 2 else { return nil }
        var tolerance = 3.0
        var kept = simplify(coords, tolerance: tolerance)
        while kept.count > maxPoints {
            tolerance *= 1.5
            kept = simplify(coords, tolerance: tolerance)
        }
        return polyline(kept)
    }

    /// Douglas-Peucker on a local flat projection (metres), fine for the size of a run.
    static func simplify(_ c: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard c.count > 2 else { return c }
        let lat0 = c[0].latitude * .pi / 180
        let pts = c.map { (x: $0.longitude * 111_320 * cos(lat0), y: $0.latitude * 110_540) }
        var keep = [Bool](repeating: false, count: c.count)
        keep[0] = true
        keep[c.count - 1] = true
        var stack = [(0, c.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            let (ax, ay) = pts[a], (bx, by) = pts[b]
            let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
            var maxD = 0.0, idx = a
            for i in (a + 1)..<b {
                let (px, py) = pts[i]
                var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
                t = min(1, max(0, t))
                let ex = px - (ax + t * dx), ey = py - (ay + t * dy)
                let d = (ex * ex + ey * ey).squareRoot()
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((a, idx))
                stack.append((idx, b))
            }
        }
        return c.indices.filter { keep[$0] }.map { c[$0] }
    }

    static func polyline(_ c: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var pLat = 0, pLng = 0
        func put(_ v: Int) {
            var n = v < 0 ? ~(v << 1) : v << 1
            while n >= 0x20 {
                out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (n & 0x1f)) + 63)))
                n >>= 5
            }
            out.unicodeScalars.append(UnicodeScalar(UInt8(n + 63)))
        }
        for p in c {
            let lat = Int((p.latitude * 1e5).rounded()), lng = Int((p.longitude * 1e5).rounded())
            put(lat - pLat); put(lng - pLng)
            pLat = lat; pLng = lng
        }
        return out
    }

    /// GPS points HealthKit stored for a workout this app saved (used to fill in runs logged before routes synced).
    static func locations(of workoutUUID: UUID, in store: HKHealthStore) async throws -> [CLLocation] {
        func samples(_ type: HKSampleType, _ predicate: NSPredicate) async throws -> [HKSample] {
            try await withCheckedThrowingContinuation { cont in
                store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: s ?? []) }
                })
            }
        }
        guard let workout = try await samples(.workoutType(), HKQuery.predicateForObject(with: workoutUUID)).first as? HKWorkout else { return [] }
        var out: [CLLocation] = []
        for route in try await samples(HKSeriesType.workoutRoute(), HKQuery.predicateForObjects(from: workout)).compactMap({ $0 as? HKWorkoutRoute }) {
            out += try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CLLocation], Error>) in
                var acc: [CLLocation] = []
                var finished = false
                store.execute(HKWorkoutRouteQuery(route: route) { _, locs, done, error in
                    guard !finished else { return }
                    if let error { finished = true; cont.resume(throwing: error); return }
                    acc += locs ?? []
                    if done { finished = true; cont.resume(returning: acc) }
                })
            }
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }
}
