//
//  HistoryView.swift
//  WarDragon
//
//  Created by Luke on 1/21/25.
//

import Foundation
import UIKit
import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct StoredEncountersView: View {
    @Query(Self.recentEncounters) private var encounters: [StoredDroneEncounter]

    /// Newest first, bounded. An unbounded query materializes every stored
    /// encounter each time the tab is built.
    private static var recentEncounters: FetchDescriptor<StoredDroneEncounter> {
        var descriptor = FetchDescriptor<StoredDroneEncounter>(
            sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        return descriptor
    }
    
    @State private var showingDeleteConfirmation = false
    @State private var searchText = ""
    @State private var sortOrder: SortOrder = .lastSeen
    let cotViewModel: CoTViewModel
    @Environment(\.modelContext) private var modelContext
    private let storage = SwiftDataStorageManager.shared
    @ObservedObject private var editorManager = DroneEditorManager.shared
    
    // Cache for expensive computed values
    @State private var cachedEncounterStats: [String: EncounterStats] = [:]
    
    // Performance: Cache sorted encounters to avoid recomputing on every render
    @State private var sortedEncounters: [StoredDroneEncounter] = []
    @State private var lastEncountersHash: Int = 0
    
    enum SortOrder {
        case lastSeen, firstSeen, maxAltitude, maxSpeed
    }
    
    struct EncounterStats {
        let maxAltitude: Double
        let maxSpeed: Double
        let averageRSSI: Double
        let flightPointCount: Int
        let signatureCount: Int
    }
    
    // Helper to detect when we need to recompute sorted encounters
    private func encountersHash() -> Int {
        var hasher = Hasher()
        hasher.combine(encounters.count)
        hasher.combine(searchText)
        hasher.combine(sortOrder)
        return hasher.finalize()
    }
    
    // Compute sorted encounters only when data actually changes
    private func updateSortedEncounters() {
        let currentHash = encountersHash()
        guard currentHash != lastEncountersHash else { return }
        lastEncountersHash = currentHash
        
        computeSortedEncounters()
    }
    
    private func computeSortedEncounters() {
        let validEncounters = encounters.filter { encounter in
            encounter.modelContext != nil
        }
        
        let uniqueEncounters: [StoredDroneEncounter]
        
        let hasDuplicates = Set(validEncounters.compactMap { encounter -> String? in
            guard encounter.modelContext != nil else { return nil }
            return encounter.metadata["mac"] ?? encounter.id
        }).count != validEncounters.count
        
        if hasDuplicates {
            uniqueEncounters = Dictionary(grouping: validEncounters) { encounter in
                encounter.metadata["mac"] ?? encounter.id
            }.values.compactMap { encounters in
                encounters.max { $0.lastSeen < $1.lastSeen }
            }
        } else {
            uniqueEncounters = validEncounters
        }
        
        let filtered: [StoredDroneEncounter]
        if searchText.isEmpty {
            filtered = uniqueEncounters
        } else {
            let lowercasedSearch = searchText.lowercased()
            filtered = uniqueEncounters.filter { encounter in
                guard encounter.modelContext != nil else { return false }
                return encounter.id.lowercased().contains(lowercasedSearch) ||
                (encounter.metadata["caaRegistration"]?.lowercased().contains(lowercasedSearch) ?? false)
            }
        }
        
        self.sortedEncounters = filtered.sorted { first, second in
            guard first.modelContext != nil, second.modelContext != nil else {
                return first.modelContext != nil
            }
            
            switch sortOrder {
            case .lastSeen: 
                return first.lastSeen > second.lastSeen
            case .firstSeen: 
                return first.firstSeen < second.firstSeen
            case .maxAltitude:
                let firstAlt = cachedEncounterStats[first.id]?.maxAltitude ?? computeMaxAltitude(first)
                let secondAlt = cachedEncounterStats[second.id]?.maxAltitude ?? computeMaxAltitude(second)
                return firstAlt > secondAlt
            case .maxSpeed:
                let firstSpeed = cachedEncounterStats[first.id]?.maxSpeed ?? computeMaxSpeed(first)
                let secondSpeed = cachedEncounterStats[second.id]?.maxSpeed ?? computeMaxSpeed(second)
                return firstSpeed > secondSpeed
            }
        }
    }
    
    private func computeMaxAltitude(_ encounter: StoredDroneEncounter) -> Double {
        // Use cached value from model - NEVER access relationships
        return encounter.cachedMaxAltitude
    }
    
    private func computeMaxSpeed(_ encounter: StoredDroneEncounter) -> Double {
        // Use cached value from model - NEVER access relationships
        return encounter.cachedMaxSpeed
    }
    
    private func updateCache(for encounter: StoredDroneEncounter, maxAltitude: Double? = nil, maxSpeed: Double? = nil) {
        var stats = cachedEncounterStats[encounter.id] ?? EncounterStats(
            maxAltitude: 0,
            maxSpeed: 0,
            averageRSSI: 0,
            flightPointCount: 0,
            signatureCount: 0
        )
        
        if let maxAlt = maxAltitude {
            stats = EncounterStats(
                maxAltitude: maxAlt,
                maxSpeed: stats.maxSpeed,
                averageRSSI: stats.averageRSSI,
                flightPointCount: stats.flightPointCount,
                signatureCount: stats.signatureCount
            )
        }
        
        if let maxSpd = maxSpeed {
            stats = EncounterStats(
                maxAltitude: stats.maxAltitude,
                maxSpeed: maxSpd,
                averageRSSI: stats.averageRSSI,
                flightPointCount: stats.flightPointCount,
                signatureCount: stats.signatureCount
            )
        }
        
        cachedEncounterStats[encounter.id] = stats
    }
    
    var body: some View {
        #if DEBUG
        let _ = PerfHeartbeat.shared.count("StoredEncountersView")
        #endif
        List {
            // MARK: - Aircraft History Section
            Section {
                NavigationLink(destination: ADSBHistoryChartView()) {
                    HStack {
                        Image(systemName: "airplane.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title2)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Aircraft History")
                                .font(.appHeadline)
                            Text("View/visualize all tracked aircraft")
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chart.bar.xaxis")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            // MARK: - Drone Encounters Section
            // Group encounters by type - filter out any detached objects first
            let validEncounters = sortedEncounters.filter { $0.modelContext != nil }
            let fpvEncounters = validEncounters.filter { $0.id.hasPrefix("fpv-") || $0.metadata["isFPVDetection"] == "true" }
            let regularEncounters = validEncounters.filter { !$0.id.hasPrefix("fpv-") && $0.metadata["isFPVDetection"] != "true" }
            
            // FPV Detections Section
            if !fpvEncounters.isEmpty {
                Section {
                    ForEach(fpvEncounters) { encounter in
                        NavigationLink(value: encounter) {
                            EncounterRow(encounter: encounter)
                        }
                        .listRowBackground(Color(UIColor.secondarySystemGroupedBackground))
                    }
                    .onDelete { indexSet in
                        withAnimation(nil) {
                            let idsToDelete = indexSet.map { fpvEncounters[$0].id }
                            let encountersToDelete = indexSet.map { fpvEncounters[$0] }
                            
                            for encounter in encountersToDelete {
                                modelContext.delete(encounter)
                            }
                            
                            for id in idsToDelete {
                                cachedEncounterStats.removeValue(forKey: id)
                            }
                            
                            do {
                                try modelContext.save()
                                print("Deleted \(idsToDelete.count) FPV encounters: \(idsToDelete)")
                            } catch {
                                print("Failed to delete FPV encounters: \(error)")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.orange)
                        Text("FPV Detections")
                        Spacer()
                        Text("\(fpvEncounters.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Regular Drone Encounters Section
            if !regularEncounters.isEmpty {
                Section {
                    ForEach(regularEncounters) { encounter in
                        NavigationLink(value: encounter) {
                            EncounterRow(encounter: encounter)
                        }
                        .listRowBackground(Color(UIColor.secondarySystemGroupedBackground))
                    }
                    .onDelete { indexSet in
                        withAnimation(nil) {
                            let idsToDelete = indexSet.map { regularEncounters[$0].id }
                            let encountersToDelete = indexSet.map { regularEncounters[$0] }
                            
                            for encounter in encountersToDelete {
                                modelContext.delete(encounter)
                            }
                            
                            for id in idsToDelete {
                                cachedEncounterStats.removeValue(forKey: id)
                            }
                            
                            do {
                                try modelContext.save()
                                print("Deleted \(idsToDelete.count) drone encounters: \(idsToDelete)")
                            } catch {
                                print("Failed to delete drone encounters: \(error)")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "airplane")
                            .foregroundStyle(.blue)
                        Text("Remote ID Drones")
                        Spacer()
                        Text("\(regularEncounters.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search by ID or CAA Registration")
        .navigationTitle("Encounter History")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: StoredDroneEncounter.self) { encounter in
            EncounterDetailView(encounter: encounter)
                .environmentObject(cotViewModel)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first,
                       let rootVC = window.rootViewController {
                        storage.shareCSV(from: rootVC)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Picker("Sort By", selection: $sortOrder) {
                        Text("Last Seen").tag(SortOrder.lastSeen)
                        Text("First Seen").tag(SortOrder.firstSeen)
                        Text("Max Altitude").tag(SortOrder.maxAltitude)
                        Text("Max Speed").tag(SortOrder.maxSpeed)
                    }
                    
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete All", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .alert("Delete All Encounters", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                // Clear UI
                Task { @MainActor in
                    withAnimation(.none) {
                        sortedEncounters = []
                        cachedEncounterStats.removeAll()
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                    storage.deleteAllEncounters()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $editorManager.isPresented) {
            DroneInfoEditorSheet()
        }
        .onAppear {
            updateSortedEncounters()
        }
        .onChange(of: encounters.count) {
            updateSortedEncounters()
        }
        .onChange(of: searchText) {
            updateSortedEncounters()
        }
        .onChange(of: sortOrder) {
            updateSortedEncounters()
        }
    }
    
    struct EncounterRow: View {
        let encounter: StoredDroneEncounter
        
        private var isValid: Bool {
            encounter.modelContext != nil
        }
        
        private var isFPVDetection: Bool {
            guard isValid else { return false }
            return encounter.id.hasPrefix("fpv-") || encounter.metadata["isFPVDetection"] == "true"
        }
        
        private var cachedMaxAltitude: Double {
            guard isValid else { return 0 }
            return encounter.maxAltitude
        }
        
        private var cachedMaxSpeed: Double {
            guard isValid else { return 0 }
            return encounter.maxSpeed
        }
        
        private var cachedAverageRSSI: Double {
            guard isValid else { return 0 }
            return encounter.averageRSSI
        }
        
        private var flightPointCount: Int {
            guard isValid else { return 0 }
            return encounter.cachedFlightPointCount
        }
        
        private var caaRegistration: String? {
            guard isValid else { return nil }
            return encounter.metadata["caaRegistration"]
        }
        
        private var macAddress: String? {
            guard isValid else { return nil }
            return encounter.metadata["mac"]
        }
        
        private var metadata: [String: String] {
            guard isValid else { return [:] }
            return encounter.metadata
        }
        
        // FPV-specific properties
        private var fpvFrequency: String? {
            guard isValid, isFPVDetection else { return nil }
            return encounter.metadata["fpvFrequency"] ?? encounter.metadata["frequency"]
        }
        
        private var fpvSource: String? {
            guard isValid, isFPVDetection else { return nil }
            return encounter.metadata["fpvSource"]
        }
        
        var body: some View {
            if !isValid {
                EmptyView()
            } else {
                actualBody
            }
        }
        
        private var actualBody: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    // Show FPV badge for FPV detections
                    if isFPVDetection {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.orange)
                            .font(.title3)
                    }
                    
                    if !encounter.customName.isEmpty {
                        Text(encounter.customName)
                            .font(.appHeadline)
                            .foregroundColor(.primary)
                        
                        Text(isFPVDetection ? encounter.id : ensureDronePrefix(encounter.id))
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    } else {
                        if isFPVDetection {
                            // For FPV, show frequency prominently with channel detection
                            if let freq = fpvFrequency {
                                HStack(spacing: 6) {
                                    if let channel = FPVChannel.detectChannel(fromFrequency: freq) {
                                        Image(systemName: channel.icon)
                                            .foregroundStyle(channel.color)
                                        Text("FPV \(channel.name)")
                                            .font(.appHeadline)
                                        Text("(\(freq) MHz)")
                                            .font(.appCaption)
                                            .foregroundColor(.secondary)
                                    } else {
                                        Text("FPV \(freq) MHz")
                                            .font(.appHeadline)
                                    }
                                }
                            } else {
                                Text(encounter.id)
                                    .font(.appHeadline)
                            }
                        } else {
                            Text(ensureDronePrefix(encounter.id))
                                .font(.appHeadline)
                        }
                    }
                    
                    if let caaReg = caaRegistration {
                        Text("CAA: \(caaReg)")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    // Only show heading icon for non-FPV drones
                    if !isFPVDetection {
                        let heading: Double = {
                            func parseHeading(_ key: String) -> Double? {
                                guard let raw = metadata[key]?
                                    .replacingOccurrences(of: "°", with: "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                      let value = Double(raw)
                                else { return nil }
                                return (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                            }
                            
                            if let trackCourse = metadata["trackCourse"], let course = Double(trackCourse) {
                                return course
                            } else if let direction = metadata["direction"], let dir = Double(direction) {
                                return dir
                            } else {
                                return parseHeading("course") ?? parseHeading("bearing") ?? parseHeading("direction") ?? 0
                            }
                        }()
                        
                        Image(systemName: "airplane")
                            .foregroundStyle(.blue)
                            .rotationEffect(.degrees(heading - 90))
                    }
                }
                
                // FPV-specific metadata
                if isFPVDetection {
                    if let source = fpvSource {
                        Text("Source: \(source)")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Regular drone MAC address
                    if let mac = metadata["mac"] {
                        Text("MAC: \(mac)")
                            .font(.appCaption)
                    }
                }
                
                // Stats row - different for FPV vs regular drones
                if isFPVDetection {
                    fpvStatsRow
                } else {
                    regularDroneStatsRow
                }
            }
            .padding(.vertical, 4)
        }
        
        // FPV-specific stats display
        private var fpvStatsRow: some View {
            HStack(spacing: 4) {
                VStack(spacing: 2) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f", cachedAverageRSSI))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text("dBm")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 2) {
                    // Show channel icon if detected
                    if let freq = fpvFrequency,
                       let channel = FPVChannel.detectChannel(fromFrequency: freq) {
                        Image(systemName: channel.icon)
                            .font(.appCaption)
                            .foregroundStyle(channel.color)
                        Text(channel.name)
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Text("\(freq) MHz")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if let freq = fpvFrequency {
                        Image(systemName: "waveform")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Text(freq)
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Text("MHz")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "waveform")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Text("N/A")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Text("MHz")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 2) {
                    Image(systemName: "map")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    let totalDetections = Int(metadata["totalDetections"] ?? "0") ?? 0
                    let displayCount = totalDetections > 0 ? totalDetections : flightPointCount
                    Text("\(displayCount)")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text("detections")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        
        // Regular drone stats display
        private var regularDroneStatsRow: some View {
            HStack(spacing: 4) {
                VStack(spacing: 2) {
                    Image(systemName: "map")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text("\(flightPointCount)")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text("points")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f", cachedMaxAltitude))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text("m")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 2) {
                    Image(systemName: "speedometer")
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f", cachedMaxSpeed))
                        .font(.appCaption)
                        .foregroundStyle(.secondary)
                    Text("m/s")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                if cachedAverageRSSI != 0 {
                    VStack(spacing: 2) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.0f", cachedAverageRSSI))
                            .font(.appCaption)
                            .foregroundStyle(.secondary)
                        Text("dB")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        
        private func formatDuration(_ time: TimeInterval) -> String {
            let hours = Int(time) / 3600
            let minutes = Int(time) % 3600 / 60
            let seconds = Int(time) % 60
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        
        private func ensureDronePrefix(_ id: String) -> String {
            return id.hasPrefix("drone-") ? id : "drone-\(id)"
        }
    }
    
    struct EncounterDetailView: View {
        let encounter: StoredDroneEncounter
        @Environment(\.dismiss) private var dismiss
        @Environment(\.modelContext) private var modelContext
        @State private var showingDeleteConfirmation = false
        @State private var showFlightPath = true
        @State private var showReplay = false
        @State private var selectedMapType: MapStyle = .standard
        @State private var mapCameraPosition: MapCameraPosition = .automatic
        @EnvironmentObject var cotViewModel: CoTViewModel
        @State private var flightPoints: [StoredFlightPoint] = []
        @State private var signatures: [StoredSignature] = []
        @State private var isDataLoaded = false
        @State private var mapPositionSet = false
        @State private var isLoadingStarted = false
        @State private var isFPVDetection = false
        @State private var loadingTimeoutReached = false
        @State private var hasAppeared = false
        @ObservedObject private var editorManager = DroneEditorManager.shared
        
        // Cache map items to prevent constant recomputation
        @State private var cachedPilotItems: [MapPointItem] = []
        @State private var cachedHomeItems: [MapPointItem] = []
        @State private var lastSignatureHash: Int = 0
        @State private var cachedSmoothedDronePath: [CLLocationCoordinate2D] = []
        @State private var lastDronePathCount: Int = -1

        /// Catmull-Rom emits 5x the input points. Long paths are drawn raw so a
        /// retained 5000-point flight cannot become a 25000-coordinate polyline.
        private static func smoothed(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
            guard coords.count > 2, coords.count <= 600 else { return coords }
            return FlightPathSmoother.smoothPath(coords, smoothness: 4)
        }
        
        enum MapStyle {
            case standard, satellite, hybrid
        }
        
        init(encounter: StoredDroneEncounter) {
            self.encounter = encounter
        }
        
        var body: some View {
            Group {
                if encounter.modelContext == nil {
                    ContentUnavailableView(
                        "Encounter Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This encounter may have been deleted.")
                    )
                } else if !isDataLoaded {
                    VStack(spacing: 16) {
                        if loadingTimeoutReached {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text("Loading Timed Out")
                                .font(.headline)
                            Text("This encounter may have too much data or the database is busy.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try Again") {
                                loadingTimeoutReached = false
                                isLoadingStarted = false
                                isDataLoaded = false
                                Task {
                                    await loadRelationshipData()
                                }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            ProgressView()
                                .scaleEffect(1.5)
                                .progressViewStyle(CircularProgressViewStyle())
                            Text("Loading encounter data...")
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .background(Color(UIColor.systemBackground))
                    .navigationTitle("Loading...")
                    .navigationBarTitleDisplayMode(.inline)
                    .onAppear {
                        guard !hasAppeared else { return }
                        hasAppeared = true
                        
                        if !isLoadingStarted {
                            isLoadingStarted = true
                            
                            Task {
                                try? await Task.sleep(for: .seconds(10))
                                if !isDataLoaded {
                                    loadingTimeoutReached = true
                                }
                            }
                            
                            Task {
                                await loadRelationshipData()
                            }
                        }
                    }
                } else {
                    actualContent
                }
            }
        }
        
        @ViewBuilder
        private var actualContent: some View {
            // Double-check encounter is still valid before rendering
            if encounter.modelContext == nil {
                ContentUnavailableView(
                    "Encounter No Longer Available",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This encounter was deleted while loading.")
                )
            } else {
                scrollContent
            }
        }
        
        @ViewBuilder
        private var scrollContent: some View {
            ScrollView {
                VStack(spacing: 16) {
                    // Custom name and trust status section
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                // Show FPV badge for FPV detections
                                if isFPVDetection {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .foregroundColor(.orange)
                                        .font(.system(size: 24))
                                }
                                
                                if !encounter.customName.isEmpty {
                                    Text(encounter.customName)
                                        .font(.system(.title2, design: .monospaced))
                                        .foregroundColor(.primary)
                                } else {
                                    if isFPVDetection {
                                        // Extract frequency from ID or metadata with channel detection
                                        if let freq = encounter.metadata["fpvFrequency"] ?? encounter.metadata["frequency"] {
                                            HStack(spacing: 8) {
                                                if let channel = FPVChannel.detectChannel(fromFrequency: freq) {
                                                    Image(systemName: channel.icon)
                                                        .foregroundStyle(channel.color)
                                                        .font(.title2)
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text("FPV Channel \(channel.name)")
                                                            .font(.system(.title2, design: .monospaced))
                                                            .foregroundColor(.primary)
                                                        Text("\(freq) MHz • \(channel.band) Band")
                                                            .font(.appCaption)
                                                            .foregroundColor(.secondary)
                                                    }
                                                } else {
                                                    Text("FPV \(freq) MHz")
                                                        .font(.system(.title2, design: .monospaced))
                                                        .foregroundColor(.primary)
                                                }
                                            }
                                        } else {
                                            Text("FPV Detection")
                                                .font(.system(.title2, design: .monospaced))
                                                .foregroundColor(.primary)
                                        }
                                    } else {
                                        Text("Unnamed Drone")
                                            .font(.system(.title2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                Spacer()
                                
                                // Only show FAA lookup for regular drones
                                if !isFPVDetection {
                                    if let mac = encounter.metadata["mac"],
                                       !encounter.id.isEmpty {
                                        let remoteId = encounter.id.replacingOccurrences(of: "drone-", with: "")
                                        FAALookupButton(mac: mac, remoteId: remoteId)
                                    }
                                }
                                
                                Image(systemName: encounter.trustStatus.icon)
                                    .foregroundColor(encounter.trustStatus.color)
                                    .font(.system(size: 24))
                                
                                Button(action: { 
                                    editorManager.present(droneId: encounter.id)
                                }) {
                                    Image(systemName: "pencil.circle")
                                        .font(.system(size: 24))
                                        .foregroundColor(.blue)
                                }
                            }
                            
                            Text(encounter.id)
                                .font(.appCaption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                    
                    //MARK - View Sections
                    
                    // Map - only show if we have flight data and data is loaded (or if FPV with alert ring)
                    if isDataLoaded && (encounter.cachedFlightPointCount > 0 || isFPVDetection) {
                        mapSection
                    }
                    
                    // Encounters section
                    encounterStats
                    
                    //                  metadataSection // TODO metadata section
                    
                    if !encounter.macAddresses.isEmpty && encounter.macAddresses.count > 1 {
                        macSection
                    }
                    
                    // Flight data stats - only show if data is loaded
                    if isDataLoaded {
                        flightDataSection
                    }
                    
                    // Raw message
                    rawMessagesSection
                }
                .padding()
            }
            .navigationTitle("Encounter Details")
            .sheet(isPresented: $showReplay) {
                NavigationStack {
                    FlightReplayView(
                        title: encounter.customName.isEmpty ? encounter.id : encounter.customName,
                        dronePath: replayDronePath,
                        operatorPath: replayOperatorPath,
                        homeCoordinate: encounter.homeLocations
                            .sorted { $0.timestamp < $1.timestamp }
                            .last
                            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showReplay = true
                        } label: {
                            Label("Replay Flight", systemImage: "play.circle")
                        }
                        .disabled(replayDronePath.count < 2)

                        Divider()

                        Toggle("Show Flight Path", isOn: $showFlightPath)

                        Divider()
                        
                        Picker("Map Style", selection: $selectedMapType) {
                            Text("Standard").tag(MapStyle.standard)
                            Text("Satellite").tag(MapStyle.satellite)
                            Text("Hybrid").tag(MapStyle.hybrid)
                        }
                        
                        Divider()
                        
                        Button {
                            exportKML()
                        } label: {
                            Label("Export KML", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.white)
                    }
                }
            }
            .alert("Delete Encounter", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        modelContext.delete(encounter)
                        try? modelContext.save()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this encounter? This action cannot be undone.")
            }
            .onChange(of: encounter.modelContext) { oldValue, newValue in
                if newValue == nil {
                    dismiss()
                }
            }
        }
        
        private var mapSection: some View {
            let droneFlightPoints = flightPoints
                .filter { !$0.isProximityPoint }
                .filter { !($0.latitude == 0 && $0.longitude == 0) }
                .sorted { $0.timestamp < $1.timestamp }
            
            let isFPVEncounter = encounter.id.hasPrefix("fpv-") || isFPVDetection
            
            // Get proximity points with RSSI for FPV detections
            let proximityPointsWithRssi = flightPoints.filter { point in
                point.isProximityPoint && 
                point.proximityRssi != nil &&
                !(point.latitude == 0 && point.longitude == 0)
            }
            
            // Update cached items only if signatures changed
            let currentHash = signatures.map { $0.id }.hashValue
            let pilotItems: [MapPointItem]
            let homeItems: [MapPointItem]
            
            if currentHash != lastSignatureHash {
                pilotItems = buildPilotItems()
                homeItems = buildHomeItems()
                // Update cache asynchronously to avoid modifying state during view update
                DispatchQueue.main.async {
                    cachedPilotItems = pilotItems
                    cachedHomeItems = homeItems
                    lastSignatureHash = currentHash
                }
            } else {
                pilotItems = cachedPilotItems
                homeItems = cachedHomeItems
            }

            let smoothedDronePath: [CLLocationCoordinate2D]
            if droneFlightPoints.count != lastDronePathCount {
                let computed = Self.smoothed(droneFlightPoints.map { $0.coordinate })
                smoothedDronePath = computed
                DispatchQueue.main.async {
                    cachedSmoothedDronePath = computed
                    lastDronePathCount = droneFlightPoints.count
                }
            } else {
                smoothedDronePath = cachedSmoothedDronePath
            }
            
            let alertRings = cotViewModel.alertRings.filter { ring in
                ring.droneId == encounter.id ||
                ring.droneId.hasPrefix("\(encounter.id)-")
            }
            
            return Map(position: $mapCameraPosition) {
                // RSSI Proximity Rings (for FPV detections) - DRAW FIRST so they're behind everything
                Group {
                    if isFPVEncounter && !proximityPointsWithRssi.isEmpty {
                        ForEach(Array(proximityPointsWithRssi.enumerated()), id: \.offset) { idx, point in
                            let rssi = point.proximityRssi!
                            let radius = point.proximityRadius ?? 100.0
                            
                            MapCircle(center: point.coordinate, radius: radius)
                                .foregroundStyle(.orange.opacity(0.15))
                                .stroke(.orange, lineWidth: 2)
                            
                            Annotation("", coordinate: point.coordinate) {
                                VStack(spacing: 4) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .foregroundStyle(.orange)
                                        .font(.title2)
                                    
                                    Text("RSSI: \(Int(rssi)) dBm")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(.white)
                                                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                                        )
                                }
                            }
                        }
                    }
                }
                
                // Alert Rings (for live detections)
                Group {
                    if !alertRings.isEmpty {
                        ForEach(alertRings) { ring in
                            MapCircle(center: ring.centerCoordinate, radius: ring.radius)
                                .foregroundStyle(.red.opacity(0.1))
                                .stroke(.red, lineWidth: 2)
                        }
                    }
                }
                
                // Regular drone flight path
                Group {
                    if !isFPVEncounter && showFlightPath && droneFlightPoints.count > 1 {
                        MapPolyline(coordinates: smoothedDronePath)
                            .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    
                    if !isFPVEncounter && !droneFlightPoints.isEmpty {
                        if let start = droneFlightPoints.first {
                            Annotation("First Detection", coordinate: start.coordinate) {
                                Image(systemName: "1.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title2)
                                    .background(Circle().fill(.white))
                            }
                        }
                        
                        if droneFlightPoints.count > 1, let end = droneFlightPoints.last {
                            Annotation("Latest Detection", coordinate: end.coordinate) {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.red)
                                    .font(.title2)
                                    .background(Circle().fill(.white))
                            }
                        }
                    }
                }
                
                // Pilot location (flight path trail + marker)
                Group {
                    let pilotCoordinates = pilotItems.map { $0.coordinate }
                    
                    // Draw operator movement trail if multiple positions
                    if pilotCoordinates.count > 1 {
                        let smoothedPath = Self.smoothed(pilotCoordinates)
                        MapPolyline(coordinates: smoothedPath)
                            .stroke(
                                LinearGradient(
                                    colors: [.purple.opacity(0.6), .orange.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [5, 3])
                            )
                    }
                    
                    // Show latest pilot marker only
                    if let latestPilot = pilotItems.last {
                        Annotation(latestPilot.title, coordinate: latestPilot.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(latestPilot.tintColor)
                                    .frame(width: 30, height: 30)
                                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                Image(systemName: latestPilot.systemImageName)
                                    .foregroundStyle(.white)
                                    .font(.body)
                            }
                        }
                    }
                }
                
                // Home locations (multiple markers with time-based colors)
                Group {
                    ForEach(homeItems) { item in
                        Annotation(item.title, coordinate: item.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(item.tintColor)
                                    .frame(width: 30, height: 30)
                                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                Image(systemName: item.systemImageName)
                                    .foregroundStyle(.white)
                                    .font(.body)
                            }
                        }
                    }
                }
            }
            .mapStyle(mapStyleForSelectedType())
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        
        private struct MapPointItem: Identifiable {
            let id = UUID()
            let title: String
            let coordinate: CLLocationCoordinate2D
            let systemImageName: String
            let tintColor: Color
        }
        
        private func buildPilotItems() -> [MapPointItem] {
            // FPV detections don't have pilot data
            guard !isFPVDetection else { return [] }
            
            // Return all operator locations from structured data for path display
            let operatorLocs = encounter.operatorLocations.sorted { $0.timestamp < $1.timestamp }
            
            if !operatorLocs.isEmpty {
                return operatorLocs.map { opLoc in
                    MapPointItem(
                        title: "Pilot",
                        coordinate: opLoc.coordinate,
                        systemImageName: "person.fill",
                        tintColor: .orange
                    )
                }
            }
            
            // Fallback to legacy metadata if no structured data
            guard let pilotLatStr = encounter.metadata["pilotLat"],
                  let pilotLonStr = encounter.metadata["pilotLon"],
                  let pilotLat = Double(pilotLatStr),
                  let pilotLon = Double(pilotLonStr),
                  !(pilotLat == 0 && pilotLon == 0) else {
                return []
            }
            
            let pilotCoord = CLLocationCoordinate2D(latitude: pilotLat, longitude: pilotLon)
            return [MapPointItem(
                title: "Pilot",
                coordinate: pilotCoord,
                systemImageName: "person.fill",
                tintColor: .orange
            )]
        }

        
        private func buildHomeItems() -> [MapPointItem] {
            // FPV detections don't have home data
            guard !isFPVDetection else { return [] }
            
            // Return ALL home locations from structured data for time-coded display
            let homeLocs = encounter.homeLocations.sorted { $0.timestamp < $1.timestamp }
            
            if !homeLocs.isEmpty {
                // Map to items with time-based colors
                return homeLocs.enumerated().map { index, homeLoc in
                    let progress = Double(index) / Double(max(1, homeLocs.count - 1))
                    let color = colorForProgress(progress)
                    
                    return MapPointItem(
                        title: "Home \(index + 1)",
                        coordinate: homeLoc.coordinate,
                        systemImageName: "house.fill",
                        tintColor: color
                    )
                }
            }
            
            // Fallback to legacy metadata if no structured data
            guard let homeLatStr = encounter.metadata["homeLat"],
                  let homeLonStr = encounter.metadata["homeLon"],
                  let homeLat = Double(homeLatStr),
                  let homeLon = Double(homeLonStr),
                  !(homeLat == 0 && homeLon == 0) else {
                return []
            }
            
            let homeCoord = CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon)
            return [MapPointItem(
                title: "Home",
                coordinate: homeCoord,
                systemImageName: "house.fill",
                tintColor: .green
            )]
        }
        
        // Helper to generate time-based colors (green -> yellow -> red)
        private func colorForProgress(_ progress: Double) -> Color {
            if progress < 0.5 {
                // Green to Yellow
                return Color(
                    red: progress * 2.0,
                    green: 1.0,
                    blue: 0.0
                )
            } else {
                // Yellow to Red
                return Color(
                    red: 1.0,
                    green: 1.0 - ((progress - 0.5) * 2.0),
                    blue: 0.0
                )
            }
        }
        
        @MapContentBuilder
        private func drawTimeBasedSegments(_ points: [FlightPathPoint]) -> some MapContent {
            if points.count > 4 {
                let segmentSize = max(1, points.count / 4)
                
                let recentPoints = Array(points.suffix(segmentSize))
                if recentPoints.count > 1 {
                    // Smooth recent path segment
                    let smoothedRecent = Self.smoothed(recentPoints.map { $0.coordinate })
                    MapPolyline(coordinates: smoothedRecent)
                        .stroke(.red, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                
                if points.count > segmentSize * 2 {
                    let startIndex = max(0, points.count - segmentSize * 2)
                    let endIndex = points.count - segmentSize
                    let middlePoints = Array(points[startIndex..<endIndex])
                    if middlePoints.count > 1 {
                        // Smooth middle path segment
                        let smoothedMiddle = Self.smoothed(middlePoints.map { $0.coordinate })
                        MapPolyline(coordinates: smoothedMiddle)
                            .stroke(.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        
        // MARK: Pilot annotations
        @MapContentBuilder
        private func pilotLocationAnnotations() -> some MapContent {
            let items = buildPilotItems()
            
            Group {
                ForEach(items) { item in
                    Annotation(item.title,
                               coordinate: item.coordinate) {
                        Image(systemName: item.systemImageName)
                            .foregroundStyle(item.tintColor)
                            .background(Circle().fill(.white))
                    }
                }
            }
        }
        
        // MARK: Home annotations
        @MapContentBuilder
        private func homeLocationAnnotations() -> some MapContent {
            let items = buildHomeItems()
            
            Group {
                ForEach(items) { item in
                    Annotation(item.title,
                               coordinate: item.coordinate) {
                        Image(systemName: item.systemImageName)
                            .foregroundStyle(item.tintColor)
                            .background(Circle().fill(.white))
                    }
                }
            }
        }
        
        
        private var rawMessagesSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("RAW MESSAGES")
                    .font(.appHeadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                
                if let latestMessage = cotViewModel.parsedMessages.first(where: { $0.uid == encounter.id }),
                   let originalRaw = latestMessage.originalRawString {
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(originalRaw)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.tertiarySystemBackground))
                    )
                    
                } else {
                    Text("No raw message data available")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(UIColor.tertiarySystemBackground))
                        )
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }

        private var replayDronePath: [FlightReplaySample] {
            flightPoints
                .filter { !$0.isProximityPoint && !($0.latitude == 0 && $0.longitude == 0) }
                .sorted { $0.timestamp < $1.timestamp }
                .map {
                    FlightReplaySample(coordinate: $0.coordinate,
                                       altitude: $0.altitude,
                                       timestamp: $0.timestamp)
                }
        }

        private var replayOperatorPath: [FlightReplaySample] {
            encounter.operatorLocations
                .filter { !($0.latitude == 0 && $0.longitude == 0) }
                .sorted { $0.timestamp < $1.timestamp }
                .map {
                    FlightReplaySample(coordinate: $0.coordinate,
                                       altitude: $0.altitude ?? 0,
                                       timestamp: $0.timestamp)
                }
        }

        private func loadRelationshipData() async {
            // Prevent multiple simultaneous loads
            guard !isDataLoaded else {
                return
            }
            
            // Capture values we need from main actor context BEFORE going to background
            let encounterId = encounter.id
            let metadata = encounter.metadata
            let modelContext = self.modelContext
            
            guard let container = modelContext.container as ModelContainer? else {
                await MainActor.run {
                    self.isDataLoaded = true
                }
                return
            }
            
            // Create background context for expensive operations
            let backgroundContext = ModelContext(container)
            backgroundContext.autosaveEnabled = false // Don't auto-save in background
            
            var descriptor = FetchDescriptor<StoredDroneEncounter>(
                predicate: #Predicate { $0.id == encounterId }
            )
            descriptor.relationshipKeyPathsForPrefetching = [
                \.flightPoints,
                \.signatures
            ]
            
            do {
                let results = try backgroundContext.fetch(descriptor)
                
                guard let freshEncounter = results.first else {
                    await MainActor.run {
                        self.isDataLoaded = true
                    }
                    return
                }
                
                // Backfill activity log if needed
                freshEncounter.backfillActivityLog()
                try? backgroundContext.save()
                
                // Extract data from managed objects into plain tuples
                // This prevents relationship faults when switching back to main thread
                let pointsData = freshEncounter.flightPoints.map { point in
                    (latitude: point.latitude,
                     longitude: point.longitude,
                     altitude: point.altitude,
                     timestamp: point.timestamp,
                     homeLatitude: point.homeLatitude,
                     homeLongitude: point.homeLongitude,
                     isProximityPoint: point.isProximityPoint,
                     proximityRssi: point.proximityRssi,
                     proximityRadius: point.proximityRadius)
                }

                let signaturesData = freshEncounter.signatures.map { sig in
                    (timestamp: sig.timestamp,
                     rssi: sig.rssi,
                     speed: sig.speed,
                     height: sig.height,
                     mac: sig.mac)
                }
                
                let fpvDetection = encounterId.hasPrefix("fpv-") || metadata["isFPVDetection"] == "true"
                
                // Switch back to main actor to update UI state
                await MainActor.run {
                    // Check again if we're still needed (user might have navigated away)
                    guard !self.isDataLoaded else {
                        return
                    }
                    
                    // Create new unmanaged objects for UI display
                    self.flightPoints = pointsData.map { data in
                        StoredFlightPoint(
                            latitude: data.latitude,
                            longitude: data.longitude,
                            altitude: data.altitude,
                            timestamp: data.timestamp,
                            homeLatitude: data.homeLatitude,
                            homeLongitude: data.homeLongitude,
                            isProximityPoint: data.isProximityPoint,
                            proximityRssi: data.proximityRssi,
                            proximityRadius: data.proximityRadius
                        )
                    }
                    
                    self.signatures = signaturesData.map { data in
                        StoredSignature(
                            timestamp: data.timestamp,
                            rssi: data.rssi,
                            speed: data.speed,
                            height: data.height,
                            mac: data.mac
                        )
                    }
                    
                    self.isFPVDetection = fpvDetection
                    self.setupInitialMapPosition()
                    self.isDataLoaded = true
                }
            } catch {
                await MainActor.run {
                    // Still mark as loaded so user sees the error state instead of infinite loading
                    self.isDataLoaded = true
                }
            }
        }
        
        private func setupInitialMapPosition() {
            guard !mapPositionSet else { return }
            
            var allCoordinates: [CLLocationCoordinate2D] = []
            
            // Regular drone flight points
            let regularFlightPoints = flightPoints.filter { point in
                !(point.latitude == 0 && point.longitude == 0) && !point.isProximityPoint
            }
            allCoordinates.append(contentsOf: regularFlightPoints.map { $0.coordinate })
            
            if isFPVDetection || encounter.id.hasPrefix("fpv-") {
                let proximityPoints = flightPoints.filter { point in
                    point.isProximityPoint && !(point.latitude == 0 && point.longitude == 0)
                }
                allCoordinates.append(contentsOf: proximityPoints.map { $0.coordinate })
            }
            
            if let homeLatStr = encounter.metadata["homeLat"],
               let homeLonStr = encounter.metadata["homeLon"],
               let homeLat = Double(homeLatStr),
               let homeLon = Double(homeLonStr),
               !(homeLat == 0 && homeLon == 0) {
                allCoordinates.append(CLLocationCoordinate2D(latitude: homeLat, longitude: homeLon))
            }
            
            if let pilotLatStr = encounter.metadata["pilotLat"],
               let pilotLonStr = encounter.metadata["pilotLon"],
               let pilotLat = Double(pilotLatStr),
               let pilotLon = Double(pilotLonStr),
               !(pilotLat == 0 && pilotLon == 0) {
                allCoordinates.append(CLLocationCoordinate2D(latitude: pilotLat, longitude: pilotLon))
            }
            
            let alertRings = cotViewModel.alertRings.filter { ring in
                ring.droneId == encounter.id ||
                ring.droneId.hasPrefix("\(encounter.id)-")
            }
            
            if allCoordinates.count > 1 {
                let latitudes = allCoordinates.map { $0.latitude }
                let longitudes = allCoordinates.map { $0.longitude }
                
                let minLat = latitudes.min()!
                let maxLat = latitudes.max()!
                let minLon = longitudes.min()!
                let maxLon = longitudes.max()!
                
                let center = CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLon + maxLon) / 2
                )
                
                let latDelta = max((maxLat - minLat) * 1.2, 0.01)
                let lonDelta = max((maxLon - minLon) * 1.2, 0.01)
                
                mapCameraPosition = .region(MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
                ))
                mapPositionSet = true
            } else if let singleCoord = allCoordinates.first {
                mapCameraPosition = .region(MKCoordinateRegion(
                    center: singleCoord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
                mapPositionSet = true
            } else if let ring = alertRings.first {
                mapCameraPosition = .region(MKCoordinateRegion(
                    center: ring.centerCoordinate,
                    span: MKCoordinateSpan(
                        latitudeDelta: max(ring.radius / 111000 * 1.5, 0.01),
                        longitudeDelta: max(ring.radius / 111000 * 1.5, 0.01)
                    )
                ))
                mapPositionSet = true
            }
        }

        
        private func mapStyleForSelectedType() -> MapKit.MapStyle {
            switch selectedMapType {
            case .standard:
                return .standard
            case .satellite:
                return .imagery
            case .hybrid:
                return .hybrid
            }
        }
        
        private var encounterStats: some View {
            VStack(spacing: 16) {
                // MARK: - Flight Performance Stats
                VStack(alignment: .leading, spacing: 12) {
                    Text("FLIGHT PERFORMANCE")
                        .font(.appHeadline)
                        .frame(maxWidth: .infinity, alignment: .center)
                    
                    StatsGrid {
                        StatItem(title: "Max Altitude", value: String(format: "%.1f m", encounter.cachedMaxAltitude))
                        StatItem(title: "Max Speed", value: String(format: "%.1f m/s", encounter.cachedMaxSpeed))
                        StatItem(title: "Avg Signal", value: String(format: "%.0f dBm", encounter.cachedAverageRSSI))
                        
                        if encounter.id.hasPrefix("fpv-") || encounter.metadata["isFPVDetection"] == "true" {
                            let totalDetections = Int(encounter.metadata["totalDetections"] ?? "0") ?? 0
                            let proximityCount = totalDetections > 0 ? totalDetections : encounter.cachedFlightPointCount
                            StatItem(title: "Detections", value: "\(proximityCount)")
                        } else {
                            StatItem(title: "Track Points", value: "\(encounter.cachedFlightPointCount)")
                        }
                        
                        StatItem(title: "Signatures", value: "\(encounter.cachedSignatureCount)")
                        
                        // Calculate actual duration
                        let totalDuration: TimeInterval = {
                            if !encounter.activityLog.isEmpty {
                                return encounter.activityLog.reduce(0) { $0 + $1.duration }
                            }
                            if !flightPoints.isEmpty {
                                let timestamps = flightPoints.map { $0.timestamp }.sorted()
                                if let first = timestamps.first, let last = timestamps.last {
                                    return last - first
                                }
                            }
                            return encounter.lastSeen.timeIntervalSince(encounter.firstSeen)
                        }()
                        
                        StatItem(title: "Duration", value: formatCompactDuration(totalDuration))
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                
                // MARK: - Activity Timeline
                if !encounter.activityLog.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACTIVITY PERIODS (\(encounter.activityLog.count))")
                            .font(.appHeadline)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        ForEach(Array(encounter.activityLog.enumerated()), id: \.offset) { index, entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.system(.caption, design: .rounded))
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(Color.blue))
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(formatDate(entry.startTime))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.primary)
                                        
                                        HStack(spacing: 12) {
                                            HStack(spacing: 4) {
                                                Image(systemName: "clock")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.green)
                                                Text(formatTime(entry.startTime))
                                                    .font(.system(size: 12, design: .monospaced))
                                            }
                                            
                                            Image(systemName: "arrow.right")
                                                .font(.system(size: 8))
                                                .foregroundColor(.secondary)
                                            
                                            HStack(spacing: 4) {
                                                Image(systemName: "clock.badge.checkmark")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.red)
                                                Text(formatTime(entry.endTime))
                                                    .font(.system(size: 12, design: .monospaced))
                                            }
                                        }
                                        .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(formatCompactDuration(entry.duration))
                                        .font(.system(.caption, design: .rounded))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule()
                                                .fill(activityDurationColor(entry.duration))
                                        )
                                }
                            }
                            .padding(12)
                            .background(Color(UIColor.tertiarySystemGroupedBackground))
                            .cornerRadius(10)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
            }
        }
        
        // Compact duration formatter (e.g., "2h 15m" instead of "02:15:00")
        private func formatCompactDuration(_ duration: TimeInterval) -> String {
            let hours = Int(duration) / 3600
            let minutes = (Int(duration) % 3600) / 60
            let seconds = Int(duration) % 60
            
            if hours > 0 {
                return "\(hours)h \(minutes)m"
            } else if minutes > 0 {
                return "\(minutes)m \(seconds)s"
            } else {
                return "\(seconds)s"
            }
        }
        
        private func formatDateTime(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter.string(from: date)
        }
        
        private func formatDate(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
        
        private func formatTime(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            return formatter.string(from: date)
        }
        
        private func activityDurationColor(_ duration: TimeInterval) -> Color {
            if duration < 60 {
                return .orange
            } else if duration < 300 {
                return .blue
            } else {
                return .green
            }
        }
        
        private var macSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                macSectionTitle
                macSectionContent
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.yellow.opacity(0.3), lineWidth: 1)
            )
        }
        
        private var macSectionTitle: some View {
            Text("MAC RANDOMIZATION")
                .font(.appHeadline)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        
        private var macSectionContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                macSectionHeader
                macAddressScrollView
            }
        }
        
        private var macSectionHeader: some View {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("Device using MAC randomization")
                    .font(.appSubheadline)
                Spacer()
                Text("\(encounter.macAddresses.count) addresses")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        }
        
        private var macAddressScrollView: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(encounter.macAddresses).sorted(), id: \.self) { mac in
                        macAddressRow(mac)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        
        private func macAddressRow(_ mac: String) -> some View {
            HStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.yellow)
                Text(mac)
                    .font(.appCaption)
                
                // Don't access signatures relationship here - too slow
                // Just show the MAC without timestamp
                Spacer()
            }
        }
        
        
        
        private var flightDataSection: some View {
            let isFPVEncounter = encounter.id.hasPrefix("fpv-") || isFPVDetection
            
            return VStack(alignment: .leading, spacing: 8) {
                Text("FLIGHT DATA")
                    .font(.appHeadline)
                    .frame(maxWidth: .infinity, alignment: .center)
                
                // Only show charts if we have data cached
                if encounter.cachedFlightPointCount > 0 || encounter.cachedSignatureCount > 0 {
                    HStack(spacing: 20) {
                        // Only show altitude chart if we have flight points
                        if encounter.cachedFlightPointCount > 0 {
                            FlightDataChart(
                                title: "Altitude", 
                                data: flightPoints.lazy.map { $0.altitude }.filter { $0 != 0 }
                            )
                        }
                        
                        // Only show speed/RSSI if we have signatures
                        if encounter.cachedSignatureCount > 0 {
                            FlightDataChart(
                                title: "Speed", 
                                data: signatures.lazy.map { $0.speed }.filter { $0 != 0 }
                            )
                            
                            // Don't show RID RSSI for FPV encounters
                            if !isFPVEncounter {
                                FlightDataChart(
                                    title: "RSSI", 
                                    data: signatures.lazy.map { $0.rssi }.filter { $0 != 0 }
                                )
                            }
                        }
                        
                        // For FPV encounters, show RSSI from proximity points
                        if isFPVEncounter {
                            let rssiData = flightPoints
                                .filter { $0.isProximityPoint && $0.proximityRssi != nil }
                                .compactMap { $0.proximityRssi }
                                .filter { $0 != 0 }
                            
                            if !rssiData.isEmpty {
                                FlightDataChart(
                                    title: "RSSI",
                                    data: rssiData
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text("No flight data available for charts")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        
    }
    
    struct StatsGrid<Content: View>: View {
        let content: Content
        
        init(@ViewBuilder content: () -> Content) {
            self.content = content()
        }
        
        var body: some View {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                content
            }
        }
    }
    
    struct StatItem: View {
        let title: String
        let value: String
        
        var body: some View {
            VStack(spacing: 4) {
                Text(title)
                    .font(.appCaption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.appHeadline)
            }
        }
    }
    
    struct FlightDataChart: View {
        let title: String
        let data: [Double]
        
        // Accept lazy sequences
        init<S: Sequence>(title: String, data: S) where S.Element == Double {
            self.title = title
            self.data = Array(data)
        }
        
        var body: some View {
            VStack {
                Text(title)
                    .font(.appCaption)
                
                if let dataMin = data.min(), let dataMax = data.max(), data.count > 1 {
                    VStack(spacing: 4) {
                        // Use fixed range for RSSI to show better differentiation
                        let (minValue, maxValue): (Double, Double) = {
                            if title == "RSSI" {
                                // Detect if this is FPV RSSI (raw ADC values ~1000-1600) vs dBm (-100 to -30)
                                let isFPVRSSI = dataMin > 0 && dataMin > 100
                                if isFPVRSSI {
                                    // FPV hardware raw ADC values - use auto-scaling
                                    return (dataMin * 0.95, dataMax * 1.05)
                                } else {
                                    // Traditional dBm values - fixed range for better comparison
                                    return (-100.0, -30.0)
                                }
                            } else {
                                // Auto-scale for other metrics
                                return (dataMin, dataMax)
                            }
                        }()
                        
                        HStack {
                            Text("Max: \(String(format: "%.1f", dataMax))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        
                        GeometryReader { geometry in
                            Path { path in
                                let step = geometry.size.width / CGFloat(data.count - 1)
                                let difference = maxValue - minValue
                                let scale = difference != 0 ? geometry.size.height / CGFloat(difference) : 0
                                
                                // Clamp values to the visible range for RSSI
                                let clampedFirstValue = max(minValue, min(maxValue, data[0]))
                                path.move(to: CGPoint(
                                    x: 0,
                                    y: geometry.size.height - (clampedFirstValue - minValue) * scale
                                ))
                                
                                for i in 1..<data.count {
                                    let clampedValue = max(minValue, min(maxValue, data[i]))
                                    path.addLine(to: CGPoint(
                                        x: CGFloat(i) * step,
                                        y: geometry.size.height - (clampedValue - minValue) * scale
                                    ))
                                }
                            }
                            .stroke(.blue, lineWidth: 2)
                        }
                        
                        HStack {
                            Text("Min: \(String(format: "%.1f", dataMin))")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                } else {
                    Text("Insufficient data")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 200, height: 120)
        }
    }
}

private func formatDuration(_ time: TimeInterval) -> String {
    let hours = Int(time) / 3600
    let minutes = Int(time) % 3600 / 60
    let seconds = Int(time) % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}

extension StoredEncountersView.EncounterDetailView {
    private func generateKML(for encounter: StoredDroneEncounter) -> String {
        // Use loaded state data instead of direct relationship access
        let regularPoints = flightPoints.filter { !$0.isProximityPoint }
        
        var kmlContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <n>\(encounter.id) Flight Path</n>
            <Style id="flightPath">
              <LineStyle>
                <color>ff0000ff</color>
                <width>4</width>
              </LineStyle>
            </Style>
            <Style id="pilotLocation">
              <IconStyle>
                <color>ff00aaff</color>
                <scale>1.0</scale>
                <Icon>
                  <href>http://maps.google.com/mapfiles/kml/shapes/man.png</href>
                </Icon>
              </IconStyle>
            </Style>
            <Style id="takeoffLocation">
              <IconStyle>
                <color>ff00ff00</color>
                <scale>1.0</scale>
                <Icon>
                  <href>http://maps.google.com/mapfiles/kml/shapes/airports.png</href>
                </Icon>
              </IconStyle>
            </Style>
            <Placemark>
              <n>\(encounter.id) Track</n>
              <styleUrl>#flightPath</styleUrl>
              <LineString>
                <altitudeMode>absolute</altitudeMode>
                <coordinates>
                    \(regularPoints.map { point in
                        "\(point.longitude),\(point.latitude),\(point.altitude)"
                    }.joined(separator: "\n                "))
                </coordinates>
              </LineString>
            </Placemark>
        """
        
        // Add pilot location if available
        if let pilotLatStr = encounter.metadata["pilotLat"],
           let pilotLonStr = encounter.metadata["pilotLon"],
           let pilotLat = Double(pilotLatStr),
           let pilotLon = Double(pilotLonStr),
           pilotLat != 0 || pilotLon != 0 {
            kmlContent += """
            
            <Placemark>
              <name>Pilot Location</name>
              <styleUrl>#pilotLocation</styleUrl>
              <Point>
                <coordinates>\(pilotLon),\(pilotLat),0</coordinates>
              </Point>
            </Placemark>
            """
        }
        
        // Add takeoff location if available
        if let takeoffLatStr = encounter.metadata["homeLat"],
           let takeoffLonStr = encounter.metadata["homeLon"],
           let takeoffLat = Double(takeoffLatStr),
           let takeoffLon = Double(takeoffLonStr),
           takeoffLat != 0 || takeoffLon != 0 {
            kmlContent += """
            
            <Placemark>
              <name>Takeoff Location</name>
              <styleUrl>#takeoffLocation</styleUrl>
              <Point>
                <coordinates>\(takeoffLon),\(takeoffLat),0</coordinates>
              </Point>
            </Placemark>
            """
        }
        
        kmlContent += """
          </Document>
        </kml>
        """
        
        return kmlContent
    }
    
    func exportKML(from viewController: UIViewController? = nil) {
        // Generate KML content
        let kmlContent = generateKML(for: encounter)
        
        // Ensure KML stuff is valid
        guard let kmlData = kmlContent.data(using: .utf8) else {
            print("Failed to convert KML content to NSData.")
            return
        }
        
        // Stamp the filename
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let timestamp = dateFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "_")
        let filename = "\(encounter.id)_flightpath_\(timestamp).kml"
        
        // Create a temporary file URL to share it
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileURL = tempDirectory.appendingPathComponent(filename)
        
        // Write KML data to the file
        do {
            try kmlData.write(to: fileURL)
        } catch {
            print("Failed to write KML data to file: \(error)")
            return
        }
        
        // Create the activity item source for sharing
        let kmlDataItem = KMLDataItem(fileURL: fileURL, filename: filename)
        
        let activityVC = UIActivityViewController(
            activityItems: [kmlDataItem],
            applicationActivities: nil
        )
        
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
                activityVC.popoverPresentationController?.permittedArrowDirections = []
            }
            
            DispatchQueue.main.async {
                window.rootViewController?.present(activityVC, animated: true)
            }
        }
    }
    
    // Workaround to prevent writing where we don't want to
    class KMLDataItem: NSObject, UIActivityItemSource {
        private let fileURL: URL
        private let filename: String
        
        init(fileURL: URL, filename: String) {
            self.fileURL = fileURL
            self.filename = filename
            super.init()
        }
        
        func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
            return fileURL
        }
        
        func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
            return fileURL
        }
        
        func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
            return "application/vnd.google-earth.kml+xml"
        }
        
        func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
            return filename
        }
        
        func activityViewController(_ activityViewController: UIActivityViewController, filenameForActivityType activityType: UIActivity.ActivityType?) -> String {
            return filename
        }
    }
    
}
