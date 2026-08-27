//
//  SwiftDataStorageManager.swift
//  WarDragon
//
//  New storage manager using SwiftData instead of UserDefaults
//

import Foundation
import SwiftData
import CoreLocation
import UIKit
import OSLog

@MainActor
class SwiftDataStorageManager: ObservableObject {
    static let shared = SwiftDataStorageManager()
    
    private let logger = Logger(subsystem: "com.wardragon", category: "Storage")
    var cotViewModel: CoTViewModel?
    var statusViewModel: StatusViewModel?
    
    var modelContext: ModelContext?
    private var macToIdCache: [String: String] = [:]
    private var caaToIdCache: [String: String] = [:]
    
    private let signatureGenerator = DroneSignatureGenerator()
    
    // MARK: - Dictionary Access (Deprecated)
    
    /// Provides dictionary-style access to encounters for backward compatibility
    /// - Warning: This creates a new dictionary on every access. Prefer `fetchEncounter(id:)` instead.
    /// - Note: This property is deprecated and will be removed in a future version.
    @available(*, deprecated, message: "Use fetchEncounter(id:) or fetchAllEncounters() instead for better performance")
    var encounters: [String: StoredDroneEncounter] {
        let allEncounters = fetchAllEncountersLightweight()
        var dict: [String: StoredDroneEncounter] = [:]
        for encounter in allEncounters {
            dict[encounter.id] = encounter
        }
        return dict
    }
    
    private var needsSave = false
    private let maxFlightPointsPerEncounter = 1000
    private let flightPointTrimSlack = 100

    private var flightPointLimit: Int {
        guard UserDefaults.standard.object(forKey: "flightPointRetentionLimit") != nil else {
            return maxFlightPointsPerEncounter
        }
        return max(1, UserDefaults.standard.integer(forKey: "flightPointRetentionLimit"))
    }

    private var flightPointMinInterval: Double {
        guard UserDefaults.standard.object(forKey: "flightPointMinIntervalSeconds") != nil else {
            return 2.0
        }
        return UserDefaults.standard.double(forKey: "flightPointMinIntervalSeconds")
    }

    private var flightPointMinDistance: Double {
        guard UserDefaults.standard.object(forKey: "flightPointMinDistanceMeters") != nil else {
            return 0.1
        }
        return UserDefaults.standard.double(forKey: "flightPointMinDistanceMeters")
    }
    private var saveTimer: Timer?
    private var pendingCacheUpdates: Set<String> = []
    private var cacheUpdateTimer: Timer?
    
    // MARK: - Performance Monitoring (Enhancement)
    
    /// Storage operation metrics tracking
    private struct StorageMetrics {
        var operationName: String
        var startTime: Date
        var duration: TimeInterval {
            return Date().timeIntervalSince(startTime)
        }
    }
    
    /// Performance thresholds (configurable)
    private struct PerformanceThresholds {
        static let slowOperation: TimeInterval = 0.1      // 100ms - warn if slower
        static let moderateOperation: TimeInterval = 0.05 // 50ms - log if slower
        static let criticalOperation: TimeInterval = 0.5  // 500ms - critical warning
    }
    
    /// Track operation metrics for debugging and optimization
    private var operationMetrics: [String: [TimeInterval]] = [:]
    private let maxMetricsPerOperation = 100 // Keep last 100 samples
    
    /// Log storage operation performance with enhanced metrics
    private func logStorageOperation(_ operation: String, duration: TimeInterval) {
        // Track metrics
        if operationMetrics[operation] == nil {
            operationMetrics[operation] = []
        }
        operationMetrics[operation]?.append(duration)
        
        // Keep only recent samples
        if let metrics = operationMetrics[operation], metrics.count > maxMetricsPerOperation {
            operationMetrics[operation]?.removeFirst()
        }
        
        // Log based on severity
        if duration > PerformanceThresholds.criticalOperation {
            logger.error("Storage operation '\(operation)' took \(String(format: "%.3f", duration))s")
        } else if duration > PerformanceThresholds.slowOperation {
            logger.warning("SLOW: Storage operation '\(operation)' took \(String(format: "%.3f", duration))s")
        } else if duration > PerformanceThresholds.moderateOperation {
            logger.info("Storage operation '\(operation)' took \(String(format: "%.3f", duration))s")
        }
        // Fast operations (< 50ms) are not logged to reduce noise
    }
      
    /// Measure and log storage operation performance
    @discardableResult
    private func measureOperation<T>(_ operation: String, block: () throws -> T) rethrows -> T {
        let startTime = Date()
        defer {
            let duration = Date().timeIntervalSince(startTime)
            logStorageOperation(operation, duration: duration)
        }
        return try block()
    }
    
    /// Get average performance for an operation (for debugging)
    func getAveragePerformance(for operation: String) -> TimeInterval? {
        guard let metrics = operationMetrics[operation], !metrics.isEmpty else {
            return nil
        }
        return metrics.reduce(0, +) / Double(metrics.count)
    }
    
    /// Get performance statistics for all operations
    func getAllPerformanceStats() -> [String: (avg: TimeInterval, min: TimeInterval, max: TimeInterval, count: Int)] {
        var stats: [String: (avg: TimeInterval, min: TimeInterval, max: TimeInterval, count: Int)] = [:]
        
        for (operation, metrics) in operationMetrics {
            guard !metrics.isEmpty else { continue }
            
            let avg = metrics.reduce(0, +) / Double(metrics.count)
            let min = metrics.min() ?? 0
            let max = metrics.max() ?? 0
            
            stats[operation] = (avg: avg, min: min, max: max, count: metrics.count)
        }
        
        return stats
    }
    
    /// Print performance report to console (useful for debugging)
    func printPerformanceReport() {
        let stats = getAllPerformanceStats()
        
        guard !stats.isEmpty else {
            logger.info("No performance data collected yet")
            return
        }
        
        logger.info("===================================================")
        logger.info("Storage Performance Report")
        logger.info("===================================================")
        
        // Sort by average duration (slowest first)
        let sorted = stats.sorted { $0.value.avg > $1.value.avg }
        
        for (operation, stat) in sorted {
            let avgMs = stat.avg * 1000
            let minMs = stat.min * 1000
            let maxMs = stat.max * 1000
            
            let severity: String
            if stat.avg > PerformanceThresholds.criticalOperation {
                severity = "CRITICAL"
            } else if stat.avg > PerformanceThresholds.slowOperation {
                severity = "SLOW"
            } else if stat.avg > PerformanceThresholds.moderateOperation {
                severity = "MODERATE"
            } else {
                severity = "FAST"
            }
            
            logger.info("[\(severity)] \(operation)")
            logger.info("   Avg: \(String(format: "%.1f", avgMs))ms | Min: \(String(format: "%.1f", minMs))ms | Max: \(String(format: "%.1f", maxMs))ms | Samples: \(stat.count)")
        }
        
        logger.info("===================================================")
    }
    
    nonisolated private init() {
    }
    
    nonisolated private static func startTimer() -> Timer {
        let timer = Timer(timeInterval: 3.0, repeats: true) { _ in
            Task { @MainActor in
                SwiftDataStorageManager.shared.saveIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        return timer
    }
    
    private func ensureTimerStarted() {
        if saveTimer == nil {
            Task { @MainActor in
                self.saveTimer = Self.startTimer()
            }
        }
    }
    
    private func trimFlightPoints(_ encounter: StoredDroneEncounter, context: ModelContext) {
        let limit = flightPointLimit
        guard encounter.flightPoints.count > limit + flightPointTrimSlack else { return }

        let regular = encounter.flightPoints.filter { !$0.isProximityPoint }
        guard regular.count > limit else { return }

        let doomed = regular.sorted { $0.timestamp < $1.timestamp }
            .prefix(regular.count - limit)
        let doomedIds = Set(doomed.map { ObjectIdentifier($0) })

        encounter.flightPoints.removeAll { doomedIds.contains(ObjectIdentifier($0)) }
        for point in doomed { context.delete(point) }
        needsSave = true

        logger.info("Trimmed \(doomedIds.count) flight points from \(encounter.id)")
    }

    private func saveIfNeeded() {
        guard needsSave, let context = modelContext else { return }
        guard context.hasChanges else {
            needsSave = false
            return
        }
        
        measureOperation("Auto-save") {
            do {
                try context.save()
                needsSave = false
            } catch {
                logger.error("Auto-save failed: \(error.localizedDescription)")
            }
        }
    }
    
    func forceSave() {
        guard let context = modelContext else { return }
        guard context.hasChanges else {
            needsSave = false
            return
        }
        
        measureOperation("Force save") {
            do {
                try context.save()
                needsSave = false
                logger.info("Force saved all changes")
            } catch {
                logger.error("Force save failed: \(error.localizedDescription)")
            }
        }
    }
    
    /// Release heavy data from memory when entering background.
    /// Persists pending changes, drops local caches, and asks SwiftData to flush
    /// its row cache via `processPendingChanges`. The model context itself is
    /// NEVER nilled — doing so orphans every `StoredDroneEncounter` reference
    /// held by SwiftUI views, causing fault-fetch crashes on resume.
    func releaseBackgroundMemory() {
        guard let context = modelContext else { return }

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                logger.error("releaseBackgroundMemory save failed: \(error.localizedDescription)")
            }
        }

        macToIdCache.removeAll()
        caaToIdCache.removeAll()
        pendingCacheUpdates.removeAll()
        operationMetrics.removeAll()

        // Flush pending changes; SwiftData manages its own row cache. We do
        // not touch `modelContext` here — bindings remain valid.
        context.processPendingChanges()

        logger.info("Released background memory - flushed caches; context retained")
    }
    
    // MARK: - Batched Cache Updates (Performance Optimization)
    
    private func scheduleCacheUpdate(for encounterId: String) {
        pendingCacheUpdates.insert(encounterId)
        
        if cacheUpdateTimer == nil {
            cacheUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.flushPendingCacheUpdates()
                }
            }
            if let timer = cacheUpdateTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    
    private func flushPendingCacheUpdates() {
        guard !self.pendingCacheUpdates.isEmpty else {
            self.cacheUpdateTimer = nil
            return
        }
        
        logger.info("Flushing \(self.pendingCacheUpdates.count) pending cache updates")
        
        self.pendingCacheUpdates.removeAll()
        self.cacheUpdateTimer = nil
        
        Task { @MainActor in
            self.objectWillChange.send()
            DroneStorageManager.shared.objectWillChange.send()
        }
    }
    
    // MARK: - Save Operations
    
    // REMOVED: saveEncounterDirect() - no longer needed, we work with SwiftData directly
    
    func saveEncounter(_ message: CoTViewModel.CoTMessage, monitorStatus: StatusViewModel.StatusMessage? = nil) {
        measureOperation("saveEncounter(\(message.uid))") {
            guard let context = modelContext else {
                logger.error("ModelContext not set")
                return
            }
            
            let droneId = message.uid
            
            if isMarkedAsDoNotTrack(id: droneId) {
                return
            }
            
            ensureTimerStarted()
            
            let lat = Double(message.lat) ?? 0
            let lon = Double(message.lon) ?? 0
            
            var targetId: String = droneId
        
        logger.info("saveEncounter: Processing \(droneId), idType: \(message.idType), MAC: \(message.mac ?? "none")")
        
        if message.idType.contains("Serial Number") {
            logger.info("Serial Number detected - use serial \(droneId) as unique ID")
            targetId = droneId
        
            if let mac = message.mac, !mac.isEmpty {
                if let existingIdForMac = macToIdCache[mac], existingIdForMac != droneId {
                    logger.warning("MAC \(mac) was previously seen with serial \(existingIdForMac), now seen with \(droneId)")
                } else {
                    macToIdCache[mac] = droneId
                    logger.info("Cached MAC for serial: \(mac) -> \(droneId)")
                }
            }
        } else if message.idType.contains("CAA"), let caaReg = message.caaRegistration {
            if let cachedId = caaToIdCache[caaReg] {
                logger.info("Found CAA in cache: \(caaReg) -> \(cachedId)")
                targetId = cachedId
            } else if let existing = findEncounterByCAA(caaReg, context: context) {
                logger.info("Found CAA in database: \(caaReg) -> \(existing.id)")
                targetId = existing.id
                caaToIdCache[caaReg] = existing.id
            }
            
            if let mac = message.mac, !mac.isEmpty {
                macToIdCache[mac] = targetId
            }
        } else if let mac = message.mac, !mac.isEmpty {
            if let cachedId = macToIdCache[mac] {
                let existingEncounter = fetchEncounter(id: cachedId)
                let droneEncounter = fetchEncounter(id: droneId)
                
                if droneEncounter == nil {
                    logger.info("Using MAC from cache: \(mac) -> \(cachedId) (no existing encounter for \(droneId))")
                    targetId = cachedId
                } else if existingEncounter != nil, cachedId == droneId {
                    logger.info("MAC maps to same drone: \(mac) -> \(droneId)")
                    targetId = droneId
                } else {
                    logger.info("MAC conflict: \(mac) cached to \(cachedId) but drone \(droneId) exists - treating as separate drones")
                    targetId = droneId
                }
            } else if let existing = findEncounterByMAC(mac, context: context) {
                if existing.id == droneId {
                    logger.info("Found MAC in database: \(mac) -> \(existing.id)")
                    targetId = existing.id
                    macToIdCache[mac] = existing.id
                } else {
                    logger.info("MAC conflict: \(mac) exists for \(existing.id) but processing \(droneId) - treating as separate drones")
                    targetId = droneId
                }
            } else {
                macToIdCache[mac] = droneId
                logger.info("New MAC cached: \(mac) -> \(droneId)")
            }
        }
        
        if targetId != droneId {
            logger.info("Consolidating \(droneId) -> \(targetId)")
        }
        
        let encounter = fetchOrCreateEncounter(id: targetId, message: message, context: context)
        
        let now = Date()
        let sessionKey = createSessionKey(for: now)
        var sessionHistory = encounter.metadata["sessionHistory"] ?? ""
        let existingSessions = Set(sessionHistory.components(separatedBy: ";").filter { !$0.isEmpty })
        if !existingSessions.contains(sessionKey) {
            if sessionHistory.isEmpty {
                sessionHistory = sessionKey
            } else {
                sessionHistory += ";\(sessionKey)"
            }
            encounter.metadata["sessionHistory"] = sessionHistory
            logger.info("Added session \(sessionKey) to drone \(targetId)")
        }
        
        logActivityForEncounter(id: encounter.id, timestamp: now)

        var didAddPoint = false
        
        if lat == 0 && lon == 0 {
            logger.info("Skipping flight point for \(droneId): coordinates are 0/0, isFPV=\(message.isFPVDetection)")
        } else if message.isFPVDetection {
            logger.info("Skipping flight point for \(droneId): message is FPV detection")
        }
        
        if !(lat == 0 && lon == 0) && !message.isFPVDetection {
            logger.info("Adding regular flight point for \(droneId): lat=\(lat), lon=\(lon), isFPV=\(message.isFPVDetection)")
            
            // Extract movement data from message
            let heading = Double(message.trackCourse ?? message.direction ?? "0") ?? 0
            let groundSpeed = Double(message.speed) ?? 0
            let verticalSpeed = Double(message.vspeed) ?? 0
            
            // Extract height data
            let heightAGL = Double(message.height ?? "0") ?? 0
            let altPressure = message.alt_pressure ?? (Double(message.alt) ?? 0)
            
            let newPoint = StoredFlightPoint(
                latitude: lat,
                longitude: lon,
                altitude: altPressure,
                timestamp: Date().timeIntervalSince1970,
                homeLatitude: Double(message.homeLat),
                homeLongitude: Double(message.homeLon),
                isProximityPoint: false,
                proximityRssi: nil,
                proximityRadius: nil,
                heading: heading != 0 ? heading : nil,
                groundSpeed: groundSpeed != 0 ? groundSpeed : nil,
                verticalSpeed: verticalSpeed != 0 ? verticalSpeed : nil,
                climbRate: nil,
                turnRate: nil,
                heightAboveGround: heightAGL != 0 ? heightAGL : nil,
                heightAboveTakeoff: nil,
                heightReferenceType: message.heightType,
                heightConsistencyScore: nil
            )
            
            let lastValidPoint = encounter.flightPoints.last(where: { 
                !($0.latitude == 0 && $0.longitude == 0) && !$0.isProximityPoint 
            })
            
            if let lastPoint = lastValidPoint {
                let distance = calculateDistance(
                    from: CLLocationCoordinate2D(latitude: lastPoint.latitude, longitude: lastPoint.longitude),
                    to: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                )
                let timeGap = newPoint.timestamp - lastPoint.timestamp
                
                if distance > flightPointMinDistance || timeGap > flightPointMinInterval {
                    encounter.flightPoints.append(newPoint)
                    didAddPoint = true
                } else {
                    
                }
            } else {
                encounter.flightPoints.append(newPoint)
                didAddPoint = true
            }

            if didAddPoint {
                trimFlightPoints(encounter, context: context)
            }
        }

        // Add proximity point if no flight point added
        if !didAddPoint, let rssi = message.rssi, rssi != 0 {
            if let monitorStatus = monitorStatus {
                let monitorLat = monitorStatus.gpsData.latitude
                let monitorLon = monitorStatus.gpsData.longitude
                
                guard !(monitorLat == 0 && monitorLon == 0) else {
                    logger.warning("Skipping proximity point for \(droneId) - monitor has no GPS location (0/0)")
                    return
                }
                
                let currentCount = Int(encounter.metadata["totalDetections"] ?? "0") ?? 0
                encounter.metadata["totalDetections"] = "\(currentCount + 1)"
                
                let proximityPoint = StoredFlightPoint(
                    latitude: monitorLat,
                    longitude: monitorLon,
                    altitude: 0,
                    timestamp: Date().timeIntervalSince1970,
                    homeLatitude: Double(message.homeLat),
                    homeLongitude: Double(message.homeLon),
                    isProximityPoint: true,
                    proximityRssi: Double(rssi),
                    proximityRadius: nil
                )
                
                let proximityPoints = encounter.flightPoints.filter { $0.isProximityPoint && $0.proximityRssi != nil }
                
                if proximityPoints.count < 3 {
                    encounter.flightPoints.append(proximityPoint)
                    encounter.metadata["hasProximityPoints"] = "true"
                } else {
                    let rssiValues = proximityPoints.compactMap { $0.proximityRssi }
                    let minRssi = rssiValues.min() ?? Double(rssi)
                    let maxRssi = rssiValues.max() ?? Double(rssi)
                    
                    if let replaceIndex = encounter.flightPoints.firstIndex(where: { point in
                        point.isProximityPoint && point.proximityRssi != nil &&
                        point.proximityRssi != minRssi && point.proximityRssi != maxRssi
                    }) {
                        encounter.flightPoints[replaceIndex] = proximityPoint
                    }
                }
                
                if let viewModel = cotViewModel {
                    var proximityMessage = message
                    proximityMessage.rssi = rssi
                    viewModel.updateAlertRing(for: proximityMessage)
                }
            }
        }
        
        // Track operator location over time
        if let pilotLat = Double(message.pilotLat),
           let pilotLon = Double(message.pilotLon),
           pilotLat != 0 || pilotLon != 0 {
            
            // Update latest coordinates
            encounter.operatorLatitude = pilotLat
            encounter.operatorLongitude = pilotLon
            
            // Track historical operator movement
            let shouldAddOpLocation: Bool
            if let lastOpLocation = encounter.operatorLocations.last {
                let dist = calculateDistance(
                    from: CLLocationCoordinate2D(latitude: lastOpLocation.latitude, longitude: lastOpLocation.longitude),
                    to: CLLocationCoordinate2D(latitude: pilotLat, longitude: pilotLon)
                )
                let timeGap = Date().timeIntervalSince1970 - lastOpLocation.timestamp
                shouldAddOpLocation = dist > 5.0 || timeGap > 30.0
            } else {
                shouldAddOpLocation = true
            }
            
            if shouldAddOpLocation {
                let opLoc = StoredOperatorLocation(
                    latitude: pilotLat,
                    longitude: pilotLon,
                    altitude: nil,
                    timestamp: Date().timeIntervalSince1970
                )
                encounter.operatorLocations.append(opLoc)
                
                // Limit operator location history
                if encounter.operatorLocations.count > 100 {
                    let toRemove = Array(encounter.operatorLocations.prefix(20))
                    toRemove.forEach { context.delete($0) }
                    encounter.operatorLocations.removeFirst(20)
                }
            }
        }
        
        // Track home location changes
        if let homeLat = Double(message.homeLat),
           let homeLon = Double(message.homeLon),
           homeLat != 0 || homeLon != 0 {
            
            // Update latest coordinates
            encounter.homeLatitude = homeLat
            encounter.homeLongitude = homeLon
            
            // Track home location changes (different from operator - home shouldn't move much)
            let shouldAddHomeLocation: Bool
            if let lastHomeLocation = encounter.homeLocations.last {
                let dist = calculateDistance(
                    from: CLLocationCoordinate2D(latitude: lastHomeLocation.latitude, longitude: lastHomeLocation.longitude),
                    to: CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
                )
                shouldAddHomeLocation = dist > 1.0 // Only add if home actually moved
            } else {
                shouldAddHomeLocation = true
            }
            
            if shouldAddHomeLocation {
                let homeLoc = StoredHomeLocation(
                    latitude: homeLat,
                    longitude: homeLon,
                    altitude: nil,
                    timestamp: Date().timeIntervalSince1970
                )
                encounter.homeLocations.append(homeLoc)
                
                // Limit home location history
                if encounter.homeLocations.count > 50 {
                    let toRemove = Array(encounter.homeLocations.prefix(10))
                    toRemove.forEach { context.delete($0) }
                    encounter.homeLocations.removeFirst(10)
                }
            }
        }
        
        if let mac = message.mac, !mac.isEmpty && !encounter.macAddresses.contains(mac) {
            encounter.macAddresses.append(mac)
            macToIdCache[mac] = encounter.id
        }
        for source in message.signalSources {
            if !source.mac.isEmpty && !encounter.macAddresses.contains(source.mac) {
                encounter.macAddresses.append(source.mac)
                macToIdCache[source.mac] = encounter.id
            }
        }
        
        if let rssi = message.rssi, rssi != 0 {
            let shouldAdd: Bool
            if let lastSig = encounter.signatures.last {
                let rssiDelta = abs(Double(rssi) - lastSig.rssi)
                let timeGap = Date().timeIntervalSince1970 - lastSig.timestamp
                shouldAdd = rssiDelta > 3.0 || timeGap > 5.0
            } else {
                shouldAdd = true
            }
            
            if shouldAdd {
                // Create full DroneSignature for complete data retention
                let droneSignature = createDroneSignature(from: message, encounter: encounter)
                let signatureData = droneSignature.flatMap { try? JSONEncoder().encode($0) }
                
                // Spoof detection if we have a StatusViewModel available
                var isSpoofed = false
                var spoofConfidence = 0.0
                var spoofReasons: [String] = []
                
                if let signature = droneSignature,
                   let statusVM = statusViewModel,
                   let monitorStatus = statusVM.statusMessages.last {
                    if let spoofResult = signatureGenerator.detectSpoof(signature, fromMonitor: monitorStatus) {
                        isSpoofed = spoofResult.isSpoofed
                        spoofConfidence = spoofResult.confidence
                        spoofReasons = spoofResult.reasons
                        
                        if isSpoofed {
                            logger.warning("SPOOFED DRONE: \(encounter.id) - Confidence: \(String(format: "%.1f%%", spoofConfidence * 100)) - Reasons: \(spoofReasons.joined(separator: ", "))")
                        }
                    }
                }
                
                let sig = StoredSignature(
                    timestamp: Date().timeIntervalSince1970,
                    rssi: Double(rssi),
                    speed: Double(message.speed) ?? 0.0,
                    height: Double(message.height ?? "0.0") ?? 0.0,
                    mac: message.mac,
                    signatureData: signatureData,
                    isSpoofed: isSpoofed,
                    spoofConfidence: spoofConfidence,
                    spoofReasons: spoofReasons
                )
                encounter.signatures.append(sig)
                
                if encounter.signatures.count > 500 {
                    let toRemove = Array(encounter.signatures.prefix(100))
                    toRemove.forEach { context.delete($0) }
                    encounter.signatures.removeFirst(100)
                }
            }
        }
        
        updateMetadata(encounter: encounter, message: message)
        encounter.lastSeen = Date()
        
        encounter.updateCachedStats()
        
        needsSave = true
        
        let shouldUpdateCache = didAddPoint || 
                               encounter.signatures.count > 0 || 
                               !message.isFPVDetection
        
        if shouldUpdateCache {
            scheduleCacheUpdate(for: encounter.id)
        }
        
        if didAddPoint {
            scheduleCacheUpdate(for: encounter.id)
        }
        } // End measureOperation
    }
    
    /// Count total encounters without loading them into memory
    /// This is much more memory-efficient than fetchAllEncounters().count
    func countEncounters() -> Int {
        return measureOperation("countEncounters") {
            guard let context = modelContext else { return 0 }
            
            let descriptor = FetchDescriptor<StoredDroneEncounter>()
            
            do {
                return try context.fetchCount(descriptor)
            } catch {
                logger.error("Failed to count encounters: \(error.localizedDescription)")
                return 0
            }
        }
    }
    
    func fetchAllEncounters() -> [StoredDroneEncounter] {
        return measureOperation("fetchAllEncounters") {
            guard let context = modelContext else { return [] }
            
            var descriptor = FetchDescriptor<StoredDroneEncounter>(
                sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]
            )
            descriptor.relationshipKeyPathsForPrefetching = [\.flightPoints, \.signatures]
            
            do {
                return try context.fetch(descriptor)
            } catch {
                logger.error("Failed to fetch encounters: \(error.localizedDescription)")
                return []
            }
        }
    }
    
    func fetchAllEncountersLightweight() -> [StoredDroneEncounter] {
        return measureOperation("fetchAllEncountersLightweight") {
            guard let context = modelContext else { return [] }
            
            let descriptor = FetchDescriptor<StoredDroneEncounter>(
                sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]
            )
            
            do {
                return try context.fetch(descriptor)
            } catch {
                logger.error("Failed to fetch encounters: \(error.localizedDescription)")
                return []
            }
        }
    }
    
    func fetchEncounter(id: String) -> StoredDroneEncounter? {
        return measureOperation("fetchEncounter(\(id))") {
            guard let context = modelContext else { return nil }
            
            let predicate = #Predicate<StoredDroneEncounter> { encounter in
                encounter.id == id
            }
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.relationshipKeyPathsForPrefetching = [\.flightPoints, \.signatures]
            
            do {
                let result = try context.fetch(descriptor).first
                
                // Verify the encounter is still attached to a context
                if let encounter = result {
                    guard encounter.modelContext != nil else {
                        logger.warning("Fetched encounter \(id) is detached from context")
                        return nil
                    }
                }
                
                return result
            } catch {
                logger.error("Failed to fetch encounter \(id): \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Fetch full encounter data
    func fetchFullEncounter(id: String) -> StoredDroneEncounter? {
        guard let context = modelContext else { return nil }
        
        let predicate = #Predicate<StoredDroneEncounter> { encounter in
            encounter.id == id
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.relationshipKeyPathsForPrefetching = [\.flightPoints, \.signatures]
        
        do {
            let result = try context.fetch(descriptor).first
            if let encounter = result {
                guard encounter.modelContext != nil else {
                    logger.warning("Fetched full encounter \(id) is detached from context")
                    return nil
                }
            }
            
            return result
        } catch {
            logger.error("Failed to fetch full encounter \(id): \(error.localizedDescription)")
            return nil
        }
    }
    
    func getEncounterSafely(id: String) -> StoredDroneEncounter? {
        return fetchEncounter(id: id)
    }
    
    func withEncounterSafely(id: String, perform: (StoredDroneEncounter) -> Void) {
        guard let encounter = fetchEncounter(id: id) else {
            logger.warning("Cannot perform operation: encounter \(id) not found or detached")
            return
        }
        perform(encounter)
    }
    
    func deleteEncounter(id: String) {
        guard let context = modelContext else { 
            logger.error("Cannot delete encounter: ModelContext not set")
            return 
        }
        
        guard let encounter = getEncounterSafely(id: id) else {
            logger.warning("Encounter \(id) not found for deletion")
            return
        }
        
        let encounterId = encounter.id
        
        context.delete(encounter)
        
        let baseId = encounterId.replacingOccurrences(of: "drone-", with: "").replacingOccurrences(of: "fpv-", with: "")
        let possibleIds = [
            encounterId,
            "drone-\(encounterId)",
            baseId,
            "drone-\(baseId)",
            "fpv-\(baseId)",
            "fpv-\(encounterId)"
        ]
        
        for possibleId in possibleIds {
            doNotTrackCache.remove(possibleId)
            macToIdCache = macToIdCache.filter { $0.value != possibleId }
            caaToIdCache = caaToIdCache.filter { $0.value != possibleId }
        }
        
        do {
            try context.save()
            logger.info("Deleted encounter and cleared caches: \(encounterId)")
            
            Task { @MainActor in
                DetectionViewCache.shared.invalidateEncounter(encounterId)
                self.objectWillChange.send()
                DroneStorageManager.shared.objectWillChange.send()
            }
        } catch {
            logger.error("Failed to delete encounter \(encounterId): \(error.localizedDescription)")
            
            if let nsError = error as NSError? {
                logger.error("Error domain: \(nsError.domain), code: \(nsError.code)")
                logger.error("Error details: \(nsError.userInfo)")
            }
        }
    }
    
    func deleteAllEncounters() {
        guard let context = modelContext else { return }
        
        Task { @MainActor in
            macToIdCache.removeAll()
            caaToIdCache.removeAll()
            doNotTrackCache.removeAll()
            DetectionViewCache.shared.invalidateAll()
        }
        
        do {
            let descriptor = FetchDescriptor<StoredDroneEncounter>()
            let encountersToDelete = try context.fetch(descriptor)
            let count = encountersToDelete.count
            
            logger.info("Deleting \(count) drone encounters...")
            
            // Delete in batches to avoid memory issues
            let batchSize = 50
            for batchStart in stride(from: 0, to: encountersToDelete.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, encountersToDelete.count)
                let batch = Array(encountersToDelete[batchStart..<batchEnd])
                
                for encounter in batch {
                    // Explicitly clear relationships to avoid faulting during deletion
                    encounter.flightPoints.removeAll()
                    encounter.signatures.removeAll()
                    encounter.homeLocations.removeAll()
                    encounter.operatorLocations.removeAll()
                    
                    context.delete(encounter)
                }
                
                try context.save()
                logger.info("Deleted batch \(batchStart/batchSize + 1) of \((count + batchSize - 1) / batchSize)")
            }
            
            logger.info("Successfully deleted all \(count) encounters and cleared all caches")
            
        } catch {
            logger.error("Failed to delete all encounters: \(error.localizedDescription)")
            
            if let nsError = error as NSError? {
                logger.error("Error domain: \(nsError.domain), code: \(nsError.code)")
                logger.error("Error details: \(nsError.userInfo)")
            }
        }
    }
    
    func updateDroneInfo(id: String, name: String, trustStatus: DroneSignature.UserDefinedInfo.TrustStatus) {
        guard let encounter = getEncounterSafely(id: id) else {
            logger.warning("Cannot update drone info for \(id): encounter not found or detached")
            return
        }
        
        encounter.customName = name
        encounter.trustStatus = trustStatus
        
        do {
            try modelContext?.save()
            scheduleCacheUpdate(for: id)
            
            NotificationCenter.default.post(
                name: Notification.Name("DroneInfoUpdated"),
                object: nil,
                userInfo: ["droneId": id, "customName": name, "trustStatus": trustStatus.rawValue]
            )
            
            logger.info("Updated drone info: \(id)")
        } catch {
            logger.error("Failed to update drone info: \(error.localizedDescription)")
        }
    }
    
    func markAsDoNotTrack(id: String) {
        let baseId = id.replacingOccurrences(of: "drone-", with: "").replacingOccurrences(of: "fpv-", with: "")
        let possibleIds = [
            id,
            "drone-\(id)",
            baseId,
            "drone-\(baseId)",
            "fpv-\(baseId)",
            "fpv-\(id)"
        ]
        
        for possibleId in possibleIds {
            doNotTrackCache.insert(possibleId)
            if let encounter = getEncounterSafely(id: possibleId) {
                encounter.metadata["doNotTrack"] = "true"
            }
        }
        
        do {
            try modelContext?.save()
            logger.info("Marked as do not track: \(possibleIds)")
        } catch {
            logger.error("Failed to mark as do not track: \(error.localizedDescription)")
        }
    }
    
    private var doNotTrackCache = Set<String>()
    
    func isMarkedAsDoNotTrack(id: String) -> Bool {
        if doNotTrackCache.contains(id) {
            return true
        }
        
        let baseId = id.replacingOccurrences(of: "drone-", with: "").replacingOccurrences(of: "fpv-", with: "")
        
        if doNotTrackCache.contains(baseId) {
            doNotTrackCache.insert(id)
            return true
        }
        
        guard let encounter = getEncounterSafely(id: id) else {
            if baseId != id, let baseEncounter = getEncounterSafely(id: baseId) {
                if baseEncounter.metadata["doNotTrack"] == "true" {
                    doNotTrackCache.insert(id)
                    doNotTrackCache.insert(baseId)
                    return true
                }
            }
            return false
        }
        
        if encounter.metadata["doNotTrack"] == "true" {
            doNotTrackCache.insert(id)
            doNotTrackCache.insert(baseId)
            return true
        }
        
        return false
    }
    
    func clearDoNotTrack(id: String) {
        let baseId = id.replacingOccurrences(of: "drone-", with: "").replacingOccurrences(of: "fpv-", with: "")
        let possibleIds = [
            id,
            "drone-\(id)",
            baseId,
            "drone-\(baseId)",
            "fpv-\(baseId)",
            "fpv-\(id)"
        ]
        
        for possibleId in possibleIds {
            doNotTrackCache.remove(possibleId)
            if let encounter = getEncounterSafely(id: possibleId) {
                encounter.metadata.removeValue(forKey: "doNotTrack")
                logger.info("Cleared do not track for: \(possibleId)")
            }
        }
        
        do {
            try modelContext?.save()
            scheduleCacheUpdate(for: id)
            logger.info("Successfully cleared do not track for: \(possibleIds)")
        } catch {
            logger.error("Failed to save after clearing do not track: \(error.localizedDescription)")
        }
    }
    
    func clearAllDoNotTrack() {
        let allEncounters = fetchAllEncounters().filter { $0.modelContext != nil }
        var clearedCount = 0
        
        for encounter in allEncounters {
            if encounter.metadata["doNotTrack"] != nil {
                encounter.metadata.removeValue(forKey: "doNotTrack")
                clearedCount += 1
            }
        }
        
        if clearedCount > 0 {
            do {
                try modelContext?.save()
                doNotTrackCache.removeAll()
                logger.info("Cleared do not track for \(clearedCount) encounters")
            } catch {
                logger.error("Failed to save after clearing all do not track: \(error.localizedDescription)")
            }
        } else {
            logger.info("No encounters had do not track set")
        }
    }
    
    func repairCachedStats() {
        guard let context = modelContext else { return }
        
        var descriptor = FetchDescriptor<StoredDroneEncounter>(
            sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]
        )
        descriptor.fetchLimit = 10
        descriptor.relationshipKeyPathsForPrefetching = []
        
        do {
            let allEncounters = try context.fetch(descriptor).filter { $0.modelContext != nil }
            
            var repairedCount = 0
            
            for encounter in allEncounters {
                let needsRepair = encounter.cachedFlightPointCount == 0 || 
                                 encounter.cachedSignatureCount == 0
                
                if needsRepair {
                    encounter.updateCachedStats()
                    repairedCount += 1
                }
            }
            
            if repairedCount > 0 {
                try context.save()
                logger.info("Repaired cached stats for \(repairedCount) encounters")
            } else {
                logger.info("All encounters have valid cached stats")
            }
        } catch {
            logger.error("Failed to repair stats: \(error.localizedDescription)")
        }
    }
    
    func exportToCSV() -> String {
        let encounters = fetchAllEncounters().filter { $0.modelContext != nil }
        var csv = DroneEncounter.csvHeaders() + "\n"
        
        for encounter in encounters {
            let legacy = encounter.toLegacy()
            csv += legacy.toCSVRow() + "\n"
        }
        
        return csv
    }
    
    func shareCSV(from viewController: UIViewController? = nil) {
        let csvContent = exportToCSV()
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "drone_encounters_\(timestamp).csv"
        
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileURL = tempDirectory.appendingPathComponent(filename)
        
        do {
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write CSV: \(error.localizedDescription)")
            return
        }
        
        let csvDataItem = DroneStorageManager.CSVDataItem(fileURL: fileURL, filename: filename)
        let activityVC = UIActivityViewController(activityItems: [csvDataItem], applicationActivities: nil)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            
            if UIDevice.current.userInterfaceIdiom == .pad {
                activityVC.popoverPresentationController?.sourceView = window
                activityVC.popoverPresentationController?.sourceRect = CGRect(
                    x: window.bounds.midX,
                    y: window.bounds.midY,
                    width: 0,
                    height: 0
                )
            }
            
            DispatchQueue.main.async {
                window.rootViewController?.present(activityVC, animated: true)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func createSessionKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH"
        return formatter.string(from: date)
    }
    
    private func findEncounterByMAC(_ mac: String, context: ModelContext) -> StoredDroneEncounter? {
        let descriptor = FetchDescriptor<StoredDroneEncounter>()
        
        do {
            let all = try context.fetch(descriptor)
            return all.first { $0.macAddresses.contains(mac) }
        } catch {
            return nil
        }
    }
    
    private func findEncounterByCAA(_ caaReg: String, context: ModelContext) -> StoredDroneEncounter? {
        let descriptor = FetchDescriptor<StoredDroneEncounter>()
        
        do {
            let all = try context.fetch(descriptor)
            return all.first { $0.metadata["caaRegistration"] == caaReg }
        } catch {
            return nil
        }
    }
    
    private func fetchOrCreateEncounter(id: String, message: CoTViewModel.CoTMessage?, context: ModelContext) -> StoredDroneEncounter {
        if let existing = fetchEncounter(id: id) {
            logger.info("Found existing encounter for ID: \(id)")
            return existing
        }
        
        logger.info("Creating NEW encounter for ID: \(id)")
        let new = StoredDroneEncounter(
            id: id,
            firstSeen: Date(),
            lastSeen: Date(),
            customName: "",
            trustStatusRaw: DroneSignature.UserDefinedInfo.TrustStatus.unknown.rawValue,
            metadata: [:],
            macAddresses: []
        )
        context.insert(new)
        logger.info("Successfully created and inserted new encounter: \(id)")
        return new
    }
    
    private func updateMetadata(encounter: StoredDroneEncounter, message: CoTViewModel.CoTMessage) {
        var metadata = encounter.metadata
        
        if let mac = message.mac {
            metadata["mac"] = mac
        }
        if let caaReg = message.caaRegistration {
            metadata["caaRegistration"] = caaReg
        }
        if let manufacturer = message.manufacturer {
            metadata["manufacturer"] = manufacturer
        }
        metadata["idType"] = message.idType
        
        // Update pilot location
        if let pilotLat = Double(message.pilotLat), let pilotLon = Double(message.pilotLon),
           pilotLat != 0 && pilotLon != 0 {
            let newCoordKey = "\(pilotLat),\(pilotLon)"
            let currentCoordKey = metadata["pilotLat"].flatMap { lat in
                metadata["pilotLon"].map { lon in "\(lat),\(lon)" }
            }
            
            if currentCoordKey != newCoordKey {
                metadata["pilotLat"] = message.pilotLat
                metadata["pilotLon"] = message.pilotLon
                
                let timestamp = Date().timeIntervalSince1970
                let pilotEntry = "\(timestamp):\(pilotLat),\(pilotLon)"
                
                if let existingHistory = metadata["pilotHistory"] {
                    let existingEntries = Set(existingHistory.components(separatedBy: ";"))
                    if !existingEntries.contains(where: { $0.hasSuffix(":\(pilotLat),\(pilotLon)") }) {
                        metadata["pilotHistory"] = existingHistory + ";" + pilotEntry
                    }
                } else {
                    metadata["pilotHistory"] = pilotEntry
                }
            }
        }
        
        // Update home location
        if let homeLat = Double(message.homeLat), let homeLon = Double(message.homeLon),
           homeLat != 0 && homeLon != 0 {
            let newCoordKey = "\(homeLat),\(homeLon)"
            let currentCoordKey = metadata["homeLat"].flatMap { lat in
                metadata["homeLon"].map { lon in "\(lat),\(lon)" }
            }
            
            if currentCoordKey != newCoordKey {
                metadata["homeLat"] = message.homeLat
                metadata["homeLon"] = message.homeLon
                
                let timestamp = Date().timeIntervalSince1970
                let homeEntry = "\(timestamp):\(homeLat),\(homeLon)"
                
                if let existingHistory = metadata["homeHistory"] {
                    let existingEntries = Set(existingHistory.components(separatedBy: ";"))
                    if !existingEntries.contains(where: { $0.hasSuffix(":\(homeLat),\(homeLon)") }) {
                        metadata["homeHistory"] = existingHistory + ";" + homeEntry
                    }
                } else {
                    metadata["homeHistory"] = homeEntry
                }
            }
        }
        
        encounter.metadata = metadata
    }
    
    private func calculateDistance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let location1 = CLLocation(latitude: from.latitude, longitude: from.longitude)
        let location2 = CLLocation(latitude: to.latitude, longitude: to.longitude)
        return location1.distance(from: location2)
    }
    
    func logActivityForEncounter(id: String, timestamp: Date) {
        guard let context = modelContext else { return }
        
        let predicate = #Predicate<StoredDroneEncounter> { encounter in
            encounter.id == id
        }
        let descriptor = FetchDescriptor(predicate: predicate)
        
        guard let encounter = try? context.fetch(descriptor).first,
              encounter.modelContext != nil else {
            return
        }
        
        let logString = encounter.metadata["activityLog"]
        
        if logString == nil {
            encounter.metadata["activityLog"] = ActivityLogEntry(startTime: timestamp, endTime: timestamp).toString()
            needsSave = true
            return
        }
        
        let entries = logString!.components(separatedBy: ";").filter { !$0.isEmpty }
        var parsedEntries = entries.compactMap { ActivityLogEntry.fromString($0) }
        
        if let lastIndex = parsedEntries.indices.last, 
           timestamp.timeIntervalSince(parsedEntries[lastIndex].endTime) < 120 {
            parsedEntries[lastIndex].endTime = timestamp
        } else {
            parsedEntries.append(ActivityLogEntry(startTime: timestamp, endTime: timestamp))
        }
        
        encounter.metadata["activityLog"] = parsedEntries.map { $0.toString() }.joined(separator: ";")
        needsSave = true
    }
    
    func cleanupOldAircraftEncounters(maxAircraftCount: Int = 200) {
        guard let context = modelContext else { return }
        
        do {
            let descriptor = FetchDescriptor<StoredDroneEncounter>()
            let allEncounters = try context.fetch(descriptor)
            
            let aircraftEncounters = allEncounters.filter { $0.id.hasPrefix("aircraft-") }
            
            guard aircraftEncounters.count > maxAircraftCount else {
                logger.info("Aircraft cleanup not needed: \(aircraftEncounters.count)/\(maxAircraftCount) stored")
                return
            }
            
            let sortedAircraft = aircraftEncounters.sorted { $0.lastSeen < $1.lastSeen }
            
            let deleteCount = aircraftEncounters.count - maxAircraftCount
            let toDelete = sortedAircraft.prefix(deleteCount)
            
            logger.info("Cleaning up \(deleteCount) old aircraft encounters (keeping \(maxAircraftCount) newest)...")
            
            for aircraft in toDelete {
                context.delete(aircraft)
            }
            
            try context.save()
            
            logger.info(" Deleted \(deleteCount) old aircraft encounters")
            
        } catch {
            logger.error("Aircraft cleanup failed: \(error.localizedDescription)")
        }
    }
    
    func deleteAllAircraftEncounters() {
        guard let context = modelContext else { return }
        
        do {
            let descriptor = FetchDescriptor<StoredDroneEncounter>()
            let allEncounters = try context.fetch(descriptor)
            
            let aircraftEncounters = allEncounters.filter { $0.id.hasPrefix("aircraft-") }
            
            logger.info("Deleting \(aircraftEncounters.count) aircraft encounters...")
            
            for aircraft in aircraftEncounters {
                context.delete(aircraft)
            }
            
            try context.save()
            
            logger.info(" Deleted all aircraft encounters (drones preserved)")
            
        } catch {
            logger.error("Failed to delete aircraft encounters: \(error.localizedDescription)")
        }
    }
    
    func backfillActivityLogsForAllEncounters() {
        guard UserDefaults.standard.bool(forKey: "activityLogBackfillCompleted") == false else {
            return
        }
        
        guard let context = modelContext else { return }
        
        do {
            var descriptor = FetchDescriptor<StoredDroneEncounter>()
            descriptor.fetchLimit = 10
            descriptor.relationshipKeyPathsForPrefetching = []
            
            let allEncounters = try context.fetch(descriptor).filter { encounter in
                guard encounter.modelContext != nil else { return false }
                return encounter.metadata["activityLog"] == nil || encounter.metadata["activityLog"]?.isEmpty == true
            }
            
            guard !allEncounters.isEmpty else {
                logger.info("No encounters need activity log backfill")
                UserDefaults.standard.set(true, forKey: "activityLogBackfillCompleted")
                return
            }
            
            logger.info("Backfilling activity logs for \(allEncounters.count) encounters...")
            
            for encounter in allEncounters {
                encounter.backfillActivityLog()
            }
            
            try context.save()
            UserDefaults.standard.set(true, forKey: "activityLogBackfillCompleted")
            logger.info("Successfully backfilled activity logs for \(allEncounters.count) encounters")
            
        } catch {
            logger.error("Failed to backfill activity logs: \(error.localizedDescription)")
        }
    }
    
    /// Remove any flight points with 0/0 coordinates from all encounters
    /// This cleans up invalid data that may have been saved before validation was added
    func cleanupInvalidFlightPoints() {
        guard UserDefaults.standard.bool(forKey: "invalidFlightPointsCleanupCompleted") == false else {
            logger.info("Invalid flight points cleanup already completed")
            return
        }
        
        guard let context = modelContext else { return }
        
        do {
            var descriptor = FetchDescriptor<StoredDroneEncounter>()
            descriptor.fetchLimit = 10
            descriptor.relationshipKeyPathsForPrefetching = []
            
            let allEncounters = try context.fetch(descriptor).filter { $0.modelContext != nil }
            
            var totalPointsRemoved = 0
            var encountersAffected = 0
            
            logger.info("Checking \(allEncounters.count) encounters for invalid 0/0 flight points...")
            
            for encounter in allEncounters {
                let invalidPoints = encounter.flightPoints.filter { point in
                    point.latitude == 0 && point.longitude == 0 && !point.isProximityPoint
                }
                
                if !invalidPoints.isEmpty {
                    logger.info("Removing \(invalidPoints.count) invalid points from encounter \(encounter.id)")
                    
                    for point in invalidPoints {
                        context.delete(point)
                        encounter.flightPoints.removeAll { $0.persistentModelID == point.persistentModelID }
                    }
                    
                    totalPointsRemoved += invalidPoints.count
                    encountersAffected += 1
                    
                    encounter.updateCachedStats()
                }
            }
            
            if totalPointsRemoved > 0 {
                try context.save()
                logger.info("Removed \(totalPointsRemoved) invalid flight points from \(encountersAffected) encounters")
            } else {
                logger.info("No invalid flight points found")
            }
            
            UserDefaults.standard.set(true, forKey: "invalidFlightPointsCleanupCompleted")
            
        } catch {
            logger.error("Failed to cleanup invalid flight points: \(error.localizedDescription)")
        }
    }
    
    private func createDroneSignature(from message: CoTViewModel.CoTMessage, encounter: StoredDroneEncounter) -> DroneSignature? {
        let idInfo = DroneSignature.IdInfo(
            id: message.id,
            type: parseIdType(message.idType),
            protocolVersion: message.protocolVersion ?? "1.0",
            uaType: message.uaType,
            macAddress: message.mac
        )
        
        let lat = Double(message.lat) ?? 0
        let lon = Double(message.lon) ?? 0
        let alt = Double(message.alt) ?? 0
        
        guard lat != 0 || lon != 0 else {
            logger.warning("Cannot create DroneSignature: invalid coordinates for \(message.id)")
            return nil
        }
        
        let opLat = Double(message.pilotLat) ?? 0
        let opLon = Double(message.pilotLon) ?? 0
        let operatorLoc = (opLat != 0 || opLon != 0) ? CLLocationCoordinate2D(latitude: opLat, longitude: opLon) : nil
        
        let homeLat = Double(message.homeLat) ?? 0
        let homeLon = Double(message.homeLon) ?? 0
        let homeLoc = (homeLat != 0 || homeLon != 0) ? CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon) : nil
        
        let position = DroneSignature.PositionInfo(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: alt,
            altitudeReference: parseAltitudeRef(message.heightType),
            lastKnownGoodPosition: nil,
            operatorLocation: operatorLoc,
            homeLocation: homeLoc,
            horizontalAccuracy: Double(message.horizontal_accuracy ?? "0") ?? 0,
            verticalAccuracy: Double(message.vertical_accuracy ?? "0") ?? 0,
            timestamp: Date().timeIntervalSince1970
        )
        
        let movement = DroneSignature.MovementVector(
            groundSpeed: Double(message.speed) ?? 0,
            verticalSpeed: Double(message.vspeed) ?? 0,
            heading: Double(message.trackCourse ?? message.direction ?? "0") ?? 0,
            climbRate: nil,
            turnRate: nil,
            flightPath: nil,
            timestamp: Date().timeIntervalSince1970
        )
        
        let heightInfo = DroneSignature.HeightInfo(
            heightAboveGround: Double(message.height ?? "0") ?? 0,
            heightAboveTakeoff: nil,
            referenceType: parseHeightRef(message.heightType),
            horizontalAccuracy: Double(message.horizontal_accuracy ?? "0") ?? 0,
            verticalAccuracy: Double(message.vertical_accuracy ?? "0") ?? 0,
            consistencyScore: 1.0,
            lastKnownGoodHeight: nil,
            timestamp: Date().timeIntervalSince1970
        )
        
        let transmissionInfo = DroneSignature.TransmissionInfo(
            transmissionType: parseTransmissionType(message),
            signalStrength: message.rssi.map { Double($0) },
            expectedSignalStrength: nil,
            macAddress: message.mac,
            frequency: message.freq,
            protocolType: .openDroneID,
            messageTypes: inferMessageTypes(from: message),
            timestamp: Date().timeIntervalSince1970,
            metadata: nil,
            channel: message.channel,
            advMode: message.advMode,
            advAddress: message.adv_mac,
            did: message.did,
            sid: message.sid,
            accessAddress: message.aa,
            phy: message.phy
        )
        
        let broadcastPattern = DroneSignature.BroadcastPattern(
            messageSequence: [],
            intervalPattern: [],
            consistency: 0.0,
            startTime: Date().timeIntervalSince1970,
            lastUpdate: Date().timeIntervalSince1970
        )
        
        return DroneSignature(
            primaryId: idInfo,
            secondaryId: nil,
            operatorId: message.operator_id,
            sessionId: nil,
            position: position,
            movement: movement,
            heightInfo: heightInfo,
            transmissionInfo: transmissionInfo,
            broadcastPattern: broadcastPattern,
            timestamp: Date().timeIntervalSince1970,
            firstSeen: encounter.firstSeen.timeIntervalSince1970,
            messageInterval: nil
        )
    }
    
    private func parseIdType(_ typeStr: String) -> DroneSignature.IdInfo.IdType {
        let lower = typeStr.lowercased()
        if lower.contains("serial") { return .serialNumber }
        if lower.contains("caa") { return .caaRegistration }
        if lower.contains("utm") { return .utmAssigned }
        if lower.contains("session") { return .sessionId }
        return .unknown
    }
    
    private func parseAltitudeRef(_ heightType: String?) -> DroneSignature.PositionInfo.AltitudeReference {
        guard let type = heightType?.lowercased() else { return .wgs84 }
        if type.contains("takeoff") { return .takeoff }
        if type.contains("ground") { return .ground }
        return .wgs84
    }
    
    private func parseHeightRef(_ heightType: String?) -> DroneSignature.HeightInfo.HeightReferenceType {
        guard let type = heightType?.lowercased() else { return .ground }
        if type.contains("takeoff") { return .takeoff }
        if type.contains("pressure") { return .pressureAltitude }
        if type.contains("wgs") { return .wgs84 }
        return .ground
    }
    
    private func parseTransmissionType(_ message: CoTViewModel.CoTMessage) -> DroneSignature.TransmissionInfo.TransmissionType {
        if message.isFPVDetection { return .fpv }
        if message.seenBy?.contains("ESP32") == true { return .esp32 }
        if message.channel != nil { return .ble }
        return .wifi
    }
    
    private func inferMessageTypes(from message: CoTViewModel.CoTMessage) -> Set<DroneSignature.TransmissionInfo.MessageType> {
        var types: Set<DroneSignature.TransmissionInfo.MessageType> = []
        
        if message.channel != nil {
            types.insert(.bt45)
        }
        
        if message.lat != "0" && message.lon != "0" {
            types.insert(.bt45)
        }
        
        if message.pilotLat != "0" && message.pilotLon != "0" {
            types.insert(.bt45)
        }
        
        if types.isEmpty {
            types.insert(.bt45)
        }
        
        return types
    }
}
