//
//  Settings.swift
//  WarDragon
//
//  Created by Luke on 11/23/24.
//

import Foundation
import SwiftUI

enum ConnectionMode: String, Codable, CaseIterable {
    case multicast = "Multicast"
    case zmq = "Direct ZMQ"
    //    case both = "Both"
    
    var icon: String {
        switch self {
        case .multicast:
            return "antenna.radiowaves.left.and.right"
        case .zmq:
            return "network"
        }
    }
}

//MARK: - Local stored vars (nothing sensitive)

@MainActor
class Settings: ObservableObject {
    static let shared = Settings()
    
    private init() {
        // Migrate sensitive data from UserDefaults to Keychain on first launch
        KeychainManager.migrateSensitiveData()
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
    
    
    
    @AppStorage("connectionMode") var connectionMode: ConnectionMode = .multicast {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("zmqHost") var zmqHost: String = "0.0.0.0" {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("multicastHost") var multicastHost: String = "239.2.3.1" {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("notificationsEnabled") var notificationsEnabled = true {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("keepScreenOn") var keepScreenOn = false {
        didSet {
            objectWillChange.send()
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
    }
    @AppStorage("enableBackgroundDetection") var enableBackgroundDetection = true {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("flightPointRetentionLimit") var flightPointRetentionLimit: Int = 1000 {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("flightPointMinIntervalSeconds") var flightPointMinIntervalSeconds: Double = 2.0 {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("flightPointMinDistanceMeters") var flightPointMinDistanceMeters: Double = 0.1 {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("backgroundDiagnosticsEnabled") var backgroundDiagnosticsEnabled = false {
        didSet {
            objectWillChange.send()
            if backgroundDiagnosticsEnabled {
                BackgroundDiagnostics.shared.startHeartbeat()
                PerfHeartbeat.shared.start()
                MainThreadWatchdog.shared.start()
            } else {
                MainThreadWatchdog.shared.stop()
            }
        }
    }
    @AppStorage("multicastPort") var multicastPort: Int = 6969 {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("zmqTelemetryPort") var zmqTelemetryPort: Int = 4224 {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("zmqStatusPort") var zmqStatusPort: Int = 4225 {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("isListening") var isListening = false {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("spoofDetectionEnabled") var spoofDetectionEnabled = true {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("zmqSpectrumPort") var zmqSpectrumPort: Int = 4226 {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("zmqHostHistory") var zmqHostHistoryJson: String = "[]" {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("multicastHostHistory") var multicastHostHistoryJson: String = "[]" {
        didSet {
            objectWillChange.send()
        }
    }
    // MARK: - Status Notification Settings
    @AppStorage("statusNotificationsEnabled") var statusNotificationsEnabled = true {
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("statusNotificationInterval") var statusNotificationInterval: StatusNotificationInterval = .never {
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("statusNotificationThresholds") var statusNotificationThresholds = true {
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("lastStatusNotificationTime") private var lastStatusNotificationTimestamp: Double = 0
    
    var lastStatusNotificationTime: Date {
        get {
            Date(timeIntervalSince1970: lastStatusNotificationTimestamp)
        }
        set {
            lastStatusNotificationTimestamp = newValue.timeIntervalSince1970
        }
    }
    
    func updateStatusNotificationSettings(
        enabled: Bool,
        interval: StatusNotificationInterval,
        thresholds: Bool
    ) {
        statusNotificationsEnabled = enabled
        statusNotificationInterval = interval
        statusNotificationThresholds = thresholds
    }
    
    func shouldSendStatusNotification() -> Bool {
        guard statusNotificationsEnabled else { return false }
        
        let now = Date()
        let timeSinceLastNotification = now.timeIntervalSince(lastStatusNotificationTime)
        
        switch statusNotificationInterval {
        case .never:
            return false
        case .always:
            return true  // Always send status notifications
        case .thresholdOnly:
            return false  // Don't send regular status updates, only thresholds
        case .every5Minutes:
            return timeSinceLastNotification >= 300
        case .every15Minutes:
            return timeSinceLastNotification >= 900
        case .every30Minutes:
            return timeSinceLastNotification >= 1800
        case .hourly:
            return timeSinceLastNotification >= 3600
        case .every2Hours:
            return timeSinceLastNotification >= 7200
        case .every6Hours:
            return timeSinceLastNotification >= 21600
        case .daily:
            return timeSinceLastNotification >= 86400
        }
    }
    // MARK: - Webhook Settings
    @AppStorage("webhooksEnabled") var webhooksEnabled = false {
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("webhookEvents") private var webhookEventsJson = "" {
        didSet {
            objectWillChange.send()
        }
    }
    
    var enabledWebhookEvents: Set<WebhookEvent> {
        get {
            if let data = webhookEventsJson.data(using: .utf8),
               let events = try? JSONDecoder().decode(Set<WebhookEvent>.self, from: data) {
                return events
            }
            return Set(WebhookEvent.allCases) // Default to all events enabled
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                webhookEventsJson = json
            }
        }
    }
    
    func updateWebhookSettings(enabled: Bool, events: Set<WebhookEvent>? = nil) {
        webhooksEnabled = enabled
        if let events = events {
            enabledWebhookEvents = events
        }
    }
    //MARK: - Warning Thresholds
    @AppStorage("cpuWarningThreshold") var cpuWarningThreshold: Double = 80.0 {  // 80% CPU
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("tempWarningThreshold") var tempWarningThreshold: Double = 70.0 {  // 70°C
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("memoryWarningThreshold") var memoryWarningThreshold: Double = 0.85 {  // 85%
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("plutoTempThreshold") var plutoTempThreshold: Double = 85.0 {  // 85°C
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("zynqTempThreshold") var zynqTempThreshold: Double = 85.0 {  // 85°C
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("proximityThreshold") var proximityThreshold: Int = -60 {  // -60 dBm
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("enableWarnings") var enableWarnings = true {
        didSet {
            objectWillChange.send()
        }
    }
    
    @AppStorage("systemWarningsEnabled") var systemWarningsEnabled = true {
        didSet {
            objectWillChange.send()
        }
    }
    @AppStorage("enableProximityWarnings") var enableProximityWarnings = true
    @AppStorage("useUserLocationForStatus") var useUserLocationForStatus = false {
        didSet { objectWillChange.send() }
    }

    @AppStorage("hasShownStatusLocationPrompt") var hasShownStatusLocationPrompt = false {
        didSet { objectWillChange.send() }
    }

    // MARK: - TAK Server Settings
    @AppStorage("takEnabled") var takEnabled = false {
        didSet {
            objectWillChange.send()
            setupTAKClient()
        }
    }
    
    @AppStorage("takHost") var takHost: String = "" {
        didSet {
            objectWillChange.send()
            setupTAKClient()
        }
    }
    
    @AppStorage("takPort") var takPort: Int = 8089 {
        didSet {
            objectWillChange.send()
            setupTAKClient()
        }
    }
    
    @AppStorage("takProtocol") private var takProtocolRaw: String = TAKProtocol.tls.rawValue {
        didSet {
            objectWillChange.send()
            setupTAKClient()
        }
    }
    
    var takProtocol: TAKProtocol {
        get { TAKProtocol(rawValue: takProtocolRaw) ?? .tls }
        set { takProtocolRaw = newValue.rawValue }
    }
    
    // Certificate mode removed - enrollment is now the only option for TLS
    
    @AppStorage("takEnrollmentUsername") var takEnrollmentUsername: String = "" {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("takTLSEnabled") var takTLSEnabled = true {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("takSkipVerification") var takSkipVerification = false {
        didSet { objectWillChange.send() }
    }
    
    // Enrollment password stored securely in Keychain
    var takEnrollmentPassword: String {
        get {
            (try? KeychainManager.shared.loadString(forKey: "takEnrollmentPassword")) ?? ""
        }
        set {
            if newValue.isEmpty {
                try? KeychainManager.shared.delete(key: "takEnrollmentPassword")
            } else {
                try? KeychainManager.shared.save(newValue, forKey: "takEnrollmentPassword")
            }
            objectWillChange.send()
        }
    }
    
    var takConfiguration: TAKConfiguration {
        get {
            TAKConfiguration(
                enabled: takEnabled,
                host: takHost,
                port: takPort,
                protocol: takProtocol,
                enrollmentUsername: takEnrollmentUsername.isEmpty ? nil : takEnrollmentUsername,
                enrollmentPassword: takEnrollmentPassword.isEmpty ? nil : takEnrollmentPassword,
                tlsEnabled: takTLSEnabled,
                skipVerification: takSkipVerification
            )
        }
        set {
            takEnabled = newValue.enabled
            takHost = newValue.host
            takPort = newValue.port
            takProtocol = newValue.protocol
            takEnrollmentUsername = newValue.enrollmentUsername ?? ""
            takEnrollmentPassword = newValue.enrollmentPassword ?? ""
            takTLSEnabled = newValue.tlsEnabled
            takSkipVerification = newValue.skipVerification
            
            setupTAKClient()
        }
    }
    
    var _takClient: TAKClient?
    var _takEnrollmentManager: TAKEnrollmentManager?
    
    var takClient: TAKClient? {
        if _takClient == nil && takEnabled {
            setupTAKClient()
        }
        return _takClient
    }
    
    private func setupTAKClient() {
        _takClient?.disconnect()
        _takClient = nil
        _takEnrollmentManager = nil
        
        guard takEnabled else {
            return
        }
        
        if takProtocol == .tls {
            _takEnrollmentManager = TAKEnrollmentManager()
        }
        
        _takClient = TAKClient(configuration: takConfiguration, enrollmentManager: _takEnrollmentManager)
        _takClient?.connect()
    }
    
    func updateTAKConfiguration(_ config: TAKConfiguration) {
        takConfiguration = config
    }
    
    // MARK: - MQTT Settings
    @AppStorage("mqttEnabled") var mqttEnabled = false {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttHost") var mqttHost: String = "" {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttPort") var mqttPort: Int = 1883 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttUseTLS") var mqttUseTLS = false {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttUsername") var mqttUsername: String = "" {
        didSet { objectWillChange.send() }
    }
    
    // MQTT password stored securely in Keychain
    var mqttPassword: String {
        get {
            (try? KeychainManager.shared.loadString(forKey: "mqttPassword")) ?? ""
        }
        set {
            if newValue.isEmpty {
                try? KeychainManager.shared.delete(key: "mqttPassword")
            } else {
                try? KeychainManager.shared.save(newValue, forKey: "mqttPassword")
            }
            objectWillChange.send()
        }
    }
    
    @AppStorage("mqttBaseTopic") var mqttBaseTopic: String = "wardragon" {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttQoS") private var mqttQoSRaw: Int = 1 {
        didSet { objectWillChange.send() }
    }
    
    var mqttQoS: MQTTQoS {
        get { MQTTQoS(rawValue: mqttQoSRaw) ?? .atLeastOnce }
        set { mqttQoSRaw = newValue.rawValue }
    }
    
    @AppStorage("mqttRetain") var mqttRetain = false {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttCleanSession") var mqttCleanSession = true {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttHomeAssistantEnabled") var mqttHomeAssistantEnabled = false {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttHomeAssistantDiscoveryPrefix") var mqttHomeAssistantDiscoveryPrefix: String = "homeassistant" {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttKeepalive") var mqttKeepalive: Int = 60 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("mqttReconnectDelay") var mqttReconnectDelay: Int = 5 {
        didSet { objectWillChange.send() }
    }
    
    var mqttConfiguration: MQTTConfiguration {
        get {
            MQTTConfiguration(
                enabled: mqttEnabled,
                host: mqttHost,
                port: mqttPort,
                useTLS: mqttUseTLS,
                username: mqttUsername.isEmpty ? nil : mqttUsername,
                password: mqttPassword.isEmpty ? nil : mqttPassword,
                baseTopic: mqttBaseTopic,
                droneTopicTemplate: "{base}/drones/{mac}",
                systemTopic: "{base}/system",
                statusTopic: "{base}/status",
                qos: mqttQoS,
                retain: mqttRetain,
                cleanSession: mqttCleanSession,
                homeAssistantEnabled: mqttHomeAssistantEnabled,
                homeAssistantDiscoveryPrefix: mqttHomeAssistantDiscoveryPrefix,
                keepalive: mqttKeepalive,
                reconnectDelay: mqttReconnectDelay
            )
        }
        set {
            mqttEnabled = newValue.enabled
            mqttHost = newValue.host
            mqttPort = newValue.port
            mqttUseTLS = newValue.useTLS
            mqttUsername = newValue.username ?? ""
            mqttPassword = newValue.password ?? ""
            mqttBaseTopic = newValue.baseTopic
            mqttQoS = newValue.qos
            mqttRetain = newValue.retain
            mqttCleanSession = newValue.cleanSession
            mqttHomeAssistantEnabled = newValue.homeAssistantEnabled
            mqttHomeAssistantDiscoveryPrefix = newValue.homeAssistantDiscoveryPrefix
            mqttKeepalive = newValue.keepalive
            mqttReconnectDelay = newValue.reconnectDelay
        }
    }
    
    func updateMQTTConfiguration(_ config: MQTTConfiguration) {
        mqttConfiguration = config
    }
    
    // MARK: - ADS-B Settings
    @AppStorage("adsbEnabled") var adsbEnabled = false {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbReadsbURL") var adsbReadsbURL: String = "http://localhost:8080" {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbDataPath") var adsbDataPath: String = "/data/aircraft.json" {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbPollInterval") var adsbPollInterval: Double = 2.0 {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbMaxDistance") var adsbMaxDistance: Double = 0 {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbMaxAircraftCount") var adsbMaxAircraftCount: Int = 25 {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbMinAltitude") var adsbMinAltitude: Double = 0 {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbMaxAltitude") var adsbMaxAltitude: Double = 50000 {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("adsbFlightPathRetentionMinutes") var adsbFlightPathRetentionMinutes: Double = 30.0 {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .adsbSettingsChanged, object: nil)
        }
    }
    
    var adsbConfiguration: ADSBConfiguration {
        get {
            ADSBConfiguration(
                enabled: adsbEnabled,
                readsbURL: adsbReadsbURL.trimmingCharacters(in: .whitespacesAndNewlines),
                dataPath: adsbDataPath.trimmingCharacters(in: .whitespacesAndNewlines),
                pollInterval: adsbPollInterval,
                maxDistance: adsbMaxDistance > 0 ? adsbMaxDistance : nil,
                minAltitude: adsbMinAltitude > 0 ? adsbMinAltitude : nil,
                maxAltitude: adsbMaxAltitude < 50000 ? adsbMaxAltitude : nil,
                maxAircraftCount: adsbMaxAircraftCount,
                flightPathRetentionMinutes: adsbFlightPathRetentionMinutes
            )
        }
        set {
            adsbEnabled = newValue.enabled
            adsbReadsbURL = newValue.readsbURL
            adsbDataPath = newValue.dataPath
            adsbPollInterval = newValue.pollInterval
            adsbMaxDistance = newValue.maxDistance ?? 0
            adsbMinAltitude = newValue.minAltitude ?? 0
            adsbMaxAltitude = newValue.maxAltitude ?? 50000
            adsbMaxAircraftCount = newValue.maxAircraftCount
            adsbFlightPathRetentionMinutes = newValue.flightPathRetentionMinutes
        }
    }
    
    func updateADSBConfiguration(_ config: ADSBConfiguration) {
        adsbConfiguration = config
    }
    
    
    // MARK: - Lattice Settings
    @AppStorage("latticeEnabled") var latticeEnabled = false {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .latticeSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("latticeServerURL") var latticeServerURL: String = "https://sandbox.lattice-das.com" {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .latticeSettingsChanged, object: nil)
        }
    }
    
    var latticeAPIToken: String {
        get {
            (try? KeychainManager.shared.loadString(forKey: "latticeAPIToken")) ?? ""
        }
        set {
            if newValue.isEmpty {
                try? KeychainManager.shared.delete(key: "latticeAPIToken")
            } else {
                try? KeychainManager.shared.save(newValue, forKey: "latticeAPIToken")
            }
            objectWillChange.send()
        }
    }
    
    @AppStorage("latticeOrganizationID") var latticeOrganizationID: String = "" {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .latticeSettingsChanged, object: nil)
        }
    }
    
    @AppStorage("latticeSiteID") var latticeSiteID: String = "" {
        didSet {
            objectWillChange.send()
            NotificationCenter.default.post(name: .latticeSettingsChanged, object: nil)
        }
    }
    
    var latticeConfiguration: LatticeClient.LatticeConfiguration {
        get {
            LatticeClient.LatticeConfiguration(
                enabled: latticeEnabled,
                serverURL: latticeServerURL.trimmingCharacters(in: .whitespacesAndNewlines),
                apiToken: latticeAPIToken.isEmpty ? nil : latticeAPIToken,
                organizationID: latticeOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines),
                siteID: latticeSiteID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        set {
            latticeEnabled = newValue.enabled
            latticeServerURL = newValue.serverURL
            latticeAPIToken = newValue.apiToken ?? ""
            latticeOrganizationID = newValue.organizationID
            latticeSiteID = newValue.siteID
        }
    }
    
    func updateLatticeConfiguration(_ config: LatticeClient.LatticeConfiguration) {
        latticeConfiguration = config
    }
    
    // MARK: - Detection Limits (matching Python DragonSync)
    @AppStorage("maxDrones") var maxDrones: Int = 30 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("maxAircraft") var maxAircraft: Int = 100 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("inactivityTimeout") var inactivityTimeout: Double = 60.0 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("persistDroneDetections") var persistDroneDetections: Bool = true {
        didSet { objectWillChange.send() }
    }
    
    // MARK: - Rate Limiting Settings
    @AppStorage("rateLimitEnabled") var rateLimitEnabled = false {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitDroneInterval") var rateLimitDroneInterval: Double = 1.0 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitDroneMaxPerMinute") var rateLimitDroneMaxPerMinute: Int = 30 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitMQTTMaxPerSecond") var rateLimitMQTTMaxPerSecond: Int = 10 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitMQTTBurstCount") var rateLimitMQTTBurstCount: Int = 20 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitMQTTBurstPeriod") var rateLimitMQTTBurstPeriod: Double = 5.0 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitTAKMaxPerSecond") var rateLimitTAKMaxPerSecond: Int = 5 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitTAKInterval") var rateLimitTAKInterval: Double = 0.5 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitWebhookMaxPerMinute") var rateLimitWebhookMaxPerMinute: Int = 20 {
        didSet { objectWillChange.send() }
    }
    
    @AppStorage("rateLimitWebhookInterval") var rateLimitWebhookInterval: Double = 2.0 {
        didSet { objectWillChange.send() }
    }
    
    var rateLimitConfiguration: RateLimitConfiguration {
        get {
            RateLimitConfiguration(
                enabled: rateLimitEnabled,
                dronePublishInterval: rateLimitDroneInterval,
                droneMaxPerMinute: rateLimitDroneMaxPerMinute,
                mqttMaxPerSecond: rateLimitMQTTMaxPerSecond,
                mqttBurstCount: rateLimitMQTTBurstCount,
                mqttBurstPeriod: rateLimitMQTTBurstPeriod,
                takMaxPerSecond: rateLimitTAKMaxPerSecond,
                takPublishInterval: rateLimitTAKInterval,
                webhookMaxPerMinute: rateLimitWebhookMaxPerMinute,
                webhookPublishInterval: rateLimitWebhookInterval
            )
        }
        set {
            rateLimitEnabled = newValue.enabled
            rateLimitDroneInterval = newValue.dronePublishInterval
            rateLimitDroneMaxPerMinute = newValue.droneMaxPerMinute
            rateLimitMQTTMaxPerSecond = newValue.mqttMaxPerSecond
            rateLimitMQTTBurstCount = newValue.mqttBurstCount
            rateLimitMQTTBurstPeriod = newValue.mqttBurstPeriod
            rateLimitTAKMaxPerSecond = newValue.takMaxPerSecond
            rateLimitTAKInterval = newValue.takPublishInterval
            rateLimitWebhookMaxPerMinute = newValue.webhookMaxPerMinute
            rateLimitWebhookInterval = newValue.webhookPublishInterval
        }
    }
    
    func updateRateLimitConfiguration(_ config: RateLimitConfiguration) {
        rateLimitConfiguration = config
    }
    
    //MARK: - Connection
    
    func updateConnection(mode: ConnectionMode, host: String? = nil, isZmqHost: Bool = false) {
        if let host = host {
            if isZmqHost {
                zmqHost = host
            } else {
                multicastHost = host
            }
        }
        connectionMode = mode
    }

    func updateStatusLocationSettings(useLocation: Bool) {
        useUserLocationForStatus = useLocation
        hasShownStatusLocationPrompt = true
    }

    func isHostConfigurationValid() -> Bool {
        switch connectionMode {
        case .multicast:
            return !multicastHost.isEmpty
        case .zmq:
            return !zmqHost.isEmpty
        }
    }
    
    func toggleListening(_ active: Bool) {
        if active == isListening {
            return
        }
        
        print("Settings: Toggle listening to \(active)")
        isListening = active
        objectWillChange.send()
    }
    
    var zmqHostHistory: [String] {
        get {
            guard let data = zmqHostHistoryJson.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return array
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                zmqHostHistoryJson = json
            }
        }
    }

    var multicastHostHistory: [String] {
        get {
            guard let data = multicastHostHistoryJson.data(using: .utf8),
                  let array = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return array
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                multicastHostHistoryJson = json
            }
        }
    }

    
    func updateConnectionHistory(host: String, isZmq: Bool) {
        if isZmq {
            var history = zmqHostHistory
            history.removeAll { $0 == host }
            history.insert(host, at: 0)
            if history.count > 5 {
                history = Array(history.prefix(5))
            }
            zmqHostHistory = history
        } else {
            var history = multicastHostHistory
            history.removeAll { $0 == host }
            history.insert(host, at: 0)
            if history.count > 5 {
                history = Array(history.prefix(5))
            }
            multicastHostHistory = history
        }
    }
    
    func updatePreferences(notifications: Bool, screenOn: Bool) {
        notificationsEnabled = notifications
        keepScreenOn = screenOn
    }
    
    func updateWarningThresholds(
        cpu: Double? = nil,
        temp: Double? = nil,
        memory: Double? = nil,
        plutoTemp: Double? = nil,
        zynqTemp: Double? = nil,
        proximity: Int? = nil
    ) {
        if let cpu = cpu { cpuWarningThreshold = cpu }
        if let temp = temp { tempWarningThreshold = temp }
        if let memory = memory { memoryWarningThreshold = memory }
        if let plutoTemp = plutoTemp { plutoTempThreshold = plutoTemp }
        if let zynqTemp = zynqTemp { zynqTempThreshold = zynqTemp }
        if let proximity = proximity { proximityThreshold = proximity }
        objectWillChange.send()
    }
}
// MARK: - Notification Names
extension Notification.Name {
    static let adsbSettingsChanged = Notification.Name("adsbSettingsChanged")
    static let latticeSettingsChanged = Notification.Name("latticeSettingsChanged")
}

