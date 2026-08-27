//
//  DetectionsStatsView.swift
//  WarDragon
//
//  Created on 1/19/26.
//

import SwiftUI
import Charts

struct DetectionsStatsView: View {
    @ObservedObject var cotViewModel: CoTViewModel
    let detectionMode: ContentView.DetectionMode
    @State private var updateTimer: Timer?
    @State private var selectedTimeRange: TimeRange = .sixMinutes
    
    enum TimeRange: String, CaseIterable, Identifiable {
        case sixMinutes = "6 min"
        case thirtyMinutes = "30 min"
        case oneHour = "1 hr"
        case threeHours = "3 hrs"
        case sixHours = "6 hrs"
        case twelveHours = "12 hrs"
        case twentyFourHours = "24 hrs"
        
        var id: String { rawValue }
        
        var timeInterval: TimeInterval {
            switch self {
            case .thirtyMinutes: return 30 * 60
            case .oneHour: return 60 * 60
            case .threeHours: return 3 * 60 * 60
            case .sixHours: return 6 * 60 * 60
            case .twelveHours: return 12 * 60 * 60
            case .twentyFourHours: return 24 * 60 * 60
            case .sixMinutes: return 6 * 60
            }
        }
        
        var bucketCount: Int {
            switch self {
            case .thirtyMinutes: return 15  // 2-minute buckets
            case .oneHour: return 12        // 5-minute buckets
            case .threeHours: return 18     // 10-minute buckets
            case .sixHours: return 18       // 20-minute buckets
            case .twelveHours: return 24    // 30-minute buckets
            case .twentyFourHours: return 24 // 1-hour buckets
            case .sixMinutes: return 12     // 30-second buckets
            }
        }
        
        var xAxisStride: Calendar.Component {
            switch self {
            case .thirtyMinutes, .sixMinutes: return .minute
            case .oneHour, .threeHours: return .minute
            case .sixHours, .twelveHours, .twentyFourHours: return .hour
            }
        }
        
        var xAxisStrideCount: Int {
            switch self {
            case .sixMinutes: return 2      // Every 2 minutes
            case .thirtyMinutes: return 5   // Every 5 minutes
            case .oneHour: return 10        // Every 10 minutes
            case .threeHours: return 30     // Every 30 minutes
            case .sixHours: return 1        // Every 1 hour
            case .twelveHours: return 2     // Every 2 hours
            case .twentyFourHours: return 4 // Every 4 hours
            }
        }
    }
    
    // Real-time timeline data - computed from current detections
    // Time range and bucket size determined by selectedTimeRange
    private var timelineData: [TimelineDataPoint] {
        let now = Date()
        let timeWindow = selectedTimeRange.timeInterval
        let bucketCount = selectedTimeRange.bucketCount
        let bucketDuration = timeWindow / Double(bucketCount)
        
        // Create time buckets going back 6 minutes
        let buckets: [(start: Date, end: Date)] = (0..<bucketCount).map { i in
            let start = now.addingTimeInterval(-timeWindow + Double(i) * bucketDuration)
            let end = now.addingTimeInterval(-timeWindow + Double(i + 1) * bucketDuration)
            return (start, end)
        }
        
        // Count detections in each bucket based on when they were observed
        return buckets.map { bucket in
            // For drones: Count how many were observed in this time bucket
            var droneCount = 0
            if detectionMode == .drones || detectionMode == .both {
                droneCount = cotViewModel.parsedMessages.filter { message in
                    // Use observedAt timestamp (when the detection was actually captured by hardware)
                    if let observedAt = message.observedAt {
                        let timestamp = Date(timeIntervalSince1970: observedAt)
                        return timestamp >= bucket.start && timestamp < bucket.end
                    }
                    // Fallback: use lastUpdated if no observedAt
                    let timestamp = message.lastUpdated
                    return timestamp >= bucket.start && timestamp < bucket.end
                }.count
            }
            
            // For aircraft: Count how many were last seen in this time bucket
            var aircraftCount = 0
            if detectionMode == .aircraft || detectionMode == .both {
                aircraftCount = cotViewModel.aircraftTracks.filter { track in
                    let timestamp = track.lastSeen
                    return timestamp >= bucket.start && timestamp < bucket.end
                }.count
            }
            
            return TimelineDataPoint(
                timestamp: bucket.end, // Use bucket end time for x-axis
                droneCount: droneCount,
                aircraftCount: aircraftCount
            )
        }
    }
    
    // Signal strength/altitude trend data - computed from current detections
    // Time range matches the timeline chart
    private var signalTrendData: [SignalTrendPoint] {
        let now = Date()
        let timeWindow = selectedTimeRange.timeInterval
        let bucketCount = selectedTimeRange.bucketCount
        let bucketDuration = timeWindow / Double(bucketCount)
        
        // Create time buckets going back 6 minutes
        let buckets: [(start: Date, end: Date)] = (0..<bucketCount).map { i in
            let start = now.addingTimeInterval(-timeWindow + Double(i) * bucketDuration)
            let end = now.addingTimeInterval(-timeWindow + Double(i + 1) * bucketDuration)
            return (start, end)
        }
        
        let raw: [Double?] = buckets.map { bucket in
            var avgRSSI: Double? = nil
            
            // For drones, calculate average RSSI
            if detectionMode == .drones || detectionMode == .both {
                let droneRSSI = cotViewModel.parsedMessages.compactMap { message -> Double? in
                    // Use observedAt timestamp
                    let timestamp: Date
                    if let observedAt = message.observedAt {
                        timestamp = Date(timeIntervalSince1970: observedAt)
                    } else {
                        timestamp = message.lastUpdated
                    }
                    
                    guard timestamp >= bucket.start && timestamp < bucket.end else { return nil }
                    
                    // Use normalized RSSI which handles both standard and FPV signal values
                    guard let rssi = message.normalizedRSSI else {
                        return nil
                    }
                    return rssi
                }
                
                if !droneRSSI.isEmpty {
                    avgRSSI = droneRSSI.reduce(0, +) / Double(droneRSSI.count)
                }
            }
            
            // For aircraft, also calculate average RSSI (not altitude)
            if detectionMode == .aircraft || detectionMode == .both {
                let aircraftRSSI = cotViewModel.aircraftTracks.compactMap { track -> Double? in
                    let timestamp = track.lastSeen
                    guard timestamp >= bucket.start && timestamp < bucket.end else { return nil }
                    guard let rssi = track.rssi else { return nil }
                    return rssi
                }
                
                if !aircraftRSSI.isEmpty {
                    let aircraftAvg = aircraftRSSI.reduce(0, +) / Double(aircraftRSSI.count)

                    // If we have both drones and aircraft, average them together
                    if detectionMode == .both, let droneAvg = avgRSSI {
                        avgRSSI = (droneAvg + aircraftAvg) / 2.0
                    } else {
                        avgRSSI = aircraftAvg
                    }
                }
            }

            return avgRSSI
        }

        let levelled = SeriesSmoother.level(raw)

        return buckets.indices.map { i in
            SignalTrendPoint(
                timestamp: buckets[i].end,
                averageRSSI: levelled[i],
                averageAltitude: 0.0
            )
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Time range picker
            timeRangePicker
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
            
            HStack(spacing: 8) {
                timelineChart
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                
                signalTrendChart
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
            }
            
            statsHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }
    
    // MARK: - Time Range Picker
    
    private var timeRangePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TIME RANGE")
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TimeRange.allCases) { range in
                        Button(action: {
                            selectedTimeRange = range
                        }) {
                            Text(range.rawValue)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(selectedTimeRange == range ? .bold : .regular)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(selectedTimeRange == range ? Color.blue : Color(UIColor.tertiarySystemGroupedBackground))
                                )
                                .foregroundColor(selectedTimeRange == range ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    // Helper for axis marks
    private var axisMarkValues: AxisMarkValues {
        if selectedTimeRange.xAxisStride == .hour {
            return .stride(by: .hour, count: selectedTimeRange.xAxisStrideCount)
        } else {
            return .stride(by: .minute, count: selectedTimeRange.xAxisStrideCount)
        }
    }
    
    // Helper for date format based on time range
    private var dateFormat: Date.FormatStyle {
        if selectedTimeRange.timeInterval >= 3600 { // 1 hour or more
            return .dateTime.hour().minute()
        } else {
            return .dateTime.hour().minute()
        }
    }
    
    private func startTimer() {
        // No longer needed - chart uses computed property
    }
    
    private func stopTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    // MARK: - Compact Stats Header
    
    private var compactStatsHeader: some View {
        HStack(spacing: 12) {
            if detectionMode == .drones || detectionMode == .both {
                StatPill(icon: "airplane.circle.fill", value: "\(activeDroneCount)", label: "Drones", color: .blue)
                StatPill(icon: "number.circle.fill", value: "\(uniqueMacCount)", label: "MACs", color: .purple)
            }
            
            if detectionMode == .aircraft || detectionMode == .both {
                StatPill(icon: "airplane.departure", value: "\(cotViewModel.aircraftTracks.count)", label: "Aircraft", color: .cyan)
                if let maxAlt = maxAircraftAltitude {
                    StatPill(icon: "arrow.up.circle.fill", value: "\(maxAlt/1000)k", label: "Alt", color: .green)
                }
            }
        }
    }
    
    // MARK: - Signal Strength Trend Chart
    
    private var signalTrendChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SIGNAL STRENGTH TREND")
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            // Show RSSI trend for all modes (drones, aircraft, and both)
            Chart(signalTrendData) { point in
                if let rssi = point.averageRSSI {
                    // Main signal line with gradient
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Avg RSSI", rssi)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.red, .orange, .yellow, .green],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)

                    // Area fill with gradient
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Avg RSSI", rssi)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [
                                .red.opacity(0.3),
                                .orange.opacity(0.2),
                                .yellow.opacity(0.15),
                                .green.opacity(0.1)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .interpolationMethod(.monotone)
                }

                // Warning threshold line (stronger signal = closer)
                RuleMark(y: .value("Warning", -60))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                
                // Good signal threshold
                RuleMark(y: .value("Good", -80))
                    .foregroundStyle(.yellow.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartYScale(domain: -128...(-20))
            .chartYAxisLabel("RSSI (dBm)", alignment: .leading)
            .chartXAxis {
                AxisMarks(values: axisMarkValues) { value in
                    AxisValueLabel(format: dateFormat, anchor: .top)
                        .font(.system(size: 9))
                }
                AxisMarks(values: axisMarkValues) { _ in
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .frame(height: 80)
        }
    }
    
    // MARK: - Timeline Chart
    
    private var timelineChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DETECTIONS TIMELINE")
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            Chart(timelineData) { point in
                if detectionMode == .drones || detectionMode == .both {
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Drones", point.droneCount)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Drones", point.droneCount)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue.opacity(0.3), .purple.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }
                
                if detectionMode == .aircraft || detectionMode == .both {
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Aircraft", point.aircraftCount)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.cyan, .mint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Aircraft", point.aircraftCount)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.cyan.opacity(0.3), .mint.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }
            }
            .frame(height: 80)
            .chartXAxis {
                AxisMarks(values: axisMarkValues) { value in
                    AxisValueLabel(format: dateFormat)
                        .font(.system(size: 9))
                }
                AxisMarks(values: axisMarkValues) { _ in
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
        }
    }
    
    // MARK: - Timeline Data Management
    // No longer needed - using computed property for real-time data
    
    // MARK: - Stats Header
    
    private var statsHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text("OVERVIEW")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                Spacer()
            }
            
            // Quick stats grid - Equal-width responsive columns
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: gridColumnCount), spacing: 8) {
                if detectionMode == .drones {
                    // DRONES MODE: Drones, FPV, MACs, Spoofed, Randomizing (5 cards)
                    QuickStatCard(
                        title: "Drones",
                        value: "\(activeDroneCount)",
                        icon: "antenna.radiowaves.left.and.right",
                        color: .blue
                    )
                    
                    QuickStatCard(
                        title: "FPV",
                        value: "\(fpvCount)",
                        icon: "dot.radiowaves.left.and.right",
                        color: .orange
                    )
                    
                    QuickStatCard(
                        title: "MACs",
                        value: "\(uniqueMacCount)",
                        icon: "number.circle.fill",
                        color: .purple
                    )
                    
                    QuickStatCard(
                        title: "Spoofed",
                        value: "\(spoofedCount)",
                        icon: "xmark.shield.fill",
                        color: spoofedCount > 0 ? .red : .gray
                    )
                    
                    QuickStatCard(
                        title: "Randomizing",
                        value: "\(randomizingMacCount)",
                        icon: "shuffle.circle.fill",
                        color: randomizingMacCount > 0 ? .yellow : .gray
                    )
                } else if detectionMode == .aircraft {
                    // AIRCRAFT MODE: Aircraft, Max Alt, Emergency, Speed
                    QuickStatCard(
                        title: "Aircraft",
                        value: "\(cotViewModel.aircraftTracks.count)",
                        icon: "airplane.departure",
                        color: .cyan
                    )
                    
                    QuickStatCard(
                        title: "Max Alt",
                        value: maxAltitudeDisplay,
                        icon: "arrow.up.circle.fill",
                        color: .green
                    )
                    
                    QuickStatCard(
                        title: "Emergency",
                        value: "\(emergencyAircraftCount)",
                        icon: "exclamationmark.triangle.fill",
                        color: emergencyAircraftCount > 0 ? .red : .gray
                    )
                    
                    QuickStatCard(
                        title: "Speed",
                        value: maxSpeedDisplay,
                        icon: "speedometer",
                        color: .mint
                    )
                } else {
                    // BOTH MODE: Drones, Aircraft, Emergency, Spoofed
                    QuickStatCard(
                        title: "Drones",
                        value: "\(activeDroneCount)",
                        icon: "antenna.radiowaves.left.and.right",
                        color: .blue
                    )
                    
                    QuickStatCard(
                        title: "Aircraft",
                        value: "\(cotViewModel.aircraftTracks.count)",
                        icon: "airplane.departure",
                        color: .cyan
                    )
                    
                    QuickStatCard(
                        title: "Emergency",
                        value: "\(emergencyAircraftCount)",
                        icon: "exclamationmark.triangle.fill",
                        color: emergencyAircraftCount > 0 ? .red : .gray
                    )
                    
                    QuickStatCard(
                        title: "Spoofed",
                        value: "\(spoofedCount)",
                        icon: "xmark.shield.fill",
                        color: spoofedCount > 0 ? .orange : .gray
                    )
                }
            }
        }
    }
    
    // Calculate responsive column count based on mode
    private var gridColumnCount: Int {
        switch detectionMode {
        case .drones:
            return 5  // 5 cards: Drones, FPV, MACs, Spoofed, Randomizing
        case .aircraft, .both:
            return 4  // 4 cards
        }
    }
    
    // Helper to display max altitude or placeholder
    private var maxAltitudeDisplay: String {
        if let maxAlt = maxAircraftAltitude {
            return "\(maxAlt/1000)k ft"
        } else {
            return "0 ft"
        }
    }
    
    // Helper to display max speed or placeholder
    private var maxSpeedDisplay: String {
        if let maxSpeed = maxAircraftSpeed {
            return "\(maxSpeed) kts"
        } else {
            return "0 kts"
        }
    }
    
    // MARK: - Drone Charts
    
    @ViewBuilder
    private var droneCharts: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Drone Type Distribution
            VStack(alignment: .leading, spacing: 6) {
                Text("DRONE TYPES")
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                Chart(droneTypeData) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("Type", item.type)
                    )
                    .foregroundStyle(by: .value("Type", item.type))
                    .annotation(position: .trailing) {
                        Text("\(item.count)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: CGFloat(droneTypeData.count * 28 + 20))
                .chartLegend(.hidden)
            }
            
            // Signal Strength Distribution
            if !droneSignalData.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SIGNAL STRENGTH")
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Chart(droneSignalData) { item in
                        BarMark(
                            x: .value("Range", item.range),
                            y: .value("Count", item.count)
                        )
                        .foregroundStyle(.blue.gradient)
                        .annotation(position: .top) {
                            Text("\(item.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 100)
                }
            }
            
            // ID Type Distribution (Pie/Donut Chart)
            if !idTypeData.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ID PROTOCOLS")
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Chart(idTypeData) { item in
                            SectorMark(
                                angle: .value("Count", item.count),
                                innerRadius: .ratio(0.5),
                                angularInset: 1.5
                            )
                            .foregroundStyle(by: .value("Type", item.type))
                            .opacity(0.8)
                        }
                        .frame(height: 100)
                        
                        // Legend
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(idTypeData) { item in
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(colorForIDType(item.type))
                                        .frame(width: 6, height: 6)
                                    Text(item.type)
                                        .font(.caption2)
                                    Spacer()
                                    Text("\(item.count)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
            }
        }
    }
    
    // MARK: - Aircraft Charts
    
    @ViewBuilder
    private var aircraftCharts: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Altitude Distribution
            if !altitudeData.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ALTITUDE DISTRIBUTION")
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Chart(altitudeData) { item in
                        BarMark(
                            x: .value("Range", item.range),
                            y: .value("Count", item.count)
                        )
                        .foregroundStyle(.cyan.gradient)
                        .annotation(position: .top) {
                            Text("\(item.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 100)
                }
            }
            
            // Speed Distribution
            if !speedData.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPEED DISTRIBUTION")
                        .font(.system(.caption2, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Chart(speedData) { item in
                        BarMark(
                            x: .value("Range", item.range),
                            y: .value("Count", item.count)
                        )
                        .foregroundStyle(.green.gradient)
                        .annotation(position: .top) {
                            Text("\(item.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 100)
                }
            }
        }
    }
    
    // MARK: - Computed Data
    
    private var activeDroneCount: Int {
        cotViewModel.parsedMessages.count
    }
    
    private var uniqueMacCount: Int {
        Set(cotViewModel.parsedMessages.compactMap { $0.mac }).count
    }
    
    private var fpvCount: Int {
        cotViewModel.parsedMessages.filter { $0.isFPVDetection }.count
    }
    
    private var totalDronesSeen: Int {
        // Count all drone encounters (not aircraft) from storage
        DetectionViewCache.shared.encounterCount()
    }
    
    private var totalAircraftSeen: Int {
        // Count all aircraft encounters from StatusViewModel
        cotViewModel.statusViewModel.adsbEncounterHistory.count
    }
    
    private var maxAircraftAltitude: Int? {
        cotViewModel.aircraftTracks.compactMap { $0.altitudeFeet }.max()
    }
    
    private var emergencyAircraftCount: Int {
        cotViewModel.aircraftTracks.filter { $0.isEmergency }.count
    }
    
    private var spoofedCount: Int {
        cotViewModel.parsedMessages.filter { $0.isSpoofed }.count
    }
    
    private var randomizingMacCount: Int {
        // Count drones with randomizing MACs
        // A MAC is randomizing if the second character is 2, 6, A, or E (local bit set)
        cotViewModel.parsedMessages.filter { message in
            guard let mac = message.mac, mac.count >= 2 else { return false }
            let secondChar = mac[mac.index(mac.startIndex, offsetBy: 1)]
            return "26AE".contains(secondChar.uppercased())
        }.count
    }
    
    private var maxAircraftSpeed: Int? {
        cotViewModel.aircraftTracks.compactMap { $0.speedKnots }.max()
    }
    
    // Drone type distribution
    private var droneTypeData: [ChartDataItem] {
        let types = Dictionary(grouping: cotViewModel.parsedMessages) { $0.uaType }
        return types.map { type, messages in
            ChartDataItem(
                id: type.rawValue,
                type: formatDroneType(type),
                count: messages.count
            )
        }.sorted { $0.count > $1.count }
    }
    
    // Signal strength distribution
    private var droneSignalData: [RangeDataItem] {
        let signals = cotViewModel.parsedMessages.compactMap { $0.normalizedRSSI }
        guard !signals.isEmpty else { return [] }
        
        let ranges = [
            ("Excellent (>-60)", signals.filter { $0 > -60 }.count),
            ("Good (-60 to -70)", signals.filter { $0 <= -60 && $0 > -70 }.count),
            ("Fair (-70 to -80)", signals.filter { $0 <= -70 && $0 > -80 }.count),
            ("Poor (<-80)", signals.filter { $0 <= -80 }.count)
        ]
        
        return ranges.enumerated().map { index, item in
            RangeDataItem(id: index, range: item.0, count: item.1)
        }.filter { $0.count > 0 }
    }
    
    // ID type distribution
    private var idTypeData: [ChartDataItem] {
        let types = Dictionary(grouping: cotViewModel.parsedMessages) { $0.idType }
        return types.map { type, messages in
            ChartDataItem(
                id: type,
                type: type,
                count: messages.count
            )
        }.sorted { $0.count > $1.count }
    }
    
    // Altitude distribution for aircraft
    private var altitudeData: [RangeDataItem] {
        let altitudes = cotViewModel.aircraftTracks.compactMap { $0.altitudeFeet }
        guard !altitudes.isEmpty else { return [] }
        
        let ranges = [
            ("0-2k ft", altitudes.filter { $0 < 2000 }.count),
            ("2k-5k ft", altitudes.filter { $0 >= 2000 && $0 < 5000 }.count),
            ("5k-10k ft", altitudes.filter { $0 >= 5000 && $0 < 10000 }.count),
            ("10k-20k ft", altitudes.filter { $0 >= 10000 && $0 < 20000 }.count),
            (">20k ft", altitudes.filter { $0 >= 20000 }.count)
        ]
        
        return ranges.enumerated().map { index, item in
            RangeDataItem(id: index, range: item.0, count: item.1)
        }.filter { $0.count > 0 }
    }
    
    // Speed distribution for aircraft
    private var speedData: [RangeDataItem] {
        let speeds = cotViewModel.aircraftTracks.compactMap { $0.speedKnots }
        guard !speeds.isEmpty else { return [] }
        
        let ranges = [
            ("0-100 kts", speeds.filter { $0 < 100 }.count),
            ("100-200 kts", speeds.filter { $0 >= 100 && $0 < 200 }.count),
            ("200-300 kts", speeds.filter { $0 >= 200 && $0 < 300 }.count),
            ("300-400 kts", speeds.filter { $0 >= 300 && $0 < 400 }.count),
            (">400 kts", speeds.filter { $0 >= 400 }.count)
        ]
        
        return ranges.enumerated().map { index, item in
            RangeDataItem(id: index, range: item.0, count: item.1)
        }.filter { $0.count > 0 }
    }
    
    // MARK: - Helper Functions
    
    private func formatDroneType(_ type: DroneSignature.IdInfo.UAType) -> String {
        switch type {
        case .none: return "None"
        case .helicopter: return "Helicopter"
        case .aeroplane: return "Aeroplane"
        case .gyroplane: return "Gyroplane"
        case .hybridLift: return "Hybrid Lift"
        case .ornithopter: return "Ornithopter"
        case .glider: return "Glider"
        case .kite: return "Kite"
        case .freeballoon: return "Free Balloon"
        case .captive: return "Captive Balloon"
        case .airship: return "Airship"
        case .freeFall: return "Parachute"
        case .rocket: return "Rocket"
        case .tethered: return "Tethered"
        case .groundObstacle: return "Ground Obstacle"
        case .other: return "Other"
        }
    }
    
    private func colorForIDType(_ type: String) -> Color {
        switch type {
        case let t where t.contains("DJI"): return .blue
        case let t where t.contains("CAA"): return .green
        case let t where t.contains("ANSI"): return .orange
        case let t where t.contains("FR"): return .purple
        default: return .gray
        }
    }
}

// MARK: - Supporting Views

private struct StatPill: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.1))
        )
    }
}

private struct QuickStatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            // Icon in a circle badge
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 28, height: 28)
                
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(color)
            }
            
            // Value
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            
            // Label
            Text(title)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(UIColor.tertiarySystemGroupedBackground))
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
    }
}

// MARK: - Data Models

private struct TimelineDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let droneCount: Int
    let aircraftCount: Int
}

private struct SignalTrendPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let averageRSSI: Double?
    let averageAltitude: Double
}

private struct ChartDataItem: Identifiable {
    let id: String
    let type: String
    let count: Int
}

private struct RangeDataItem: Identifiable {
    let id: Int
    let range: String
    let count: Int
}

// MARK: - Preview

#Preview {
    DetectionsStatsView(
        cotViewModel: CoTViewModel(statusViewModel: StatusViewModel()),
        detectionMode: .drones
    )
}
