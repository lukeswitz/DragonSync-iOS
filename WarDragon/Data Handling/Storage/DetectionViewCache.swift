import Foundation
import CoreLocation

@MainActor
final class DetectionViewCache {
    static let shared = DetectionViewCache()

    private struct PathEntry {
        let stamp: Date
        let raw: [CLLocationCoordinate2D]
        let smoothed: [CLLocationCoordinate2D]
    }

    private var paths: [String: PathEntry] = [:]
    private var encounters: [String: (stamp: Date, value: StoredDroneEncounter?)] = [:]
    private var countValue = 0
    private var countStamp = Date.distantPast

    private let pathTTL: TimeInterval = 2.0
    private let countTTL: TimeInterval = 10.0
    private let missTTL: TimeInterval = 2.0
    private let maxCachedEncounters = 200
    private let maxCachedPaths = 200
    private let maxSmoothedInput = 600

    private init() {}

    func encounter(for uid: String) -> StoredDroneEncounter? {
        if let cached = encounters[uid] {
            if let value = cached.value {
                if value.modelContext != nil { return value }
            } else if Date().timeIntervalSince(cached.stamp) < missTTL {
                return nil
            }
        }
        let fresh = SwiftDataStorageManager.shared.fetchEncounter(id: uid)
        if encounters.count > maxCachedEncounters { encounters.removeAll() }
        encounters[uid] = (Date(), fresh)
        return fresh
    }

    func flightPath(for uid: String) -> [CLLocationCoordinate2D] {
        entry(for: uid).raw
    }

    func smoothedFlightPath(for uid: String) -> [CLLocationCoordinate2D] {
        entry(for: uid).smoothed
    }

    func encounterCount() -> Int {
        if Date().timeIntervalSince(countStamp) < countTTL { return countValue }
        countValue = SwiftDataStorageManager.shared.fetchAllEncountersLightweight()
            .filter { !$0.id.hasPrefix("aircraft-") }
            .count
        countStamp = Date()
        return countValue
    }

    func invalidate(_ uid: String) {
        paths.removeValue(forKey: uid)
    }

    func sizes() -> String {
        "pathCache=\(paths.count) encCache=\(encounters.count)"
    }

    func invalidateEncounter(_ uid: String) {
        encounters.removeValue(forKey: uid)
        invalidate(uid)
    }

    func invalidateAll() {
        paths.removeAll()
        encounters.removeAll()
        countStamp = .distantPast
    }

    private func entry(for uid: String) -> PathEntry {
        if let cached = paths[uid], Date().timeIntervalSince(cached.stamp) < pathTTL {
            return cached
        }
        let raw = buildPath(uid)
        let smoothed = (raw.count > 2 && raw.count <= maxSmoothedInput)
            ? FlightPathSmoother.smoothPath(raw, smoothness: 4)
            : raw
        let fresh = PathEntry(stamp: Date(), raw: raw, smoothed: smoothed)
        if paths.count >= maxCachedPaths { paths.removeAll(keepingCapacity: true) }
        paths[uid] = fresh
        return fresh
    }

    private func buildPath(_ uid: String) -> [CLLocationCoordinate2D] {
        guard let encounter = encounter(for: uid) else { return [] }
        return encounter.flightPoints
            .filter { !$0.isProximityPoint && !($0.latitude == 0 && $0.longitude == 0) }
            .sorted { $0.timestamp < $1.timestamp }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
