//
//  SettingsView.swift
//  WarDragon
//
//  Created by Luke on 11/23/24.
//

import SwiftUI
import UIKit
import Network

@MainActor
struct SettingsView: View {
    @ObservedObject var cotHandler : CoTViewModel
    @StateObject private var settings = Settings.shared
    @StateObject private var openSkyService = OpenSkyService.shared
    
    var body: some View {
        #if DEBUG
        let _ = PerfHeartbeat.shared.count("SettingsView")
        #endif
        Form {
            Section("Connection") {
                HStack {
                    Image(systemName: connectionStatusSymbol)
                        .foregroundStyle(connectionStatusColor)
                        .symbolEffect(.bounce, options: .repeat(3), value: cotHandler.isListeningCot)
                    Text(connectionStatusText)
                        .foregroundStyle(connectionStatusColor)
                }
                
                Picker("Mode", selection: .init(
                    get: { settings.connectionMode },
                    set: { (mode: ConnectionMode) in settings.updateConnection(mode: mode) }
                )) {
                    ForEach(ConnectionMode.allCases, id: \.self) { mode in
                        HStack {
                            Image(systemName: mode.icon)
                            Text(mode.rawValue)
                        }
                        .tag(mode)
                    }
                }
                .disabled(settings.isListening)
                
                if settings.connectionMode == .zmq {
                    HStack {
                        TextField("ZMQ Host", text: .init(
                            get: { settings.zmqHost },
                            set: { settings.updateConnection(mode: settings.connectionMode, host: $0, isZmqHost: true) }
                        ))
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disabled(settings.isListening)
                        .onSubmit {
                            settings.updateConnectionHistory(host: settings.zmqHost, isZmq: true)
                        }
                        
                        if !settings.zmqHostHistory.isEmpty {
                            Menu {
                                ForEach(settings.zmqHostHistory, id: \.self) { host in
                                    Button(host) {
                                        settings.updateConnection(mode: settings.connectionMode, host: host, isZmqHost: true)
                                        settings.updateConnectionHistory(host: host, isZmq: true)
                                    }
                                }
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .disabled(settings.isListening)
                        }
                    }
                } else {
                    HStack {
                        TextField("Multicast Host", text: .init(
                            get: { settings.multicastHost },
                            set: { settings.updateConnection(mode: settings.connectionMode, host: $0, isZmqHost: false) }
                        ))
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disabled(settings.isListening)
                        .onSubmit {
                            settings.updateConnectionHistory(host: settings.multicastHost, isZmq: false)
                        }
                        
                        
                        if !settings.multicastHostHistory.isEmpty {
                            Menu {
                                ForEach(settings.multicastHostHistory, id: \.self) { host in
                                    Button(host) {
                                        settings.updateConnection(mode: settings.connectionMode, host: host, isZmqHost: false)
                                        settings.updateConnectionHistory(host: host, isZmq: false)
                                    }
                                }
                            } label: {
                                Image(systemName: "clock.arrow.circlepath")
                            }
                            .disabled(settings.isListening)
                        }
                    }
                }
                
                Toggle(isOn: .init(
                    get: { settings.isListening && cotHandler.isListeningCot },
                    set: { newValue in
                        if newValue {
                            settings.toggleListening(true)
                            cotHandler.startListening()
                            
                            // Save host to history when activating
                            if settings.connectionMode == .zmq {
                                settings.updateConnectionHistory(host: settings.zmqHost, isZmq: true)
                            } else {
                                settings.updateConnectionHistory(host: settings.multicastHost, isZmq: false)
                            }
                        } else {
                            settings.toggleListening(false)
                            cotHandler.stopListening()
                        }
                    }
                )) {
                    Text(settings.isListening && cotHandler.isListeningCot ? "Active" : "Inactive")
                }
                .disabled(!settings.isHostConfigurationValid())
            }
            
            Section("Preferences") {
                Toggle("Auto Spoof Detection", isOn: .init(
                    get: { settings.spoofDetectionEnabled },
                    set: { settings.spoofDetectionEnabled = $0 }
                ))
                
                Toggle("Keep Screen On", isOn: .init(
                    get: { settings.keepScreenOn },
                    set: { settings.updatePreferences(notifications: settings.notificationsEnabled, screenOn: $0) }
                ))
                
                Toggle("Persist Drone Detections", isOn: Binding(
                    get: { settings.persistDroneDetections },
                    set: { settings.persistDroneDetections = $0 }
                ))
                
                if !settings.persistDroneDetections {
                    Text("Drone detections will be removed after \(Int(settings.inactivityTimeout)) seconds of inactivity")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Drone detections will remain visible until manually cleared")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
//                Toggle("Enable Background Detection", isOn: .init(
//                    get: { settings.enableBackgroundDetection },
//                    set: { settings.enableBackgroundDetection = $0 }
//                ))
//                .disabled(settings.isListening) // Can't change while listening is active
            }
            
            Section("Notifications") {
                Toggle("Enable Push Notifications", isOn: .init(
                    get: { settings.notificationsEnabled },
                    set: { settings.updatePreferences(notifications: $0, screenOn: settings.keepScreenOn) }
                ))
                
                if settings.notificationsEnabled {
                    NavigationLink(destination: StatusNotificationSettingsView()) {
                        HStack {
                            Image(systemName: "bell.circle.fill")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading) {
                                Text("Notification Settings")
                                Text("Configure frequency and types")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("Enable to receive alerts on this device when drones are detected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Webhooks & External Services") {
                Toggle("Enable Webhooks", isOn: .init(
                    get: { settings.webhooksEnabled },
                    set: { settings.updateWebhookSettings(enabled: $0) }
                ))
                
                if settings.webhooksEnabled {
                    NavigationLink(destination: WebhookSettingsView()) {
                        HStack {
                            Image(systemName: "link.circle.fill")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading) {
                                Text("Webhook Services")
                                Text("\(WebhookManager.shared.configurations.count) services configured")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("Send notifications to Discord, Matrix, IFTTT, and other external services")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Performance") {
                NavigationLink {
                    RateLimitSettingsView()
                } label: {
                    HStack {
                        Image(systemName: "speedometer")
                            .foregroundColor(.orange)
                        Text("Rate Limiting")
                        Spacer()
                        if settings.rateLimitEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }

                Toggle("Background Diagnostics Logging", isOn: Binding(
                    get: { settings.backgroundDiagnosticsEnabled },
                    set: { settings.backgroundDiagnosticsEnabled = $0 }
                ))

                NavigationLink {
                    BackgroundDiagnosticsView()
                } label: {
                    HStack {
                        Image(systemName: "stethoscope")
                            .foregroundColor(.teal)
                        VStack(alignment: .leading) {
                            Text("Background Diagnostics")
                            Text("Why detection stopped, and when")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .disabled(!settings.backgroundDiagnosticsEnabled)
            }
            
            Section("Warning Thresholds") {
                Toggle("System Warnings", isOn: Binding(
                    get: { settings.systemWarningsEnabled },
                    set: { settings.systemWarningsEnabled = $0 }
                ))
                
                if settings.systemWarningsEnabled {
                    ThresholdSlider(
                        title: "CPU Usage",
                        value: $settings.cpuWarningThreshold,
                        range: 50...90,
                        step: 5,
                        unit: "%",
                        color: .blue
                    )
                    
                    ThresholdSlider(
                        title: "System Temperature",
                        value: $settings.tempWarningThreshold,
                        range: 40...85,
                        step: 5,
                        unit: "°C",
                        color: .red
                    )
                    
                    ThresholdSlider(
                        title: "Memory Usage",
                        value: .init(
                            get: { settings.memoryWarningThreshold * 100 },
                            set: { settings.memoryWarningThreshold = $0 / 100 }
                        ),
                        range: 50...95,
                        step: 5,
                        unit: "%",
                        color: .green
                    )
                    
                    ThresholdSlider(
                        title: "PlutoSDR Temperature",
                        value: $settings.plutoTempThreshold,
                        range: 40...100,
                        step: 5,
                        unit: "°C",
                        color: .purple
                    )
                    
                    ThresholdSlider(
                        title: "Zynq Temperature",
                        value: $settings.zynqTempThreshold,
                        range: 40...100,
                        step: 5,
                        unit: "°C",
                        color: .orange
                    )
                }
                
                Toggle("Proximity Warnings", isOn: Binding(
                    get: { settings.enableProximityWarnings },
                    set: { settings.enableProximityWarnings = $0 }
                ))
                
                if settings.enableProximityWarnings {
                    ThresholdSlider(
                        title: "RSSI Threshold",
                        value: .init(
                            get: { Double(settings.proximityThreshold) },
                            set: { settings.proximityThreshold = Int($0) }
                        ),
                        range: -90...(-30),
                        step: 5,
                        unit: "dBm",
                        color: .yellow
                    )
                }
            }
            
            Section("Output - Beta Features") {
                NavigationLink {
                    TAKServerSettingsView()
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.blue)
                        Text("TAK Server")
                        Spacer()
                        if settings.takEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                NavigationLink {
                    MQTTSettingsView()
                } label: {
                    HStack {
                        Image(systemName: "network")
                            .foregroundColor(.orange)
                        Text("MQTT Broker")
                        Spacer()
                        if settings.mqttEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                NavigationLink {
                    LatticeSettingsView()
                } label: {
                    HStack {
                        Image(systemName: "grid.circle.fill")
                            .foregroundColor(.purple)
                        Text("Lattice DAS")
                        Spacer()
                        if settings.latticeEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            
            Section("Input") {
                NavigationLink {
                    ADSBSettingsView()
                } label: {
                    HStack {
                        Image(systemName: "airplane")
                            .foregroundColor(.teal)
                        Text("ADS-B Aircraft")
                        Spacer()
                        if settings.adsbEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                NavigationLink {
                    OpenSkySettingsView()
                } label: {
                    HStack {
                        Image(systemName: "airplane.departure")
                            .foregroundColor(.blue)
                        Text("OpenSky Network")
                        Spacer()
                        if openSkyService.isEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
            
            Section("Ports") {
                switch settings.connectionMode {
                case .multicast:
                    HStack {
                        Text("Multicast")
                        Spacer()
                        Text(verbatim: String(settings.multicastPort))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    
                case .zmq:
                    HStack {
                        Text("ZMQ Telemetry")
                        Spacer()
                        Text(verbatim: String(settings.zmqTelemetryPort))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("ZMQ Status")
                        Spacer()
                        Text(verbatim: String(settings.zmqStatusPort))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            
            Section("Flight Path Storage") {
                ThresholdSlider(
                    title: "Points Kept Per Drone",
                    value: Binding(
                        get: { Double(settings.flightPointRetentionLimit) },
                        set: { settings.flightPointRetentionLimit = Int($0) }
                    ),
                    range: 100...5000,
                    step: 100,
                    unit: " pts",
                    color: .blue
                )

                ThresholdSlider(
                    title: "Min Interval Between Points",
                    value: Binding(
                        get: { settings.flightPointMinIntervalSeconds },
                        set: { settings.flightPointMinIntervalSeconds = $0 }
                    ),
                    range: 1...60,
                    step: 1,
                    unit: "s",
                    color: .blue
                )

                ThresholdSlider(
                    title: "Min Movement Between Points",
                    value: Binding(
                        get: { settings.flightPointMinDistanceMeters },
                        set: { settings.flightPointMinDistanceMeters = $0 }
                    ),
                    range: 0...100,
                    step: 1,
                    unit: "m",
                    color: .blue
                )

                Text("A point is stored when the drone moves past the distance OR the interval elapses. 0m records any movement. Oldest points beyond the limit are deleted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Data Management") {
                NavigationLink {
                    DatabaseManagementView()
                } label: {
                    HStack {
                        Image(systemName: "cylinder.split.1x2.fill")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text("Database Management")
                            Text("Backup, restore, and repair")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                        .foregroundStyle(.secondary)
                }
                
                Link(destination: URL(string: "https://github.com/Root-Down-Digital/DragonSync-iOS")!) {
                    HStack {
                        Text("Source Code")
                        Spacer()
                        Image(systemName: "arrow.up.right.circle")
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .font(.appHeadline)
    }
    
    private var connectionStatusSymbol: String {
        if cotHandler.isListeningCot {
            switch settings.connectionMode {
            case .multicast:
                return "antenna.radiowaves.left.and.right.circle.fill"
            case .zmq:
                return "network.badge.shield.half.filled"
            }
        } else {
            return "bolt.horizontal.circle"
        }
    }
    
    private var connectionStatusColor: Color {
        if settings.isListening {
            return .green  // Always green when listening
        } else {
            return .red
        }
    }
    
    private var connectionStatusText: String {
        if settings.isListening {
            if cotHandler.isListeningCot {
                return "Connected"
            } else {
                return "Listening..."
            }
        } else {
            return "Disconnected"
        }
    }
}
