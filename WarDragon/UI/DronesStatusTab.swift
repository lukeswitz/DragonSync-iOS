//
//  DronesStatusTab.swift
//  WarDragon
//
//  Created on 1/19/26.
//

import SwiftUI
import Charts
import MapKit
import CoreLocation

struct DronesStatusTab: View {
    @ObservedObject var cotViewModel: CoTViewModel
    @State private var sortBy: SortOption = .lastSeen
    @State private var showFilters = false
    @State private var filterOptions = FilterOptions()
    @ObservedObject private var editorManager = DroneEditorManager.shared
    @State private var isFiltersActive = false
    
    enum SortOption: String, CaseIterable {
        case lastSeen = "Last Seen"
        case rssi = "Signal Strength"
        case distance = "Distance"
        case manufacturer = "Manufacturer"
    }
    
    struct FilterOptions {
        var showSpoofed = true
        var showFPV = true
        var showNormal = true
        var minimumRSSI: Int = -100
    }
    
    private var filteredAndSortedDrones: [CoTViewModel.CoTMessage] {
        var drones = cotViewModel.parsedMessages
        
        drones = drones.filter { drone in
            if !filterOptions.showSpoofed && drone.isSpoofed { return false }
            if !filterOptions.showFPV && drone.isFPVDetection { return false }
            if !filterOptions.showNormal && !drone.isSpoofed && !drone.isFPVDetection { return false }
            
            if let rssi = drone.rssi, rssi < filterOptions.minimumRSSI { return false }
            
            return true
        }
        
        switch sortBy {
        case .lastSeen:
            return drones.sorted { $0.lastUpdated > $1.lastUpdated }
        case .rssi:
            return drones.sorted { ($0.rssi ?? -100) > ($1.rssi ?? -100) }
        case .distance:
            return drones.sorted { ($0.rssi ?? -100) > ($1.rssi ?? -100) }
        case .manufacturer:
            return drones.sorted { $0.idType < $1.idType }
        }
    }
    
    var body: some View {
        #if DEBUG
        let _ = PerfHeartbeat.shared.count("DronesStatusTab")
        #endif
        // Main list
        if cotViewModel.parsedMessages.isEmpty {
            emptyStateView
                .navigationTitle("Drones")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // Filter button
                        Button {
                            showFilters.toggle()
                        } label: {
                            Label("Filter", systemImage: isFiltersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .labelStyle(.iconOnly)
                        }
                        .help("Filter drones")
                        .disabled(true)
                        
                        // Sort menu
                        Menu {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Button {
                                    sortBy = option
                                } label: {
                                    HStack {
                                        Text(option.rawValue)
                                        Spacer()
                                        if sortBy == option {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                                .labelStyle(.iconOnly)
                        }
                        .help("Sort drones")
                        .disabled(true)
                        
                        // Clear button
                        Button {
                            clearAllDrones()
                        } label: {
                            Label("Clear All", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .help("Clear all drone detections")
                        .disabled(true)
                    }
                }
        } else {
            // Use GeometryReader to properly divide screen space
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Map takes 30% of available height
                    VStack(spacing: 0) {
                        HStack {
                            Text("OVERVIEW")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(filteredAndSortedDrones.count) DRONE\(filteredAndSortedDrones.count == 1 ? "" : "S")")
                                .font(.system(.subheadline))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        
                        CompactMapView(cotViewModel: cotViewModel, statusViewModel: cotViewModel.statusViewModel, drones: filteredAndSortedDrones)
                            .frame(height: geometry.size.height * 0.3)
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                    .frame(height: geometry.size.height * 0.3 + 50) // Fixed height for map section
                    .background(Color(UIColor.systemGroupedBackground))
                    
                    // List takes remaining 70% of height
                    List {
                        Section(header: sectionHeader) {
                            ForEach(filteredAndSortedDrones) { drone in
                                MessageRow(message: drone, cotViewModel: cotViewModel, isCompact: false)
                                    .id(drone.uid)
                            }
                        }
                    }
                    .frame(height: geometry.size.height * 0.7 - 50) // Fixed height for list
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.visible)
                    .refreshable {
                        // Pull to refresh on the list
                    }
                }
            }
            .navigationTitle("Drones")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Filter button
                    Button {
                        showFilters.toggle()
                    } label: {
                        Label("Filter", systemImage: isFiltersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Filter drones")
                    
                    // Sort menu
                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button {
                                sortBy = option
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    Spacer()
                                    if sortBy == option {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                            .labelStyle(.iconOnly)
                    }
                    .help("Sort drones")
                    
                    // Clear button
                    Button {
                        clearAllDrones()
                    } label: {
                        Label("Clear All", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .help("Clear all drone detections")
                    .disabled(cotViewModel.parsedMessages.isEmpty)
                }
            }
            .sheet(isPresented: $showFilters) {
                filterSheet
            }
            .sheet(isPresented: $editorManager.isPresented) {
                DroneInfoEditorSheet()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var sectionHeader: some View {
        HStack {
            Text("\(filteredAndSortedDrones.count) DRONES")
            Spacer()
            if spoofedCount > 0 {
                Label("\(spoofedCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
            if fpvCount > 0 {
                Label("\(fpvCount)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .textCase(nil)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "airplane.circle")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Drones Detected")
                .font(.headline)
            
            Text("Drone detections will appear here when Remote ID signals are received")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section(header: Text("Drone Types")) {
                    Toggle("Show Normal Drones", isOn: $filterOptions.showNormal)
                    Toggle("Show Spoofed Drones", isOn: $filterOptions.showSpoofed)
                    Toggle("Show FPV Drones", isOn: $filterOptions.showFPV)
                }
                
                Section(header: Text("Signal Strength")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Minimum RSSI: \(filterOptions.minimumRSSI) dBm")
                            .font(.caption)
                        
                        Slider(value: Binding(
                            get: { Double(filterOptions.minimumRSSI) },
                            set: { filterOptions.minimumRSSI = Int($0) }
                        ), in: -100...(-30), step: 5)
                        
                        HStack {
                            Text("Weak (-100)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("Strong (-30)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section {
                    Button("Reset Filters") {
                        filterOptions = FilterOptions()
                        updateFilterState()
                    }
                }
            }
            .onChange(of: filterOptions.showNormal) { updateFilterState() }
            .onChange(of: filterOptions.showSpoofed) { updateFilterState() }
            .onChange(of: filterOptions.showFPV) { updateFilterState() }
            .onChange(of: filterOptions.minimumRSSI) { updateFilterState() }
            .navigationTitle("Filter Drones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showFilters = false
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func detectionTimelineChart(data: [TimelineDataPoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DETECTION TIMELINE (Last Hour)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)
            
            Chart(data) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Count", point.count)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
                
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("Count", point.count)
                )
                .foregroundStyle(.blue.opacity(0.1))
                .interpolationMethod(.monotone)
            }
            .frame(height: 100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(date, format: .dateTime.minute())
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text("\(count)")
                                .font(.caption2)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    private var droneStatisticsList: some View {
        Group {
            HStack {
                Text("Total Detections")
                Spacer()
                Text("\(cotViewModel.parsedMessages.count)")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Unique MAC Addresses")
                Spacer()
                Text("\(uniqueMACCount)")
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("ID Randomizing")
                Spacer()
                Text("\(randomizingCount)")
                    .foregroundColor(randomizingCount > 0 ? .yellow : .secondary)
            }
            
            if let avgRSSI = averageRSSI {
                HStack {
                    Text("Average Signal")
                    Spacer()
                    Text("\(avgRSSI) dBm")
                        .foregroundColor(.secondary)
                }
            }
            
            HStack {
                Text("Manufacturers Detected")
                Spacer()
                Text("\(uniqueManufacturers)")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    /// Dynamically adjust map height to ensure drone list is always visible
    private var mapHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 200
        #else
        // FIXED HEIGHT: Small enough to ensure list is always scrollable and visible
        return 180
        #endif
    }
    
    private var uniqueMACCount: Int {
        Set(cotViewModel.parsedMessages.compactMap { $0.mac }).count
    }
    
    private var spoofedCount: Int {
        cotViewModel.parsedMessages.filter { $0.isSpoofed }.count
    }
    
    private var fpvCount: Int {
        cotViewModel.parsedMessages.filter { $0.isFPVDetection }.count
    }
    
    private var averageRSSI: Int? {
        let rssiValues = cotViewModel.parsedMessages.compactMap { $0.rssi }
        guard !rssiValues.isEmpty else { return nil }
        return rssiValues.reduce(0, +) / rssiValues.count
    }
    
    private var strongestSignal: Int? {
        cotViewModel.parsedMessages.compactMap { $0.rssi }.max()
    }
    
    private var timeActive: String {
        guard let oldestMessage = cotViewModel.parsedMessages.min(by: { $0.lastUpdated < $1.lastUpdated }) else {
            return "0m"
        }
        
        let duration = Date().timeIntervalSince(oldestMessage.lastUpdated)
        let minutes = Int(duration / 60)
        
        if minutes < 60 {
            return "\(minutes)m"
        } else {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return "\(hours)h \(remainingMinutes)m"
        }
    }
    
    private var randomizingCount: Int {
        cotViewModel.parsedMessages.filter { msg in
            !msg.idType.contains("CAA") && // Exclude CAA-only
            (cotViewModel.macIdHistory[msg.uid]?.count ?? 0 > 1)
        }.count
    }
    
    private var uniqueManufacturers: Int {
        Set(cotViewModel.parsedMessages.map { $0.idType }).count
    }
    
    private var detectionTimelineData: [TimelineDataPoint]? {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        
        // Get messages from the last hour
        let recentMessages = cotViewModel.parsedMessages.filter { $0.lastUpdated >= oneHourAgo }
        guard !recentMessages.isEmpty else { return nil }
        
        // Create 12 five-minute buckets
        var buckets: [Date: Int] = [:]
        for i in 0..<12 {
            let bucketTime = oneHourAgo.addingTimeInterval(Double(i) * 300) // 300 seconds = 5 minutes
            buckets[bucketTime] = 0
        }
        
        // Count messages in each bucket
        for message in recentMessages {
            let timeSinceStart = message.lastUpdated.timeIntervalSince(oneHourAgo)
            let bucketIndex = min(11, max(0, Int(timeSinceStart / 300)))
            let bucketTime = oneHourAgo.addingTimeInterval(Double(bucketIndex) * 300)
            buckets[bucketTime, default: 0] += 1
        }
        
        return buckets.sorted { $0.key < $1.key }.map { TimelineDataPoint(time: $0.key, count: $0.value) }
    }
    
    // MARK: - Helper Functions
    
    private func clearAllDrones() {
        cotViewModel.parsedMessages.removeAll()
        cotViewModel.droneSignatures.removeAll()
        cotViewModel.macIdHistory.removeAll()
        cotViewModel.macProcessing.removeAll()
        cotViewModel.alertRings.removeAll()
    }
    
    private func updateFilterState() {
        isFiltersActive = !filterOptions.showAll
    }
}

// MARK: - Supporting Views

private struct DroneStatusRow: View {
    let drone: CoTViewModel.CoTMessage
    @ObservedObject var cotViewModel: CoTViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack {
                // Status indicator
                Circle()
                    .fill(signalColor)
                    .frame(width: 10, height: 10)
                
                // Drone ID
                Text(drone.uid)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                
                Spacer()
                
                // Time since last update
                Text(timeSinceUpdate)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // Details row
            HStack(spacing: 16) {
                // RSSI
                if let rssi = drone.rssi {
                    DetailItem(
                        icon: "antenna.radiowaves.left.and.right",
                        label: "\(rssi) dBm",
                        color: signalColor
                    )
                }
                
                // ID Type
                DetailItem(
                    icon: "tag",
                    label: drone.idType,
                    color: .blue
                )
                
                // Drone Type
                DetailItem(
                    icon: "airplane",
                    label: formatDroneType(drone.uaType),
                    color: .purple
                )
            }
            
            // Badges row
            HStack(spacing: 8) {
                if drone.isSpoofed {
                    Badge(text: "SPOOFED", color: .yellow)
                }
                
                if drone.isFPVDetection {
                    Badge(text: "FPV", color: .orange)
                }
                
                if let macCount = cotViewModel.macIdHistory[drone.uid]?.count, macCount > 1 {
                    Badge(text: "RANDOMIZING", color: .red)
                }
                
                if let mac = drone.mac {
                    Badge(text: "MAC: \(String(mac.suffix(8)))", color: .gray)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    private var signalColor: Color {
        guard let rssi = drone.rssi else { return .gray }
        switch rssi {
        case ..<(-75): return .red
        case (-75)...(-60): return .yellow
        default: return .green
        }
    }
    
    private var timeSinceUpdate: String {
        let interval = Date().timeIntervalSince(drone.lastUpdated)
        if interval < 60 {
            return "\(Int(interval))s ago"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else {
            return "\(Int(interval / 3600))h ago"
        }
    }
    
    private func formatDroneType(_ type: DroneSignature.IdInfo.UAType) -> String {
        switch type {
        case .helicopter: return "Helicopter"
        case .aeroplane: return "Aeroplane"
        case .gyroplane: return "Gyroplane"
        default: return "Other"
        }
    }
}

private struct DetailItem: View {
    let icon: String
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced))
            .fontWeight(.medium)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .cornerRadius(4)
    }
}

private struct StatBadge: View {
    let icon: String
    let value: String
    let label: String
    
    var body: some View {
        VStack(spacing: 6) {
            // Icon in circular background
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.blue)
            }
            
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// MARK: - Data Models

private struct TimelineDataPoint: Identifiable {
    let id = UUID()
    let time: Date
    let count: Int
}

// MARK: - Extensions

private extension DronesStatusTab.FilterOptions {
    var showAll: Bool {
        showNormal && showSpoofed && showFPV && minimumRSSI == -100
    }
}

// MARK: - Compact Map View

private struct CompactMapView: View {
    @ObservedObject var cotViewModel: CoTViewModel
    @ObservedObject var statusViewModel: StatusViewModel
    let drones: [CoTViewModel.CoTMessage]
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    @State private var showPaths = true
    @State private var showPilots = true
    @State private var showHomes = true
    @State private var showDrones = true
    @State private var mapStyle: MapStyle = .standard

    private var monitorLocation: CLLocationCoordinate2D? {
        if let last = statusViewModel.statusMessages.last {
            let lat = last.gpsData.latitude
            let lon = last.gpsData.longitude
            if lat != 0.0 || lon != 0.0 {
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        if let user = LocationManager.shared.userLocation {
            return user.coordinate
        }
        return nil
    }

    private var droneCoordHash: String {
        let mon = monitorLocation.map { "\($0.latitude),\($0.longitude)" } ?? "nil"
        return drones.map { "\($0.uid)|\($0.lat)|\($0.lon)" }.joined(separator: ",")
            + "#" + cotViewModel.alertRings.map { "\($0.droneId)|\($0.centerCoordinate.latitude)|\($0.centerCoordinate.longitude)|\($0.radius)" }.joined(separator: ",")
            + "@" + mon
    }
    
    var body: some View {
        #if DEBUG
        let _ = PerfHeartbeat.shared.count("CompactMapView")
        #endif
        Map(position: $mapCameraPosition, interactionModes: .all) {
            if let mon = monitorLocation {
                Annotation("Monitor", coordinate: mon) {
                    ZStack {
                        Circle()
                            .fill(.purple)
                            .frame(width: 22, height: 22)
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .resizable()
                            .frame(width: 13, height: 13)
                            .foregroundStyle(.white)
                    }
                }
            }

            ForEach(cotViewModel.alertRings.filter { ring in
                // Only show rings for drones in our filtered list
                drones.contains { drone in
                    drone.uid == ring.droneId || 
                    drone.uid.hasPrefix(ring.droneId.components(separatedBy: "-").dropLast().joined(separator: "-"))
                }
            }, id: \.mapKey) { ring in
                // Use minimum 100m radius if ring radius is 0 or too small
                let displayRadius = ring.radius > 0 ? ring.radius : 100.0
                
                MapCircle(center: ring.centerCoordinate, radius: CLLocationDistance(displayRadius))
                    .foregroundStyle(.red.opacity(0.15))
                    .stroke(.red, lineWidth: 2)
                
                // Center marker for the alert ring
                Annotation("Detection", coordinate: ring.centerCoordinate) {
                    ZStack {
                        Circle()
                            .fill(.red)
                            .frame(width: 24, height: 24)
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .resizable()
                            .frame(width: 14, height: 14)
                            .foregroundStyle(.white)
                    }
                }
            }
            
            if showPaths {
                ForEach(drones, id: \.uid) { drone in
                    if let path = getPath(for: drone), path.count > 1 {
                        let smoothedPath = DetectionViewCache.shared.smoothedFlightPath(for: drone.uid)
                        MapPolyline(coordinates: smoothedPath)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            
            if showDrones {
                ForEach(drones, id: \.droneMapKey) { drone in
                    if let coord = drone.coordinate, coord.isValid {
                        Annotation(drone.uid, coordinate: coord) {
                            ZStack {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 24, height: 24)
                                Image(systemName: "airplane")
                                    .resizable()
                                    .frame(width: 14, height: 14)
                                    .foregroundStyle(.white)
                                    .rotationEffect(.degrees(drone.headingDeg - 90))
                            }
                        }
                    }
                }
            }
            
            if showHomes {
                ForEach(drones, id: \.homeMapKey) { drone in
                    if let lat = Double(drone.homeLat), let lon = Double(drone.homeLon), lat != 0 || lon != 0 {
                        Annotation("Home", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                            ZStack {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 20, height: 20)
                                Image(systemName: "house.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
            
            if showPilots {
                ForEach(drones, id: \.pilotMapKey) { drone in
                    if let lat = Double(drone.pilotLat), let lon = Double(drone.pilotLon), lat != 0 || lon != 0 {
                        Annotation("Pilot", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                            ZStack {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 20, height: 20)
                                Image(systemName: "person.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
            }
        }
        .mapStyle(mapStyle)
        .onAppear {
            updateMapRegion()
        }
        .onChange(of: droneCoordHash) { _, _ in
            updateMapRegion()
        }
    }
    
    private func updateMapRegion() {
        var allCoords: [CLLocationCoordinate2D] = []

        allCoords += drones.compactMap { drone -> CLLocationCoordinate2D? in
            guard let coord = drone.coordinate else { return nil }
            if coord.latitude == 0 && coord.longitude == 0 { return nil }
            return coord
        }

        let relevantRings = cotViewModel.alertRings.filter { ring in
            drones.contains { drone in
                drone.uid == ring.droneId ||
                drone.uid.hasPrefix(ring.droneId.components(separatedBy: "-").dropLast().joined(separator: "-"))
            }
        }
        allCoords += relevantRings.map { $0.centerCoordinate }

        if allCoords.isEmpty {
            if let mon = monitorLocation {
                let region = MKCoordinateRegion(
                    center: mon,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                mapCameraPosition = .region(region)
            } else {
                mapCameraPosition = .automatic
            }
            return
        }
        
        if allCoords.count == 1 {
            let region = MKCoordinateRegion(
                center: allCoords[0],
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            mapCameraPosition = .region(region)
            return
        }
        
        let latitudes = allCoords.map(\.latitude)
        let longitudes = allCoords.map(\.longitude)
        let minLat = latitudes.min()!
        let maxLat = latitudes.max()!
        let minLon = longitudes.min()!
        let maxLon = longitudes.max()!
        
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.01)
        )
        
        mapCameraPosition = .region(MKCoordinateRegion(center: center, span: span))
    }
    
    private func getPath(for drone: CoTViewModel.CoTMessage) -> [CLLocationCoordinate2D]? {
        let path = DetectionViewCache.shared.flightPath(for: drone.uid)
        return path.isEmpty ? nil : path
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DronesStatusTab(cotViewModel: CoTViewModel(statusViewModel: StatusViewModel()))
    }
}
