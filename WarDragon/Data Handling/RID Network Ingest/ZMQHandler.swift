//
//  ZMQHandler.swift
//  WarDragon
//  Created by Root Down Digital on 11/25/24.
//

import Foundation
import SwiftyZeroMQ5


class ZMQHandler: ObservableObject {
    @Published var messageFormat: MessageFormat = .bluetooth
    var isInBackgroundMode = false
    static let shared = ZMQHandler()
    
    private var context: SwiftyZeroMQ.Context?
    private var telemetrySocket: SwiftyZeroMQ.Socket?
    private var statusSocket: SwiftyZeroMQ.Socket?
    private var poller: SwiftyZeroMQ.Poller?
    private var pollingQueue: DispatchQueue?
    private var shouldContinueRunning = false
    private var lastHost = ""
    private var lastTelemetryPort: UInt16 = 0
    private var lastStatusPort: UInt16 = 0
    private var lastTelemetryHandler: MessageHandler = { _ in }
    private var lastStatusHandler: MessageHandler = { _ in }
    private var lastMessageTime: Date = Date()
    private let subscriptionTimeout: TimeInterval = 120
    private var isSubscriptionActive = true
    private var connectionMonitorTimer: Timer?
    private let connectionCheckInterval: TimeInterval = 30
    private var pollingLock = NSLock()
    private var isPollingActive = false
    // Signaled by the polling loop when it exits. disconnect() waits on this
    // off-main so it never blocks the UI. Recreated on each connect().
    private var pollingExitSemaphore: DispatchSemaphore?
    
    // Status message deduplication - track last message per serial number
    private var lastStatusMessageBySN: [String: (timestamp: Date, jsonString: String)] = [:]
    private let statusDedupeInterval: TimeInterval = 1.0  // Don't send duplicate within 1 second
    
    typealias MessageHandler = (String) -> Void
    
    @Published var isConnected = false {
        didSet {
            if oldValue != isConnected {
                DispatchQueue.main.async {
                    Settings.shared.isListening = self.isConnected
                }
            }
        }
    }
    
    enum MessageFormat {
        case wifi
        case bluetooth
        case sdr
        case fpv
    }

    // MARK: - droneid-go backend health
    @Published var backendHealth: DroneidGoHealth?

    struct DroneidGoHealth: Equatable {
        var enabled: Bool
        var state: String
        var stateString: String
        var connectedSince: Date?
        var lastMessageTime: Date?
        var lastErrorTime: Date?
        var lastError: String
        var connectAttempts: Int
        var messagesTotal: Int
        var messagesPerSec: Double
        var errorsTotal: Int
        var errorsRecent: Int
        var uptimeSeconds: Double
        var sources: [String: DroneidGoHealth]
        var receivedAt: Date
    }
    
    private let manufacturerMapping: [Int: String] = [
        1187: "Ruko",
    ]
    
    public let macPrefixesByManufacturer: [String: [String]] = [
        "DJI": [
            "04:A8:5A",
            "34:D2:62",
            "48:1C:B9",
            "58:B8:58",
            "60:60:1F",  // Mavic 1 Pro
            "E4:7A:2C",
            "9C:5A:8A" // Check this one
        ],
        "Parrot": [
            "00:12:1C",
            "00:26:7E",  // AR Drone and AR Drone 2.0
            "90:03:B7",  // AR Drone 2.0
            "90:3A:E6",
            "A0:14:3D"   // Jumping Sumo and SkyController
        ],
        "GuangDong Syma": [
            "58:04:54"
        ],
        "Skydio": [
            "38:1D:14"
        ],
        "Autel": [
            "EC:5B:CD",
            "18:D7:93" // Check this
        ],
        "Yuneec": [
            "E0:B6:F5"
        ],
        "Hubsan": [
            "98:AA:FC"
        ],
        "Holy Stone": [
            "00:0C:BF",
            "18:65:6A"
        ],
        "Ruko": [
            "E0:4E:7A"
        ],
        "PowerVision": [
            "54:7D:40"
        ],
        "Teal": [
            "B0:30:C8"
        ],
        "UAV Navigation": [
            "00:50:C2",
            "B4:4D:43"
        ],
        "Amimon": [
            "0C:D6:96"
        ],
        "Baiwang": [
            "9C:5A:8A"
        ],
        "Bilian": [
            "08:EA:40", "0C:8C:24", "0C:CF:89", "10:A4:BE", "14:5D:34", "14:6B:9C", "20:32:33", "20:F4:1B", "28:F3:66", "2C:C3:E6", "30:7B:C9", "34:7D:E4", "38:01:46", "38:7A:CC", "3C:33:00", "44:01:BB", "44:33:4C", "54:EF:33", "60:FB:00", "74:EE:2A", "78:22:88", "7C:A7:B0", "98:03:CF", "A0:9F:10", "AC:A2:13", "B4:6D:C2", "C4:3C:B0", "C8:FE:0F", "CC:64:1A", "E0:B9:4D", "EC:3D:FD", "F0:C8:14", "FC:23:CD"
        ]
    ]
    

    func connect(host: String, zmqTelemetryPort: UInt16, zmqStatusPort: UInt16, onTelemetry: @escaping MessageHandler, onStatus: @escaping MessageHandler) {
        // Store parameters for reconnection
        self.lastHost = host
        self.lastTelemetryPort = zmqTelemetryPort
        self.lastStatusPort = zmqStatusPort
        self.lastTelemetryHandler = onTelemetry
        self.lastStatusHandler = onStatus
        
        guard !host.isEmpty && zmqTelemetryPort > 0 && zmqStatusPort > 0 else {
            print("ZMQ: Invalid connection parameters")
            return
        }
        
        guard !isConnected else {
            print("ZMQ: Already connected")
            return
        }
        
        // Ensure we're fully disconnected before connecting. disconnect() now
        // performs its own off-main wait on the polling-exit semaphore, so no
        // extra Thread.sleep is needed here.
        if telemetrySocket != nil || statusSocket != nil || context != nil || poller != nil {
            print("ZMQ: Cleaning up previous connection state before reconnecting")
            disconnect()
        }

        shouldContinueRunning = true
        pollingExitSemaphore = DispatchSemaphore(value: 0)
        
        do {
            // Initialize context and poller
            context = try SwiftyZeroMQ.Context()
            guard let context = context else {
                throw NSError(domain: "ZMQHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create ZMQ context"])
            }
            
            poller = SwiftyZeroMQ.Poller()
            guard let poller = poller else {
                throw NSError(domain: "ZMQHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create ZMQ poller"])
            }
            
            // Setup telemetry socket
            telemetrySocket = try context.socket(.subscribe)
            guard let telemetrySocket = telemetrySocket else {
                throw NSError(domain: "ZMQHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create telemetry socket"])
            }
            try telemetrySocket.setSubscribe("")
            try configureSocket(telemetrySocket)
            try telemetrySocket.connect("tcp://\(host):\(zmqTelemetryPort)")
            try poller.register(socket: telemetrySocket, flags: .pollIn)
            print("ZMQ: Telemetry socket connected to tcp://\(host):\(zmqTelemetryPort)")
            
            // Setup status socket
            statusSocket = try context.socket(.subscribe)
            guard let statusSocket = statusSocket else {
                throw NSError(domain: "ZMQHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create status socket"])
            }
            try statusSocket.setSubscribe("")
            try configureSocket(statusSocket)
            try statusSocket.connect("tcp://\(host):\(zmqStatusPort)")
            try poller.register(socket: statusSocket, flags: .pollIn)
            print("ZMQ: Status socket connected to tcp://\(host):\(zmqStatusPort)")
            
            // Start polling on background queue
            pollingQueue = DispatchQueue(label: "com.wardragon.zmq.polling")
            startPolling(onTelemetry: onTelemetry, onStatus: onStatus)
            
            isConnected = true
            isSubscriptionActive = true
            print("ZMQ: Connected successfully")
            BackgroundDiagnostics.shared.log(.socket, "zmq connected",
                                             "tcp://\(host):\(zmqTelemetryPort),\(zmqStatusPort)")
            
            // Start connection monitoring
            startConnectionMonitoring()
            
        } catch {
            print("ZMQ Setup Error: \(error)")
            BackgroundDiagnostics.shared.log(.socket, "zmq connect failed", String(describing: error))
            disconnect()
        }
    }
    
    private func startConnectionMonitoring() {
        connectionMonitorTimer?.invalidate()
        
        connectionMonitorTimer = Timer.scheduledTimer(withTimeInterval: connectionCheckInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }

            if self.isInBackgroundMode {
                return
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.checkConnectionStatus()
            }
        }
        
        if let timer = connectionMonitorTimer {
            RunLoop.main.add(timer, forMode: .default)
        }
    }
    
    private func checkConnectionStatus() {
        guard isConnected,
              pollingLock.try() else {
            return
        }
        
        defer { pollingLock.unlock() }
        
        guard !isPollingActive,
              let poller = self.poller,
              telemetrySocket != nil,
              statusSocket != nil else {
            print("ZMQ: Invalid connection state during check")
            DispatchQueue.main.async { [weak self] in
                self?.reconnect()
            }
            return
        }
        
        do {
            isPollingActive = true
            _ = try poller.poll(timeout: 50)
            isPollingActive = false

            // poll() reports one entry per registered socket regardless of
            // events, so emptiness proves nothing. Staleness does.
            let silence = Date().timeIntervalSince(lastMessageTime)
            if silence > subscriptionTimeout {
                print("ZMQ: No traffic for \(Int(silence))s, reconnecting")
                DispatchQueue.main.async { [weak self] in
                    self?.reconnect()
                }
            }
        } catch let error as SwiftyZeroMQ.ZeroMQError {
            isPollingActive = false
            if error.description != "Resource temporarily unavailable" &&
               error.description != "Operation would block" {
                print("ZMQ: Connection check failed: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.reconnect()
                }
            }
        } catch {
            isPollingActive = false
            print("ZMQ: Connection check failed: \(error)")
            DispatchQueue.main.async { [weak self] in
                self?.reconnect()
            }
        }
    }
    
    func setBackgroundMode(_ enabled: Bool) {
        isInBackgroundMode = enabled
        print("ZMQ Background mode \(enabled ? "enabled" : "disabled")")

        // ZMQ socket options are not thread-safe; mutating them while the
        // polling thread is mid-recv is undefined behavior. Serialize against
        // the polling loop via pollingLock.
        let timeout: Int32 = enabled ? 2000 : 500
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            self.pollingLock.lock()
            defer { self.pollingLock.unlock() }
            try? self.telemetrySocket?.setRecvTimeout(timeout)
            try? self.statusSocket?.setRecvTimeout(timeout)
        }

        if Thread.isMainThread {
            DispatchQueue.global(qos: .utility).async(execute: apply)
        } else {
            apply()
        }
    }
    
    private func configureSocket(_ socket: SwiftyZeroMQ.Socket) throws {
        try socket.setRecvHighWaterMark(500)
        try socket.setLinger(0)
        try socket.setRecvTimeout(500)
        try socket.setImmediate(true)
        try socket.setIntegerSocketOption(ZMQ_TCP_KEEPALIVE, 1)
        try socket.setIntegerSocketOption(ZMQ_TCP_KEEPALIVE_IDLE, 120)
        try socket.setIntegerSocketOption(ZMQ_TCP_KEEPALIVE_INTVL, 60)
    }
    
    private func startPolling(onTelemetry: @escaping MessageHandler, onStatus: @escaping MessageHandler) {
        pollingQueue?.async { [weak self] in
            guard let self = self else { return }
            
            while self.shouldContinueRunning {
                autoreleasepool {
                    guard self.pollingLock.try() else {
                        Thread.sleep(forTimeInterval: 0.01)
                        return
                    }
                    
                    defer { self.pollingLock.unlock() }
                    
                    guard let poller = self.poller,
                          self.telemetrySocket != nil,
                          self.statusSocket != nil else {
                        Thread.sleep(forTimeInterval: 0.1)
                        return
                    }
                    
                    do {
                        let pollTimeout: Double = self.isInBackgroundMode ? 2000 : 100
                        self.isPollingActive = true
                        let items = try poller.poll(timeout: pollTimeout)
                        self.isPollingActive = false
                        
                        for (socket, events) in items {
                            if events.contains(.pollIn) {
                                if let data = try socket.recv(bufferLength: 32768),
                                   let jsonString = String(data: data, encoding: .utf8) {
                                    
                                    self.lastMessageTime = Date()
                                    self.isSubscriptionActive = true
                                    
                                    if socket === self.telemetrySocket {
                                        BackgroundDiagnostics.shared.recordPacket(.zmqTelemetry)
                                        // Try to convert any telemetry message to XML
                                        print("ZMQ: Received telemetry data (\(jsonString.count) bytes)")
                                        let xmlMessages = self.convertTelemetryToXMLArray(jsonString)
                                        if !xmlMessages.isEmpty {
                                            print("ZMQ: Converted to \(xmlMessages.count) XML message(s), dispatching to handler")
                                            DispatchQueue.main.async {
                                                for xmlMessage in xmlMessages {
                                                    onTelemetry(xmlMessage)
                                                }
                                            }
                                        } else {
                                            print("ZMQ: ⚠️ Conversion returned empty array - message skipped")
                                            print("ZMQ: First 200 chars: \(jsonString.prefix(200))")
                                        }
                                    } else if socket === self.statusSocket {
                                        BackgroundDiagnostics.shared.recordPacket(.zmqStatus)
                                        // Deduplicate status messages
                                        if self.shouldDispatchStatusMessage(jsonString) {
                                            print("ZMQ: Status JSON received, dispatching to CoTViewModel")
                                            DispatchQueue.main.async {
                                                onStatus(jsonString)
                                            }
                                        } else {
                                            print("ZMQ: Status message deduplicated (too soon after last)")
                                        }
                                    }
                                }
                            }
                        }
                        
                        if self.isInBackgroundMode {
                            Thread.sleep(forTimeInterval: 0.5)
                        }
                        
                    } catch let error as SwiftyZeroMQ.ZeroMQError {
                        self.isPollingActive = false
                        if error.description != "Resource temporarily unavailable" &&
                           error.description != "Operation would block" &&
                           self.shouldContinueRunning {
                            print("ZMQ Polling Error: \(error)")
                            BackgroundDiagnostics.shared.log(.socket, "zmq poll error", error.description)
                            if self.shouldContinueRunning && self.isConnected {
                                DispatchQueue.main.async {
                                    self.reconnect()
                                }
                                return
                            }
                        }
                    } catch {
                        self.isPollingActive = false
                        if self.shouldContinueRunning {
                            print("ZMQ Polling Error: \(error)")
                        }
                    }
                }
            }
            
            print("ZMQ: Polling stopped")
            self.pollingExitSemaphore?.signal()
        }
    }
    
    //MARK: - Message Deduplication
    
    func clearCaches() {
        lastStatusMessageBySN.removeAll()
        print("ZMQ: Cleared deduplication caches")
    }
    
    private func shouldDispatchStatusMessage(_ jsonString: String) -> Bool {
        // Extract serial number from JSON to use as key
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serialNumber = json["serial_number"] as? String else {
            // If we can't parse it, let it through - the parser will handle it
            return true
        }
        
        let now = Date()
        
        // Check if we've seen this serial number recently
        if let lastMessage = lastStatusMessageBySN[serialNumber] {
            let timeSinceLastMessage = now.timeIntervalSince(lastMessage.timestamp)
            
            // If less than deduplication interval, check if content is identical
            if timeSinceLastMessage < statusDedupeInterval {
                // If the content is exactly the same, skip it
                if lastMessage.jsonString == jsonString {
                    return false
                }
                // If content changed, allow it through (rapid update is legitimate)
            }
        }
        
        // Update tracking
        lastStatusMessageBySN[serialNumber] = (timestamp: now, jsonString: jsonString)
        
        // Clean up old entries (keep only last 10 devices)
        if lastStatusMessageBySN.count > 10 {
            let sortedKeys = lastStatusMessageBySN.sorted { $0.value.timestamp < $1.value.timestamp }.map { $0.key }
            for key in sortedKeys.prefix(lastStatusMessageBySN.count - 10) {
                lastStatusMessageBySN.removeValue(forKey: key)
            }
        }
        
        return true
    }
    
    //MARK: - Message Parsing & Conversion

    var status = ""
    var direction = 0.0
    var alt_pressure = 0.0
    var horiz_acc = 0
    var vert_acc = ""
    var baro_acc = 0
    var speed_acc = 0
    var timestamp = 0
    
    func convertTelemetryToXML(_ jsonString: String) -> String? {
        let results = convertTelemetryToXMLArray(jsonString)
        return results.first
    }
    
    func convertTelemetryToXMLArray(_ jsonString: String) -> [String] {
        guard let data = jsonString.data(using: .utf8) else {
            print("ZMQ: Failed to convert string to UTF8 data")
            return []
        }

        if let healthObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           isDroneidGoHealthMessage(healthObj) {
            print("ZMQ: Detected health/heartbeat message, ingesting")
            ingestDroneidGoHealth(healthObj)
            return []
        }

        // Determine message format
        if jsonString.contains("fpv") {
            messageFormat = .fpv
            print("ZMQ: Detected FPV message format")
        } else if jsonString.contains("\"index\":") &&
            jsonString.contains("\"runtime\":") &&
            (jsonString.range(of: "\"index\":\\s*([1-9]\\d*)", options: .regularExpression) != nil) &&
            (jsonString.range(of: "\"runtime\":\\s*([1-9]\\d*)", options: .regularExpression) != nil) {
            messageFormat = .wifi
            print("ZMQ: Detected WiFi message format (has index + runtime)")
        } else if jsonString.hasPrefix("[") {
            messageFormat = .bluetooth
            print("ZMQ: Detected BLE array format")
        } else {
            messageFormat = .sdr
            print("ZMQ: Detected SDR/unknown format")
        }
        
        if let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let results = processJsonArrayToMultiple(jsonArray)
            if !results.isEmpty {
                print("→ Processed BLE array into \(results.count) separate drone messages")
            }
            return results
        }
        
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        
        let hasIndexRuntime = jsonObject["index"] != nil && jsonObject["runtime"] != nil
        let hasBasicId = jsonObject["Basic ID"] != nil
        
        if hasBasicId && hasIndexRuntime {
            print("DEBUG: Detected WiFi JSON with Basic ID, converting to XML...")
            if let result = processJsonObject(jsonObject) {
                print("→ Successfully converted WiFi message to XML")
                return [result]
            } else {
                print("⚠️ Failed to convert WiFi message to XML")
                return []
            }
        }
        
        if hasBasicId || jsonObject["FPV Detection"] != nil || jsonObject["AUX_ADV_IND"] != nil {
            print("DEBUG: Detected JSON object format, passing through raw")
            return [jsonString]
        }
        
        if let result = processRawFPVMessage(jsonObject) {
            print("→ Processed raw FPV serial message successfully")
            return [result]
        }
        
        if let result = processJsonObject(jsonObject) {
            print("→ Processed WiFi/SDR message successfully")
            return [result]
        }
        return []
    }
    
    func processJsonObject(_ jsonObject: [String: Any]) -> String? {
        
        // Extract messages from the object - try both with and without spaces
        var basicId = jsonObject["Basic ID"] as? [String: Any]
        if basicId == nil {
            basicId = jsonObject["BasicID"] as? [String: Any]
        }
        if basicId == nil {
            basicId = jsonObject["Basic_ID"] as? [String: Any]
        }
        
        var location = jsonObject["Location/Vector Message"] as? [String: Any]
        if location == nil {
            location = jsonObject["Location"] as? [String: Any]
        }
        
        var system = jsonObject["System Message"] as? [String: Any]
        if system == nil {
            system = jsonObject["System"] as? [String: Any]
        }
        
        _ = jsonObject["Auth Message"] as? [String: Any]
        
        var operatorId = jsonObject["Operator ID Message"] as? [String: Any]
        if operatorId == nil {
            operatorId = jsonObject["OperatorID"] as? [String: Any]
        }
        
        var selfID = jsonObject["Self-ID Message"] as? [String: Any]
        if selfID == nil {
            selfID = jsonObject["SelfID"] as? [String: Any]
        }
        
        // Extract index and runtime
        let mIndex = jsonObject["index"] as? Int ?? 0
        let mRuntime = jsonObject["runtime"] as? Int ?? 0
        
        // Extract backend metadata (from dragonsync.py/drone.py)
        let freq = jsonObject["freq"] as? Double
        let seenBy = jsonObject["seen_by"] as? String
        let observedAt = jsonObject["observed_at"] as? Double
        let ridTimestamp = jsonObject["rid_timestamp"] as? String
        
        // Extract FAA RID enrichment data
        var ridMake: String?
        var ridModel: String?
        var ridSource: String?
        if let rid = jsonObject["rid"] as? [String: Any] {
            ridMake = rid["make"] as? String
            ridModel = rid["model"] as? String
            ridSource = rid["source"] as? String
        }
        
        // Extract takeoff location from DJI via SDR
        let homeLat = system?["home_lat"] as? Double ?? 0.0
        let homeLon = system?["home_lon"] as? Double ?? 0.0

        var frequencyMessageMHz: Double? = nil
        if let freqMsg = jsonObject["Frequency Message"] as? [String: Any] {
            frequencyMessageMHz = (freqMsg["frequency"] as? Double)
                ?? (freqMsg["frequency"] as? Int).map(Double.init)
                ?? (freqMsg["frequency_mhz"] as? Double)
                ?? (freqMsg["frequency_mhz"] as? Int).map(Double.init)
        }

        let transport = (basicId?["transport"] as? String) ?? ""
        let basicFrequencyMHz: Double? = (basicId?["frequency_mhz"] as? Double)
            ?? (basicId?["frequency_mhz"] as? Int).map(Double.init)

        let areaCount = system?["area_count"] as? Int
        let areaRadius = system?["area_radius"] as? Int
            ?? (system?["area_radius"] as? Double).map { Int($0) }
        let areaCeiling = (system?["area_ceiling"] as? Double)
            ?? (system?["area_ceiling"] as? Int).map(Double.init)
        let areaFloor = (system?["area_floor"] as? Double)
            ?? (system?["area_floor"] as? Int).map(Double.init)
        let operatorLocationType = system?["operator_location_type"] as? String
        let operatorIdType = operatorId?["operator_id_type"] as? String
        let selfIdTextType = selfID?["text_type"] as? String
        let authMsg = jsonObject["Auth Message"] as? [String: Any]
        let authType = authMsg?["auth_type"] as? String
        let authData = authMsg?["auth_data"] as? String
        let authPage = authMsg?["page"] as? Int
        let authPageCount = authMsg?["page_count"] as? Int
        let authLength = authMsg?["length"] as? Int
        
        // Extract operator ID from both possible sources
        var opID = (system?["operator_id"] as? String) ?? (operatorId?["operator_id"] as? String) ?? ""
        
        // Handle weird multicast output
        if opID == "Terminator0x00" {
            opID = "N/A"
        }
        
        guard let basicId = basicId else {
            // Silently skip - this is expected for incomplete message fragments
            print("ZMQ: ⚠️ processJsonObject: No valid Basic ID found in message")
            return nil
        }
        
        // Basic ID Message Fields
        let uaType = String(describing: basicId["ua_type"] ?? "")
        let droneId = basicId["id"] as? String ?? UUID().uuidString
        if droneId.contains("NONE"){
            print("SKIPPING THE NONE IN ID")
            return nil
        }
        let idType = basicId["id_type"] as? String ?? ""
        var caaReg =  ""
        if idType.contains("CAA") {
            caaReg = droneId.replacingOccurrences(of: "drone-", with: "")
        }
        var mac = basicId["MAC"] as? String ?? ""
        let rssi = basicId["RSSI"] as? Int ?? 0
        let desc = basicId["description"] as? String ?? ""
        let mProtocol = basicId["protocol_version"] as? String ?? ""
        
        // SelfID Message Fields
        let selfIDtext = selfID?["text"] as? String ?? ""
        let selfIDDesc = selfID?["description"] as? String ?? ""
        
        // Tricky way to get MAC from "text": "UAV 4f:16:39:ff:ff:ff operational" if mac empty
        if mac.isEmpty, let selfIDtext = selfID?["text"] as? String {
            mac = selfIDtext.replacingOccurrences(of: "UAV ", with: "").replacingOccurrences(of: " operational", with: "")
        }
        
        // Location Message Fields
        let lat = formatDoubleValue(location?["latitude"])
        let lon = formatDoubleValue(location?["longitude"])
        let alt = formatDoubleValue(location?["geodetic_altitude"])
        let speed = formatDoubleValue(location?["speed"])
        let vspeed = formatDoubleValue(location?["vert_speed"])
        let height_agl = formatDoubleValue(location?["height_agl"])
        let pressure_altitude = formatDoubleValue(location?["pressure_altitude"])
        let speed_multiplier = formatDoubleValue(location?["speed_multiplier"])
        
        // Protocol specific handling
        let protocol_version = location?["protocol_version"] as? String ?? mProtocol
        let op_status = location?["op_status"] as? String ?? ""
        let height_type = location?["height_type"] as? String ?? ""
        let ew_dir_segment = location?["ew_dir_segment"] as? String ?? ""
        let direction = formatDoubleValue(location?["direction"])
        
        
        // MARK: - Status and Accuracy
        let status = location?["status"] as? Int ?? 0
        let alt_pressure = formatDoubleValue(location?["alt_pressure"])
        let horiz_acc = (location?["horizontal_accuracy"] as? Int)
            ?? (location?["horiz_acc"] as? Int)
            ?? 0
        let horiz_acc_str = (location?["horizontal_accuracy"] as? String) ?? ""
        let vert_acc = (location?["vertical_accuracy"] as? String)
            ?? (location?["vert_acc"] as? String)
            ?? ""
        let baro_acc = (location?["baro_accuracy"] as? Int)
            ?? (location?["baro_acc"] as? Int)
            ?? 0
        let baro_acc_str = (location?["baro_accuracy"] as? String) ?? ""
        let speed_acc = (location?["speed_accuracy"] as? Int)
            ?? (location?["speed_acc"] as? Int)
            ?? 0
        let speed_acc_str = (location?["speed_accuracy"] as? String) ?? ""
        let timestamp = location?["timestamp"] as? Int ?? 0
        let timestamp_acc = (location?["timestamp_accuracy"] as? String)
            ?? ((location?["timestamp_accuracy"] as? Int).map { String($0) } ?? "")
        
        // System Message Fields - check all possible field names
        let operator_lat = formatDoubleValue(system?["operator_lat"]) != "0.0" ?
        formatDoubleValue(system?["operator_lat"]) :
        formatDoubleValue(system?["latitude"])
        
        let operator_lon = formatDoubleValue(system?["operator_lon"]) != "0.0" ?
        formatDoubleValue(system?["operator_lon"]) :
        formatDoubleValue(system?["longitude"])
        
        let operator_alt_geo: String = {
            if let v = system?["operator_altitude_geo"] { return formatDoubleValue(v) }
            if let v = system?["operator_alt_geo"] { return formatDoubleValue(v) }
            if let v = location?["operator_alt_geo"] { return formatDoubleValue(v) }
            return "0.0"
        }()

        let classification = system?["classification"] as? Int ?? 0
        let classificationType = (system?["classification_type"] as? String) ?? ""
        var channel: Int?
        var phy: Int?
        var accessAddress: Int?
        var advMode: String?
        var deviceId: Int?
        var sequenceId: Int?
        var advAddress: String?
        
        
        var manufacturer = "Unknown"
        if let aext = jsonObject["aext"] as? [String: Any],
           let advInfo = aext["AdvDataInfo"] as? [String: Any],
           let macAddress = advInfo["mac"] as? String {
            
            for (key, prefixes) in macPrefixesByManufacturer {
                for prefix in prefixes {
                    if macAddress.hasPrefix(prefix) {
                        manufacturer = key
                        break
                    }
                }
            }
        }
        
        if !mac.isEmpty {
            let normalizedMac = mac.uppercased()
            for (key, prefixes) in macPrefixesByManufacturer {
                for prefix in prefixes {
                    let normalizedPrefix = prefix.uppercased()
                    if normalizedMac.hasPrefix(normalizedPrefix) {
                        manufacturer = key
                        break
                    }
                }
                if manufacturer != "Unknown" { break }
            }
        }
        
        // Extract from AUX_ADV_IND
        if let auxData = jsonObject["AUX_ADV_IND"] as? [String: Any] {
            channel = auxData["chan"] as? Int
            phy = auxData["phy"] as? Int
            accessAddress = auxData["aa"] as? Int
        }
        
        // Extract from aext
        if let aext = jsonObject["aext"] as? [String: Any],
           let advInfo = aext["AdvDataInfo"] as? [String: Any] {
            deviceId = advInfo["did"] as? Int
            sequenceId = advInfo["sid"] as? Int
            advMode = aext["AdvMode"] as? String ?? ""
            advAddress = aext["AdvA"] as? String ?? ""
        }
        
        var backendMetadata = ""
        let resolvedFrequencyMHz: Double? = basicFrequencyMHz ?? frequencyMessageMHz ?? freq
        if let resolvedFrequencyMHz = resolvedFrequencyMHz {
            backendMetadata += ", Frequency: \(String(format: "%.3f", resolvedFrequencyMHz)) MHz"
        }
        if let seenBy = seenBy {
            backendMetadata += ", SeenBy: \(seenBy)"
        }
        if let observedAt = observedAt {
            let date = Date(timeIntervalSince1970: observedAt)
            let formatter = ISO8601DateFormatter()
            backendMetadata += ", ObservedAt: \(formatter.string(from: date))"
        }
        if let ridTimestamp = ridTimestamp {
            backendMetadata += ", RID_TS: \(ridTimestamp)"
        }
        
        // Build FAA RID enrichment string
        var ridInfo = ""
        if let make = ridMake, let model = ridModel {
            ridInfo = ", RID: \(make) \(model)"
            // Always include source, default to "UNKNOWN" if not provided
            let source = ridSource ?? "UNKNOWN"
            ridInfo += " (\(source))"
        }

        // MARK: - droneid-go remarks extras
        var droneidGoExtras = ""
        if !transport.isEmpty {
            droneidGoExtras += ", Transport: \(transport)"
        }
        if let basicFrequencyMHz = basicFrequencyMHz {
            droneidGoExtras += ", BasicFrequency: \(String(format: "%.3f", basicFrequencyMHz)) MHz"
        }
        if let frequencyMessageMHz = frequencyMessageMHz {
            droneidGoExtras += ", FrequencyMessage: \(String(format: "%.3f", frequencyMessageMHz)) MHz"
        }
        if !timestamp_acc.isEmpty {
            droneidGoExtras += ", Timestamp Accuracy: \(timestamp_acc)"
        }
        if !horiz_acc_str.isEmpty && horiz_acc == 0 {
            droneidGoExtras += ", Horizontal Accuracy Str: \(horiz_acc_str)"
        }
        if !baro_acc_str.isEmpty && baro_acc == 0 {
            droneidGoExtras += ", Baro Accuracy Str: \(baro_acc_str)"
        }
        if !speed_acc_str.isEmpty && speed_acc == 0 {
            droneidGoExtras += ", Speed Accuracy Str: \(speed_acc_str)"
        }
        if !classificationType.isEmpty {
            droneidGoExtras += ", Classification Type: \(classificationType)"
        }
        if let operatorIdType = operatorIdType, !operatorIdType.isEmpty {
            droneidGoExtras += ", Operator ID Type: \(operatorIdType)"
        }
        if let operatorLocationType = operatorLocationType, !operatorLocationType.isEmpty {
            droneidGoExtras += ", Operator Location Type: \(operatorLocationType)"
        }
        if let selfIdTextType = selfIdTextType, !selfIdTextType.isEmpty {
            droneidGoExtras += ", Self-ID Text Type: \(selfIdTextType)"
        }
        if let areaCount = areaCount {
            droneidGoExtras += ", Area Count: \(areaCount)"
        }
        if let areaRadius = areaRadius {
            droneidGoExtras += ", Area Radius: \(areaRadius) m"
        }
        if let areaFloor = areaFloor {
            droneidGoExtras += ", Area Floor: \(String(format: "%.1f", areaFloor)) m"
        }
        if let areaCeiling = areaCeiling {
            droneidGoExtras += ", Area Ceiling: \(String(format: "%.1f", areaCeiling)) m"
        }
        if let authType = authType, !authType.isEmpty {
            droneidGoExtras += ", Auth Type: \(authType)"
        }
        if let authPage = authPage {
            droneidGoExtras += ", Auth Page: \(authPage)"
        }
        if let authPageCount = authPageCount {
            droneidGoExtras += ", Auth Page Count: \(authPageCount)"
        }
        if let authLength = authLength {
            droneidGoExtras += ", Auth Length: \(authLength)"
        }
        if let authData = authData, !authData.isEmpty {
            let trimmed = authData.count > 64 ? String(authData.prefix(64)) + "…" : authData
            droneidGoExtras += ", Auth Data: \(trimmed)"
        }
        
        let transmissionType: String = {
            switch transport.lowercased() {
            case "wifi": return "WiFi"
            case "ble": return "BLE"
            case "uart": return "ESP32"
            case "dji": return "DJI"
            case "": return (mIndex > 0 && mRuntime > 0) ? "WiFi" : "BLE"
            default: return transport.uppercased()
            }
        }()
        
        // Generate XML with properly escaped remarks content
        let now = ISO8601DateFormatter().string(from: Date())
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
        
        // Build remarks string and escape special XML characters
        let remarksContent = "Transmission Type: \(transmissionType), MAC: \(mac), RSSI: \(rssi)dBm, CAA: \(caaReg), ID Type: \(idType), UA Type: \(uaType), Manufacturer: \(manufacturer), Channel: \(String(describing: channel)), PHY: \(String(describing: phy)), Operator ID: \(opID), Access Address: \(String(describing: accessAddress)), Advertisement Mode: \(String(describing: advMode)), Device ID: \(String(describing: deviceId)), Sequence ID: \(String(describing: sequenceId)), Advertisement Address: \(String(describing: advAddress)), Protocol Version: \(protocol_version.isEmpty ? mProtocol : protocol_version), Location/Vector: [Speed: \(speed) m/s, Vert Speed: \(vspeed) m/s, Geodetic Altitude: \(alt) m, Altitude \(operator_alt_geo) m, Classification: \(classification), Height AGL: \(height_agl) m, Height Type: \(height_type), Pressure Altitude: \(pressure_altitude) m, EW Direction Segment: \(ew_dir_segment), Speed Multiplier: \(speed_multiplier), Operational Status: \(op_status), Direction: \(direction), Course: \(direction)°, Track Speed: \(speed) m/s, Timestamp: \(timestamp), Runtime: \(mRuntime), Index: \(mIndex), Status: \(status), Alt Pressure: \(alt_pressure) m, Horizontal Accuracy: \(horiz_acc), Vertical Accuracy: \(vert_acc), Baro Accuracy: \(baro_acc), Speed Accuracy: \(speed_acc)], Text: \(selfIDtext), Description: \(desc), SelfID Description: \(selfIDDesc), System: [Operator Lat: \(operator_lat), Operator Lon: \(operator_lon), Home Lat: \(homeLat), Home Lon: \(homeLon)]\(backendMetadata)\(ridInfo)\(droneidGoExtras)"
        
        let escapedRemarks = xmlEscape(remarksContent)
        
        let xmlOutput = """
        <event version="2.0" uid="drone-\(droneId)" type="a-u-A-M-H-R" time="\(now)" start="\(now)" stale="\(stale)" how="m-g">
            <point lat="\(lat)" lon="\(lon)" hae="\(alt)" ce="9999999" le="999999"/>
            <detail>
                <track course="\(direction)" speed="\(speed)"/>
                <remarks>\(escapedRemarks)</remarks>
                <contact endpoint="" phone="" callsign="drone-\(droneId)"/>
                <precisionlocation geopointsrc="GPS" altsrc="GPS"/>
                <color argb="-256"/>
                <usericon iconsetpath="34ae1613-9645-4222-a9d2-e5f243dea2865/Military/UAV_quad.png"/>
            </detail>
        </event>
        """
        
        // Only log if debug mode is needed (comment out for production)
        // print("GENERATED XML: \(xmlOutput)")
        return xmlOutput
    }
    
    func createFPVUpdateCoTMessage(_ source: String, rssi: Double, frequency: Double) -> String {
        let fpvId = "fpv-\(Int(frequency))"
        
        let now = ISO8601DateFormatter().string(from: Date())
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
        
        return """
            <event version="2.0" uid="\(fpvId)" type="a-u-A-M-H-R-F" time="\(now)" start="\(now)" stale="\(stale)" how="m-g">
                <point lat="0.0" lon="0.0" hae="0" ce="9999999" le="999999"/>
                <detail>
                    <remarks>FPV Update, RSSI: \(Int(rssi))dBm, Frequency: \(frequency) MHz, Source: \(source)</remarks>
                    <contact endpoint="" phone="" callsign="FPV \(Int(frequency))MHz"/>
                    <precisionlocation geopointsrc="GPS" altsrc="GPS"/>
                    <color argb="-1"/>
                    <usericon iconsetpath="34ae1613-9645-4222-a9d2-e5f243dea2865/Military/UAV_quad.png"/>
                </detail>
            </event>
            """
    }
    
    /// Process raw FPV serial messages from fpv_mdn_receiver.py
    /// Format: {"from":{"inst":"01","node":"97e8"},"to":{"inst":"00","node":"mcn"},"msg":{"type":"nodeAlert","time":146,"freq":5621,"rssi":1278,"stat":"NEW CONTACT LOCK"}}
    private func processRawFPVMessage(_ json: [String: Any]) -> String? {
        // Check if this is a raw FPV serial message
        guard let from = json["from"] as? [String: Any],
              let _ = json["to"] as? [String: Any],  // Validate structure but don't use
              let msg = json["msg"] as? [String: Any],
              let msgType = msg["type"] as? String,
              msgType == "nodeAlert" else {
            return nil
        }
        
        // Extract message fields
        let inst = from["inst"] as? String ?? "00"
        let node = from["node"] as? String ?? "0000"
        let source = "\(inst)-\(node)"
        
        let frequency = msg["freq"] as? Double ?? (msg["freq"] as? Int).map(Double.init) ?? 0.0
        let rssi = msg["rssi"] as? Double ?? (msg["rssi"] as? Int).map(Double.init) ?? 0.0
        let status = msg["stat"] as? String ?? "UNKNOWN"
        let time = msg["time"] as? Int ?? 0
        
        // Don't process boot or calibration messages
        if status.contains("NODE_START") || status.contains("CALIBRATION") {
            print("→ Skipping FPV system message: \(status)")
            return nil
        }
        
        // Create unique ID based on source and frequency
        let fpvId = "fpv-\(source)-\(Int(frequency))"
        
        let now = ISO8601DateFormatter().string(from: Date())
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))
        
        // Determine if this is initial detection or update
        let isNewContact = status.contains("NEW CONTACT")
        let eventType = isNewContact ? "a-u-A-M-H-R-F" : "a-u-A-M-H-R-F"  // Same type for now
        
        // Format CoT XML
        let xml = """
        <event version="2.0" uid="\(fpvId)" type="\(eventType)" time="\(now)" start="\(now)" stale="\(stale)" how="m-g">
            <point lat="0.0" lon="0.0" hae="0" ce="9999999" le="999999"/>
            <detail>
                <remarks>FPV \(status), RSSI: \(Int(rssi))dBm, Frequency: \(Int(frequency)) MHz, Source: \(source), Time: \(time)s</remarks>
                <contact endpoint="" phone="" callsign="FPV \(Int(frequency))MHz"/>
                <precisionlocation geopointsrc="GPS" altsrc="GPS"/>
                <color argb="-1"/>
                <usericon iconsetpath="34ae1613-9645-4222-a9d2-e5f243dea2865/Military/UAV_quad.png"/>
            </detail>
        </event>
        """
        
        print("→ Converted raw FPV message: \(status) @ \(Int(frequency))MHz, RSSI: \(Int(rssi))dBm")
        return xml
    }
    
    // ZMQ BG socket check
    func verifySubscription(completion: @escaping (Bool) -> Void) {
        guard isConnected else {
            completion(false)
            return
        }
        
        let hasValidSockets = telemetrySocket != nil && statusSocket != nil
        let isActive = Date().timeIntervalSince(lastMessageTime) < subscriptionTimeout
        let isValid = hasValidSockets && isActive
        
        if !isValid && shouldContinueRunning {
            print("ZMQ subscription needs refresh: valid sockets: \(hasValidSockets), active: \(isActive)")
            completion(false)
        } else {
            completion(true)
        }
    }

    
    //MARK - Parse and format data
    
    /// XML-escape special characters to prevent parsing errors
    private func xmlEscape(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    
    private func formatDoubleValue(_ value: Any?) -> String {
        if let doubleVal = value as? Double {
            return String(format: "%.7f", doubleVal)
        }
        if let intVal = value as? Int {
            return String(format: "%.7f", Double(intVal))
        }
        if let stringVal = value as? String {
            if let doubleVal = Double(stringVal.replacingOccurrences(of: " m/s", with: "")
                .replacingOccurrences(of: " m", with: "")) {
                return String(format: "%.7f", doubleVal)
            }
        }
        return "0.0"
    }
    
    func processJsonArray(_ jsonArray: [[String: Any]]) -> String? {
        var basicId: [String: Any]?
        var location: [String: Any]?
        var system: [String: Any]?
        var selfID: [String: Any]?
        var operatorId: [String: Any]?
        var auth: [String: Any]?
        var index: Int?
        var runtime: Int?
        
        // Find best Basic ID with a valid id field
        // Priority: Serial Number > CAA Registration > any other with valid ID
        var serialNumberId: [String: Any]?
        var caaId: [String: Any]?
        var fallbackId: [String: Any]?
        
        for obj in jsonArray {
            if let basicIdMsg = obj["Basic ID"] as? [String: Any],
               let id = basicIdMsg["id"] as? String,
               !id.isEmpty {
                let idType = basicIdMsg["id_type"] as? String ?? ""
                
                if idType.contains("Serial Number") {
                    serialNumberId = basicIdMsg
                    break // Serial Number is highest priority, use it immediately
                } else if idType.contains("CAA") {
                    caaId = basicIdMsg
                } else if fallbackId == nil {
                    fallbackId = basicIdMsg
                }
            }
        }
        
        // Select the best available Basic ID
        basicId = serialNumberId ?? caaId ?? fallbackId
        
        // If no valid Basic ID found, skip this message silently
        guard basicId != nil else {
            // Silently skip - these are incomplete message fragments (MAC-only beacons)
            return nil
        }
        
        // Collect other messages
        var frequencyMessage: [String: Any]?
        var auxAdvInd: [String: Any]?
        var aext: [String: Any]?
        for obj in jsonArray {
            if let locationMsg = obj["Location/Vector Message"] as? [String: Any] { location = locationMsg }
            if let systemMsg = obj["System Message"] as? [String: Any] { system = systemMsg }
            if let selfIDMsg = obj["Self-ID Message"] as? [String: Any] { selfID = selfIDMsg }
            if let operatorIDMsg = obj["Operator ID Message"] as? [String: Any] { operatorId = operatorIDMsg }
            if let authMsg = obj["Auth Message"] as? [String: Any] { auth = authMsg }
            if let freqMsg = obj["Frequency Message"] as? [String: Any] { frequencyMessage = freqMsg }
            if let aux = obj["AUX_ADV_IND"] as? [String: Any] { auxAdvInd = aux }
            if let aextObj = obj["aext"] as? [String: Any] { aext = aextObj }
            if let indexVal = obj["index"] as? Int { index = indexVal }
            if let runtimeVal = obj["runtime"] as? Int { runtime = runtimeVal }
        }

        // Create consolidated object and process it
        var consolidatedObject: [String: Any] = [:]
        if let basicId = basicId { consolidatedObject["Basic ID"] = basicId }
        if let location = location { consolidatedObject["Location/Vector Message"] = location }
        if let system = system { consolidatedObject["System Message"] = system }
        if let selfID = selfID { consolidatedObject["Self-ID Message"] = selfID }
        if let operatorId = operatorId { consolidatedObject["Operator ID Message"] = operatorId }
        if let auth = auth { consolidatedObject["Auth Message"] = auth }
        if let frequencyMessage = frequencyMessage { consolidatedObject["Frequency Message"] = frequencyMessage }
        if let auxAdvInd = auxAdvInd { consolidatedObject["AUX_ADV_IND"] = auxAdvInd }
        if let aext = aext { consolidatedObject["aext"] = aext }
        if let index = index { consolidatedObject["index"] = index }
        if let runtime = runtime { consolidatedObject["runtime"] = runtime }

        return processJsonObject(consolidatedObject)
    }
    
    func processJsonArrayToMultiple(_ jsonArray: [[String: Any]]) -> [String] {
        // Track every wrapper droneid-go / zmq_decoder.py emits in BLE array form, keyed by Basic ID.id.
        typealias DroneEntry = (
            basicId: [String: Any],
            location: [String: Any]?,
            system: [String: Any]?,
            selfID: [String: Any]?,
            operatorId: [String: Any]?,
            auth: [String: Any]?,
            frequencyMessage: [String: Any]?,
            auxAdvInd: [String: Any]?,
            aext: [String: Any]?,
            index: Int?,
            runtime: Int?
        )
        var dronesBySerial: [String: DroneEntry] = [:]

        // Some droneid-go / sniffle frames carry AUX_ADV_IND / aext / Frequency Message at the
        // top of the array (sibling, not child of Basic ID). Capture those once for fan-out.
        var sharedAuxAdvInd: [String: Any]?
        var sharedAext: [String: Any]?
        var sharedFrequencyMessage: [String: Any]?
        for obj in jsonArray {
            if sharedAuxAdvInd == nil, let aux = obj["AUX_ADV_IND"] as? [String: Any] { sharedAuxAdvInd = aux }
            if sharedAext == nil, let ax = obj["aext"] as? [String: Any] { sharedAext = ax }
            if sharedFrequencyMessage == nil, let fm = obj["Frequency Message"] as? [String: Any] { sharedFrequencyMessage = fm }
        }

        for obj in jsonArray {
            if let basicIdMsg = obj["Basic ID"] as? [String: Any],
               let id = basicIdMsg["id"] as? String,
               !id.isEmpty {

                var entry = dronesBySerial[id] ?? (basicId: basicIdMsg, location: nil, system: nil, selfID: nil, operatorId: nil, auth: nil, frequencyMessage: nil, auxAdvInd: nil, aext: nil, index: nil, runtime: nil)

                entry.basicId = basicIdMsg

                if let locationMsg = obj["Location/Vector Message"] as? [String: Any] { entry.location = locationMsg }
                if let systemMsg = obj["System Message"] as? [String: Any] { entry.system = systemMsg }
                if let selfIDMsg = obj["Self-ID Message"] as? [String: Any] { entry.selfID = selfIDMsg }
                if let operatorIDMsg = obj["Operator ID Message"] as? [String: Any] { entry.operatorId = operatorIDMsg }
                if let authMsg = obj["Auth Message"] as? [String: Any] { entry.auth = authMsg }
                if let freqMsg = obj["Frequency Message"] as? [String: Any] { entry.frequencyMessage = freqMsg }
                if let aux = obj["AUX_ADV_IND"] as? [String: Any] { entry.auxAdvInd = aux }
                if let ax = obj["aext"] as? [String: Any] { entry.aext = ax }
                if let indexVal = obj["index"] as? Int { entry.index = indexVal }
                if let runtimeVal = obj["runtime"] as? Int { entry.runtime = runtimeVal }

                dronesBySerial[id] = entry
            }
        }

        var xmlMessages: [String] = []

        for (_, entry) in dronesBySerial {
            var consolidatedObject: [String: Any] = [:]
            consolidatedObject["Basic ID"] = entry.basicId
            if let location = entry.location { consolidatedObject["Location/Vector Message"] = location }
            if let system = entry.system { consolidatedObject["System Message"] = system }
            if let selfID = entry.selfID { consolidatedObject["Self-ID Message"] = selfID }
            if let operatorId = entry.operatorId { consolidatedObject["Operator ID Message"] = operatorId }
            if let auth = entry.auth { consolidatedObject["Auth Message"] = auth }
            if let freqMsg = entry.frequencyMessage ?? sharedFrequencyMessage { consolidatedObject["Frequency Message"] = freqMsg }
            if let aux = entry.auxAdvInd ?? sharedAuxAdvInd { consolidatedObject["AUX_ADV_IND"] = aux }
            if let ax = entry.aext ?? sharedAext { consolidatedObject["aext"] = ax }
            if let index = entry.index { consolidatedObject["index"] = index }
            if let runtime = entry.runtime { consolidatedObject["runtime"] = runtime }

            if let xml = processJsonObject(consolidatedObject) {
                xmlMessages.append(xml)
            }
        }

        return xmlMessages
    }

    // MARK: - droneid-go health/heartbeat ingestion

    private func isDroneidGoHealthMessage(_ json: [String: Any]) -> Bool {
        let droneEnvelopeKeys = [
            "Basic ID", "BasicID", "Basic_ID",
            "Location/Vector Message", "Location",
            "System Message", "System",
            "Self-ID Message", "SelfID",
            "Operator ID Message", "OperatorID",
            "Auth Message",
            "Frequency Message",
            "AUX_ADV_IND", "aext",
            "FPV Detection",
            "from", "to", "msg"
        ]
        for key in droneEnvelopeKeys where json[key] != nil { return false }

        let healthMarkers = [
            "messages_per_sec", "messages_total",
            "errors_recent", "errors_total",
            "state_str",
            "connected_since",
            "last_message_time",
            "uptime", "uptime_ns",
            "sources"
        ]
        var hits = 0
        for key in healthMarkers where json[key] != nil { hits += 1 }
        return hits >= 2
    }

    private func ingestDroneidGoHealth(_ json: [String: Any]) {
        let snapshot = parseDroneidGoHealth(json)
        DispatchQueue.main.async { [weak self] in
            self?.backendHealth = snapshot
        }
    }

    private func parseDroneidGoHealth(_ json: [String: Any]) -> DroneidGoHealth {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterFallback = ISO8601DateFormatter()

        func parseDate(_ value: Any?) -> Date? {
            if let s = value as? String, !s.isEmpty {
                if let d = isoFormatter.date(from: s) { return d }
                if let d = isoFormatterFallback.date(from: s) { return d }
            }
            if let n = value as? Double { return Date(timeIntervalSince1970: n) }
            if let n = value as? Int { return Date(timeIntervalSince1970: Double(n)) }
            return nil
        }

        var nestedSources: [String: DroneidGoHealth] = [:]
        if let sources = json["sources"] as? [String: Any] {
            for (key, value) in sources {
                if let nested = value as? [String: Any] {
                    nestedSources[key] = parseDroneidGoHealth(nested)
                }
            }
        }

        let uptimeSeconds: Double = {
            if let s = json["uptime"] as? Double { return s }
            if let s = json["uptime"] as? Int { return Double(s) }
            if let ns = json["uptime_ns"] as? Double { return ns / 1_000_000_000.0 }
            if let ns = json["uptime_ns"] as? Int { return Double(ns) / 1_000_000_000.0 }
            return 0
        }()

        return DroneidGoHealth(
            enabled: (json["enabled"] as? Bool) ?? true,
            state: (json["state"] as? String) ?? "",
            stateString: (json["state_str"] as? String) ?? "",
            connectedSince: parseDate(json["connected_since"]),
            lastMessageTime: parseDate(json["last_message_time"]),
            lastErrorTime: parseDate(json["last_error_time"]),
            lastError: (json["last_error"] as? String) ?? "",
            connectAttempts: (json["connect_attempts"] as? Int) ?? 0,
            messagesTotal: (json["messages_total"] as? Int) ?? 0,
            messagesPerSec: (json["messages_per_sec"] as? Double)
                ?? Double((json["messages_per_sec"] as? Int) ?? 0),
            errorsTotal: (json["errors_total"] as? Int) ?? 0,
            errorsRecent: (json["errors_recent"] as? Int) ?? 0,
            uptimeSeconds: uptimeSeconds,
            sources: nestedSources,
            receivedAt: Date()
        )
    }

    func extractDouble(from dict: [String: Any]?, key: String) -> Double? {
        guard let dict = dict else { return nil }
        
        if let strValue = dict[key] as? String {
            return Double(strValue.replacingOccurrences(of: " m/s", with: "").replacingOccurrences(of: " m", with: ""))
        }
        return dict[key] as? Double
    }
    
    func extractString(from dict: [String: Any]?, key: String) -> String? {
        return dict?[key] as? String
    }
    
    func extractInt(from dict: [String: Any]?, key: String) -> Int? {
        return dict?[key] as? Int
    }
    
    func extractOperatorID(from dict: [String: Any]?) -> String {
        guard let operatorId = dict else { return "" }
        
        if let opId = operatorId["operator_id"] as? String {
            return opId == "Terminator0x00" ? "N/A" : opId
        }
        return ""
    }
    
    private func getFieldValue(_ json: [String: Any], keys: [String], defaultValue: Any) -> Any {
        for key in keys {
            if let value = json[key], !(value is NSNull) {
                return value
            }
        }
        return defaultValue
    }
    
    func convertStatusToXML(_ jsonString: String) -> String? {
        print("📥 ZMQ: Received status JSON of length \(jsonString.count)")
        
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("ZMQ: Failed to convert status string to Data")
            return nil
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            print("ZMQ: Failed to parse status JSON")
            print("First 500 chars: \(jsonString.prefix(500))")
            return nil
        }
        
        print(" ZMQ: Status JSON parsed, keys: \(json.keys.joined(separator: ", "))")
        let xml = createStatusXML(json)
        print(" ZMQ: Status XML created (\(xml.count) chars)")
        return xml
    }
    
    
    private func createStatusXML(_ json: [String: Any]) -> String {
        // DEBUG: Print the full JSON structure
        print("🔍 DEBUG STATUS JSON STRUCTURE:")
        print("================================================")
        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
        print("================================================")
        
        // top level
        let serialNumber = json["serial_number"] as? String ?? ""
        let gpsData = json["gps_data"] as? [String: Any] ?? [:]
        let systemStats = json["system_stats"] as? [String: Any] ?? [:]
        let antSDRTemps = json["ant_sdr_temps"] as? [String: Any] ?? [:]
        
        print("📊 DEBUG STATUS PARSING:")
        print("  Serial Number: \(serialNumber)")
        print("  GPS Data keys: \(gpsData.keys.joined(separator: ", "))")
        print("  System Stats keys: \(systemStats.keys.joined(separator: ", "))")
        print("  ANT SDR Temps keys: \(antSDRTemps.keys.joined(separator: ", "))")
        print("  ANT SDR Temps raw: \(antSDRTemps)")
        print("================================================")
        
        let memory = systemStats["memory"] as? [String: Any] ?? [:]
        let memoryTotal = Double(memory["total"] as? Int64 ?? 0)
        let memoryAvailable = Double(memory["available"] as? Int64 ?? 0)
        let memoryPercent = Double(memory["percent"] as? Double ?? 0.0)
        let memoryUsed = Double(memory["used"] as? Int64 ?? 0)
        let memoryFree = Double(memory["free"] as? Int64 ?? 0)
        let memoryActive = Double(memory["active"] as? Int64 ?? 0)
        let memoryInactive = Double(memory["inactive"] as? Int64 ?? 0)
        let memoryBuffers = Double(memory["buffers"] as? Int64 ?? 0)
        let memoryShared = Double(memory["shared"] as? Int64 ?? 0)
        let memoryCached = Double(memory["cached"] as? Int64 ?? 0)
        let memorySlab = Double(memory["slab"] as? Int64 ?? 0)
        
        // Disk stats
        let disk = systemStats["disk"] as? [String: Any] ?? [:]
        let diskTotal = Double(disk["total"] as? Int64 ?? 0)
        let diskUsed = Double(disk["used"] as? Int64 ?? 0)
        let diskFree = Double(disk["free"] as? Int64 ?? 0)
        let diskPercent = Double(disk["percent"] as? Double ?? 0.0)
        
        // Get ANTSDR temps either from dedicated field or remarks string
        // Handle both numeric values and "N/A" strings from Python
        var plutoTemp: Double = 0.0
        var zynqTemp: Double = 0.0
        
        // Try to get pluto_temp from JSON
        if let temp = antSDRTemps["pluto_temp"] as? Double {
            plutoTemp = temp
        } else if let tempStr = antSDRTemps["pluto_temp"] as? String,
                  tempStr != "N/A",
                  let tempValue = Double(tempStr) {
            plutoTemp = tempValue
        }
        
        // Try to get zynq_temp from JSON
        if let temp = antSDRTemps["zynq_temp"] as? Double {
            zynqTemp = temp
        } else if let tempStr = antSDRTemps["zynq_temp"] as? String,
                  tempStr != "N/A",
                  let tempValue = Double(tempStr) {
            zynqTemp = tempValue
        }
        
        // If temps are 0, try to parse from remarks if available (fallback)
        if (plutoTemp == 0.0 || zynqTemp == 0.0),
           let details = json["detail"] as? [String: Any],
           let remarks = details["remarks"] as? String {
            // Extract Pluto temp
            if plutoTemp == 0.0, let plutoMatch = remarks.firstMatch(of: /Pluto Temp: (\d+\.?\d*)°C/) {
                plutoTemp = Double(plutoMatch.1) ?? 0.0
            }
            // Extract Zynq temp
            if zynqTemp == 0.0, let zynqMatch = remarks.firstMatch(of: /Zynq Temp: (\d+\.?\d*)°C/) {
                zynqTemp = Double(zynqMatch.1) ?? 0.0
            }
        }
        
        // Exact format that parseRemarks() expects
        let remarks = "CPU Usage: \(systemStats["cpu_usage"] as? Double ?? 0.0)%, " +
        "Memory Total: \(String(format: "%.1f", memoryTotal)) MB, " +
        "Memory Available: \(String(format: "%.1f", memoryAvailable)) MB, " +
        "Memory Used: \(String(format: "%.1f", memoryUsed)) MB, " +
        "Memory Free: \(String(format: "%.1f", memoryFree)) MB, " +
        "Memory Active: \(String(format: "%.1f", memoryActive)) MB, " +
        "Memory Inactive: \(String(format: "%.1f", memoryInactive)) MB, " +
        "Memory Buffers: \(String(format: "%.1f", memoryBuffers)) MB, " +
        "Memory Shared: \(String(format: "%.1f", memoryShared)) MB, " +
        "Memory Cached: \(String(format: "%.1f", memoryCached)) MB, " +
        "Memory Slab: \(String(format: "%.1f", memorySlab)) MB, " +
        "Memory Percent: \(String(format: "%.1f", memoryPercent))%, " +
        "Disk Total: \(String(format: "%.1f", diskTotal)) MB, " +
        "Disk Used: \(String(format: "%.1f", diskUsed)) MB, " +
        "Disk Free: \(String(format: "%.1f", diskFree)) MB, " +
        "Disk Percent: \(String(format: "%.1f", diskPercent))%, " +
        "Temperature: \(systemStats["temperature"] as? Double ?? 0.0)°C, " +
        "Uptime: \(systemStats["uptime"] as? Double ?? 0.0) seconds, " +
        "Pluto Temp: \(plutoTemp)°C, " +
        "Zynq Temp: \(zynqTemp)°C"
        
        // Debug log to verify temps are being extracted
        print("DEBUG: AntSDR Temps - Pluto: \(plutoTemp)°C, Zynq: \(zynqTemp)°C")
        
        let xml = """
        <event version="2.0" uid="\(serialNumber)" type="b-m-p-s-m">
            <point lat="\(gpsData["latitude"] as? Double ?? 0.0)" lon="\(gpsData["longitude"] as? Double ?? 0.0)" hae="\(gpsData["altitude"] as? Double ?? 0.0)" ce="9999999" le="9999999"/>
            <detail>
                <track course="\(gpsData["track"] as? Double ?? 0.0)" speed="\(gpsData["speed"] as? Double ?? 0.0)"/>
                <status readiness="true"/>
                <remarks>\(remarks)</remarks>
            </detail>
        </event>
        """

//        print("DEBUG GENERATED STATUS XML:")
//        print("================================================")
//        print(xml)
//        print("================================================")
        
        return xml
    }
    
    //MARK: - Services Manager
    
    func sendServiceCommand(_ command: [String: Any], completion: @escaping (Bool, Any?) -> Void) {
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: command)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                if let statusSocket = statusSocket {
                    try statusSocket.send(string: jsonString)
                    
                    // Wait for response
                    if let response = try statusSocket.recv(bufferLength: 65536),
                       let responseString = String(data: response, encoding: .utf8),
                       let responseData = responseString.data(using: .utf8),
                       let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                       let cmdResponse = json["command_response"] as? [String: Any] {
                        
                        let success = cmdResponse["success"] as? Bool ?? false
                        completion(success, cmdResponse["data"])
                        return
                    }
                }
            }
            completion(false, "Failed to send command")
        } catch {
            completion(false, error.localizedDescription)
        }
    }
    
    func getServiceLogs(_ service: String, completion: @escaping (Result<String, Error>) -> Void) {
        let command: [String: Any] = [
            "command": [
                "type": "service_logs",
                "service": service,
                "timestamp": Date().timeIntervalSince1970
            ]
        ]
        
        sendServiceCommand(command) { success, response in
            if success, let logs = (response as? [String: Any])?["logs"] as? String {
                completion(.success(logs))
            } else {
                completion(.failure(NSError(domain: "", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "Failed to get logs"])))
            }
        }
    }
    
    //MARK: - Connection helpers
    
    func disconnect() {
        print("ZMQ: Disconnecting...")
        if isConnected {
            BackgroundDiagnostics.shared.log(.socket, "zmq disconnect", "host=\(lastHost) bgMode=\(isInBackgroundMode)")
        }
        shouldContinueRunning = false
        isReconnecting = false  // Reset reconnection flag

        connectionMonitorTimer?.invalidate()
        connectionMonitorTimer = nil

        lastStatusMessageBySN.removeAll()

        // Capture references; cleanup performed off-main so we never freeze
        // the UI thread (previously up to ~400ms via Thread.sleep + queue.sync).
        let queue = pollingQueue
        let semaphore = pollingExitSemaphore
        let capturedPoller = poller
        let capturedTelemetry = telemetrySocket
        let capturedStatus = statusSocket
        let capturedContext = context

        poller = nil
        telemetrySocket = nil
        statusSocket = nil
        context = nil
        pollingQueue = nil
        pollingExitSemaphore = nil
        isConnected = false
        isSubscriptionActive = false

        let cleanup: () -> Void = { [weak self] in
            if let self {
                self.pollingLock.lock()
                self.isPollingActive = false
                self.pollingLock.unlock()
            }
            // Wait for the polling loop to exit (it signals on exit).
            // 1s cap — if loop is wedged we close anyway to avoid leaking ZMQ
            // resources; libzmq tolerates close of a poll-target socket.
            if let semaphore = semaphore {
                _ = semaphore.wait(timeout: .now() + 1.0)
            }
            do {
                if let s = capturedTelemetry { try? capturedPoller?.unregister(socket: s) }
                if let s = capturedStatus    { try? capturedPoller?.unregister(socket: s) }
                try capturedTelemetry?.close()
                try capturedStatus?.close()
                try capturedContext?.terminate()
            } catch {
                print("ZMQ Cleanup Error: \(error)")
            }
            print("ZMQ: Disconnected")
        }

        if Thread.isMainThread {
            // Off-load teardown so main is never blocked.
            DispatchQueue.global(qos: .utility).async(execute: cleanup)
        } else if let queue = queue {
            queue.async(execute: cleanup)
        } else {
            cleanup()
        }
    }
    
    /// Force reset connection state - useful when stuck in reconnecting loop
    func resetConnectionState() {
        print("ZMQ: Force resetting connection state")
        disconnect()
        isReconnecting = false
        lastHost = ""
        lastTelemetryPort = 0
        lastStatusPort = 0
    }

    private var isReconnecting = false
    
    func reconnect() {
        // Prevent multiple simultaneous reconnection attempts
        guard !isReconnecting else {
            print("ZMQ: Reconnection already in progress, skipping")
            return
        }
        
        guard !isConnected else {
            print("ZMQ: Already connected, skipping reconnect")
            return
        }
        
        guard !lastHost.isEmpty, lastTelemetryPort > 0, lastStatusPort > 0 else {
            print("ZMQ: Invalid reconnection parameters")
            return
        }
        
        isReconnecting = true
        print("ZMQ: Reconnecting...")

        // Full disconnect — this unregisters sockets from the poller before
        // closing them (libzmq UB to close a registered, polled socket from
        // another thread) and waits off-main for the polling loop to exit.
        disconnect()

        // Small delay before reconnecting to avoid rapid reconnect loops
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            self.connect(
                host: self.lastHost,
                zmqTelemetryPort: self.lastTelemetryPort,
                zmqStatusPort: self.lastStatusPort,
                onTelemetry: self.lastTelemetryHandler,
                onStatus: self.lastStatusHandler
            )

            self.isReconnecting = false
        }
    }

    
}

extension ZMQHandler {

    func connectIfNeeded() {
        guard !isConnected,
              !lastHost.isEmpty,
              lastTelemetryPort > 0,
              lastStatusPort > 0 else {
            return
        }

        guard pollingLock.try() else {
            print("ZMQ: Poll lock contended, retrying connectIfNeeded shortly")
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.connectIfNeeded()
            }
            return
        }
        let isCurrentlyPolling = isPollingActive
        pollingLock.unlock()

        guard !isCurrentlyPolling else {
            print("ZMQ: Cannot connect while polling is active")
            return
        }

        connect(host: lastHost,
                zmqTelemetryPort: lastTelemetryPort,
                zmqStatusPort: lastStatusPort,
                onTelemetry: lastTelemetryHandler,
                onStatus: lastStatusHandler)
    }

    @discardableResult
    func drainOnce() -> Bool {
        // CRITICAL: Wrap entire function in autoreleasepool to prevent memory buildup in background
        return autoreleasepool {
            guard isConnected,
                  pollingLock.try() else {
                return false
            }
            
            defer { pollingLock.unlock() }
            
            guard !isPollingActive,
                  let telemetrySocket = self.telemetrySocket,
                  let statusSocket = self.statusSocket else {
                return false
            }
            
            var drained = false

            do {
                if let payload = try telemetrySocket.recv(bufferLength: 32768),
                   !payload.isEmpty,
                   let text = String(data: payload, encoding: .utf8) {
                    BackgroundDiagnostics.shared.recordPacket(.zmqTelemetry)
                    let xmlMessages = convertTelemetryToXMLArray(text)
                    let handler = lastTelemetryHandler
                    DispatchQueue.main.async {
                        for xmlMessage in xmlMessages { handler(xmlMessage) }
                    }
                    drained = true
                }
            } catch let error as SwiftyZeroMQ.ZeroMQError {
                if error.description != "Resource temporarily unavailable" &&
                   error.description != "Operation would block" {
                    print("ZMQ telemetry drain error: \(error)")
                }
            } catch {
                print("ZMQ telemetry drain error: \(error)")
            }
            
            do {
                if let payload = try statusSocket.recv(bufferLength: 32768),
                   !payload.isEmpty,
                   let text = String(data: payload, encoding: .utf8) {
                    BackgroundDiagnostics.shared.recordPacket(.zmqStatus)
                    let handler = lastStatusHandler
                    DispatchQueue.main.async { handler(text) }
                    drained = true
                }
            } catch let error as SwiftyZeroMQ.ZeroMQError {
                if error.description != "Resource temporarily unavailable" &&
                   error.description != "Operation would block" {
                    print("ZMQ status drain error: \(error)")
                }
            } catch {
                print("ZMQ status drain error: \(error)")
            }
            
            return drained
        }
    }

}

