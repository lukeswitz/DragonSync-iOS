//
//  CoTViewModel.swift
//  WarDragon
//
//  Created by Luke on 11/18/24.
//

import Foundation
import Network
import UserNotifications
import CoreLocation
import UIKit
import SwiftUI
import Combine

class CoTViewModel: ObservableObject, @unchecked Sendable {
    let objectWillChange = ObservableObjectPublisher()
    var parsedMessages: [CoTMessage] = [] { didSet { scheduleUIRefresh() } }
    var droneSignatures: [DroneSignature] = [] { didSet { scheduleUIRefresh() } }
    var randomMacIdHistory: [String: Set<String>] = [:] { didSet { scheduleUIRefresh() } }
    var alertRings: [AlertRing] = [] { didSet { scheduleUIRefresh() } }
    private(set) var isReconnecting = false { didSet { scheduleUIRefresh() } }
    private var uiRefreshPending = false
    private let uiRefreshInterval: TimeInterval = 0.25
    private var lastProcessTime = Date.distantPast
    private var isInBackground = false
    private let signatureGenerator = DroneSignatureGenerator()
    public let statusViewModel: StatusViewModel
    private var spectrumViewModel: SpectrumData.SpectrumViewModel?
    private var zmqHandler: ZMQHandler?
    private lazy var messageConverter = ZMQHandler() // For message conversion even in multicast mode
    private let backgroundManager = BackgroundManager.shared
    private var cotListener: NWListener?
    private var statusListener: NWListener?
    private var multicastGroup: NWConnectionGroup?
    private var multicastRecoveryScheduled = false
    private var multicastRecoveryAttempts = 0
    private var lastDetectionPublish: [String: Date] = [:]
    private let coordlessRepublishInterval: TimeInterval = 30
    
    // ADS-B update counters (moved from extension)
    private var openSkyUpdateCount: Int = 0
    private var aircraftUpdateCounter: Int = 0
    
    // MARK: - Detection Limits (matching Python DragonSync)
    // Python has max_drones = 30 (default), configurable via config.ini
    private let maxDrones = 30
    private let maxAircraft = 100
    
    // MARK: - Inactivity Timeout (matching Python DragonSync)
    // Python has inactivity_timeout = 60.0 seconds (default)
    private let inactivityTimeout: TimeInterval = 60.0
    private var inactivityCleanupTimer: Timer?
    
    // Cached settings values to avoid main actor access issues
    private var cachedConnectionMode: ConnectionMode = .multicast
    private var cachedMulticastHost: String = "239.2.3.1"
    private var cachedMulticastPort: UInt16 = 6969
    private var cachedZmqHost: String = "192.168.2.1"
    private var cachedZmqTelemetryPort: UInt16 = 45454
    private var cachedZmqStatusPort: UInt16 = 4225
    private var cachedIsListening: Bool = false
    
    private let listenerQueue = DispatchQueue(label: "CoTListenerQueue")
    public var isListeningCot = false
    private var isStarting = false
    public var macIdHistory: [String: Set<String>] = [:]
    public var macProcessing: [String: Bool] = [:]
    private var lastNotificationTime: Date?
    private var notifiedDrones: Set<String> = []  // Track which drones we've already notified about
    private var macToCAA: [String: String] = [:]
    private var backgroundMaintenanceTimer: Timer?
    private var macToHomeLoc: [String: (lat: Double, lon: Double)] = [:]
    private var currentMessageFormat: ZMQHandler.MessageFormat {
        return zmqHandler?.messageFormat ?? .bluetooth
    }
    
    // MARK: - MQTT and TAK Integration
    private var mqttClient: MQTTClient?
    private var takClient: TAKClient?
    private var cancellables = Set<AnyCancellable>()
    private var publishedDrones: Set<String> = []
    
    private var latticeClient: LatticeClient? // Track drones for HA discovery
    
    // MARK: - ADS-B Integration
    private var adsbClient: ADSBClient?
    private var adsbCancellables = Set<AnyCancellable>()  // Separate cancellables for ADS-B to prevent interference
    var aircraftTracks: [Aircraft] = [] { didSet { scheduleUIRefresh() } }
    
    /// Unified detection statistics
    struct DetectionStats {
        let totalDrones: Int
        let activeDrones: Int
        let totalAircraft: Int
        let activeAircraft: Int
        
        var totalDetections: Int { totalDrones + totalAircraft }
        var activeDetections: Int { activeDrones + activeAircraft }
        var hasDrones: Bool { totalDrones > 0 }
        var hasAircraft: Bool { totalAircraft > 0 }
        var hasAnyDetections: Bool { totalDetections > 0 }
    }
    
    /// Get current detection statistics
    var detectionStats: DetectionStats {
        let drones = parsedMessages.filter { !$0.uid.hasPrefix("aircraft-") && !$0.uid.hasPrefix("fpv-") }
        let aircraft = parsedMessages.filter { $0.uid.hasPrefix("aircraft-") }
        
        return DetectionStats(
            totalDrones: drones.count,
            activeDrones: drones.filter { $0.isActive }.count,
            totalAircraft: aircraft.count,
            activeAircraft: aircraft.filter { $0.isActive }.count
        )
    }
    
    struct AlertRing: Identifiable {
            let id = UUID()
            let droneId: String
            let centerCoordinate: CLLocationCoordinate2D
            let radius: Double
            let rssi: Int

            var mapKey: String { "\(droneId)|\(centerCoordinate.latitude)|\(centerCoordinate.longitude)|\(Int(radius))" }
        }
    
    struct SignalSource: Hashable {
        let mac: String
        let rssi: Int
        let type: SignalType
        let timestamp: Date
        
        enum SignalType: String, Hashable {
            case bluetooth
            case wifi
            case sdr
            case fpv
            case unknown
        }
        
        init?(mac: String, rssi: Int, type: SignalType, timestamp: Date) {
            guard rssi != 0 else { return nil }
            self.mac = mac
            self.rssi = rssi
            self.type = type
            self.timestamp = timestamp
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(mac)
            hasher.combine(type)
        }
        
        static func == (lhs: SignalSource, rhs: SignalSource) -> Bool {
            return lhs.mac == rhs.mac && lhs.type == rhs.type
        }
    }
    
    struct CoTMessage: Identifiable, Equatable {
        var id: String { uid }
        var caaRegistration: String?
        var uid: String
        var type: String
        
        // Basic location and movement
        var lat: String
        var lon: String
        var homeLat: String
        var homeLon: String
        var speed: String
        var vspeed: String
        var alt: String
        var height: String?
        var pilotLat: String
        var pilotLon: String
        var description: String
        var selfIDText: String
        var uaType: DroneSignature.IdInfo.UAType
        
        // Basic ID fields with protocol info
        var idType: String
        var protocolVersion: String?
        var mac: String?
        var rssi: Int?
        var manufacturer: String?
        var signalSources: [SignalSource] = []
        
        // Location/Vector Message fields
        var location_protocol: String?
        var op_status: String?
        var height_type: String?
        var ew_dir_segment: String?
        var speed_multiplier: String?
        var direction: String?
        var geodetic_altitude: Double?
        var vertical_accuracy: String?
        var horizontal_accuracy: String?
        var baro_accuracy: String?
        var speed_accuracy: String?
        var timestamp: String?
        var timestamp_accuracy: String?
        
        // Multicast CoT specific fields
        var time: String?
        var start: String?
        var stale: String?
        var how: String?
        var ce: String?  // Circular error
        var le: String?  // Linear error
        var hae: String? // Height above ellipsoid
        
        // BT/WiFi transmission fields from ZMQ
        var aux_rssi: Int?
        var channel: Int?
        var phy: Int?
        var aa: Int?
        var adv_mode: String?
        var adv_mac: String?
        var did: Int?
        var sid: Int?
        
        // Extended Location fields
        var timeSpeed: String?
        var status: String?
        var opStatus: String?
        var altPressure: String?
        var heightType: String?
        var horizAcc: String?
        var vertAcc: String?
        var baroAcc: String?
        var speedAcc: String?
        var timestampAccuracy: String?
        
        // ZMQ Operator & System fields
        var operator_id: String?
        var operator_id_type: String?
        var classification_type: String?
        var operator_location_type: String?
        var area_count: String?
        var area_radius: String?
        var area_ceiling: String?
        var area_floor: String?
        var advMode: String?
        var txAdd: Int?
        var rxAdd: Int?
        var adLength: Int?
        var accessAddress: Int?
        
        // System Message fields
        var operatorAltGeo: String?
        var areaCount: String?
        var areaRadius: String?
        var areaCeiling: String?
        var areaFloor: String?
        var classification: String?
        var system_timestamp: Int?
        var location_status: Int?
        var alt_pressure: Double?
        var horiz_acc: Int?
        var description_type: Int?
        
        // Self-ID fields
        var selfIdType: String?
        var selfIdId: String?
        
        // Auth Message fields
        var authType: String?
        var authPage: String?
        var authLength: String?
        var authTimestamp: String?
        var authData: String?
        
        // Spoof detection
        var isSpoofed: Bool = false
        var spoofingDetails: DroneSignatureGenerator.SpoofDetectionResult?
        
        var customName: String = ""
        var trustStatus: DroneSignature.UserDefinedInfo.TrustStatus = .unknown
        
        var displayName: String {
            if !customName.isEmpty {
                return customName
            }
            if !description.isEmpty && description != uid {
                return description
            }
            return uid.replacingOccurrences(of: "drone-", with: "")
        }
        
        var index: String?
        var runtime: String?
        
        var freq: Double?
        var seenBy: String?
        var observedAt: Double?
        var ridTimestamp: String?
        var ridTracking: String?
        var ridStatus: String?
        var ridMake: String?
        var ridModel: String?
        var ridSource: String?
        var ridLookupSuccess: Bool = false

        // MARK: - droneid-go schema additions
        var transport: String?
        var basicFrequencyMHz: Double?
        var frequencyMessageMHz: Double?
        var selfIdTextType: String?
        var authPageCount: String?
        
        // MARK: - FPV Signal Conversion
        
        /// Converts FPV signal strength values (1200-3500 range) to standard RSSI dBm (-100 to -40)
        /// FPV detectors often use raw ADC values or non-standard scales
        /// This mapping assumes: 1200 = very weak (-100 dBm), 3500 = very strong (-40 dBm)
        var normalizedRSSI: Double? {
            // PRIORITY 1: Check if this is an FPV detection with fpvRSSI value
            // FPV signals use 1000-3500 range (raw ADC from RX5808)
            if isFPVDetection, let fpvSignal = fpvRSSI {
                // Map FPV signal (1200-3500) to RSSI dBm (-100 to -40)
                // Linear interpolation: RSSI = minRSSI + (signal - minSignal) * (maxRSSI - minRSSI) / (maxSignal - minSignal)
                let minSignal: Double = 1200.0  // Weakest FPV signal
                let maxSignal: Double = 3500.0  // Strongest FPV signal
                let minRSSI: Double = -100.0    // Corresponding weak RSSI
                let maxRSSI: Double = -40.0     // Corresponding strong RSSI
                
                // Clamp signal to valid range
                let clampedSignal = min(max(fpvSignal, minSignal), maxSignal)
                
                // Linear interpolation
                let normalizedValue = minRSSI + (clampedSignal - minSignal) * (maxRSSI - minRSSI) / (maxSignal - minSignal)
                
//                print("DEBUG normalizedRSSI: FPV signal \(fpvSignal) -> \(normalizedValue) dBm")
                return normalizedValue
            }
            
            // PRIORITY 2: Standard negative RSSI value (already in dBm)
            if let rssi = rssi, rssi < 0 {
                return Double(rssi)
            }
            
            // PRIORITY 3: Check if rssi field contains large FPV-style value (shouldn't happen, but fallback)
            if let rssi = rssi, rssi > 1000 {
                let minSignal: Double = 1200.0
                let maxSignal: Double = 3500.0
                let minRSSI: Double = -100.0
                let maxRSSI: Double = -40.0
                let clampedSignal = min(max(Double(rssi), minSignal), maxSignal)
                let normalizedValue = minRSSI + (clampedSignal - minSignal) * (maxRSSI - minRSSI) / (maxSignal - minSignal)
//                print("DEBUG normalizedRSSI: Large rssi value \(rssi) -> \(normalizedValue) dBm")
                return normalizedValue
            }
            
            // PRIORITY 4: Standard positive RSSI (convert to negative)
            if let rssi = rssi, rssi > 0 && rssi < 100 {
                return Double(-rssi)
            }
            
//            print("DEBUG normalizedRSSI: No valid RSSI found for \(uid)")
            return nil
        }
        
        // FPV Detection Properties
        var isFPVDetection: Bool {
            // Simply check if UID starts with "fpv-" - this is definitive
            // The idType check is unreliable because it may not be preserved during updates
            return uid.hasPrefix("fpv-")
        }
        
        var fpvDisplayName: String {
            if let frequency = fpvFrequency {
                return "FPV \(frequency)MHz"
            }
            return "FPV Signal"
        }
        
        var fpvSignalStrengthFormatted: String {
            // Use normalized RSSI which converts FPV signals to dBm scale
            if let normalized = normalizedRSSI {
                return String(format: "%.0f dBm", normalized)
            }
            // Fallback to raw FPV signal value
            if let rssi = fpvRSSI {
                return String(format: "%.0f", rssi)
            }
            return "Unknown"
        }
        
        var fpvFrequencyFormatted: String {
            if let frequency = fpvFrequency {
                return "\(frequency) MHz"
            }
            return "Unknown"
        }
        
        var statusColor: Color {
            let timeSinceLastUpdate = Date().timeIntervalSince(lastUpdated)
            // FPV Staleout
            if isFPVDetection {
                if timeSinceLastUpdate < 30 {
                    guard let rssi = fpvRSSI else { return .gray }
                    if rssi > 2000 { return .green }
                    if rssi > 100 { return .yellow }
                    return .red
                }
                else if timeSinceLastUpdate < 120 {
                    return .yellow
                } else {
                    return .gray
                }
            }
            
            // Drone Staleout
            else if timeSinceLastUpdate < 30 {
                if let rssiValue = rssi {
                    return rssiValue > -60 ? .green : rssiValue > -80 ? .yellow : .red
                }
                return .red
            } else if timeSinceLastUpdate < 120 {
                return .yellow
            } else {
                return .gray
            }
        }
    
    //CoT Message Tracks
    var trackCourse: String?
        var trackSpeed: String?
        
        var hasTrackInfo: Bool {
            return trackCourse != nil || trackSpeed != nil ||
            (direction != nil && direction != "0")
        }
        
        var trackSpeedFormatted: String? {
            if let speed = trackSpeed {
                return "\(speed) m/s"
            } else if !self.speed.isEmpty && self.speed != "0.0" {
                return "\(self.speed) m/s"
            }
            return nil
        }
        
        // FPV vars
        var fpvTimestamp: String?
        var fpvSource: String?
        var fpvFrequency: Int?
        var fpvBandwidth: String?
        var fpvRSSI: Double?
        var fpvStatus: String?  // Status from fpv_mdn_receiver (NEW CONTACT LOCK, LOCK UPDATE, etc.)
        var fpvEstimatedDistance: Double?  // Calculated distance from RSSI
        var fpvSensorLat: Double?  // Sensor location when detection occurred
        var fpvSensorLon: Double?  // Sensor location when detection occurred
        
        // Helper - Heading calculation with priority order
        public var headingDeg: Double {
            // Priority 1: Use trackCourse from multicast CoT <track> element
            if let rawTrack = trackCourse,
               rawTrack != "0.0",
               let deg = Double(rawTrack.replacingOccurrences(of: "°", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            }
            
            // Priority 2: Use direction from ZMQ Location/Vector Message
            if let directionStr = direction,
               directionStr != "0.0",
               let deg = Double(directionStr.replacingOccurrences(of: "°", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            }
            
            // Priority 3: Could calculate from flight path history, but that requires
            // async/main actor access to DroneStorageManager which isn't safe here
            // The calculation would happen in the map view instead
            
            // Default: 0° (North)
            return 0.0
        }


        // Stale timer
        var lastUpdated: Date = Date()
        
        var isActive: Bool {
            return Date().timeIntervalSince(lastUpdated) <= 300  // 5 minutes standard
        }
        
        var isStale: Bool {
            guard let staleTime = self.stale else { return true }
            let formatter = ISO8601DateFormatter()
            guard let staleDate = formatter.date(from: staleTime) else { return true }
            return Date() > staleDate
        }
        
        var statusDescription: String {
            // Using times from CoT 4.0 Spec, Section 2.2.2.2
            let timeSince = Date().timeIntervalSince(lastUpdated)
            if timeSince <= 90 {
                return "Active"
            } else if timeSince <= 120 {
                return "Aging"
            } else {
                return "Stale"
            }
        }
        
        // Data store
        func saveToStorage() {
            Task { @MainActor in
                DroneStorageManager.shared.saveEncounter(self)
            }
        }
        
        var formattedAltitude: String? {
            if let altValue = Double(alt), altValue != 0 {
                return String(format: "%.1f m MSL", altValue)
            }
            return nil
        }
        
        var formattedHeight: String? {
            if let heightValue = Double(height ?? ""), heightValue != 0 {
                return String(format: "%.1f m AGL", heightValue)
            }
            return nil
        }
        
        var rawMessage: [String: Any]
        var originalRawString: String?
        
        static func == (lhs: CoTViewModel.CoTMessage, rhs: CoTViewModel.CoTMessage) -> Bool {
            return lhs.uid == rhs.uid &&
            lhs.caaRegistration == rhs.caaRegistration &&
            lhs.type == rhs.type &&
            lhs.lat == rhs.lat &&
            lhs.lon == rhs.lon &&
            lhs.speed == rhs.speed &&
            lhs.vspeed == rhs.vspeed &&
            lhs.alt == rhs.alt &&
            lhs.height == rhs.height &&
            lhs.pilotLat == rhs.pilotLat &&
            lhs.pilotLon == rhs.pilotLon &&
            lhs.description == rhs.description &&
            lhs.uaType == rhs.uaType &&
            lhs.idType == rhs.idType &&
            lhs.mac == rhs.mac &&
            lhs.rssi == rhs.rssi &&
            lhs.location_protocol == rhs.location_protocol &&
            lhs.op_status == rhs.op_status &&
            lhs.height_type == rhs.height_type &&
            lhs.speed_multiplier == rhs.speed_multiplier &&
            lhs.direction == rhs.direction &&
            lhs.vertical_accuracy == rhs.vertical_accuracy &&
            lhs.horizontal_accuracy == rhs.horizontal_accuracy &&
            lhs.baro_accuracy == rhs.baro_accuracy &&
            lhs.speed_accuracy == rhs.speed_accuracy &&
            lhs.timestamp == rhs.timestamp &&
            lhs.timestamp_accuracy == rhs.timestamp_accuracy &&
            lhs.operator_id == rhs.operator_id &&
            lhs.operator_id_type == rhs.operator_id_type &&
            lhs.aux_rssi == rhs.aux_rssi &&
            lhs.channel == rhs.channel &&
            lhs.phy == rhs.phy &&
            lhs.aa == rhs.aa &&
            lhs.adv_mode == rhs.adv_mode &&
            lhs.adv_mac == rhs.adv_mac &&
            lhs.did == rhs.did &&
            lhs.sid == rhs.sid &&
            lhs.type == rhs.type &&
            lhs.timeSpeed == rhs.timeSpeed &&
            lhs.status == rhs.status &&
            lhs.altPressure == rhs.altPressure &&
            lhs.heightType == rhs.heightType &&
            lhs.horizAcc == rhs.horizAcc &&
            lhs.vertAcc == rhs.vertAcc &&
            lhs.baroAcc == rhs.baroAcc &&
            lhs.speedAcc == rhs.speedAcc &&
            lhs.operatorAltGeo == rhs.operatorAltGeo &&
            lhs.areaCount == rhs.areaCount &&
            lhs.areaRadius == rhs.areaRadius &&
            lhs.areaCeiling == rhs.areaCeiling &&
            lhs.areaFloor == rhs.areaFloor &&
            lhs.classification == rhs.classification &&
            lhs.selfIdType == rhs.selfIdType &&
            lhs.selfIdId == rhs.selfIdId &&
            lhs.authType == rhs.authType &&
            lhs.authPage == rhs.authPage &&
            lhs.authLength == rhs.authLength &&
            lhs.authTimestamp == rhs.authTimestamp &&
            lhs.authData == rhs.authData &&
            lhs.isSpoofed == rhs.isSpoofed &&
            lhs.spoofingDetails?.isSpoofed == rhs.spoofingDetails?.isSpoofed &&
            lhs.spoofingDetails?.confidence == rhs.spoofingDetails?.confidence &&
            lhs.accessAddress == rhs.accessAddress &&
            lhs.mac == rhs.mac &&
            lhs.rssi == rhs.rssi &&
            lhs.lat == rhs.lat &&
            lhs.lon == rhs.lon &&
            lhs.speed == rhs.speed &&
            lhs.vspeed == rhs.vspeed &&
            lhs.alt == rhs.alt &&
            lhs.height == rhs.height &&
            lhs.op_status == rhs.op_status &&
            lhs.height_type == rhs.height_type &&
            lhs.direction == rhs.direction &&
            lhs.geodetic_altitude == rhs.geodetic_altitude &&
            lhs.fpvRSSI == rhs.fpvRSSI &&
            lhs.fpvSource == rhs.fpvSource &&
            lhs.fpvBandwidth == rhs.fpvBandwidth &&
            lhs.fpvFrequency == rhs.fpvFrequency &&
            lhs.fpvTimestamp == rhs.fpvTimestamp &&
            lhs.fpvStatus == rhs.fpvStatus &&
            lhs.fpvEstimatedDistance == rhs.fpvEstimatedDistance &&
            lhs.fpvSensorLat == rhs.fpvSensorLat &&
            lhs.fpvSensorLon == rhs.fpvSensorLon
        }
        
        var coordinate: CLLocationCoordinate2D? {
            guard let latDouble = Double(lat),
                  let lonDouble = Double(lon) else {
                print("Failed to convert lat: \(lat) or lon: \(lon) to Double")
                return nil
            }
            return CLLocationCoordinate2D(latitude: latDouble, longitude: lonDouble)
        }

        var droneMapKey: String { "\(uid)|\(lat)|\(lon)" }
        var homeMapKey: String { "\(uid)|H|\(homeLat)|\(homeLon)" }
        var pilotMapKey: String { "\(uid)|P|\(pilotLat)|\(pilotLon)" }
        
        func toDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "uid": self.uid,
                "id": self.id,
                "type": self.type,
                "lat": self.lat,
                "lon": self.lon,
                "latitude": self.lat,
                "longitude": self.lon,
                "speed": Double(self.speed) ?? 0.0,
                "vspeed": Double(self.vspeed) ?? 0.0,
                "alt": Double(self.alt) ?? 0.0,
                "pilotLat": self.pilotLat,
                "pilotLon": self.pilotLon,
                "description": self.description,
                "selfIDText": self.selfIDText,
                "uaType": self.uaType,
                "idType": self.idType,
                "isSpoofed": self.isSpoofed,
                "rssi": self.rssi ?? 0,
                "mac": self.mac ?? "",
                "manufacturer": self.manufacturer ?? "",
                "op_status": self.op_status ?? "",
                "ew_dir_segment": self.ew_dir_segment ?? "",
                "direction": self.direction ?? "",
                "geodetic_altitude": self.geodetic_altitude ?? 0.0,
                "fpvTimestamp": self.fpvTimestamp ?? Date().timeIntervalSince1970,
                "detection_source": self.fpvSource ?? "",
                "bandwidth": self.fpvBandwidth ?? 0.0,
                "signal_strength": self.fpvRSSI ?? 0
            ]
            
            // Include optional fields if they exist
            dict["id"] = self.id
            dict["uid"] = self.uid
            dict["height"] = self.height
            dict["protocolVersion"] = self.protocolVersion
            dict["geodetic_altitude"] = self.geodetic_altitude
            dict["mac"] = self.mac
            dict["rssi"] = self.rssi
            dict["rssi"] = self.rssi
            dict["manufacturer"] = self.manufacturer
            dict["op_status"] = self.op_status
            dict["direction"] = self.direction
            dict["ew_dir_segment"] = self.ew_dir_segment
            dict["location_protocol"] = self.location_protocol
            dict["op_status"] = self.op_status
            dict["height_type"] = self.height_type
            dict["direction"] = self.direction
            dict["time"] = self.time
            dict["start"] = self.start
            dict["stale"] = self.stale
            dict["how"] = self.how
            dict["ce"] = self.ce
            dict["le"] = self.le
            dict["hae"] = self.hae
            dict["aux_rssi"] = self.aux_rssi
            dict["channel"] = self.channel
            dict["phy"] = self.phy
            dict["aa"] = self.aa
            dict["adv_mode"] = self.adv_mode
            dict["adv_mac"] = self.adv_mac
            dict["operator_id"] = self.operator_id
            dict["classification_type"] = self.classification_type
            dict["area_radius"] = self.area_radius
            dict["area_ceiling"] = self.area_ceiling
            dict["area_floor"] = self.area_floor
            
            // Add FPV-specific fields
            dict["fpvStatus"] = self.fpvStatus
            dict["fpvEstimatedDistance"] = self.fpvEstimatedDistance
            dict["fpvSensorLat"] = self.fpvSensorLat
            dict["fpvSensorLon"] = self.fpvSensorLon

            // MARK: - droneid-go envelope passthrough
            for envelopeKey in ["Basic ID", "Location/Vector Message", "System Message",
                                "Self-ID Message", "Operator ID Message", "Auth Message",
                                "Frequency Message", "AUX_ADV_IND", "aext"] {
                if let v = self.rawMessage[envelopeKey] {
                    dict[envelopeKey] = v
                }
            }
            dict["transport"] = self.transport
            dict["basic_frequency_mhz"] = self.basicFrequencyMHz
            dict["frequency_message_mhz"] = self.frequencyMessageMHz

            return dict
        }
        

    }
    
    init(statusViewModel: StatusViewModel, spectrumViewModel: SpectrumData.SpectrumViewModel? = nil) {
        self.statusViewModel = statusViewModel
        self.spectrumViewModel = spectrumViewModel
        
        Task { @MainActor in
            self.cachedConnectionMode = Settings.shared.connectionMode
            self.cachedMulticastHost = Settings.shared.multicastHost
            self.cachedMulticastPort = UInt16(Settings.shared.multicastPort)
            self.cachedZmqHost = Settings.shared.zmqHost
            self.cachedZmqTelemetryPort = UInt16(Settings.shared.zmqTelemetryPort)
            self.cachedZmqStatusPort = UInt16(Settings.shared.zmqStatusPort)


            // Don't force isListening to false - preserve user's previous state
            self.cachedIsListening = Settings.shared.isListening
            self.isListeningCot = false
            
            BackgroundManager.shared.configure(with: self)

            self.checkPermissions()
            self.setupMQTTClient()
            self.setupTAKClient()
            self.setupLatticeClient()
            
            Task.detached {
                await MainActor.run {
                    SwiftDataStorageManager.shared.cleanupOldAircraftEncounters(maxAircraftCount: 200)
                }
            }
            
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self.setupADSBClient()
            
            self.restoreAlertRingsFromStorage()
            self.startInactivityCleanupTimer()
        }
        
        // Register for application lifecycle notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        // Also add observer for refreshing connections
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshConnections),
            name: Notification.Name("RefreshNetworkConnections"),
            object: nil
        )
        
        // Add observer for drone info updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDroneInfoUpdate(_:)),
            name: Notification.Name("DroneInfoUpdated"),
            object: nil
        )
        
        // Observe ADS-B configuration changes with debouncing to prevent rapid toggling issues
        NotificationCenter.default.publisher(for: .adsbSettingsChanged)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    if Settings.shared.adsbEnabled {
                        await self.setupADSBClient()
                    } else {
                        // Stop ADS-B client but KEEP existing aircraft detections in view
                        print("ADS-B disabled - stopping client but preserving \(self.aircraftTracks.count) aircraft tracks")
                        
                        self.adsbCancellables.removeAll()
                        self.adsbClient?.stop()
                        self.adsbClient = nil
                        
                        // DO NOT clear aircraftTracks - let them age out naturally
                        // DO NOT clear aircraft alert rings - let them remain visible
                        
                        print("ADS-B client stopped - \(self.aircraftTracks.count) aircraft tracks preserved, \(self.parsedMessages.count) drone detections preserved")
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        print("🧹 CoTViewModel deinit - final cleanup")
        
        // Invalidate all timers
        inactivityCleanupTimer?.invalidate()
        backgroundMaintenanceTimer?.invalidate()
        
        // Cancel all network connections (non-isolated)
        multicastGroup?.cancel()
        cotListener?.cancel()
        statusListener?.cancel()
        
        // Clean up external connections - capture locally to avoid self in Task
        let mqtt = mqttClient
        let tak = takClient
        let adsb = adsbClient
        
        // Disconnect on main actor without capturing self
        Task { @MainActor in
            mqtt?.disconnect()
            tak?.disconnect()
            adsb?.stop()
        }
        
        // Cancel all Combine subscriptions
        cancellables.removeAll()
        adsbCancellables.removeAll()
        
        // Remove all observers
        NotificationCenter.default.removeObserver(self)
        
        print("CoTViewModel cleanup completed")
    }
    
    nonisolated private func scheduleUIRefresh() {
        Task { @MainActor [weak self] in
            guard let self, !self.uiRefreshPending else { return }
            self.uiRefreshPending = true
            try? await Task.sleep(nanoseconds: UInt64(self.uiRefreshInterval * 1_000_000_000))
            self.uiRefreshPending = false
            self.objectWillChange.send()
        }
    }

    /// Update cached settings values - call this when settings change
    @MainActor
    private func updateCachedSettings() {
        cachedConnectionMode = Settings.shared.connectionMode
        cachedMulticastHost = Settings.shared.multicastHost
        cachedMulticastPort = UInt16(Settings.shared.multicastPort)
        cachedZmqHost = Settings.shared.zmqHost
        cachedZmqTelemetryPort = UInt16(Settings.shared.zmqTelemetryPort)
        cachedZmqStatusPort = UInt16(Settings.shared.zmqStatusPort)
        cachedIsListening = Settings.shared.isListening
    }
    
    
    @objc private func handleAppDidEnterBackground() {
        print("App entering background - ALWAYS continue monitoring")
        isInBackground = true
        
        // Pause UI-related timers (they consume battery and aren't needed in background)
        inactivityCleanupTimer?.invalidate()
        inactivityCleanupTimer = nil
        
        backgroundMaintenanceTimer?.invalidate()
        backgroundMaintenanceTimer = nil
        
        // Save current state before going to background
        Task { @MainActor in
            self.alertRings.removeAll()
            print("Cleared alert rings for background (will restore on foreground)")
            
            DroneStorageManager.shared.forceSave()
            SwiftDataStorageManager.shared.forceSave()
            
            print("Background monitoring - continuing detection")
            self.prepareForBackgroundExpiry()
        }
    }

    @objc private func handleAppWillEnterForeground() {
        print("App entering foreground - resuming")
        isInBackground = false
        
        Task { @MainActor in
            BackgroundManager.shared.endAllBackgroundTasks(stopKeepAlive: !Settings.shared.isListening)

            // Restart timers
            self.startInactivityCleanupTimer()
            
            // Restore alert rings
            self.restoreAlertRingsFromStorage()
            
            // Check if we need to reconnect
            if Settings.shared.isListening {
                // Only reconnect if we're not already connected
                if !self.isListeningCot {
                    print("Reconnecting after foreground transition...")
                    self.resumeFromBackground()
                } else {
                    print("Already connected, skipping reconnect")
                }
            } else {
                print("Not listening, skipping reconnect")
            }
            
            // Force UI refresh
            self.objectWillChange.send()
        }
    }
    
    @objc private func handleAppDidBecomeActive() {
        isInBackground = false
        Task { @MainActor in
            self.restoreAlertRingsFromStorage()
        }
    }

    @objc private func handleAppWillTerminate() {
        print("App terminating - cleaning up connections")
        
        BackgroundManager.shared.endAllBackgroundTasks()
        
        inactivityCleanupTimer?.invalidate()
        inactivityCleanupTimer = nil
        backgroundMaintenanceTimer?.invalidate()
        backgroundMaintenanceTimer = nil
        
        stopListening()
        
        cancellables.removeAll()
        adsbCancellables.removeAll()
        
        Task { @MainActor in
            self.mqttClient?.disconnect()
            self.takClient?.disconnect()
            self.adsbClient?.stop()
            self.latticeClient = nil
        }
        
        NotificationCenter.default.removeObserver(self)
        
        print("App termination cleanup completed")
    }
    
    @objc private func refreshConnections() {
        // Only refresh if we're actively listening
        if isListeningCot && !isReconnecting {
            // Briefly reconnect to keep connections alive
            performBackgroundRefresh()
        }
    }
    
    @objc private func handleDroneInfoUpdate(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let droneId = userInfo["droneId"] as? String else {
            return
        }
        
        // Find and update the message in parsedMessages
        Task { @MainActor in
            if let index = self.parsedMessages.firstIndex(where: { $0.uid == droneId }) {
                // Get fresh encounter data from storage
                if let encounter = DroneStorageManager.shared.fetchEncounter(id: droneId) {
                    let updatedMessage = self.parsedMessages[index]
                    
                    // Update the metadata from storage
                    let customName = encounter.customName
                    let trustStatus = encounter.trustStatus
                    
                    print("Updated drone info in parsedMessages: \(droneId) - Name: '\(customName)', Trust: \(trustStatus.rawValue)")
                    
                    self.parsedMessages[index] = updatedMessage
                }
            }
        }
    }
    
    private func performBackgroundRefresh() {
        // Quick reconnect to refresh connections
        if isListeningCot && !isReconnecting {
            isReconnecting = true
            
            // Brief reconnection to keep connections active
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                // Update cached settings on main thread
                Task { @MainActor in
                    self.updateCachedSettings()
                    
                    switch self.cachedConnectionMode {
                    case .multicast:
                        self.multicastGroup?.cancel()
                        self.multicastGroup = nil
                        self.startMulticastListening()
                    case .zmq:
                        self.zmqHandler?.disconnect()
                        self.zmqHandler = nil
                        self.startZMQListening()
                    }
                    
                    // Reset reconnecting flag
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.isReconnecting = false
                    }
                }
            }
        }
    }
    
    // MARK: - Inactivity Cleanup (matches Python DragonSync)
    
    /// Start timer to periodically clean up inactive detections
    /// Matches Python's inactivity_timeout behavior in manager.py
    @MainActor
    private func startInactivityCleanupTimer() {
        // Stop any existing timer
        inactivityCleanupTimer?.invalidate()
        
        // REDUCED: Run cleanup every 60 seconds instead of 10 to reduce background load
        // iOS will kill the app if we do too much work in background
        inactivityCleanupTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            // Only run cleanup if app is in foreground
            guard let self = self, !self.isInBackground else { return }
            Task { @MainActor in
                await self.cleanupInactiveDetections()
            }
        }
    }
    
    /// Clean up detections that haven't been updated within inactivityTimeout
    /// By default, only removes aircraft - drones are kept indefinitely for historical tracking
    @MainActor
    private func cleanupInactiveDetections() async {
        let now = Date()
        let timeout = Settings.shared.inactivityTimeout
        let persistDrones = Settings.shared.persistDroneDetections
        var removedUIDs: [String] = []
        
        // Find stale detections
        for message in parsedMessages {
            // If persistDroneDetections is enabled, only apply timeout to aircraft
            let isAircraft = message.uid.hasPrefix("aircraft-")
            if persistDrones && !isAircraft {
                continue // Skip drones, keep them indefinitely
            }
            
            let age = now.timeIntervalSince(message.lastUpdated)
            if age > timeout {
                removedUIDs.append(message.uid)
                
                // Publish MQTT offline status before removing (only for drones with MAC)
                if !isAircraft, let mac = message.mac, !mac.isEmpty, mqttClient != nil {
                    do {
                        try await mqttClient?.publishDroneOffline(mac)
                        print("Published offline status for \(message.uid)")
                    } catch {
                        print("Failed to publish offline status for \(message.uid): \(error)")
                    }
                }
                
                let type = isAircraft ? "aircraft" : "drone"
                print("Removing stale \(type): \(message.uid) (age: \(Int(age))s)")
            }
        }
        
        // Remove stale detections
        if !removedUIDs.isEmpty {
            parsedMessages.removeAll { removedUIDs.contains($0.uid) }
            print("Removed \(removedUIDs.count) inactive detections (timeout: \(timeout)s)")
        }
    }
    
    /// Enforce maximum detection limits (matches Python DragonSync max_drones behavior)
    /// When limit is exceeded, removes oldest detections (FIFO)
    /// Aggressively trim unbounded UI buffers when memory is tight in the
    /// background. Called by BackgroundManager.checkMemoryUsage before the
    /// jetsam threshold is crossed. Idempotent.
    @MainActor
    func trimDetectionBuffersForBackground() {
        let droneCap = 50
        let aircraftCap = 50
        let signatureCap = 100

        if parsedMessages.count > (droneCap + aircraftCap) {
            let sorted = parsedMessages.sorted { $0.lastUpdated > $1.lastUpdated }
            var drones: [CoTMessage] = []
            var aircraft: [CoTMessage] = []
            for m in sorted {
                if m.uid.hasPrefix("aircraft-") {
                    if aircraft.count < aircraftCap { aircraft.append(m) }
                } else {
                    if drones.count < droneCap { drones.append(m) }
                }
            }
            parsedMessages = drones + aircraft
        }

        if droneSignatures.count > signatureCap {
            droneSignatures = Array(droneSignatures.suffix(signatureCap))
        }

        if aircraftTracks.count > aircraftCap {
            aircraftTracks = Array(aircraftTracks.suffix(aircraftCap))
        }
    }

    @MainActor
    private func enforceDetectionLimits() {
        let maxDrones = Settings.shared.maxDrones
        let maxAircraft = Settings.shared.maxAircraft
        
        // Separate drones and aircraft
        let drones = parsedMessages.filter { !$0.uid.hasPrefix("aircraft-") && !$0.uid.hasPrefix("fpv-") }
        let aircraft = parsedMessages.filter { $0.uid.hasPrefix("aircraft-") }
        
        var removedUIDs: [String] = []
        
        // Enforce drone limit
        if drones.count > maxDrones {
            let excess = drones.count - maxDrones
            // Sort by last update time (oldest first) and remove oldest
            let sortedDrones = drones.sorted { 
                $0.lastUpdated < $1.lastUpdated
            }
            
            for i in 0..<excess {
                let drone = sortedDrones[i]
                removedUIDs.append(drone.uid)
                
                // Publish MQTT offline status
                if let mac = drone.mac, !mac.isEmpty, mqttClient != nil {
                    Task {
                        try? await mqttClient?.publishDroneOffline(mac)
                    }
                }
            }
            
            print("Drone limit exceeded (\(drones.count)/\(maxDrones)). Removing \(excess) oldest drones.")
        }
        
        // Enforce aircraft limit
        if aircraft.count > maxAircraft {
            let excess = aircraft.count - maxAircraft
            let sortedAircraft = aircraft.sorted {
                $0.lastUpdated < $1.lastUpdated
            }
            
            for i in 0..<excess {
                removedUIDs.append(sortedAircraft[i].uid)
            }
            
            print("Aircraft limit exceeded (\(aircraft.count)/\(maxAircraft)). Removing \(excess) oldest aircraft.")
        }
        
        // Remove excess detections
        if !removedUIDs.isEmpty {
            parsedMessages.removeAll { removedUIDs.contains($0.uid) }
        }
    }
    
    private func checkPermissions() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus != .authorized {
                self?.requestNotificationPermission()
            }
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            print("Notification permission granted: \(granted)")
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }
    
    func startListening() {
        // ATOMIC CHECK - Exit immediately if already in progress
        guard !isListeningCot && !isReconnecting && !isStarting else {
            print("Already listening (\(isListeningCot)), reconnecting (\(isReconnecting)), or starting (\(isStarting)) - skipping")
            return
        }
        
        // Mark as starting FIRST
        isStarting = true
        
        print("Settings: Toggle listening to true")
        print("Cleaning up existing connections before restart...")
        
        // FORCE CLEANUP - Cancel any existing connection synchronously
        if let existing = multicastGroup {
            existing.cancel()
            multicastGroup = nil
        }

        if let existing = cotListener {
            existing.cancel()
            cotListener = nil
        }
        
        if let existing = statusListener {
            existing.cancel()
            statusListener = nil
        }
        
        // Give the OS time to release the socket
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 0.15 seconds
            
            await MainActor.run {
                // Now actually start
                self.proceedWithStartListening()
                
                // Clear the starting flag AFTER everything is set up
                self.isStarting = false
                print("Listening started successfully, cleared reconnecting flag")
            }
        }
    }
    
    private func proceedWithStartListening() {
        isListeningCot = true
        
        // Setup background processing notification observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkConnections),
            name: Notification.Name("RefreshNetworkConnections"),
            object: nil
        )
        
        // Update cached settings before starting
        Task { @MainActor in
            self.updateCachedSettings()
            
            // Start the appropriate connection type
            switch self.cachedConnectionMode {
            case .multicast:
                self.startMulticastListening()
            case .zmq:
                self.startZMQListening()
            }
            
            if Settings.shared.enableBackgroundDetection {
                SilentAudioKeepAlive.shared.start()
            }

            if self.isInBackground && UIApplication.shared.applicationState == .background {
                print("Starting background processing (app is in background)")
                self.backgroundManager.startBackgroundProcessing()
            } else {
                print("Foreground listening started - background processing will start when app backgrounds")
            }
            
            // Clear reconnecting flag after a delay to ensure connection is established
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.isReconnecting = false
                print("Listening started successfully, cleared reconnecting flag")
            }
        }
    }
    
    @MainActor
    func ensureMulticastHealthy() {
        guard cachedConnectionMode == .multicast, Settings.shared.isListening else { return }
        guard multicastGroup == nil else { return }
        BackgroundDiagnostics.shared.log(.socket, "multicast group missing", "rebuilding")
        startMulticastListening()
    }

    @MainActor
    private func scheduleMulticastRecovery() {
        guard !multicastRecoveryScheduled else { return }
        multicastRecoveryScheduled = true
        let delay = min(30.0, pow(2.0, Double(multicastRecoveryAttempts)))
        multicastRecoveryAttempts += 1
        BackgroundDiagnostics.shared.log(.socket, "multicast recovery scheduled", "in \(Int(delay))s attempt=\(multicastRecoveryAttempts)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.multicastRecoveryScheduled = false
            guard Settings.shared.isListening, self.multicastGroup == nil else { return }
            self.startMulticastListening()
        }
    }

    private func startMulticastListening() {
        let host = NWEndpoint.Host(cachedMulticastHost)
        let port = NWEndpoint.Port(integerLiteral: cachedMulticastPort)

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        params.prohibitedInterfaceTypes = [.cellular]
        if let ipOpts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }

        do {
            let desc = try NWMulticastGroup(for: [.hostPort(host: host, port: port)])
            let group = NWConnectionGroup(with: desc, using: params)

            group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: true) { [weak self] _, data, _ in
                guard let self = self, let data = data, !data.isEmpty else { return }

                BackgroundDiagnostics.shared.recordPacket(.multicast)

                self.lastProcessTime = Date()
                self.processIncomingMessage(data)
            }

            group.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("Successfully joined multicast group \(self.cachedMulticastHost):\(self.cachedMulticastPort)")
                    BackgroundDiagnostics.shared.log(.socket, "multicast ready",
                                                     "\(self.cachedMulticastHost):\(self.cachedMulticastPort)")
                    DispatchQueue.main.async {
                        self.isListeningCot = true
                        self.multicastRecoveryAttempts = 0
                    }
                case .failed(let error):
                    print("Multicast group failed: \(error)")
                    BackgroundDiagnostics.shared.log(.socket, "multicast failed", String(describing: error))
                    DispatchQueue.main.async {
                        self.multicastGroup?.cancel()
                        self.multicastGroup = nil
                        self.isListeningCot = false
                        if Settings.shared.isListening {
                            self.scheduleMulticastRecovery()
                        }
                        let content = UNMutableNotificationContent()
                        content.title = "Connection Error"
                        content.body = "Multicast connection failed. Tap to reconnect."
                        content.sound = .default
                        let request = UNNotificationRequest(
                            identifier: "multicast-error",
                            content: content,
                            trigger: nil
                        )
                        UNUserNotificationCenter.current().add(request) { err in
                            if let err = err { print("Failed to show notification: \(err)") }
                        }
                    }
                case .waiting(let error):
                    print("Multicast group waiting: \(error)")
                    BackgroundDiagnostics.shared.log(.socket, "multicast waiting", String(describing: error))
                case .cancelled:
                    print("Multicast group cancelled")
                    BackgroundDiagnostics.shared.log(.socket, "multicast cancelled", "group torn down")
                    DispatchQueue.main.async { self.isListeningCot = false }
                default:
                    break
                }
            }

            multicastGroup = group
            group.start(queue: listenerQueue)
            print("Joining multicast group \(cachedMulticastHost):\(cachedMulticastPort)")
        } catch {
            print("Failed to create multicast group: \(error)")
            if let nwError = error as? NWError {
                print("NWError details: \(nwError)")
            }
        }
    }
    
    private func startZMQListening() {
        zmqHandler = ZMQHandler.shared

        let handler = zmqHandler
        let host = cachedZmqHost
        let telemetryPort = cachedZmqTelemetryPort
        let statusPort = cachedZmqStatusPort

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.performZMQConnect(handler, host, telemetryPort, statusPort)
        }
    }

    private func performZMQConnect(_ handler: ZMQHandler?,
                                   _ cachedZmqHost: String,
                                   _ cachedZmqTelemetryPort: UInt16,
                                   _ cachedZmqStatusPort: UInt16) {
        let zmqHandler = handler

        zmqHandler?.connect(
            host: cachedZmqHost,
            zmqTelemetryPort: cachedZmqTelemetryPort,
            zmqStatusPort: cachedZmqStatusPort,
            onTelemetry: { [weak self] message in
                // MARK: Check if this is raw FPV JSON
                if message.contains("AUX_ADV_IND") || message.contains("FPV Detection") {
                    print("FPV JSON received from ZMQ")
                    if let data = message.data(using: .utf8) {
                        self?.processFPVMessage(data)
                    }
                } else if let data = message.data(using: .utf8) {
                    self?.processIncomingMessage(data)
                }
            },
            onStatus: { [weak self] message in
                if let data = message.data(using: .utf8) {
                    // Parse status JSON directly and send to StatusViewModel
                    self?.processStatusJSON(data)
                    
                    // Auto-broadcast system status to TAK and MQTT (matches Python DragonSync behavior)
                    Task { @MainActor in
                        self?.publishSystemStatusToTAK()
                        self?.publishSystemStatusToMQTT()
                    }
                }
            }
        )
    }
    
    @MainActor
    private func isDeviceBlocked(_ message: CoTMessage) async -> Bool {
        let droneId = message.uid.hasPrefix("drone-") ? message.uid : "drone-\(message.uid)"
        let fpvID = message.uid.hasPrefix("fpv-") ? message.uid : "fpv-\(message.uid)"
        
        // Check both the original UID and the formatted drone ID
        let possibleIds = [
            message.uid,
            droneId,
            fpvID,
            message.uid.replacingOccurrences(of: "fpv-", with: ""),
            message.uid.replacingOccurrences(of: "drone-", with: "")
        ]
        
        // Check each possible ID format
        for id in possibleIds {
            if let encounter = DroneStorageManager.shared.fetchEncounter(id: id),
               encounter.metadata["doNotTrack"] == "true" {
                print("BLOCKED message with ID \(id) - marked as do not track")
                return true
            }
            
            // Also check the "drone-" and fpv- prefixed version
            let droneFormatId = id.hasPrefix("drone-") ? id : "drone-\(id)"
            if let encounter = DroneStorageManager.shared.fetchEncounter(id: droneFormatId),
               encounter.metadata["doNotTrack"] == "true" {
                print("BLOCKED message with drone ID \(droneFormatId) - marked as do not track")
                return true
            }
            let fpvFormatId = id.hasPrefix("fpv-") ? id : "fpv-\(id)"
            if let encounter = DroneStorageManager.shared.fetchEncounter(id: fpvID),
               encounter.metadata["doNotTrack"] == "true" {
                print(" BLOCKED message with drone ID \(fpvFormatId) - marked as do not track")
                return true
            }
        }
        
        return false
    }
    
    // MARK: - FPV Message Processing
    private func processFPVMessage(_ data: Data?) {
        guard let data = data,
              let fpvmessage = String(data: data, encoding: .utf8) else { return }
        
        print("DEBUG: FPV message data: \(fpvmessage)")
        
        do {
            // Try to parse as JSON array first (FPV Detection format or BT/WiFi arrays)
            if fpvmessage.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
                if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    for messageObj in jsonArray {
                        // Handle FPV Detection in array
                        if let fpvDetection = messageObj["FPV Detection"] as? [String: Any] {
                            let fpvMessage = createFPVDetectionMessage(fpvDetection)
                            Task { @MainActor in
                                await self.updateMessage(fpvMessage)
                                if Settings.shared.webhooksEnabled {
                                    self.sendFPVWebhookNotification(for: fpvMessage)
                                }
                            }
                        }
                        // Handle AUX_ADV_IND from BT/WiFi array
                        else if messageObj["AUX_ADV_IND"] != nil {
                            guard let fpvMessage = createAuxAdvIndMessage(messageObj) else { return }
                            Task { @MainActor in
                                // Check if this is an update message (no frequency)
                                if fpvMessage.uid.hasPrefix("fpv-UPDATE-") {
                                    // Extract source from UID
                                    let source = fpvMessage.fpvSource ?? ""
                                    
                                    // Find existing FPV detection with this source
                                    if let index = self.parsedMessages.firstIndex(where: { 
                                        $0.isFPVDetection && $0.fpvSource == source 
                                    }) {
                                        var existing = self.parsedMessages[index]
                                        existing.fpvRSSI = fpvMessage.fpvRSSI
                                        existing.rssi = fpvMessage.rssi
                                        existing.fpvTimestamp = fpvMessage.fpvTimestamp
                                        existing.lastUpdated = Date()
                                        existing.aa = fpvMessage.aa
                                        existing.adv_mac = fpvMessage.adv_mac
                                        
                                        if let newSource = fpvMessage.signalSources.first {
                                            existing.signalSources = [newSource]
                                        }
                                        
                                        self.parsedMessages[index] = existing
                                        self.updateAlertRing(for: existing)
                                        
                                        if Settings.shared.webhooksEnabled {
                                            self.sendFPVWebhookNotification(for: existing)
                                        }
                                        
                                        print("DEBUG: Updated existing FPV detection \(existing.uid) with new RSSI: \(fpvMessage.fpvRSSI ?? 0)")
                                    } else {
                                        print("DEBUG: No existing FPV detection found for update (source: \(source))")
                                    }
                                } else {
                                    // Regular FPV message with frequency
                                    await self.updateMessage(fpvMessage)
                                    if Settings.shared.webhooksEnabled {
                                        self.sendFPVWebhookNotification(for: fpvMessage)
                                    }
                                }
                            }
                        }
                        // Handle direct frequency field (from ZMQ decoded messages)
                        else if messageObj["frequency"] != nil &&
                               (messageObj["rssi"] != nil || messageObj["AUX_ADV_IND"] != nil) {
                            guard let fpvMessage = createAuxAdvIndMessage(messageObj) else { return }
                            Task { @MainActor in
                                // Check if this is an update message (no frequency)
                                if fpvMessage.uid.hasPrefix("fpv-UPDATE-") {
                                    // Extract source from UID
                                    let source = fpvMessage.fpvSource ?? ""
                                    
                                    // Find existing FPV detection with this source
                                    if let index = self.parsedMessages.firstIndex(where: { 
                                        $0.isFPVDetection && $0.fpvSource == source 
                                    }) {
                                        var existing = self.parsedMessages[index]
                                        existing.fpvRSSI = fpvMessage.fpvRSSI
                                        existing.rssi = fpvMessage.rssi
                                        existing.fpvTimestamp = fpvMessage.fpvTimestamp
                                        existing.lastUpdated = Date()
                                        existing.aa = fpvMessage.aa
                                        existing.adv_mac = fpvMessage.adv_mac
                                        
                                        if let newSource = fpvMessage.signalSources.first {
                                            existing.signalSources = [newSource]
                                        }
                                        
                                        self.parsedMessages[index] = existing
                                        self.updateAlertRing(for: existing)
                                        
                                        if Settings.shared.webhooksEnabled {
                                            self.sendFPVWebhookNotification(for: existing)
                                        }
                                        
                                        print("DEBUG: Updated existing FPV detection \(existing.uid) with new RSSI: \(fpvMessage.fpvRSSI ?? 0)")
                                    } else {
                                        print("DEBUG: No existing FPV detection found for update (source: \(source))")
                                    }
                                } else {
                                    // Regular FPV message with frequency
                                    await self.updateMessage(fpvMessage)
                                    if Settings.shared.webhooksEnabled {
                                        self.sendFPVWebhookNotification(for: fpvMessage)
                                    }
                                }
                            }
                        }
                    }
                    return
                }
            }
            
            // Try to parse as single JSON object
            if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Handle single FPV Detection object
                if let fpvDetection = jsonObject["FPV Detection"] as? [String: Any] {
                    let fpvMessage = createFPVDetectionMessage(fpvDetection)
                    Task { @MainActor in
                        await self.updateMessage(fpvMessage)
                        if Settings.shared.webhooksEnabled {
                            self.sendFPVWebhookNotification(for: fpvMessage)
                        }
                    }
                }
                // Handle AUX_ADV_IND update message (from BT/WiFi)
                else if jsonObject["AUX_ADV_IND"] != nil {
                    guard let fpvMessage = createAuxAdvIndMessage(jsonObject) else { return }
                    Task { @MainActor in
                        // Check if this is an update message (no frequency)
                        if fpvMessage.uid.hasPrefix("fpv-UPDATE-") {
                            // Extract source from UID
                            let source = fpvMessage.fpvSource ?? ""
                            
                            // Find existing FPV detection with this source
                            if let index = self.parsedMessages.firstIndex(where: { 
                                $0.isFPVDetection && $0.fpvSource == source 
                            }) {
                                var existing = self.parsedMessages[index]
                                existing.fpvRSSI = fpvMessage.fpvRSSI
                                existing.rssi = fpvMessage.rssi
                                existing.fpvTimestamp = fpvMessage.fpvTimestamp
                                existing.lastUpdated = Date()
                                existing.aa = fpvMessage.aa
                                existing.adv_mac = fpvMessage.adv_mac
                                
                                if let newSource = fpvMessage.signalSources.first {
                                    existing.signalSources = [newSource]
                                }
                                
                                self.parsedMessages[index] = existing
                                self.updateAlertRing(for: existing)
                                
                                if Settings.shared.webhooksEnabled {
                                    self.sendFPVWebhookNotification(for: existing)
                                }
                                
                                print("DEBUG: Updated existing FPV detection \(existing.uid) with new RSSI: \(fpvMessage.fpvRSSI ?? 0)")
                            } else {
                                print("DEBUG: No existing FPV detection found for update (source: \(source))")
                            }
                        } else {
                            // Regular FPV message with frequency
                            await self.updateMessage(fpvMessage)
                            if Settings.shared.webhooksEnabled {
                                self.sendFPVWebhookNotification(for: fpvMessage)
                            }
                        }
                    }
                }
                // Handle direct frequency-based messages (from ZMQ decoded BT/WiFi)
                else if jsonObject["frequency"] != nil &&
                       (jsonObject["rssi"] != nil ||
                        jsonObject["signal_strength"] != nil ||
                        jsonObject["AUX_ADV_IND"] != nil) {
                    guard let fpvMessage = createAuxAdvIndMessage(jsonObject) else { return }
                    Task { @MainActor in
                        // Check if this is an update message (no frequency)
                        if fpvMessage.uid.hasPrefix("fpv-UPDATE-") {
                            // Extract source from UID
                            let source = fpvMessage.fpvSource ?? ""
                            
                            // Find existing FPV detection with this source
                            if let index = self.parsedMessages.firstIndex(where: { 
                                $0.isFPVDetection && $0.fpvSource == source 
                            }) {
                                var existing = self.parsedMessages[index]
                                existing.fpvRSSI = fpvMessage.fpvRSSI
                                existing.rssi = fpvMessage.rssi
                                existing.fpvTimestamp = fpvMessage.fpvTimestamp
                                existing.lastUpdated = Date()
                                existing.aa = fpvMessage.aa
                                existing.adv_mac = fpvMessage.adv_mac
                                
                                if let newSource = fpvMessage.signalSources.first {
                                    existing.signalSources = [newSource]
                                }
                                
                                self.parsedMessages[index] = existing
                                self.updateAlertRing(for: existing)
                                
                                if Settings.shared.webhooksEnabled {
                                    self.sendFPVWebhookNotification(for: existing)
                                }
                                
                                print("DEBUG: Updated existing FPV detection \(existing.uid) with new RSSI: \(fpvMessage.fpvRSSI ?? 0)")
                            } else {
                                print("DEBUG: No existing FPV detection found for update (source: \(source))")
                            }
                        } else {
                            // Regular FPV message with frequency
                            await self.updateMessage(fpvMessage)
                            if Settings.shared.webhooksEnabled {
                                self.sendFPVWebhookNotification(for: fpvMessage)
                            }
                        }
                    }
                }
            }
        } catch {
            print("DEBUG: Failed to parse FPV JSON: \(error)")
        }
    }

    private func createFPVDetectionMessage(_ fpvData: [String: Any]) -> CoTMessage {
        let timestamp = fpvData["timestamp"] as? String ?? ""
        let manufacturer = fpvData["manufacturer"] as? String ?? ""
        
        // Parse device type - handle both "device_type" and "model" field names
        let deviceType: String
        if let type = fpvData["device_type"] as? String {
            deviceType = type
        } else if let model = fpvData["model"] as? String {
            deviceType = model
        } else {
            deviceType = ""
        }
        
        // Parse frequency - handle both Int and Double, and both Hz and MHz units
        // Try multiple field names: "frequency", "frequency_mhz", "freq"
        var frequencyHz: Double = 0.0
        
        // First try "frequency" field (from fpv_mdn_receiver)
        if let freqDouble = fpvData["frequency"] as? Double {
            // Determine if it's MHz or Hz based on magnitude
            // fpv_mdn_receiver: 5785000000 (Hz) - very large
            // fpv_receive: might use this for Hz values
            frequencyHz = freqDouble > 100000 ? freqDouble : freqDouble * 1_000_000
        } else if let freqInt = fpvData["frequency"] as? Int {
            let freqDouble = Double(freqInt)
            frequencyHz = freqDouble > 100000 ? freqDouble : freqDouble * 1_000_000
        }
        // Try "frequency_mhz" field (from fpv_receive/AntSDR)
        else if let freqMhz = fpvData["frequency_mhz"] as? Double {
            // Already in MHz, convert to Hz
            frequencyHz = freqMhz * 1_000_000
        }
        // Try "freq" field (alternative naming)
        else if let freq = fpvData["freq"] as? Double {
            frequencyHz = freq > 100000 ? freq : freq * 1_000_000
        } else if let freqInt = fpvData["freq"] as? Int {
            let freqDouble = Double(freqInt)
            frequencyHz = freqDouble > 100000 ? freqDouble : freqDouble * 1_000_000
        }
        
        // Convert to MHz for display/storage (CoTMessage.fpvFrequency is Int, stores MHz)
        let frequencyMHz = Int(frequencyHz / 1_000_000)
        
        let bandwidth = fpvData["bandwidth"] as? String ?? ""
        
        // Parse signal strength - handle both field names
        // fpv_receive uses "signal_strength_dbm", fpv_mdn_receiver uses "signal_strength"
        let signalStrength: Double
        if let strength = fpvData["signal_strength"] as? Double {
            signalStrength = strength
        } else if let strengthDbm = fpvData["signal_strength_dbm"] as? Double {
            signalStrength = strengthDbm
        } else if let strengthInt = fpvData["signal_strength"] as? Int {
            signalStrength = Double(strengthInt)
        } else if let strengthDbmInt = fpvData["signal_strength_dbm"] as? Int {
            signalStrength = Double(strengthDbmInt)
        } else {
            signalStrength = 0.0
        }
        
        let detectionSource = fpvData["detection_source"] as? String ?? ""
        
        let fpvId = "fpv-\(detectionSource)-\(frequencyMHz)"
        
        // Create the CoTMessage with FPV data
        var message = CoTMessage(
            uid: fpvId,
            type: "a-f-A-M-F-R", // FPV detection type
            lat: "0.0", // FPV doesn't have location
            lon: "0.0",
            homeLat: "0.0",
            homeLon: "0.0",
            speed: "0.0",
            vspeed: "0.0",
            alt: "0.0",
            pilotLat: "0.0",
            pilotLon: "0.0",
            description: "FPV Detection: \(deviceType)",
            selfIDText: "FPV \(frequencyMHz)MHz \(bandwidth)",
            uaType: .helicopter, // Default for FPV
            idType: "FPV Detection",
            rawMessage: fpvData
        )
        
        // Populate FPV-specific variables
        message.fpvTimestamp = timestamp
        message.fpvSource = detectionSource
        message.fpvFrequency = frequencyMHz
        message.fpvBandwidth = bandwidth
        message.fpvRSSI = signalStrength
        message.manufacturer = manufacturer
        message.rssi = Int(signalStrength)
        
        // Populate additional FPV fields from fpv_mdn_receiver
        if let status = fpvData["status"] as? String {
            message.fpvStatus = status
        }
        
        if let estimatedDistance = fpvData["estimated_distance"] as? Double {
            message.fpvEstimatedDistance = estimatedDistance
        }
        
        if let sensorLat = fpvData["sensor_lat"] as? Double {
            message.fpvSensorLat = sensorLat
        }
        
        if let sensorLon = fpvData["sensor_lon"] as? Double {
            message.fpvSensorLon = sensorLon
        }
        
        // Set additional metadata
        message.time = formatCurrentTimeForCoT()
        message.start = message.time
        message.stale = formatStaleTimeForCoT()
        
        // Add signal source for FPV
        if let source = SignalSource(mac: detectionSource, rssi: Int(signalStrength), type: .fpv, timestamp: Date()) {
            message.signalSources = [source]
        }
        
        return message
    }

    private func createAuxAdvIndMessage(_ jsonObject: [String: Any]) -> CoTMessage? {
        guard let auxAdvInd = jsonObject["AUX_ADV_IND"] as? [String: Any],
              let aext = jsonObject["aext"] as? [String: Any] else {
            print("DEBUG: Invalid AUX_ADV_IND format")
            return nil
        }
        
        let rssi = auxAdvInd["rssi"] as? Double ?? 0.0
        let timestamp = auxAdvInd["time"] as? String ?? ""
        let aa = auxAdvInd["aa"] as? Int ?? 0
        let advA = (aext["AdvA"] as? String ?? "").replacingOccurrences(of: " random", with: "").replacingOccurrences(of: " ", with: "-")
        
        // Parse frequency - handle both Int and Double, and both Hz and MHz units
        var frequencyHz: Double = 0.0
        if let freqDouble = jsonObject["frequency"] as? Double {
            // fpv_mdn_receiver update: might be in Hz or MHz
            frequencyHz = freqDouble > 100000 ? freqDouble : freqDouble * 1_000_000
        } else if let freqInt = jsonObject["frequency"] as? Int {
            let freqDouble = Double(freqInt)
            frequencyHz = freqDouble > 100000 ? freqDouble : freqDouble * 1_000_000
        }
        
        // Convert to MHz for storage
        let frequencyMHz = Int(frequencyHz / 1_000_000)
        
        let detectionSource = advA
        
        // BUGFIX: If frequency is missing (0), this is an UPDATE message
        // Return a special marker object with just the update fields
        // The caller will handle finding and updating the existing detection
        if frequencyMHz == 0 {
            print("DEBUG: AUX_ADV_IND update (no frequency) for \(detectionSource)")
            // Create a minimal message with update-only fields
            var updateMessage = CoTMessage(
                uid: "fpv-UPDATE-\(detectionSource)", // Special marker UID
                type: "a-f-A-M-F-R",
                lat: "0.0", lon: "0.0", homeLat: "0.0", homeLon: "0.0",
                speed: "0.0", vspeed: "0.0", alt: "0.0",
                pilotLat: "0.0", pilotLon: "0.0",
                description: "FPV Update",
                selfIDText: "",
                uaType: .helicopter,
                idType: "FPV Update",
                rawMessage: jsonObject
            )
            updateMessage.fpvSource = detectionSource
            updateMessage.fpvRSSI = rssi
            updateMessage.rssi = Int(rssi)
            updateMessage.fpvTimestamp = timestamp
            updateMessage.aa = aa
            updateMessage.adv_mac = advA
            
            return updateMessage
        }
        
        let fpvId = "fpv-\(detectionSource)-\(frequencyMHz)"
        
        // Create the CoTMessage with AUX_ADV_IND data
        var message = CoTMessage(
            uid: fpvId,
            type: "a-f-A-M-F-R", // FPV update type
            lat: "0.0", // FPV doesn't have location
            lon: "0.0",
            homeLat: "0.0",
            homeLon: "0.0",
            speed: "0.0",
            vspeed: "0.0",
            alt: "0.0",
            pilotLat: "0.0",
            pilotLon: "0.0",
            description: "FPV Update: \(detectionSource)",
            selfIDText: "FPV \(frequencyMHz)MHz Update",
            uaType: .helicopter,
            idType: "FPV Update",
            rawMessage: jsonObject
        )
        
        // Populate FPV-specific variables
        message.fpvTimestamp = timestamp
        message.fpvSource = detectionSource
        message.fpvFrequency = frequencyMHz  // Use converted MHz value
        message.fpvBandwidth = "" // Not provided in AUX_ADV_IND
        message.fpvRSSI = rssi
        message.rssi = Int(rssi)
        
        // Set BT/WiFi transmission fields from the AUX_ADV_IND message
        message.aa = aa
        message.adv_mac = advA
        
        // Set additional metadata
        message.time = formatCurrentTimeForCoT()
        message.start = message.time
        message.stale = formatStaleTimeForCoT()
        message.how = "m-g"
        message.ce = "35.0"
        message.le = "999999"
        message.hae = "0.0"
        
        // Add signal source for FPV update
        if let source = SignalSource(mac: detectionSource, rssi: Int(rssi), type: .fpv, timestamp: Date()) {
            message.signalSources = [source]
        }
        
        return message
    }

    @MainActor
    private func updateFPVMessage(_ updatedMessage: CoTMessage) async {
        let possibleUIDs = [
            updatedMessage.uid,
            "drone-\(updatedMessage.uid)"
        ]
        
        var existingIndex: Int?
        for uid in possibleUIDs {
            if let index = self.parsedMessages.firstIndex(where: { $0.uid == uid }) {
                existingIndex = index
                break
            }
        }
        
        guard let index = existingIndex else {
            return
        }
        
        var existingMessage = self.parsedMessages[index]
        existingMessage.fpvRSSI = updatedMessage.fpvRSSI
        existingMessage.rssi = updatedMessage.rssi
        existingMessage.fpvTimestamp = updatedMessage.fpvTimestamp
        existingMessage.lastUpdated = Date()
        
        if let newSource = updatedMessage.signalSources.first {
            existingMessage.signalSources = [newSource]
        }
        
        existingMessage.aa = updatedMessage.aa
        existingMessage.adv_mac = updatedMessage.adv_mac
        
        if Settings.shared.webhooksEnabled {
            self.sendFPVWebhookNotification(for: existingMessage)
        }
        
        self.parsedMessages[index] = existingMessage
        self.updateAlertRing(for: existingMessage)
    }

    private func formatCurrentTimeForCoT() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    private func formatStaleTimeForCoT() -> String {
        guard let staleTime = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) else {
            // Fallback to 5 minutes from now manually
            let fallbackDate = Date(timeIntervalSinceNow: 300)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: fallbackDate)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: staleTime)
    }
    
    func restoreAlertRingsFromStorage() {
        guard !isInBackground else {
            print("⚠️ Skipping alert ring restoration while in background")
            return
        }
        
        guard UIApplication.shared.applicationState == .active else {
            print("⚠️ Skipping alert ring restoration - app not active")
            return
        }
        
        Task { @MainActor in
            print("Restoring alert rings from storage...")
            
            // Clear existing alert rings
            alertRings.removeAll()
            
            // Lightweight fetch: relationships are only faulted for the few
            // encounters that actually carry proximity points.
            let allEncounters = SwiftDataStorageManager.shared.fetchAllEncountersLightweight()
                .filter { $0.metadata["hasProximityPoints"] == "true" }

            // Restore alert rings for FPV and encrypted signals from storage
            for encounter in allEncounters {
                let droneId = encounter.id
                
                // Get all proximity points with RSSI data
                let proximityPoints = encounter.flightPath.filter {
                    $0.isProximityPoint && $0.proximityRssi != nil && $0.proximityRssi ?? 0 > 0
                }
                
                guard !proximityPoints.isEmpty else { continue }
                
                // For FPV detections, show highest, lowest, and median RSSI
                var ringsToAdd: [AlertRing] = []
                
                if encounter.metadata["isFPVDetection"] == "true" || droneId.hasPrefix("fpv-") {
                    // Sort proximity points by RSSI
                    let sortedPoints = proximityPoints.sorted {
                        ($0.proximityRssi ?? 0) < ($1.proximityRssi ?? 0)
                    }
                    
                    // Get lowest RSSI (weakest signal)
                    if let lowestPoint = sortedPoints.first,
                       let lowestRssi = lowestPoint.proximityRssi {
                        let radius = calculateRadiusForPoint(lowestPoint, isFPV: true)
                        ringsToAdd.append(AlertRing(
                            droneId: "\(droneId)-lowest",
                            centerCoordinate: CLLocationCoordinate2D(
                                latitude: lowestPoint.latitude,
                                longitude: lowestPoint.longitude
                            ),
                            radius: radius,
                            rssi: Int(lowestRssi)
                        ))
                    }
                    
                    // Get highest RSSI (strongest signal)
                    if sortedPoints.count > 1, 
                       let highestPoint = sortedPoints.last,
                       let highestRssi = highestPoint.proximityRssi {
                        let radius = calculateRadiusForPoint(highestPoint, isFPV: true)
                        ringsToAdd.append(AlertRing(
                            droneId: "\(droneId)-highest",
                            centerCoordinate: CLLocationCoordinate2D(
                                latitude: highestPoint.latitude,
                                longitude: highestPoint.longitude
                            ),
                            radius: radius,
                            rssi: Int(highestRssi)
                        ))
                    }
                    
                    // Get median RSSI (middle signal)
                    if sortedPoints.count > 2 {
                        let medianIndex = sortedPoints.count / 2
                        let medianPoint = sortedPoints[medianIndex]
                        if let medianRssi = medianPoint.proximityRssi {
                            let radius = calculateRadiusForPoint(medianPoint, isFPV: true)
                            ringsToAdd.append(AlertRing(
                                droneId: "\(droneId)-median",
                                centerCoordinate: CLLocationCoordinate2D(
                                    latitude: medianPoint.latitude,
                                    longitude: medianPoint.longitude
                                ),
                                radius: radius,
                                rssi: Int(medianRssi)
                            ))
                        }
                    }
                    
                    print("FPV Detection \(droneId): Found \(proximityPoints.count) detections, showing \(ringsToAdd.count) rings (highest/lowest/median)")
                    
                } else {
                    // For regular drones, show up to 3 most recent proximity points
                    let recentPoints = Array(proximityPoints.suffix(3))
                    
                    for point in recentPoints {
                        guard let pointRssi = point.proximityRssi else { continue }
                        let radius = calculateRadiusForPoint(point, isFPV: false)
                        ringsToAdd.append(AlertRing(
                            droneId: droneId,
                            centerCoordinate: CLLocationCoordinate2D(
                                latitude: point.latitude,
                                longitude: point.longitude
                            ),
                            radius: radius,
                            rssi: Int(pointRssi)
                        ))
                    }
                }
                
                // Add rings to the collection
                for ring in ringsToAdd {
                    alertRings.append(ring)
                    print("Restored alert ring for \(ring.droneId): radius \(Int(ring.radius))m, RSSI: \(ring.rssi)")
                }
            }
            
            print("Restored \(alertRings.count) alert rings from storage")
        }
    }

    // MARK: - Helper function to calculate radius for a proximity point
    private func calculateRadiusForPoint(_ point: FlightPathPoint, isFPV: Bool) -> Double {
        var radius: Double
        
        // Use stored radius if available
        if let storedRadius = point.proximityRadius, storedRadius > 0 {
            radius = storedRadius
        } else {
            // Calculate radius from RSSI based on detection type
            let rssi = point.proximityRssi ?? 0
            
            if isFPV {
                // FPV 5.8GHz detection range based on actual capabilities
                // RSSI values from RX5808 module: 1100 (weak) to 3500 (very strong)
                // Detection range realistic for 5.8GHz: 10m to 500m max
                let minRssi = 1100.0  // Weakest detectable signal
                let maxRssi = 1800.0  // Strong signal (adjusted for realistic range)
                
                if rssi <= minRssi {
                    radius = 500.0  // Maximum detection range for 5.8GHz
                } else if rssi >= maxRssi {
                    radius = 10.0   // Very close range for strong signal
                } else {
                    // Logarithmic scale for more realistic distance mapping
                    let normalizedRssi = (rssi - minRssi) / (maxRssi - minRssi)
                    // Use exponential decay for distance
                    radius = 500.0 * exp(-3.0 * normalizedRssi)
                }
                
                // Debug log for FPV calculations
                print("FPV RSSI \(Int(rssi)) -> radius \(Int(radius))m")
                
            } else {
                // Standard drone RSSI calculation (negative dBm values)
                radius = DroneSignatureGenerator().calculateDistance(rssi)
            }
        }
        
        // Ensure minimum radius
        radius = max(radius, 10.0)
        
        // Cap at realistic maximum for 5.8GHz
        radius = min(radius, 500.0)
        
        return radius
    }
    // MARK: - FPV Webhook Integration
    private func sendFPVWebhookNotification(for message: CoTMessage) {
        let event: WebhookEvent = .fpvSignal
        
        // Build data payload
        var data: [String: Any] = [
            "uid": message.uid,
            "timestamp": message.fpvTimestamp ?? Date().timeIntervalSince1970
        ]
        
        if let frequency = message.fpvFrequency {
            data["frequency"] = frequency
        }
        
        if let rssi = message.fpvRSSI {
            data["signal_strength"] = rssi
        }
        
        if let bandwidth = message.fpvBandwidth {
            data["bandwidth"] = bandwidth
        }
        
        // Build metadata
        var metadata: [String: String] = [:]
        
        if let source = message.fpvSource {
            metadata["detection_source"] = source
        }
        
        if let manufacturer = message.manufacturer {
            metadata["manufacturer"] = manufacturer
        }
        
        metadata["detection_type"] = "FPV"
        metadata["id_type"] = message.idType
        
        // Send webhook
        WebhookManager.shared.sendWebhook(event: event, data: data, metadata: metadata)
    }
    
    private func processIncomingMessage(_ data: Data) {
        guard let message = String(data: data, encoding: .utf8) else { return }
        
        if BackgroundDiagnostics.isEnabled { print("DEBUG: incoming message: \(message)") }
        
        // MARK: Check for FPV messages FIRST - Parse JSON to verify structure
        // Check for single object with AUX_ADV_IND (FPV update format)
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if jsonObject["AUX_ADV_IND"] != nil {
                print("DEBUG: AUX_ADV_IND format detected, routing to FPV processor")
                processFPVMessage(data)
                return
            }
        }
        
        // Check for array with FPV Detection (initial FPV detection format)
        if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = jsonArray.first,
           first["FPV Detection"] != nil {
            print("DEBUG: FPV Detection array format detected, routing to FPV processor")
            processFPVMessage(data)
            return
        }

        // Incoming Message (JSON/XML) - Determine type and convert if needed gi
        let xmlData: Data
        if message.trimmingCharacters(in: .whitespacesAndNewlines).starts(with: "{") {
            // Handle JSON input
            if message.contains("system_stats") {
                // Status JSON
                guard let statusXML = self.messageConverter.convertStatusToXML(message),
                      let convertedData = statusXML.data(using: String.Encoding.utf8) else {
                    print("ERROR: Failed to convert status JSON to XML")
                    return
                }
                xmlData = convertedData
            } else if let jsonData = message.data(using: .utf8),
                      let parsedJson = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      parsedJson["Basic ID"] != nil {
                // Drone JSON
                print("DEBUG: Detected drone JSON with Basic ID, converting to XML...")
                guard let droneXML = self.messageConverter.convertTelemetryToXML(message) else {
                    print("ERROR: convertTelemetryToXML returned nil")
                    return
                }
                guard let convertedData = droneXML.data(using: String.Encoding.utf8) else {
                    print("ERROR: Failed to convert XML string to data")
                    return
                }
                print("DEBUG: Successfully converted JSON to XML")
                xmlData = convertedData
            } else {
                print("ERROR: Unrecognized JSON format - no 'Basic ID' or 'system_stats' found")
                return
            }
        } else {
            // Already XML
            xmlData = data
        }
        
        // Parse XML and create appropriate message
        let parser = CoTMessageParser()
        parser.originalRawString = message
        let xmlParser = XMLParser(data: xmlData)
        xmlParser.delegate = parser
        
        guard xmlParser.parse() else {
            print("Failed to parse XML: \(xmlData)")
            return
        }
        
        // Update UI with appropriate message type
        Task { @MainActor in
            if message.contains("<remarks>CPU Usage:"),
               let statusMessage = parser.statusMessage {
                // Status message path
                self.updateStatusMessage(statusMessage)
            } else if let cotMessage = parser.cotMessage {
                // Drone message path
                await self.updateMessage(cotMessage)
            }
        }
    }
    
    private func receiveMessages(from connection: NWConnection, isZMQ: Bool = false) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Error receiving data: \(error.localizedDescription)")
                if !isComplete && (isZMQ ? self.zmqHandler?.isConnected == true : self.isListeningCot) {
                    self.receiveMessages(from: connection, isZMQ: isZMQ)
                }
                return
            }
            
            guard let data = data, !data.isEmpty else {
                if !isComplete && (isZMQ ? self.zmqHandler?.isConnected == true : self.isListeningCot) {
                    self.receiveMessages(from: connection, isZMQ: isZMQ)
                }
                return
            }
            
            self.lastProcessTime = Date()
            self.processIncomingMessage(data)

            if !isComplete && (isZMQ ? self.zmqHandler?.isConnected == true : self.isListeningCot) {
                self.receiveMessages(from: connection, isZMQ: isZMQ)
            }
        }
    }

    private func updateStatusMessage(_ message: StatusViewModel.StatusMessage) {
        DispatchQueue.main.async {
            self.statusViewModel.updateExistingStatusMessage(message)
        }
    }
    
    /// Process status JSON directly (from ZMQ status port)
    /// This bypasses XML conversion and sends status directly to StatusViewModel
    private func processStatusJSON(_ data: Data) {
        guard let jsonString = String(data: data, encoding: .utf8),
              let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("ERROR: Failed to parse status JSON")
            return
        }
        
        // Extract status data from JSON
        // Python DragonSync sends serial_number (not uid) - use it for both
        guard let serialNumber = json["serial_number"] as? String,
              let timestamp = json["timestamp"] as? Double,
              let gpsData = json["gps_data"] as? [String: Any],
              let systemStats = json["system_stats"] as? [String: Any],
              let antStats = json["ant_sdr_temps"] as? [String: Any] else {
            print("ERROR: Missing required fields in status JSON")
            print("  Available keys: \(json.keys.joined(separator: ", "))")
            return
        }
        
        // Use serial_number as uid for compatibility
        let uid = serialNumber
        
        // Parse GPS data
        // Handle both Double values and "N/A" strings from Python
        let latitude = gpsData["latitude"] as? Double ?? 0.0
        let longitude = gpsData["longitude"] as? Double ?? 0.0
        
        // Altitude and speed can be "N/A" strings from Python
        let altitude: Double = {
            if let doubleVal = gpsData["altitude"] as? Double {
                return doubleVal
            } else if let strVal = gpsData["altitude"] as? String, strVal != "N/A" {
                return Double(strVal) ?? 0.0
            }
            return 0.0
        }()
        
        let speed: Double = {
            if let doubleVal = gpsData["speed"] as? Double {
                return doubleVal
            } else if let strVal = gpsData["speed"] as? String, strVal != "N/A" {
                return Double(strVal) ?? 0.0
            }
            return 0.0
        }()
        
        let gps = StatusViewModel.StatusMessage.GPSData(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            speed: speed
        )
        
        // Parse system stats
        let cpuUsage = systemStats["cpu_usage"] as? Double ?? 0.0
        
        // Temperature can be "N/A" string from Python
        let temperature: Double = {
            if let doubleVal = systemStats["temperature"] as? Double {
                return doubleVal
            } else if let strVal = systemStats["temperature"] as? String, strVal != "N/A" {
                return Double(strVal) ?? 0.0
            }
            return 0.0
        }()
        
        let uptime = systemStats["uptime"] as? Double ?? 0.0
        
        // Parse memory stats
        guard let memoryData = systemStats["memory"] as? [String: Any] else {
            print("ERROR: Missing memory data in status JSON")
            return
        }
        
        let memory = StatusViewModel.StatusMessage.SystemStats.MemoryStats(
            total: memoryData["total"] as? Int64 ?? 0,
            available: memoryData["available"] as? Int64 ?? 0,
            percent: memoryData["percent"] as? Double ?? 0.0,
            used: memoryData["used"] as? Int64 ?? 0,
            free: memoryData["free"] as? Int64 ?? 0,
            active: memoryData["active"] as? Int64 ?? 0,
            inactive: memoryData["inactive"] as? Int64 ?? 0,
            buffers: memoryData["buffers"] as? Int64 ?? 0,
            cached: memoryData["cached"] as? Int64 ?? 0,
            shared: memoryData["shared"] as? Int64 ?? 0,
            slab: memoryData["slab"] as? Int64 ?? 0
        )
        
        // Parse disk stats
        guard let diskData = systemStats["disk"] as? [String: Any] else {
            print("ERROR: Missing disk data in status JSON")
            return
        }
        
        let disk = StatusViewModel.StatusMessage.SystemStats.DiskStats(
            total: diskData["total"] as? Int64 ?? 0,
            used: diskData["used"] as? Int64 ?? 0,
            free: diskData["free"] as? Int64 ?? 0,
            percent: diskData["percent"] as? Double ?? 0.0
        )
        
        let systemStatsObj = StatusViewModel.StatusMessage.SystemStats(
            cpuUsage: cpuUsage,
            memory: memory,
            disk: disk,
            temperature: temperature,
            uptime: uptime
        )
        
        // Parse ANTSDR temps - handle both Double values and "N/A" strings from Python
        let plutoTemp: Double = {
            if let doubleVal = antStats["pluto_temp"] as? Double {
                return doubleVal
            } else if let strVal = antStats["pluto_temp"] as? String, strVal != "N/A" {
                return Double(strVal) ?? 0.0
            }
            return 0.0
        }()
        
        let zynqTemp: Double = {
            if let doubleVal = antStats["zynq_temp"] as? Double {
                return doubleVal
            } else if let strVal = antStats["zynq_temp"] as? String, strVal != "N/A" {
                return Double(strVal) ?? 0.0
            }
            return 0.0
        }()
        
        let antStatsObj = StatusViewModel.StatusMessage.ANTStats(
            plutoTemp: plutoTemp,
            zynqTemp: zynqTemp
        )
        
        // Create status message
        let statusMessage = StatusViewModel.StatusMessage(
            uid: uid,
            serialNumber: serialNumber,
            timestamp: timestamp,
            gpsData: gps,
            systemStats: systemStatsObj,
            antStats: antStatsObj
        )
        
        // Send to StatusViewModel on main thread
        Task { @MainActor in
            self.statusViewModel.addStatusMessage(statusMessage)
            print("Status message processed successfully and sent to StatusViewModel")
            print("   Serial: \(serialNumber), CPU: \(String(format: "%.1f", cpuUsage))%, Uptime: \(Int(uptime))s")
        }
    }
    
    // Check connection status without heavy processing
    @MainActor
    func checkConnectionStatus() {
        if !isListeningCot && Settings.shared.isListening {
            reconnectIfNeeded()
        }
    }
    
    @MainActor
    func prepareForBackgroundExpiry() {
        print("WarDragon preparing for background - ALWAYS monitoring")
        
        // Don't end existing tasks - the silent audio will keep us alive indefinitely
        
        // Start background processing (this also starts SilentAudioKeepAlive)
        BackgroundManager.shared.startBackgroundProcessing()
        
        print("Background detection enabled - no timeout, audio keepalive active")
    }
    
    func resumeFromBackground() {
        print("WarDragon resuming from background...")
        
        // Clear reconnecting flag
        isReconnecting = false
        
        Task { @MainActor in
            guard Settings.shared.isListening else {
                print("Not listening, skipping resume")
                return
            }
            
            // Check if already connected
            if isListeningCot {
                print("Already listening, just refreshing state")
                self.objectWillChange.send()
                return
            }
            
            // Not connected but should be - reconnect
            print("Restarting listening after background...")
            startListening()
            objectWillChange.send()
            print("WarDragon successfully resumed from background")
        }
    }
    
    // Reconnect BG if we need to
    func reconnectIfNeeded() {
        guard !isReconnecting else { 
            print("Reconnection already in progress, skipping")
            return 
        }
        
        Task { @MainActor in
            updateCachedSettings()
            guard cachedIsListening && !isListeningCot else {
                print("No reconnection needed: listening=\(cachedIsListening), isListeningCot=\(isListeningCot)")
                return
            }
            
            print("Initiating reconnection...")
            isReconnecting = true
            
            // Clean up any existing connections
            stopListening()
            
            // Wait for cleanup to complete before reconnecting
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                
                self.startListening()
                
                // Clear reconnecting flag after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.isReconnecting = false
                    print("Reconnection complete")
                }
            }
        }
    }
    
    @MainActor
    private func updateMessage(_ message: CoTMessage) async {
        
        // Uncomment this to disallow zero-coordinate entries
        //        guard let coordinate = message.coordinate,
        //              coordinate.latitude != 0 || coordinate.longitude != 0 else {
        //            return
        //        }
        
        
        if await isDeviceBlocked(message) {
            print("UNTRACKED: Dropping message for \(message.uid)")
            return
        }
        
        // Special handling for FPV messages - don't convert to drone- format
        if message.isFPVDetection {
            // Check if this is a new FPV detection
            if let existingIndex = self.parsedMessages.firstIndex(where: { $0.uid == message.uid }) {
                var existingMessage = self.parsedMessages[existingIndex]
                
                // Update FPV fields
                existingMessage.fpvRSSI = message.fpvRSSI
                existingMessage.rssi = message.rssi
                existingMessage.fpvTimestamp = message.fpvTimestamp
                existingMessage.lastUpdated = Date()
                existingMessage.signalSources = message.signalSources
                
                self.parsedMessages[existingIndex] = existingMessage
                self.updateAlertRing(for: existingMessage)
            } else {
                // New FPV detection
                var fpvMessage = message
                fpvMessage.lastUpdated = Date()
                self.parsedMessages.append(fpvMessage)
                
                Task { @MainActor in
                    self.enforceDetectionLimits()
                }
                
                self.updateAlertRing(for: fpvMessage)
                self.sendNotification(for: fpvMessage)
                
                // Publish to MQTT and TAK
                self.publishDroneToMQTT(fpvMessage)
                if let cotXML = self.generateCoTXML(from: fpvMessage) {
                    self.publishCoTToTAK(cotXML)
                }
                self.publishToLattice(fpvMessage)
            }
            
            // Save to storage
            Task { @MainActor in
                let currentMonitorStatus = self.statusViewModel.statusMessages.last
                DroneStorageManager.shared.saveEncounter(message, monitorStatus: currentMonitorStatus)
                
                if let storedEncounter = SwiftDataStorageManager.shared.fetchEncounter(id: message.uid) {
                    storedEncounter.logActivity(timestamp: Date())
                }
            }
            
            return
        }
        
        // Extract the numerical ID from messages like "pilot-107", "home-107", "drone-107"
        let extractedId = extractNumericId(from: message.uid)
    
        // Check if this is a pilot or home message that should be associated with a drone
        if message.uid.hasPrefix("pilot-") {
            await updatePilotLocation(for: extractedId, message: message)
            return
        }
        
        if message.uid.hasPrefix("home-") {
            await updateHomeLocation(for: extractedId, message: message)
            return
        }

        if message.uid.hasPrefix("aircraft-") || 
           message.uid.contains("adsb") ||
           message.idType == "ADS-B Aircraft" ||
           message.idType.contains("Aircraft") {
            print("Filtering out aircraft message - UID: \(message.uid), Type: \(message.idType)")
            return
        }
        
        let droneId = message.uid.hasPrefix("drone-") ? message.uid : "drone-\(message.uid)"
        var mac: String? = nil
        if let basicIdMac = (message.rawMessage["Basic ID"] as? [String: Any])?["MAC"] as? String {
            mac = basicIdMac
        } else if let auxAdvMac = (message.rawMessage["AUX_ADV_IND"] as? [String: Any])?["addr"] as? String {
            mac = auxAdvMac
        } else {
            mac = message.mac
        }
        
        let trackSpeed = message.trackSpeed ?? "0.0"
        let trackCourse = message.trackCourse ?? "0.0"
        
        if BackgroundDiagnostics.isEnabled {
            print("DEBUG: Track data from message - Speed: \(String(describing: message.trackSpeed)), Course: \(String(describing: message.trackCourse))")
            print("DEBUG: Track data after defaults - Speed: \(trackSpeed), Course: \(trackCourse)")
        }
        
        // Prepare updated message
        var updatedMessage = message
        updatedMessage.uid = droneId
        
        // CoT XML Track data
        updatedMessage.trackSpeed = trackSpeed
        updatedMessage.trackCourse = trackCourse
        
        // If track course is 0.0 or missing, try to calculate from flight path
        if trackCourse == "0.0" || trackCourse.isEmpty {
            if let calculatedBearing = await calculateBearingFromFlightPath(droneId: droneId, currentLat: message.lat, currentLon: message.lon) {
                updatedMessage.trackCourse = String(calculatedBearing)
                print("DEBUG: Calculated bearing from flight path: \(calculatedBearing)°")
            }
        }
        
        // Determine signal type and update sources
        _ = self.determineSignalType(message: message, mac: mac, rssi: updatedMessage.rssi, updatedMessage: &updatedMessage)
        
        // Handle CAA and location mapping
        if let mac = mac, !mac.isEmpty {
            // Update the MAC-to-CAA mapping without changing the primary ID
            if message.idType.contains("CAA") {
                if let mac = message.mac {
                    // Find existing message with same MAC and update its CAA registration
                    if let existingIndex = self.parsedMessages.firstIndex(where: { $0.mac == mac }) {
                        var existingMessage = self.parsedMessages[existingIndex]
                        existingMessage.caaRegistration = message.caaRegistration ?? message.id
                        // Keep the original ID type if it's a serial number
                        if !existingMessage.idType.contains("Serial") {
                            existingMessage.idType = "CAA Assigned Registration ID"
                        }
                        // Wrap in MainActor to prevent background thread publishing
                        Task { @MainActor in
                            self.parsedMessages[existingIndex] = existingMessage
                        }
                        print("Updated CAA registration for existing drone with MAC: \(mac)")
                    }
                }
                // Don't process CAA as a standalone message
                return
            }
        }
        
        // Generate signature and handle spoof detection
        guard let signature = self.signatureGenerator.createSignature(from: updatedMessage.toDictionary()) else {
            if message.idType.contains("CAA") {
                self.handleCAAMessage(updatedMessage)
            }
            return
        }
        
        // Update tracking data
        self.updateDroneSignaturesAndEncounters(signature, message: updatedMessage)
        self.updateMACHistory(droneId: droneId, mac: mac)
        
        // Spoof detection
        let spoofDetectionEnabled = await MainActor.run {
            Settings.shared.spoofDetectionEnabled
        }
        
        if spoofDetectionEnabled {
            let monitorStatus = await MainActor.run {
                self.statusViewModel.statusMessages.last
            }
            
            if let monitorStatus = monitorStatus {
                if let spoofResult = self.signatureGenerator.detectSpoof(signature, fromMonitor: monitorStatus) {
                    updatedMessage.isSpoofed = spoofResult.isSpoofed
                    updatedMessage.spoofingDetails = spoofResult
                }
                
                let monitorLoc = CLLocation(
                    latitude: monitorStatus.gpsData.latitude,
                    longitude: monitorStatus.gpsData.longitude
                )
                self.signatureGenerator.updateMonitorLocation(monitorLoc)
            }
        }
        
        // Final update
        self.updateParsedMessages(updatedMessage: updatedMessage, signature: signature)
    }
    
    private func extractNumericId(from uid: String) -> String {
        if let match = uid.firstMatch(of: /.*-([a-zA-Z0-9]+)/) {
            return String(match.1)
        }
        return uid
    }
    
    @MainActor
    private func updatePilotLocation(for droneId: String, message: CoTMessage) async {
        let targetUid = "drone-\(droneId)"
        
        // Find existing drone message and update pilot location
        if let index = parsedMessages.firstIndex(where: { $0.uid == targetUid }) {
            var updatedMessage = parsedMessages[index]
            updatedMessage.pilotLat = message.lat
            updatedMessage.pilotLon = message.lon
            parsedMessages[index] = updatedMessage
        }
        
        // Also update in storage (MainActor isolated)
        DroneStorageManager.shared.updatePilotLocation(
            droneId: "drone-\(droneId)",
            latitude: Double(message.lat) ?? 0.0,
            longitude: Double(message.lon) ?? 0.0
        )
    }
    
    @MainActor
    private func updateHomeLocation(for droneId: String, message: CoTMessage) async {
        let targetUid = "drone-\(droneId)"
        
        // Find existing drone message and update home location
        if let index = parsedMessages.firstIndex(where: { $0.uid == targetUid }) {
            var updatedMessage = parsedMessages[index]
            updatedMessage.homeLat = message.lat
            updatedMessage.homeLon = message.lon
            parsedMessages[index] = updatedMessage
        }
        
        // Also update in storage (MainActor isolated)
        DroneStorageManager.shared.updateHomeLocation(
            droneId: "drone-\(droneId)",
            latitude: Double(message.lat) ?? 0.0,
            longitude: Double(message.lon) ?? 0.0
        )
    }
    
    // MARK: - Helper Methods
    
    /// Calculate bearing from the last two coordinates in the flight path
    @MainActor
    private func calculateBearingFromFlightPath(droneId: String, currentLat: String, currentLon: String) async -> Double? {
        guard let currentLatDouble = Double(currentLat),
              let currentLonDouble = Double(currentLon),
              currentLatDouble != 0.0 && currentLonDouble != 0.0 else {
            return nil
        }
        
        // Get the encounter from storage
        guard let encounter = DroneStorageManager.shared.fetchEncounter(id: droneId),
              let lastPoint = encounter.flightPath.last else {
            return nil
        }
        
        // Get the last coordinate from flight path
        let lastLat = lastPoint.latitude
        let lastLon = lastPoint.longitude
        
        // Don't calculate if we're at the same position
        guard lastLat != currentLatDouble || lastLon != currentLonDouble else {
            return nil
        }
        
        // Calculate bearing using spherical law of cosines
        let lat1 = lastLat * .pi / 180
        let lon1 = lastLon * .pi / 180
        let lat2 = currentLatDouble * .pi / 180
        let lon2 = currentLonDouble * .pi / 180
        
        let dLon = lon2 - lon1
        
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let bearing = atan2(y, x) * 180 / .pi
        
        // Normalize to 0-360
        return (bearing + 360).truncatingRemainder(dividingBy: 360)
    }
    
    // MARK: - Helper Methods (continued)
    
    
    private func extractMAC(from message: CoTMessage) -> String? {
        // Try message property first
        if let mac = message.mac { return mac }
        
        // Try raw message sources
        if let basicIdMac = (message.rawMessage["Basic ID"] as? [String: Any])?["MAC"] as? String {
            return basicIdMac
        }
        
        if let auxAdvMac = (message.rawMessage["AUX_ADV_IND"] as? [String: Any])?["addr"] as? String {
            return auxAdvMac
        }
        
        return nil
    }
    
    private func updateCAARegistration(for mac: String, message: CoTMessage) {
        // Find existing message with same MAC and update its CAA registration
        if let existingIndex = self.parsedMessages.firstIndex(where: { $0.mac == mac }) {
            var existingMessage = self.parsedMessages[existingIndex]
            existingMessage.caaRegistration = message.caaRegistration ?? message.id
            // Keep the original ID type if it's a serial number
            if !existingMessage.idType.contains("Serial") {
                existingMessage.idType = "CAA Assigned Registration ID"
            }
            self.parsedMessages[existingIndex] = existingMessage
            print("Updated CAA registration for existing drone with MAC: \(mac)")
        }
    }
    
    func determineSignalType(message: CoTMessage, mac: String?, rssi: Int?, updatedMessage: inout CoTMessage) -> SignalSource.SignalType {
        print("DEBUG: Index and runtime : \(String(describing: message.index)) and \(String(describing: message.runtime))")
        print("CurrentmessageFormat: \(currentMessageFormat)")
        
        func isValidMAC(_ mac: String) -> Bool {
            return mac.range(of: "^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$", options: .regularExpression) != nil
        }
        
        // Early return for FPV to prevent SDR processing
        if message.isFPVDetection || message.fpvSource != nil {
            let newSourceType = SignalSource.SignalType.fpv
            
            // Create FPV source with detection source as identifier
            let fpvIdentifier = message.fpvSource ?? "fpv-signal"
            guard let newSource = SignalSource(
                mac: fpvIdentifier,
                rssi: rssi ?? Int(message.fpvRSSI ?? 0.0),
                type: newSourceType,
                timestamp: Date()
            ) else { return newSourceType }
            
            // Update message with FPV source
            updatedMessage.signalSources = [newSource]
            return newSourceType
        }
        
        var checkedMac = mac ?? ""
        if !isValidMAC(checkedMac) {
            checkedMac = ""
        }
        
        let newSourceType: SignalSource.SignalType
        
        if !isValidMAC(checkedMac) {
            newSourceType = .sdr
        } else if currentMessageFormat == .wifi {
            newSourceType = .wifi
        } else if message.index != nil && message.index != "" && message.index != "0" ||
                    message.runtime != nil && message.runtime != "" && message.runtime != "0" {
            newSourceType = .wifi
        } else {
            newSourceType = .bluetooth
        }
        
        // Create new source only if we have valid data
        guard let newSource = SignalSource(
            mac: checkedMac,
            rssi: rssi ?? 0,
            type: newSourceType,
            timestamp: Date()
        ) else { return newSourceType }
        
        // Keep track of sources by TYPE
        var sourcesByType: [SignalSource.SignalType: SignalSource] = [:]
        
        // Process existing sources - keep newest per type
        for source in updatedMessage.signalSources {
            if let existing = sourcesByType[source.type] {
                if source.timestamp > existing.timestamp {
                    sourcesByType[source.type] = source
                }
            } else {
                sourcesByType[source.type] = source
            }
        }
        
        // Only add the new source if it's valid
        sourcesByType[newSourceType] = newSource
        
        // Sort by precedence: WiFi > BT > SDR > FPV
        updatedMessage.signalSources = Array(sourcesByType.values).sorted { s1, s2 in
            let typeOrder: [SignalSource.SignalType] = [.wifi, .bluetooth, .sdr, .fpv]
            if let index1 = typeOrder.firstIndex(of: s1.type),
               let index2 = typeOrder.firstIndex(of: s2.type) {
                return index1 < index2
            }
            return false
        }
        
        print("DEBUG: Signal sources after filtering by type: \(updatedMessage.signalSources.count)")
        for source in updatedMessage.signalSources {
            print("  - \(source.type): \(source.mac) @ \(source.rssi)dBm")
        }
        
        return newSourceType
    }
    
    
    private func updateDroneSignaturesAndEncounters(_ signature: DroneSignature, message: CoTMessage) {
        Task { @MainActor in
            if let index = self.droneSignatures.firstIndex(where: { $0.primaryId.id == signature.primaryId.id }) {
                self.droneSignatures[index] = signature
            } else {
                self.droneSignatures.append(signature)
            }

            let currentMonitorStatus = self.statusViewModel.statusMessages.last

            DroneStorageManager.shared.saveEncounter(message, monitorStatus: currentMonitorStatus)

            SwiftDataStorageManager.shared.logActivityForEncounter(id: signature.primaryId.id, timestamp: Date())

            DetectionViewCache.shared.invalidate(signature.primaryId.id)

            guard BackgroundDiagnostics.isEnabled else { return }

            guard let existing = DroneStorageManager.shared.fetchEncounter(id: signature.primaryId.id) else {
                print("⚠️ Encounter not found for signature: \(signature.primaryId.id) - skipping position check")
                return
            }

            let lastPoint = existing.flightPoints.last
            let hasNewPosition = lastPoint?.latitude != signature.position.coordinate.latitude ||
            lastPoint?.longitude != signature.position.coordinate.longitude ||
            lastPoint?.altitude != signature.position.altitude

            if hasNewPosition {
                print("DEBUG:  Added new position to existing encounter: \(signature.primaryId.id)")
            } else {
                print("DEBUG:  Updated existing encounter data: \(signature.primaryId.id)")
            }
        }
    }
    
    @MainActor
    public func updateAlertRing(for message: CoTMessage) {
        let latValue = Double(message.lat) ?? 0
        let lonValue = Double(message.lon) ?? 0

        guard (latValue == 0 && lonValue == 0) && message.rssi != nil && message.rssi != 0 else {
            self.alertRings.removeAll(where: { $0.droneId == message.uid })
            return
        }

        var monitorLocation: CLLocationCoordinate2D?
        if let monitorStatus = self.statusViewModel.statusMessages.last {
            let statusLat = monitorStatus.gpsData.latitude
            let statusLon = monitorStatus.gpsData.longitude
            if statusLat != 0.0 || statusLon != 0.0 {
                monitorLocation = CLLocationCoordinate2D(latitude: statusLat, longitude: statusLon)
            }
        }
        if monitorLocation == nil, let userLocation = LocationManager.shared.userLocation {
            monitorLocation = userLocation.coordinate
        }

        guard let location = monitorLocation, let rssi = message.rssi else {
            print("❌ Cannot create alert ring for \(message.uid): no monitor location or no RSSI")
            return
        }

        let rssiValue = Double(rssi)
        let distance: Double
        if message.isFPVDetection, let fpvRSSI = message.fpvRSSI {
            distance = self.calculateFPVDistance(fpvRSSI)
        } else if rssiValue > 1000 {
            distance = self.calculateFPVDistance(rssiValue)
        } else {
            distance = DroneSignatureGenerator().calculateDistance(rssiValue)
        }

        if let index = self.alertRings.firstIndex(where: { $0.droneId == message.uid }) {
            let existing = self.alertRings[index]
            let latDelta = abs(existing.centerCoordinate.latitude - location.latitude)
            let lonDelta = abs(existing.centerCoordinate.longitude - location.longitude)
            let radiusDelta = abs(existing.radius - distance)
            if existing.rssi == rssi && radiusDelta < 1.0 && latDelta < 1e-6 && lonDelta < 1e-6 {
                return
            }
            self.alertRings[index] = AlertRing(
                droneId: message.uid,
                centerCoordinate: location,
                radius: distance,
                rssi: rssi
            )
        } else {
            self.alertRings.append(AlertRing(
                droneId: message.uid,
                centerCoordinate: location,
                radius: distance,
                rssi: rssi
            ))
        }
    }

    // Helper function to calculate FPV distance based on signal strength
    private func calculateFPVDistance(_ rssi: Double) -> Double {
        // FPV 5.8GHz realistic detection range
        let minRssi = 1100.0  // Weak signal
        let maxRssi = 2800.0  // Strong signal (realistic for close range)
        
        if rssi <= minRssi {
            return 500.0 // Maximum realistic range for 5.8GHz detection
        }
        
        if rssi >= maxRssi {
            return 20.0 // Very close range
        }
        
        // Exponential decay for realistic RF propagation
        let normalizedRssi = (rssi - minRssi) / (maxRssi - minRssi)
        let distance = 500.0 * exp(-3.0 * normalizedRssi)
        
        return max(min(distance, 500.0), 10.0)
    }
    

    // Helper function to update alert rings for consolidated messages
    private func updateAlertRingForConsolidated(consolidated: CoTMessage, originalMessages: [CoTMessage]) {
        // Remove all existing alert rings for the original messages
        for message in originalMessages {
            alertRings.removeAll(where: { $0.droneId == message.uid })
        }
        
        // Create a new alert ring for the consolidated message
        Task { @MainActor in
            if let monitorStatus = self.statusViewModel.statusMessages.last {
                let monitorLocation = CLLocationCoordinate2D(
                    latitude: monitorStatus.gpsData.latitude,
                    longitude: monitorStatus.gpsData.longitude
                )
                
                // Calculate radius based on strongest signal
                let rssiValue = Double(consolidated.rssi ?? 0)
                let distance: Double
                
                if rssiValue > 1000 {
                    distance = self.calculateFPVDistance(rssiValue)
                } else {
                    distance = DroneSignatureGenerator().calculateDistance(rssiValue)
                }
                
                let newRing = AlertRing(
                    droneId: consolidated.uid,
                    centerCoordinate: monitorLocation,
                    radius: distance,
                    rssi: consolidated.rssi ?? 0
                )
                
                // Wrap in MainActor to prevent background thread publishing
                Task { @MainActor in
                    self.alertRings.append(newRing)
                }
            }
        }
    }
    
    // Helper to calculate radius from RSSI
    private func calculateRadius(rssi: Double) -> Double {
        if rssi > 1000 {
            // MDN-style values (around 1400-2500)
            return 100.0 + ((rssi - 1200) / 10)
        } else {
            // Standard RSSI values (negative dBm)
            let generator = DroneSignatureGenerator()
            return generator.calculateDistance(rssi)
        }
    }
    
    
    private func calculateConfidenceRadius(_ confidence: Double) -> Double {
        // Radius gets smaller as confidence increases
        return 50.0 + ((1.0 - confidence) * 250.0)
    }
    
    private func updateMACHistory(droneId: String, mac: String?) {
        guard let mac = mac, !mac.isEmpty else { return }
        
        // Check second character for randomization pattern (2,6,A,E)
        if mac.count >= 2 {
            let secondChar = mac[mac.index(mac.startIndex, offsetBy: 1)]
            let isRandomized = "26AE".contains(secondChar)
            
            if isRandomized {
                macProcessing[droneId] = true
            }
        }
        
        var macs = self.macIdHistory[droneId] ?? Set<String>()
        macs.insert(mac)
        self.macIdHistory[droneId] = macs
    }
    
    private func updateParsedMessages(updatedMessage: CoTMessage, signature: DroneSignature) {
        var messageToProcess = updatedMessage
        
        Task { @MainActor in
            if let storedEncounter = SwiftDataStorageManager.shared.fetchEncounter(id: updatedMessage.uid) {
                if !storedEncounter.customName.isEmpty {
                    messageToProcess.customName = storedEncounter.customName
                }
                messageToProcess.trustStatus = storedEncounter.trustStatus
            }
            
            self.applyStoredDataAndUpdate(messageToProcess, signature)
        }
    }
    
    @MainActor
    private func applyStoredDataAndUpdate(_ messageToProcess: CoTMessage, _ signature: DroneSignature) {
        if let existingIndex = self.parsedMessages.firstIndex(where: { $0.mac == messageToProcess.mac || $0.uid == messageToProcess.uid }) {
            var existingMessage = self.parsedMessages[existingIndex]
            
            existingMessage.customName = messageToProcess.customName
            existingMessage.trustStatus = messageToProcess.trustStatus
            
            var consolidatedSources: [SignalSource.SignalType: SignalSource] = [:]
            
            for source in existingMessage.signalSources {
                consolidatedSources[source.type] = source
            }
            
            for source in messageToProcess.signalSources {
                if let existing = consolidatedSources[source.type] {
                    if source.timestamp > existing.timestamp {
                        consolidatedSources[source.type] = source
                    }
                } else {
                    consolidatedSources[source.type] = source
                }
            }
            
            let typeOrder: [SignalSource.SignalType] = [.wifi, .bluetooth, .sdr]
            existingMessage.signalSources = Array(consolidatedSources.values)
                .sorted { s1, s2 in
                    if let index1 = typeOrder.firstIndex(of: s1.type),
                       let index2 = typeOrder.firstIndex(of: s2.type) {
                        return index1 < index2
                    }
                    return false
                }
            
            if let latestSource = existingMessage.signalSources.first {
                existingMessage.mac = latestSource.mac
                existingMessage.rssi = latestSource.rssi
            }
            
            if messageToProcess.lat != "0.0" { existingMessage.lat = messageToProcess.lat }
            if messageToProcess.lon != "0.0" { existingMessage.lon = messageToProcess.lon }
            if messageToProcess.speed != "0.0" { existingMessage.speed = messageToProcess.speed }
            if messageToProcess.vspeed != "0.0" { existingMessage.vspeed = messageToProcess.vspeed }
            if messageToProcess.alt != "0.0" { existingMessage.alt = messageToProcess.alt }
            if let height = messageToProcess.height, height != "0.0" { existingMessage.height = height }
            
            existingMessage.lastUpdated = Date()
            
            if !messageToProcess.pilotLat.isEmpty && messageToProcess.pilotLat != "0.0" {
                existingMessage.pilotLat = messageToProcess.pilotLat
                existingMessage.pilotLon = messageToProcess.pilotLon
            }
            
            if let newOpId = messageToProcess.operator_id, !newOpId.isEmpty {
                existingMessage.operator_id = newOpId
            }
            
            if messageToProcess.idType.contains("CAA") {
                existingMessage.caaRegistration = messageToProcess.caaRegistration
                existingMessage.idType = "CAA Assigned Registration ID"
            }
            
            if messageToProcess.trackSpeed != "0.0" && messageToProcess.trackCourse != "0.0" {
                existingMessage.trackSpeed = messageToProcess.trackSpeed
                existingMessage.trackCourse = messageToProcess.trackCourse
            }
            
            existingMessage.isSpoofed = messageToProcess.isSpoofed
            existingMessage.spoofingDetails = messageToProcess.spoofingDetails
            
            // Check if anything meaningful changed before triggering UI update
            let oldMessage = self.parsedMessages[existingIndex]
            let hasSignificantChange = (
                oldMessage.lat != existingMessage.lat ||
                oldMessage.lon != existingMessage.lon ||
                oldMessage.alt != existingMessage.alt ||
                oldMessage.speed != existingMessage.speed ||
                oldMessage.rssi != existingMessage.rssi ||
                oldMessage.pilotLat != existingMessage.pilotLat ||
                oldMessage.pilotLon != existingMessage.pilotLon
            )

            // Already on @MainActor - no need for nested Task
            self.parsedMessages[existingIndex] = existingMessage
            
            // Only update alert ring if drone has no GPS coords but has RSSI
            let lat = Double(existingMessage.lat) ?? 0
            let lon = Double(existingMessage.lon) ?? 0
            if (lat == 0 && lon == 0) && existingMessage.rssi != nil && existingMessage.rssi != 0 {
                self.updateAlertRing(for: existingMessage)
            }

            let hasCoords = !(lat == 0 && lon == 0)
            let lastPublish = self.lastDetectionPublish[existingMessage.uid] ?? .distantPast
            let coordlessDue = Date().timeIntervalSince(lastPublish) >= self.coordlessRepublishInterval

            if hasSignificantChange && (hasCoords || coordlessDue) {
                self.publishDetection(existingMessage)
            }

        } else {
            // Already on @MainActor - no need for nested Task
            self.parsedMessages.append(messageToProcess)
            
            // Only update alert ring if drone has no GPS coords but has RSSI
            let lat = Double(messageToProcess.lat) ?? 0
            let lon = Double(messageToProcess.lon) ?? 0
            if (lat == 0 && lon == 0) && messageToProcess.rssi != nil && messageToProcess.rssi != 0 {
                self.updateAlertRing(for: messageToProcess)
            }
            
            self.enforceDetectionLimits()
            
            if !messageToProcess.idType.contains("CAA") {
                self.sendNotification(for: messageToProcess)
            }
            
            self.publishDetection(messageToProcess)
        }
    }

    @MainActor
    private func publishDetection(_ message: CoTMessage) {
        lastDetectionPublish[message.uid] = Date()
        publishDroneToMQTT(message)
        if let cotXML = generateCoTXML(from: message) {
            publishCoTToTAK(cotXML)
        }
        publishToLattice(message)
    }
    
    private func handleCAAMessage(_ message: CoTMessage) {
        // Special handling for CAA messages that don't generate a signature
        if let mac = message.mac {
            // Update MAC to CAA mapping
            self.macToCAA[mac] = message.id
            
            // Find and update existing message with same MAC
            if let index = self.parsedMessages.firstIndex(where: { $0.mac == mac }) {
                var existingMessage = self.parsedMessages[index]
                existingMessage.caaRegistration = message.caaRegistration
                self.parsedMessages[index] = existingMessage
                print("Updated CAA registration for existing drone")
            }
        }
    }
    
    //MARK: - Helper functions
    
    private func sendNotification(for message: CoTViewModel.CoTMessage) {
        Task { @MainActor in
            guard Settings.shared.notificationsEnabled else { return }
            
            // Only send notification ONCE per drone (check if we've already notified)
            guard !self.notifiedDrones.contains(message.uid) else {
                return
            }
            
            // Global rate limit: Only send notification if more than 5 seconds have passed since ANY notification
            if let lastTime = self.lastNotificationTime,
               Date().timeIntervalSince(lastTime) < 5 {
                return
            }
            
            if Settings.shared.webhooksEnabled {
                self.sendWebhookNotification(for: message)
            }
            
            // Create and send notification with DRONE-SPECIFIC identifier
            // Using the drone's UID as identifier ensures iOS replaces old notifications for the same drone
            let content = UNMutableNotificationContent()
            print("Sending notification for NEW drone: \(message.uid)")
            content.title = "Drone Detected"
            content.body = "ID: \(message.id)\nRSSI: \(message.rssi ?? 0)dBm"
            
            // Use drone UID as notification identifier so iOS replaces old notifications
            let request = UNNotificationRequest(identifier: "drone-\(message.uid)", content: content, trigger: nil)
            
            try? await UNUserNotificationCenter.current().add(request)
            
            // Mark this drone as notified
            self.notifiedDrones.insert(message.uid)
            self.lastNotificationTime = Date()
        }
    }
    
    private func sendStatusNotification(for message: StatusViewModel.StatusMessage) {
        Task { @MainActor in
            guard Settings.shared.notificationsEnabled else { return }
            // Don't send here - let StatusViewModel handle it through checkSystemThresholds
            self.statusViewModel.checkSystemThresholds()
        }
    }
    
    func stopListening() {
        guard isListeningCot || multicastGroup != nil else {
            print("Already stopped, skipping stopListening()")
            return
        }
        
        print("Stopping all listeners")
        BackgroundDiagnostics.shared.log(.socket, "stopListening",
                                         "mode=\(cachedConnectionMode) inBackground=\(isInBackground)")

        SilentAudioKeepAlive.shared.stop()
        multicastRecoveryAttempts = 0
        isListeningCot = false
        isReconnecting = false
        isStarting = false
        
        backgroundMaintenanceTimer?.invalidate()
        backgroundMaintenanceTimer = nil
        
        NotificationCenter.default.removeObserver(
            self,
            name: Notification.Name("RefreshNetworkConnections"),
            object: nil
        )
        
        if let group = multicastGroup {
            group.stateUpdateHandler = nil
            group.cancel()
            multicastGroup = nil
            print("Multicast group cancelled")
        }
        
        if let listener = cotListener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            cotListener = nil
            print("CoT listener cancelled")
        }
        
        if let listener = statusListener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            statusListener = nil
            print("Status listener cancelled")
        }
        
        if let zmqHandler = zmqHandler {
            zmqHandler.disconnect()
            self.zmqHandler = nil
            print("ZMQ: Disconnected")
        }
        
        print("All listeners stopped")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            print("Network resources cleanup completed")
        }
    }
    
    func verifyZMQSubscription() {
        Task { @MainActor in
            updateCachedSettings()
            guard cachedConnectionMode == .zmq else { return }
            
            if zmqHandler == nil {
                print("ZMQ handler is nil, creating new connection")
                startZMQListening()
                return
            }
            
            if zmqHandler?.isConnected != true {
                print("ZMQ connection lost, reconnecting...")
                zmqHandler?.disconnect()
                zmqHandler = nil
                startZMQListening()
                return
            }
            
            // Just check if connection is valid, but don't resubscribe
            zmqHandler?.verifySubscription { [weak self] isValid in
                if !isValid {
                    print("ZMQ connection invalid, reconnecting...")
                    self?.zmqHandler?.disconnect()
                    self?.zmqHandler = nil
                    self?.startZMQListening()
                }
            }
        }
    }
    
    @objc private func checkConnections() {
        // Only check if we're supposed to be listening
        guard isListeningCot else { return }
        
        Task { @MainActor in
            updateCachedSettings()
            if cachedConnectionMode == .zmq {
                verifyZMQSubscription()
            } else if cachedConnectionMode == .multicast {
                if multicastGroup == nil {
                    print("Multicast connection lost in background, reconnecting...")
                    startMulticastListening()
                }
            }
        }
    }
    
}


extension CoTViewModel.CoTMessage {
    
    var timestampDouble: Double {
        if let timestampString = timestamp, let value = Double(timestampString) {
            return value
        }
        // Fallback to current time if timestamp is invalid
        return Date().timeIntervalSince1970
    }
    
    enum ConnectionStatus {
        case connected
        case weak
        case lost
        case unknown
        
        var color: Color {
            switch self {
            case .connected: return .green
            case .weak: return .yellow
            case .lost: return .red
            case .unknown: return .gray
            }
        }
        
        var description: String {
            switch self {
            case .connected: return "Connected"
            case .weak: return "Weak Signal"
            case .lost: return "Connection Lost"
            case .unknown: return "Unknown"
            }
        }
    }
    
    var connectionStatus: ConnectionStatus {
        let currentTime = Date().timeIntervalSince1970
        let messageTime = timestampDouble
        let timeSinceLastUpdate = currentTime - messageTime
        
        if timeSinceLastUpdate < 5 {
            if let rssi = rssi {
                return rssi > -70 ? .connected : .weak
            }
            return .connected
        } else if timeSinceLastUpdate < 30 {
            return .weak
        } else {
            return .lost
        }
    }
    
    struct TrackData {
        let course: String?
        let speed: String?
        let bearing: String?
    }
    
    /// Create a unified detection message from an ADS-B aircraft
    static func from(aircraft: Aircraft) -> CoTViewModel.CoTMessage {
        let uid = "aircraft-\(aircraft.hex)"
        let lat = aircraft.lat.map { String($0) } ?? "0.0"
        let lon = aircraft.lon.map { String($0) } ?? "0.0"
        let alt = aircraft.altitudeMeters.map { String($0) } ?? "0.0"
        let speed = aircraft.speedMPS.map { String($0) } ?? "0.0"
        let vspeed = aircraft.verticalRate.map { String(Double($0) * 0.00508) } ?? "0.0" // fpm to m/s
        let track = aircraft.track.map { String($0) } ?? "0.0"
        
        let description = aircraft.displayName
        let idType = "ADS-B Aircraft"
        
        // Build raw message from aircraft data
        var rawMessage: [String: Any] = [
            "hex": aircraft.hex,
            "type": "aircraft",
            "source": "adsb"
        ]
        
        if let lat = aircraft.lat { rawMessage["lat"] = lat }
        if let lon = aircraft.lon { rawMessage["lon"] = lon }
        if let alt = aircraft.altitude { rawMessage["altitude_feet"] = alt }
        if let flight = aircraft.flight { rawMessage["callsign"] = flight }
        if let squawk = aircraft.squawk { rawMessage["squawk"] = squawk }
        if let rssi = aircraft.rssi { rawMessage["rssi"] = rssi }
        
        var message = CoTViewModel.CoTMessage(
            uid: uid,
            type: "a-f-A", // Aircraft CoT type
            lat: lat,
            lon: lon,
            homeLat: "0.0",
            homeLon: "0.0",
            speed: speed,
            vspeed: vspeed,
            alt: alt,
            height: nil,
            pilotLat: "0.0",
            pilotLon: "0.0",
            description: description,
            selfIDText: "DEBUG:  \(description) - Alt: \(aircraft.altitudeFeet ?? 0)ft",
            uaType: DroneSignature.IdInfo.UAType.aeroplane,
            idType: idType,
            rawMessage: rawMessage
        )
        
        // Set aircraft-specific fields
        message.trackCourse = track
        message.trackSpeed = speed
        message.rssi = aircraft.rssi.map { Int($0) }
        message.manufacturer = aircraft.category
        message.lastUpdated = aircraft.lastSeen
        
        // Set emergency status if applicable
        if aircraft.isEmergency, let emergencyType = aircraft.emergency {
            message.op_status = "Emergency: \(emergencyType)"
        }
        
        return message
    }
}

// MARK: - Webhook Integration
extension CoTViewModel {
    
    private func sendWebhookNotification(for message: CoTMessage) {
        // Check rate limit
        guard RateLimiterManager.shared.shouldAllowWebhook() else {
            // Rate limited - skip this webhook
            return
        }
        
        // Always drone detected for this branch (no FPV support)
        let event: WebhookEvent = .droneDetected
        
        // Build data payload
        var data: [String: Any] = [
            "uid": message.uid,
            "timestamp": message.timestamp ?? Date().timeIntervalSince1970
        ]
        
        if let rssi = message.rssi {
            data["rssi"] = rssi
        }
        
        // Use the existing lat/lon properties from CoTMessage
        if let latitude = Double(message.lat) {
            data["latitude"] = latitude
        }
        
        if let longitude = Double(message.lon) {
            data["longitude"] = longitude
        }
        
        if let altitude = Double(message.alt) {
            data["altitude"] = altitude
        }
        
        // Build metadata
        var metadata: [String: String] = [:]
        
        if let mac = message.mac {
            metadata["mac"] = mac
        }
        
        if let caaReg = message.caaRegistration {
            metadata["caa_registration"] = caaReg
        }
        
        if let manufacturer = message.manufacturer {
            metadata["manufacturer"] = manufacturer
        }
        
        metadata["id_type"] = message.idType
        metadata["ua_type"] = message.uaType.rawValue
        
        // Send webhook
        WebhookManager.shared.sendWebhook(event: event, data: data, metadata: metadata)
    }
    
    private func sendSystemWebhookAlert(_ title: String, _ message: String, event: WebhookEvent) {
        let data: [String: Any] = [
            "title": title,
            "message": message,
            "timestamp": Date()
        ]
        
        WebhookManager.shared.sendWebhook(event: event, data: data)
    }
}

// MARK: - MQTT and TAK Integration
extension CoTViewModel {
    
    /// Setup MQTT client and start connection
    func setupMQTTClient() {
        Task { @MainActor in
            let config = Settings.shared.mqttConfiguration
            guard config.enabled && config.isValid else {
                self.mqttClient = nil
                return
            }
            
            self.mqttClient = MQTTClient(configuration: config)
            self.mqttClient?.connect()
            
            // Observe connection state
            self.mqttClient?.$state
                .sink { state in
                    print("MQTT state: \(state)")
                }
                .store(in: &self.cancellables)
        }
    }
    
    /// Setup TAK client and start connection
    func setupTAKClient() {
        Task { @MainActor in
            var config = Settings.shared.takConfiguration
            guard config.enabled && config.isValid else {
                self.takClient = nil
                return
            }
            
            config.protocol = .udp
            self.takClient = TAKClient(configuration: config, enrollmentManager: nil)
            self.takClient?.connect()
            
            self.takClient?.$state
                .sink { state in
                    print("TAK state: \(state)")
                }
                .store(in: &self.cancellables)
        }
    }
    
    func setupLatticeClient() {
        Task { @MainActor in
            let config = Settings.shared.latticeConfiguration
            guard config.enabled && config.isValid else {
                self.latticeClient = nil
                return
            }
            
            self.latticeClient = LatticeClient(configuration: config)
            
            NotificationCenter.default.publisher(for: .latticeSettingsChanged)
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    Task { @MainActor in
                        if Settings.shared.latticeEnabled {
                            self.setupLatticeClient()
                        } else {
                            self.latticeClient = nil
                        }
                    }
                }
                .store(in: &self.cancellables)
        }
    }
    
    /// Publish drone detection to MQTT
    func publishDroneToMQTT(_ message: CoTMessage) {
        Task { @MainActor in
            guard Settings.shared.mqttEnabled, let mqttClient = self.mqttClient else { return }
            
            // Check rate limit
            let droneId = message.mac ?? message.uid
            guard RateLimiterManager.shared.shouldAllowDronePublish(for: droneId) else {
                // Rate limited - skip this publish
                return
            }
            
            guard RateLimiterManager.shared.shouldAllowMQTTPublish() else {
                // Global MQTT rate limit hit
                return
            }
            
            do {
                let mqttMessage = message.toMQTTDroneMessage()
                try await mqttClient.publishDrone(mqttMessage)
                
                // Home Assistant discovery (first time only per MAC)
                if Settings.shared.mqttHomeAssistantEnabled {
                    let mac = message.mac ?? message.uid
                    if !self.publishedDrones.contains(mac) {
                        self.publishedDrones.insert(mac)
                        try await mqttClient.publishHomeAssistantDiscovery(
                            for: mac,
                            deviceName: message.deviceName
                        )
                    }
                }
            } catch {
                print("MQTT publish failed: \(error)")
            }
        }
    }
    
    /// Publish CoT XML to TAK server
    func publishCoTToTAK(_ cotXML: String) {
        Task { @MainActor in
            guard Settings.shared.takEnabled, let takClient = self.takClient else { return }
            
            // Check rate limit
            guard RateLimiterManager.shared.shouldAllowTAKPublish() else {
                // Rate limited - skip this publish
                return
            }
            
            do {
                try await takClient.send(cotXML)
            } catch {
                print("TAK publish failed: \(error)")
            }
        }
    }
    
    /// Publish system status to TAK server (matches Python DragonSync behavior)
    func publishSystemStatusToTAK() {
        Task { @MainActor in
            guard Settings.shared.takEnabled, let takClient = self.takClient else { return }
            guard let latestStatus = statusViewModel.statusMessages.last else { return }
            
            // Check rate limit
            guard RateLimiterManager.shared.shouldAllowTAKPublish() else {
                return
            }
            
            do {
                let cotXML = latestStatus.toCoTXML()
                try await takClient.send(cotXML)
                print("Published system status to TAK")
            } catch {
                print("TAK system status publish failed: \(error)")
            }
        }
    }
    
    /// Publish system status to MQTT (call periodically)
    func publishSystemStatusToMQTT() {
        Task { @MainActor in
            guard Settings.shared.mqttEnabled, let mqttClient = self.mqttClient else { return }
            
            let systemMessage = self.createMQTTSystemMessage(dronesTracked: self.droneSignatures.count)
            
            do {
                try await mqttClient.publishSystemStatus(systemMessage)
            } catch {
                print("MQTT system status failed: \(error)")
            }
        }
    }
    
    /// Create MQTT system status message
    @MainActor
    private func createMQTTSystemMessage(dronesTracked: Int) -> MQTTSystemMessage {
        // Get latest status message if available
        guard let latestStatus = statusViewModel.statusMessages.last else {
            // Generate kit serial identifier (fallback case)
            let kitSerial: String?
            if let uuid = UIDevice.current.identifierForVendor?.uuidString {
                let shortId = String(uuid.prefix(8))
                kitSerial = "wardragon-\(shortId)"
            } else {
                kitSerial = nil
            }
            
            // Return minimal message if no status available
            return MQTTSystemMessage(
                timestamp: ISO8601DateFormatter().string(from: Date()),
                cpuUsage: nil,
                memoryUsed: nil,
                temperature: nil,
                plutoTemp: nil,
                zynqTemp: nil,
                gpsFix: nil,
                dronesTracked: dronesTracked,
                uptime: formatUptime(),
                timeSource: "unknown",
                gpsdTimeUtc: nil,
                kitSerial: kitSerial
            )
        }
        
        // Determine GPS status (matching Python dragonsync.py behavior)
        let hasGPSFix = latestStatus.gpsData.latitude != 0 && latestStatus.gpsData.longitude != 0
        let timeSource: String
        if hasGPSFix {
            timeSource = "gps" // iOS uses CoreLocation, similar to gpsd
        } else {
            timeSource = "static" // Using fallback/manual coordinates
        }
        
        // Format GPS time if available (ISO8601)
        let gpsdTimeUtc: String? = hasGPSFix ? ISO8601DateFormatter().string(from: Date()) : nil
        
        // Generate kit serial identifier
        let kitSerial: String?
        if let uuid = UIDevice.current.identifierForVendor?.uuidString {
            let shortId = String(uuid.prefix(8))
            kitSerial = "wardragon-\(shortId)"
        } else {
            kitSerial = nil
        }
        
        return MQTTSystemMessage(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            cpuUsage: latestStatus.systemStats.cpuUsage,
            memoryUsed: latestStatus.systemStats.memory.percent,
            temperature: latestStatus.systemStats.temperature,
            plutoTemp: latestStatus.antStats.plutoTemp,
            zynqTemp: latestStatus.antStats.zynqTemp,
            gpsFix: hasGPSFix,
            dronesTracked: dronesTracked,
            uptime: formatUptime(),
            timeSource: timeSource,
            gpsdTimeUtc: gpsdTimeUtc,
            kitSerial: kitSerial
        )
    }
    
    /// Format uptime string
    private func formatUptime() -> String {
        let uptime = ProcessInfo.processInfo.systemUptime
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        return String(format: "%dh %dm", hours, minutes)
    }
    
    /// XML-escape special characters
    private func xmlEscape(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    
    /// Generate CoT XML from message (for TAK server)
    func generateCoTXML(from message: CoTMessage) -> String? {
        let dateFormatter = ISO8601DateFormatter()
        let now = dateFormatter.string(from: Date())
        
        // Calculate stale time (15 minutes from now)
        let staleDate = Date().addingTimeInterval(900)
        let stale = dateFormatter.string(from: staleDate)
        
        // Escape special characters in text fields
        let escapedCallsign = xmlEscape(message.deviceName)
        let escapedRemarks = xmlEscape(message.selfIDText)
        
        // Build CoT XML
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="\(message.uid)" type="a-f-A-M-H-Q" time="\(now)" start="\(now)" stale="\(stale)" how="m-g">
            <point lat="\(message.lat)" lon="\(message.lon)" hae="\(message.alt)" ce="10.0" le="10.0"/>
            <detail>
                <contact callsign="\(escapedCallsign)"/>
                <remarks>\(escapedRemarks)</remarks>
                <track course="\(message.direction ?? "0")" speed="\(message.speed)"/>
                <uid Droneid="\(message.uid)"/>
            </detail>
        </event>
        """
        
        return xml
    }
    
    private func publishToLattice(_ message: CoTMessage) {
        guard let latticeClient = latticeClient else {
            print("Lattice publish skipped: latticeClient is nil")
            return
        }
        
        Task { @MainActor in
            guard Settings.shared.latticeEnabled else {
                print("Lattice publish skipped: latticeEnabled is false")
                return
            }
            
            do {
                try await latticeClient.publish(detection: message)
                print("Published detection \(message.uid) to Lattice")
            } catch {
                print("Lattice publish failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - ADS-B Integration
/// Aircraft tracking via ADS-B (Automatic Dependent Surveillance-Broadcast)
/// 
/// This section handles integration with readsb/dump1090 for tracking commercial and general aviation aircraft.
/// Aircraft data is displayed in the unified Detections tab alongside drone detections.
///
/// Features:
/// - Real-time aircraft position, altitude, speed, and heading tracking
/// - Proximity alerts for low-flying aircraft
/// - MQTT and TAK server integration for aircraft data
/// - Rate-limited publishing to prevent system overload
/// - Emergency aircraft detection and alerting
/// - Signal quality monitoring
///
/// Configuration is done through Settings.shared.adsbConfiguration
extension CoTViewModel {
    
    /// Setup ADS-B client and start polling
    @MainActor
    func setupADSBClient() async {
        let config = Settings.shared.adsbConfiguration
        print("DEBUG: setupADSBClient called - enabled: \(config.enabled), URL: '\(config.readsbURL)', isValid: \(config.isValid)")
        
        guard config.enabled && config.isValid else {
            print("DEBUG: ADS-B config not enabled or invalid, cleaning up aircraft only")
            print("DEBUG: Preserving \(self.parsedMessages.count) drone detections")
            
            // Cancel all subscriptions first to prevent memory leaks
            self.adsbCancellables.removeAll()
            
            // Stop and clear client
            self.adsbClient?.stop()
            self.adsbClient = nil
            
            // Clear ONLY aircraft-related data - DO NOT touch parsedMessages (drone detections)
            self.aircraftTracks.removeAll()
            
            // Remove aircraft alert rings only (preserve drone alert rings)
            self.alertRings.removeAll { $0.droneId.hasPrefix("aircraft-") }
            
            print("DEBUG: ADS-B cleanup complete - \(self.parsedMessages.count) drone detections preserved")
            return
        }
        
        // Cancel ALL previous ADS-B subscriptions first
        self.adsbCancellables.removeAll()
        
        // Stop existing client if any
        if let existingClient = self.adsbClient {
            existingClient.stop()
            self.adsbClient = nil
        }
        
        // Create new client
        let client = ADSBClient(configuration: config)
        self.adsbClient = client
        
        // Set up callback for when connection permanently fails
        client.onConnectionFailed = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                
                // Automatically disable ADS-B in settings
                Settings.shared.adsbEnabled = false
                
                print("ADS-B has been automatically disabled after repeated connection failures.")
                print("💡 Check that readsb/dump1090 is running at: \(config.readsbURL)")
                print("   You can re-enable ADS-B in Settings once the server is available.")
                
                // Show a user notification about this
                self.showAdsbAutoDisabledAlert()
            }
        }
        
        // Observe aircraft updates
        client.$aircraft
            .receive(on: DispatchQueue.main)
            .sink { [weak self] aircraft in
                guard let self = self else { return }
                self.handleAircraftUpdate(aircraft)
            }
            .store(in: &self.adsbCancellables)
        
        // Observe connection state
        client.$state
            .receive(on: DispatchQueue.main)
            .sink { state in
                if case .failed(let error) = state {
                    print("ADS-B error: \(error.localizedDescription)")
                    // Provide helpful message for connection errors
                    if (error as NSError).code == -1004 || (error as NSError).code == -1003 {
                        print("TIP: Make sure readsb/dump1090 is running at: \(config.readsbURL)")
                        print("     You can test with: curl \(config.readsbURL)/data/aircraft.json")
                    }
                }
            }
            .store(in: &self.adsbCancellables)
        
        // Start polling AFTER observations are set up and cleanup is complete
        client.start()
    }
    
    /// Show alert that ADS-B was automatically disabled
    private func showAdsbAutoDisabledAlert() {
        // Post notification for UI to show alert
        NotificationCenter.default.post(
            name: Notification.Name("ADSBAutoDisabled"),
            object: nil,
            userInfo: ["reason": "Connection failed after multiple attempts"]
        )
    }
    
    /// Get all active detections (drones + aircraft)
    var allActiveDetections: Int {
        return parsedMessages.filter { $0.isActive }.count
    }
    
    /// Get total detection count
    var totalDetections: Int {
        return parsedMessages.count
    }
    
    /// Check if we have any detections at all
    var hasAnyDetections: Bool {
        return !parsedMessages.isEmpty
    }
    
    /// Clear all aircraft tracks
    func clearAircraftTracks() {
        // Clear from aircraftTracks array
        aircraftTracks.removeAll()
        
        // Remove aircraft alert rings only (preserve drone alert rings)
        alertRings.removeAll { $0.droneId.hasPrefix("aircraft-") }
        
        print("Cleared all aircraft tracks - \(parsedMessages.count) drone detections preserved")
    }
    
    /// Clear all drone detections
    func clearDroneDetections() {
        // Remove all drone messages (including FPV detections)
        parsedMessages.removeAll()
        droneSignatures.removeAll()
        macIdHistory.removeAll()
        macProcessing.removeAll()
        
        // Remove drone alert rings only (preserve aircraft alert rings)
        alertRings.removeAll { !$0.droneId.hasPrefix("aircraft-") }
        
        print("Cleared all drone detections - \(aircraftTracks.count) aircraft tracks preserved")
    }
    
    /// Clear all detections (drones + aircraft)
    func clearAllDetections() {
        clearDroneDetections()
        clearAircraftTracks()
        
        print("Cleared all detections (drones and aircraft)")
    }
    
    /// Update aircraft tracks from OpenSky Network
    @MainActor
    func updateOpenSkyAircraft(_ aircraft: [Aircraft]) {
        let openSkyAircraft = aircraft.filter { $0.hex.count == 6 }
        var existingAircraft = aircraftTracks.filter { $0.hex.count != 6 }
        existingAircraft.append(contentsOf: openSkyAircraft)
        aircraftTracks = existingAircraft
        let limitedAircraft = Array(openSkyAircraft.prefix(50))
        for ac in limitedAircraft {
            statusViewModel.trackAircraft(
                hex: ac.hex,
                callsign: ac.flight,
                altitude: ac.altitude
            )
        }
        
        print("Updated OpenSky aircraft: \(openSkyAircraft.count) aircraft (tracking \(limitedAircraft.count))")

        if openSkyUpdateCount % 5 == 0 {
            if Settings.shared.notificationsEnabled {
                checkNearbyAircraft(openSkyAircraft)
            }
        }
        openSkyUpdateCount += 1
        if openSkyUpdateCount % 3 == 0 {
            if Settings.shared.mqttEnabled {
                publishAircraftToMQTT(openSkyAircraft)
            }
            
            if Settings.shared.takEnabled {
                publishAircraftToTAK(openSkyAircraft)
            }
        }
    }
    
    /// Handle aircraft data updates
    @MainActor
    private func handleAircraftUpdate(_ aircraft: [Aircraft]) {
        // Already on main thread from .receive(on: DispatchQueue.main)
        aircraftTracks = aircraft
        
        // Track aircraft encounters in StatusViewModel
        for ac in aircraft {
            statusViewModel.trackAircraft(
                hex: ac.hex,
                callsign: ac.flight,
                altitude: ac.altitude
            )
        }
        
        // Only run cleanup every 50 updates to avoid performance impact
        aircraftUpdateCounter += 1
        if aircraftUpdateCounter % 50 == 0 {
            Task.detached {
                await MainActor.run {
                    // Limit to 200 aircraft in storage to prevent crashes
                    SwiftDataStorageManager.shared.cleanupOldAircraftEncounters(maxAircraftCount: 200)
                }
            }
        }
        
        // Keep aircraft separate from drone messages
        
        print("Updated aircraft tracks: \(aircraft.count) aircraft")

        // Check for nearby aircraft if enabled
        if Settings.shared.notificationsEnabled {
            checkNearbyAircraft(aircraft)
        }
        
        // Publish to MQTT if enabled
        if Settings.shared.mqttEnabled {
            publishAircraftToMQTT(aircraft)
        }
        
        // Publish to TAK if enabled
        if Settings.shared.takEnabled {
            publishAircraftToTAK(aircraft)
        }
    }
    
    /// Check for nearby aircraft and send notifications
    private func checkNearbyAircraft(_ aircraft: [Aircraft]) {
        Task { @MainActor in
            guard let userLocation = LocationManager.shared.userLocation else { return }
            
            let proximityThreshold: Double = 5000 // 5km in meters
            let minAltitude: Double = 1000 // Only alert for low-flying aircraft below 1000ft
            
            // Track which aircraft have alert rings
            var activeAircraftIds = Set<String>()
            
            for ac in aircraft {
                let aircraftId = "aircraft-\(ac.hex)"
                
                // Check if aircraft has coordinates
                if let coord = ac.coordinate,
                   let altitude = ac.altitudeFeet,
                   altitude < Int(minAltitude) {
                    
                    let aircraftLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    let distance = userLocation.distance(from: aircraftLocation)
                    
                    if distance <= proximityThreshold {
                        self.sendAircraftProximityNotification(for: ac, distance: distance)
                        
                        // Create alert ring for aircraft with RSSI data
                        if let rssi = ac.rssi {
                            self.updateAircraftAlertRing(for: ac, coordinate: coord, rssi: rssi)
                            activeAircraftIds.insert(aircraftId)
                        }
                    }
                }
                // Also handle aircraft with RSSI but no coordinates (similar to drones)
                else if let rssi = ac.rssi, rssi != 0 {
                    self.updateAircraftAlertRing(for: ac, coordinate: userLocation.coordinate, rssi: rssi)
                    activeAircraftIds.insert(aircraftId)
                }
            }
            
            // Clean up alert rings for aircraft no longer in proximity or without RSSI
            self.alertRings.removeAll { ring in
                ring.droneId.hasPrefix("aircraft-") && !activeAircraftIds.contains(ring.droneId)
            }
        }
    }
    
    /// Create or update alert ring for aircraft based on RSSI
    @MainActor
    private func updateAircraftAlertRing(for aircraft: Aircraft, coordinate: CLLocationCoordinate2D, rssi: Double) {
        let aircraftId = "aircraft-\(aircraft.hex)"
        
        // Calculate distance/radius from RSSI
        // ADS-B RSSI is typically in dBFS (negative values, similar to dBm)
        let distance: Double
        
        // ADS-B RSSI is usually in dBFS format (e.g., -10 to -40)
        // Convert to approximate distance using path loss model
        if rssi >= -10 {
            distance = 100.0  // Very close, strong signal
        } else if rssi >= -20 {
            distance = 500.0  // Close
        } else if rssi >= -30 {
            distance = 1000.0  // Medium distance
        } else if rssi >= -40 {
            distance = 2000.0  // Far
        } else {
            distance = 5000.0  // Very far/weak signal
        }
        
        // Create or update alert ring
        if let index = self.alertRings.firstIndex(where: { $0.droneId == aircraftId }) {
            self.alertRings[index] = AlertRing(
                droneId: aircraftId,
                centerCoordinate: coordinate,
                radius: distance,
                rssi: Int(rssi)
            )
        } else {
            self.alertRings.append(AlertRing(
                droneId: aircraftId,
                centerCoordinate: coordinate,
                radius: distance,
                rssi: Int(rssi)
            ))
        }
        
        print("Created/Updated alert ring for aircraft \(aircraft.displayName): radius \(Int(distance))m, RSSI: \(Int(rssi))dBFS")
    }
    
    /// Send notification for nearby aircraft
    @MainActor
    private func sendAircraftProximityNotification(for aircraft: Aircraft, distance: Double) {
        // Rate limiting
        guard let lastTime = lastNotificationTime,
              Date().timeIntervalSince(lastTime) >= 10 else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Low Aircraft Detected"
        content.body = "\(aircraft.displayName) - \(Int(distance))m away - Alt: \(aircraft.altitudeFeet ?? 0)ft"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "aircraft-\(aircraft.hex)",
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Aircraft notification failed: \(error)")
            }
        }
        
        lastNotificationTime = Date()
        
        // Also send webhook if enabled
        if Settings.shared.webhooksEnabled {
            sendAircraftWebhook(for: aircraft, distance: distance)
        }
    }
    
    /// Send webhook notification for aircraft
    private func sendAircraftWebhook(for aircraft: Aircraft, distance: Double) {
        var data: [String: Any] = [
            "hex": aircraft.hex,
            "callsign": aircraft.displayName,
            "distance_meters": Int(distance),
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        if let coord = aircraft.coordinate {
            data["latitude"] = coord.latitude
            data["longitude"] = coord.longitude
        }
        
        if let altitude = aircraft.altitudeFeet {
            data["altitude_feet"] = altitude
        }
        
        if let speed = aircraft.speedKnots {
            data["speed_knots"] = speed
        }
        
        if let track = aircraft.track {
            data["track"] = track
        }
        
        // Include RSSI data if available
        if let rssi = aircraft.rssi {
            data["rssi"] = rssi
            data["rssi_dbfs"] = rssi
        }
        
        var metadata: [String: String] = [
            "detection_type": "aircraft",
            "source": "adsb"
        ]
        
        if let squawk = aircraft.squawk {
            metadata["squawk"] = squawk
        }
        
        if aircraft.isEmergency {
            metadata["emergency"] = "true"
            metadata["emergency_type"] = aircraft.emergency ?? "unknown"
        }
        
        WebhookManager.shared.sendWebhook(
            event: .droneDetected, // Could add .aircraftDetected if available
            data: data,
            metadata: metadata
        )
    }
    
    /// Publish aircraft to MQTT
    private func publishAircraftToMQTT(_ aircraft: [Aircraft]) {
        guard let mqttClient = mqttClient else { return }
        
        Task { @MainActor in
            let mqttBaseTopic = Settings.shared.mqttBaseTopic
            
            for aircraft in aircraft {
                // Rate limit per aircraft
                guard RateLimiterManager.shared.shouldAllowDronePublish(for: aircraft.hex) else {
                    continue
                }
                
                // Global MQTT rate limit
                guard RateLimiterManager.shared.shouldAllowMQTTPublish() else {
                    break // Stop publishing if global limit hit
                }
                
                do {
                    let topic = "\(mqttBaseTopic)/aircraft/\(aircraft.hex)"
                    let message = aircraft.toMQTTMessage()
                    let data = try JSONSerialization.data(withJSONObject: message)
                    
                    try await mqttClient.publish(topic: topic, payload: data)
                } catch {
                    print("MQTT aircraft publish failed: \(error)")
                }
            }
        }
    }
    
    /// Publish aircraft to TAK server
    private func publishAircraftToTAK(_ aircraft: [Aircraft]) {
        guard let takClient = takClient else { return }
        
        Task { @MainActor in
            guard case .connected = takClient.state else {
                // Silently skip if not connected - don't spam errors
                return
            }
            
            for aircraft in aircraft {
                // Rate limit per aircraft
                guard RateLimiterManager.shared.shouldAllowDronePublish(for: aircraft.hex) else {
                    continue
                }
                
                // Global TAK rate limit
                guard RateLimiterManager.shared.shouldAllowTAKPublish() else {
                    break
                }
                
                do {
                    let cotXML = aircraft.toCoTXML()
                    try await takClient.send(cotXML)
                } catch {
                    // Only log error once per session to prevent spam
                    print("TAK aircraft publish failed: \(error)")
                    return // Stop trying to send more on first error
                }
            }
        }
    }
}

