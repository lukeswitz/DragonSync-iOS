//
//  DashboardView.swift
//  WarDragon
//
//  Created by Luke on 1/20/25.
//

import Foundation
import SwiftUI
import UIKit
import CoreLocation


struct DashboardView: View {
    @ObservedObject var statusViewModel: StatusViewModel
    @ObservedObject var cotViewModel: CoTViewModel
    @ObservedObject var spectrumViewModel: SpectrumData.SpectrumViewModel
    
    // Check if OpenSky is enabled by looking at the service
    private var isOpenSkyEnabled: Bool {
        OpenSkyService.shared.isEnabled
    }
    
    var body: some View {
        #if DEBUG
        let _ = PerfHeartbeat.shared.count("DashboardView")
        #endif
        ScrollView {
            VStack(spacing: 20) {
                // System Status Card
                SystemStatusCard(statusViewModel: statusViewModel)
                
                // Active Drones Card
                DronesOverviewCard(cotViewModel: cotViewModel)
                
                // Aircraft Card (ADS-B or OpenSky)
                // Show if either ADS-B is enabled OR OpenSky is enabled OR we have aircraft tracks
                if Settings.shared.adsbEnabled || isOpenSkyEnabled || !cotViewModel.aircraftTracks.isEmpty {
                    AircraftOverviewCard(cotViewModel: cotViewModel)
                }
                
                // SDR Status Card
                SDRStatusCard(
                    statusViewModel: statusViewModel,
                    spectrumViewModel: spectrumViewModel
                )
                
                // Warnings Card
                WarningsCard(
                    statusViewModel: statusViewModel,
                    cotViewModel: cotViewModel
                )
            }
            .padding()
        }
    }
}

struct SystemStatusCard: View {
    @ObservedObject var statusViewModel: StatusViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with Real-Time Status
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(statusViewModel.statusColor)
                Text("SYSTEM STATUS")
                    .font(.appHeadline)
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusViewModel.statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusViewModel.statusText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(statusViewModel.statusColor)
                            .fontWeight(.medium)
                    }
                    
                    Text(statusViewModel.lastReceivedText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            // Metrics row with circular gauges
            HStack(spacing: 16) {
                CircularGauge(
                    value: statusViewModel.statusMessages.last?.systemStats.cpuUsage ?? 0,
                    maxValue: 100,
                    title: "CPU",
                    unit: "%",
                    color: cpuColor
                )
                
                CircularGauge(
                    value: memoryUsagePercent,
                    maxValue: 100,
                    title: "MEM",
                    unit: "%",
                    color: memoryColor
                )
                
                CircularGauge(
                    value: statusViewModel.statusMessages.last?.systemStats.temperature ?? 0,
                    maxValue: 85,
                    title: "TEMP",
                    unit: "°C",
                    color: temperatureColor
                )
            }
            .frame(height: 80)
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var cpuColor: Color {
        let usage = statusViewModel.statusMessages.last?.systemStats.cpuUsage ?? 0
        switch usage {
        case 0..<60: return .green
        case 60..<80: return .yellow
        default: return .red
        }
    }
    
    private var memoryUsagePercent: Double {
        guard let lastMessage = statusViewModel.statusMessages.last else { return 0 }
        let used = lastMessage.systemStats.memory.total - lastMessage.systemStats.memory.available
        return Double(used) / Double(lastMessage.systemStats.memory.total) * 100
    }
    
    private var memoryColor: Color {
        switch memoryUsagePercent {
        case 0..<70: return .green
        case 70..<85: return .yellow
        default: return .red
        }
    }
    
    private var temperatureColor: Color {
        let temp = statusViewModel.statusMessages.last?.systemStats.temperature ?? 0
        switch temp {
        case 0..<60: return .green
        case 60..<75: return .yellow
        default: return .red
        }
    }
}

struct DronesOverviewCard: View {
    @ObservedObject var cotViewModel: CoTViewModel
    
    private var activeDroneCount: Int {
        // Simple count of unique drones by their MAC addresses
        return Set(cotViewModel.parsedMessages.compactMap { $0.mac }).count
    }
    
    private var fpvCount: Int {
        cotViewModel.parsedMessages.filter { $0.isFPVDetection }.count
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundColor(.blue)
                Text("ACTIVE DRONES")
                    .font(.appHeadline)
                Spacer()
                Text("\(activeDroneCount)")
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.blue)
            }
            
            HStack {
                StatBox(
                    title: "TRACKED",
                    value: "\(activeDroneCount)",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .blue
                )
                
                StatBox(
                    title: "SPOOFED",
                    value: "\(spoofedCount)",
                    icon: "exclamationmark.triangle",
                    color: .yellow
                )
                
                StatBox(
                    title: "NEARBY",
                    value: "\(nearbyCount)",
                    icon: "location.fill",
                    color: .green
                )
                
                StatBox(
                    title: "FPV",
                    value: "\(fpvCount)",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .orange
                )
                
                let randomizingCount = cotViewModel.parsedMessages.filter { msg in
                    !msg.idType.contains("CAA") && // Exclude CAA-only
                    (cotViewModel.macIdHistory[msg.uid]?.count ?? 0 > 1)
                }.count
                
                if randomizingCount > 0 {
                    StatBox(
                        title: "RANDOMIZING",
                        value: "\(randomizingCount)",
                        icon: "shuffle",
                        color: .yellow
                    )
                }
            }

            // Recent activity list
            if !recentDrones.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recentDrones) { drone in
                        HStack {
                            Text(drone.uid)
                                .font(.appCaption)
                            Spacer()
                            Text(drone.rssi?.description ?? "")
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var signalColor: Color {
        guard let rssi = recentRSSI else { return .gray }
        switch rssi {
        case ..<(-75): return .red
        case (-75)...(-60): return .yellow
        default: return .green
        }
    }

    private var recentRSSI: Int? {
        return cotViewModel.parsedMessages.last?.rssi
    }
    
    private var uniqueDroneCount: Int {
        // Count unique drones by MAC address, falling back to ID if no MAC
        let uniqueMacs = Set(cotViewModel.parsedMessages.compactMap { message in
            message.mac ?? message.uid
        })
        return uniqueMacs.count
    }
    
    private var spoofedCount: Int {
        cotViewModel.parsedMessages.filter { $0.isSpoofed }.count
    }
    
    private var nearbyCount: Int {
        // Only count unique nearby drones
        let uniqueNearbyMacs = Set(cotViewModel.parsedMessages.filter { msg in
            guard let rssi = msg.rssi else { return false }
            return rssi > -70
        }.compactMap { $0.mac })
        return uniqueNearbyMacs.count
    }
        
        private var recentDrones: [CoTViewModel.CoTMessage] {
            Array(cotViewModel.parsedMessages.prefix(3))
        }
}

struct SDRStatusCard: View {
    @ObservedObject var statusViewModel: StatusViewModel
    @ObservedObject var spectrumViewModel: SpectrumData.SpectrumViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "thermometer")
                    .foregroundColor(.purple)
                Text("SDR STATUS")
                    .font(.appHeadline)
                Spacer()
                Circle()
                    .fill(sdrStatusColor)
                    .frame(width: 8, height: 8)
            }
            
            if let antStats = statusViewModel.statusMessages.last?.antStats {
                HStack(spacing: 20) {
                    // Pluto Temperature
                    VStack(alignment: .leading) {
                        Text("PLUTO")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                        Text("\(Int(antStats.plutoTemp))°C")
                            .font(.system(.title2, design: .monospaced))
                            .foregroundColor(temperatureColor(antStats.plutoTemp, threshold: Settings.shared.plutoTempThreshold))
                    }
                    
                    // Zynq Temperature
                    VStack(alignment: .leading) {
                        Text("ZYNQ")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                        Text("\(Int(antStats.zynqTemp))°C")
                            .font(.system(.title2, design: .monospaced))
                            .foregroundColor(temperatureColor(antStats.zynqTemp, threshold: Settings.shared.zynqTempThreshold))
                    }
                    
                    // SDR Connection Status
                    VStack(alignment: .leading) {
                        Text("STATUS")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                        Text(antStats.plutoTemp != 0.0 || antStats.zynqTemp != 0.0 ? "ACTIVE" : "INACTIVE")
                           .font(.system(.caption, design: .monospaced))
                           .foregroundColor(antStats.plutoTemp != 0.0 || antStats.zynqTemp != 0.0 ? .green : .red)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("No SDR Data")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var sdrStatusColor: Color {
        guard let antStats = statusViewModel.statusMessages.last?.antStats else {
            return .gray
        }
        
        if antStats.plutoTemp > Settings.shared.plutoTempThreshold ||
           antStats.zynqTemp > Settings.shared.zynqTempThreshold {
            return .red
        }
        if !spectrumViewModel.isListening {
            return .yellow
        }
        return .green
    }
    
    private func temperatureColor(_ temp: Double, threshold: Double) -> Color {
        switch temp {
        case ..<(threshold - 10): return .green
        case ..<threshold: return .yellow
        default: return .red
        }
    }
}

struct WarningsCard: View {
    @ObservedObject var statusViewModel: StatusViewModel
    @ObservedObject var cotViewModel: CoTViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.red)
                Text("WARNINGS")
                    .font(.appHeadline)
                Spacer()
                Text("\(activeWarnings.count)")
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.red)
            }
            
            if activeWarnings.isEmpty {
                Text("No active warnings")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(activeWarnings) { warning in
                    WarningRow(warning: warning)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var activeWarnings: [SystemWarning] {
        var warnings: [SystemWarning] = []
        
        // Only check system warnings if enabled
        if Settings.shared.systemWarningsEnabled {
            if let lastMessage = statusViewModel.statusMessages.last {
                let stats = lastMessage.systemStats
                
                // CPU Warning
                if stats.cpuUsage > Settings.shared.cpuWarningThreshold {
                    warnings.append(SystemWarning(
                        id: "cpu",
                        title: "High CPU Usage",
                        detail: "\(Int(stats.cpuUsage))%",
                        severity: .high
                    ))
                }
                
                // System Temperature Warning
                if stats.temperature > Settings.shared.tempWarningThreshold {
                    warnings.append(SystemWarning(
                        id: "temp",
                        title: "High Temperature",
                        detail: "\(Int(stats.temperature))°C",
                        severity: .high
                    ))
                }
                
                // Memory Warning
                let memoryUsed = Double(stats.memory.total - stats.memory.available)
                let memoryPercent = (memoryUsed / Double(stats.memory.total)) * 100
                if memoryPercent > (Settings.shared.memoryWarningThreshold * 100) {
                    warnings.append(SystemWarning(
                        id: "memory",
                        title: "High Memory Usage",
                        detail: "\(Int(memoryPercent))%",
                        severity: .medium
                    ))
                }
                
                // ANTSDR Temperature Warnings
                if lastMessage.antStats.plutoTemp > Settings.shared.plutoTempThreshold {
                    warnings.append(SystemWarning(
                        id: "pluto_temp",
                        title: "High Pluto Temperature",
                        detail: "\(Int(lastMessage.antStats.plutoTemp))°C",
                        severity: .high
                    ))
                }
                
                if lastMessage.antStats.zynqTemp > Settings.shared.zynqTempThreshold {
                    warnings.append(SystemWarning(
                        id: "zynq_temp",
                        title: "High Zynq Temperature",
                        detail: "\(Int(lastMessage.antStats.zynqTemp))°C",
                        severity: .high
                    ))
                }
            }
        }

        // Proximity Warnings
        if Settings.shared.enableProximityWarnings {
            let nearbyDrones = cotViewModel.parsedMessages.filter { message in
                guard let rssi = message.rssi else { return false }
                return rssi > Settings.shared.proximityThreshold
            }
            
            if !nearbyDrones.isEmpty {
                warnings.append(SystemWarning(
                    id: "proximity",
                    title: "Nearby Drones",
                    detail: "\(nearbyDrones.count) detected",
                    severity: .medium
                ))
            }
        }
        
        // Spoofing Warnings (always enabled if detected)
        let spoofedDrones = cotViewModel.parsedMessages.filter { $0.isSpoofed }
        if !spoofedDrones.isEmpty {
            warnings.append(SystemWarning(
                id: "spoof",
                title: "Possible Spoofed Signals",
                detail: "\(spoofedDrones.count) drones",
                severity: .high
            ))
        }
        
        // ADS-B Aircraft Warnings (if enabled)
        if Settings.shared.adsbEnabled {
            // Emergency aircraft
            let emergencyAircraft = cotViewModel.aircraftTracks.filter { $0.isEmergency }
            if !emergencyAircraft.isEmpty {
                warnings.append(SystemWarning(
                    id: "aircraft_emergency",
                    title: "Emergency Aircraft",
                    detail: "\(emergencyAircraft.count) aircraft",
                    severity: .high
                ))
            }
            
            // Low-flying aircraft nearby
            if let userLocation = LocationManager.shared.userLocation {
                let lowNearby = cotViewModel.aircraftTracks.filter { aircraft in
                    guard let coord = aircraft.coordinate,
                          let alt = aircraft.altitudeFeet,
                          alt < 1000 else { return false }
                    
                    let aircraftLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    let distance = userLocation.distance(from: aircraftLocation)
                    return distance <= 5000 // Within 5km
                }
                
                if !lowNearby.isEmpty {
                    warnings.append(SystemWarning(
                        id: "low_aircraft",
                        title: "Low-Flying Aircraft Nearby",
                        detail: "\(lowNearby.count) aircraft",
                        severity: .medium
                    ))
                }
            }
        }
        
        return warnings
    }
    
    private var warningColor: Color {
        switch activeWarnings.count {
        case 0: return .green
        case 1: return .yellow
        default: return .red
        }
    }
    
}

// Supporting Views
struct StatBox: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(value)
                .font(.system(.title2, design: .monospaced))
                .foregroundColor(color)
            Text(title)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct AircraftOverviewCard: View {
    @ObservedObject var cotViewModel: CoTViewModel
    
    private var activeAircraft: [Aircraft] {
        cotViewModel.aircraftTracks.filter { !$0.isStale }
    }
    
    // Separate OpenSky aircraft from ADS-B
    private var openSkyAircraft: [Aircraft] {
        activeAircraft.filter { $0.source == .opensky }
    }
    
    private var adsbAircraft: [Aircraft] {
        activeAircraft.filter { $0.source == .adsb }
    }
    
    private var cardTitle: String {
        let hasOpenSky = !openSkyAircraft.isEmpty
        let hasADSB = !adsbAircraft.isEmpty
        
        if hasOpenSky && hasADSB {
            return "AIRCRAFT (ADS-B + OPENSKY)"
        } else if hasOpenSky {
            return "AIRCRAFT (OPENSKY)"
        } else {
            return "ADS-B AIRCRAFT"
        }
    }
    
    private var nearbyAircraft: [Aircraft] {
        guard let userLocation = LocationManager.shared.userLocation else { return [] }
        
        return activeAircraft.filter { aircraft in
            guard let coord = aircraft.coordinate else { return false }
            let aircraftLocation = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let distance = userLocation.distance(from: aircraftLocation)
            return distance <= 10000 // Within 10km
        }
    }
    
    private var lowFlying: [Aircraft] {
        activeAircraft.filter { aircraft in
            guard let alt = aircraft.altitudeFeet else { return false }
            return alt < 2000 // Below 2000ft
        }
    }
    
    private var emergencyAircraft: [Aircraft] {
        activeAircraft.filter { $0.isEmergency }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "airplane.departure")
                    .foregroundColor(.cyan)
                Text(cardTitle)
                    .font(.appHeadline)
                Spacer()
                Text("\(activeAircraft.count)")
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            
            // Stats boxes
            HStack(spacing: 12) {
                StatBox(
                    title: "TRACKED",
                    value: "\(cotViewModel.aircraftTracks.count)",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .cyan
                )
                
                // Show breakdown if we have both sources
                if !openSkyAircraft.isEmpty && !adsbAircraft.isEmpty {
                    StatBox(
                        title: "OPENSKY",
                        value: "\(openSkyAircraft.count)",
                        icon: "globe",
                        color: .blue
                    )
                    
                    StatBox(
                        title: "ADS-B",
                        value: "\(adsbAircraft.count)",
                        icon: "antenna.radiowaves.left.and.right",
                        color: .green
                    )
                } else {
                    StatBox(
                        title: "NEARBY",
                        value: "\(nearbyAircraft.count)",
                        icon: "location.fill",
                        color: .blue
                    )
                    
                    StatBox(
                        title: "LOW ALT",
                        value: "\(lowFlying.count)",
                        icon: "arrow.down.circle",
                        color: lowFlying.isEmpty ? .gray : .orange
                    )
                }
                
                if !emergencyAircraft.isEmpty {
                    StatBox(
                        title: "EMERGENCY",
                        value: "\(emergencyAircraft.count)",
                        icon: "exclamationmark.triangle.fill",
                        color: .red
                    )
                }
            }
            
            // Recent aircraft list
            if !recentAircraft.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    
                    Text("RECENT AIRCRAFT")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)
                    
                    ForEach(recentAircraft) { aircraft in
                        AircraftDashRow(aircraft: aircraft)
                    }
                }
            } else {
                VStack(spacing: 4) {
                    Divider()
                    Text("No aircraft detected")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var recentAircraft: [Aircraft] {
        Array(activeAircraft.sorted { $0.lastSeen > $1.lastSeen }.prefix(5))
    }
}

struct AircraftDashRow: View {
    let aircraft: Aircraft
    
    var body: some View {
        HStack(spacing: 8) {
            // Signal quality indicator
            Circle()
                .fill(signalColor)
                .frame(width: 8, height: 8)
            
            // Callsign/Hex
            Text(aircraft.displayName)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
            
            Spacer()
            
            // Altitude
            if let alt = aircraft.altitudeFeet {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text("\(alt)ft")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            // Speed
            if let speed = aircraft.speedKnots {
                HStack(spacing: 2) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                    Text("\(speed)kts")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            
            // Emergency indicator
            if aircraft.isEmergency {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(6)
    }
    
    private var signalColor: Color {
        switch aircraft.signalQuality {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .yellow
        case .poor: return .red
        case .unknown: return .gray
        }
    }
}

struct WarningRow: View {
    let warning: SystemWarning
    
    var body: some View {
        HStack {
            Circle()
                .fill(warning.severity.color)
                .frame(width: 8, height: 8)
            Text(warning.title)
                .font(.appCaption)
            Spacer()
            Text(warning.detail)
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct SystemWarning: Identifiable {
    let id: String
    let title: String
    let detail: String
    let severity: Severity
    
    enum Severity {
        case high, medium, low
        
        var color: Color {
            switch self {
            case .high: return .red
            case .medium: return .yellow
            case .low: return .blue
            }
        }
    }
    
    enum WarningType {
            case system
            case proximity
            case spoof
            case temperature
            case performance
        }
}


