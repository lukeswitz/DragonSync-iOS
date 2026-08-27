//
//  AircraftListView.swift
//  WarDragon
//
//  List view for displaying tracked aircraft from ADS-B
//

import SwiftUI
import MapKit

struct AircraftListView: View {
    @ObservedObject var cotViewModel: CoTViewModel
    @State private var searchText = ""
    @State private var sortBy: SortOption = .distance
    @State private var showFilters = false
    @State private var showUnifiedMap = false
    
    enum SortOption: String, CaseIterable {
        case distance = "Distance"
        case altitude = "Altitude"
        case speed = "Speed"
        case callsign = "Callsign"
    }
    
    var filteredAircraft: [Aircraft] {
        var aircraft = cotViewModel.aircraftTracks
        
        // Apply search filter
        if !searchText.isEmpty {
            aircraft = aircraft.filter { ac in
                ac.displayName.localizedCaseInsensitiveContains(searchText) ||
                ac.hex.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Apply sorting
        switch sortBy {
        case .distance:
            // Would need user location to sort by distance
            return aircraft.sorted { ($0.seen ?? 999) < ($1.seen ?? 999) }
        case .altitude:
            return aircraft.sorted { ($0.altitude ?? 0) > ($1.altitude ?? 0) }
        case .speed:
            return aircraft.sorted { ($0.groundSpeed ?? 0) > ($1.groundSpeed ?? 0) }
        case .callsign:
            return aircraft.sorted { $0.displayName < $1.displayName }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if cotViewModel.aircraftTracks.isEmpty {
                emptyStateView
            } else {
                List {
                    if cotViewModel.aircraftTracks.count >= 2 {
                        Section {
                            aircraftMapPreview
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    
                    Section {
                        ForEach(filteredAircraft) { aircraft in
                            AircraftRow(aircraft: aircraft, isCompact: cotViewModel.aircraftTracks.count >= 2)
                                .opacity(aircraft.isStale ? 0.6 : 1.0)
                        }
                    } header: {
                        HStack {
                            Text("\(filteredAircraft.count) Aircraft")
                            Spacer()
                            if staleAircraftCount > 0 {
                                Text("\(activeAircraftCount) active · \(staleAircraftCount) stale")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Search by callsign or ICAO")
                .refreshable {
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button {
                            sortBy = option
                        } label: {
                            HStack {
                                Image(systemName: iconForSortOption(option))
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
                    Label("Sort", systemImage: sortIcon)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                }
                .help("Sort aircraft")
                
                Button(action: {
                    withAnimation {
                        cotViewModel.clearAircraftTracks()
                    }
                }) {
                    Label("Clear All", systemImage: "xmark.bin.fill")
                        .labelStyle(.iconOnly)
                }
                .help("Clear all aircraft")
                .disabled(cotViewModel.aircraftTracks.isEmpty)
            }
        }
        .navigationDestination(isPresented: $showUnifiedMap) {
            LazyView {
                UnifiedAircraftMapView(cotViewModel: cotViewModel)
            }
        }
    }
    
    private var aircraftMapPreview: some View {
        Button {
            showUnifiedMap = true
        } label: {
            LiveAircraftMapPreview(cotViewModel: cotViewModel)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Subviews
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "airplane.departure")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("No Aircraft Tracked")
                .font(.headline)
            
            Text("Enable ADS-B or OpenSky in Settings to track aircraft")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Computed Properties
    
    private var activeAircraftCount: Int {
        filteredAircraft.filter { !$0.isStale }.count
    }
    
    private var staleAircraftCount: Int {
        filteredAircraft.filter { $0.isStale }.count
    }
    
    private var highestAircraft: Int? {
        cotViewModel.aircraftTracks.compactMap { $0.altitudeFeet }.max()
    }
    
    /// Icon that reflects the current sort option
    private var sortIcon: String {
        switch sortBy {
        case .distance:
            return "arrow.up.and.down.circle"
        case .altitude:
            return "arrow.up.arrow.down.circle"
        case .speed:
            return "speedometer"
        case .callsign:
            return "textformat.abc"
        }
    }
    
    /// Get icon for a specific sort option (for menu items)
    private func iconForSortOption(_ option: SortOption) -> String {
        switch option {
        case .distance:
            return "location.circle"
        case .altitude:
            return "arrow.up.right"
        case .speed:
            return "gauge.with.needle"
        case .callsign:
            return "textformat.abc.dottedunderline"
        }
    }
}

#Preview {
    NavigationStack {
        AircraftListView(cotViewModel: CoTViewModel(statusViewModel: StatusViewModel()))
            .navigationTitle("Aircraft")
    }
}
private struct LiveAircraftMapPreview: View {
    @ObservedObject var cotViewModel: CoTViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            Map(bounds: MapCameraBounds(centerCoordinateBounds: mapRegion)) {
                // Flight paths
                ForEach(cotViewModel.aircraftTracks) { aircraft in
                    let flightPath = getAircraftFlightPath(for: aircraft)
                    if flightPath.count > 1 {
                        MapPolyline(coordinates: flightPath)
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                
                // Aircraft markers
                ForEach(cotViewModel.aircraftTracks) { aircraft in
                    if let coordinate = aircraft.coordinate {
                        Annotation(aircraft.callsign, coordinate: coordinate) {
                            aircraftAnnotationIcon(for: aircraft)
                        }
                    }
                }
            }
            .mapStyle(.standard)
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "airplane")
                            .foregroundStyle(.cyan)
                            .font(.caption)
                        Text("\(cotViewModel.aircraftTracks.count)")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.semibold)
                    }
                    
                    if cotViewModel.aircraftTracks.filter({ $0.isEmergency }).count > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text("\(cotViewModel.aircraftTracks.filter({ $0.isEmergency }).count)")
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.semibold)
                        }
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(8)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                HStack {
                    Image(systemName: "map")
                        .font(.caption)
                    Text("Live aircraft positions")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
    }
    
    private func aircraftAnnotationIcon(for aircraft: Aircraft) -> some View {
        let iconName = aircraft.isOnGround ? "airplane.arrival" : "airplane"
        let iconColor: Color = aircraft.isEmergency ? .red : (aircraft.isStale ? .gray : .cyan)
        let rotation = Double(aircraft.track ?? 0) - 90
        let opacity = aircraft.isStale ? 0.5 : 1.0
        
        return Image(systemName: iconName)
            .foregroundStyle(iconColor)
            .font(.title3)
            .rotationEffect(.degrees(rotation))
            .background(
                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
            )
            .opacity(opacity)
    }
    
    private func getAircraftFlightPath(for aircraft: Aircraft) -> [CLLocationCoordinate2D] {
        var coordinates = aircraft.positionHistory.map { $0.coordinate }
        
        // Ensure path ends at current position
        if let currentCoord = aircraft.coordinate {
            if coordinates.isEmpty {
                coordinates = [currentCoord]
            } else {
                coordinates[coordinates.count - 1] = currentCoord
            }
        }
        
        return coordinates
    }
    
    private var mapRegion: MKCoordinateRegion {
        let allCoords = cotViewModel.aircraftTracks.compactMap { $0.coordinate }
        
        guard !allCoords.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
        }
        
        if allCoords.count == 1 {
            return MKCoordinateRegion(
                center: allCoords[0],
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
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
            latitudeDelta: max((maxLat - minLat) * 1.5, 0.1),
            longitudeDelta: max((maxLon - minLon) * 1.5, 0.1)
        )
        
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Unified Aircraft Map View
/// Full-screen map view for all aircraft with flight paths
private struct UnifiedAircraftMapView: View {
    @ObservedObject var cotViewModel: CoTViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mapCameraPosition: MapCameraPosition
    @State private var showFlightPaths = true
    @State private var selectedMapStyle: MapStyleOption = .standard
    @State private var userHasMovedMap = false
    
    enum MapStyleOption {
        case standard
        case hybrid
        case satellite
        
        var mapStyle: MapStyle {
            switch self {
            case .standard: return .standard
            case .hybrid: return .hybrid
            case .satellite: return .imagery
            }
        }
    }
    
    init(cotViewModel: CoTViewModel) {
        self.cotViewModel = cotViewModel
        
        let allCoords = cotViewModel.aircraftTracks.compactMap { $0.coordinate }
        
        if allCoords.count > 1 {
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
            
            let region = MKCoordinateRegion(center: center, span: span)
            _mapCameraPosition = State(initialValue: .region(region))
        } else if let firstCoord = allCoords.first {
            let region = MKCoordinateRegion(
                center: firstCoord,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
            _mapCameraPosition = State(initialValue: .region(region))
        } else {
            _mapCameraPosition = State(initialValue: .region(
                MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
                )
            ))
        }
    }
    
    var body: some View {
        ZStack {
            Map(position: $mapCameraPosition, interactionModes: .all) {
                // Aircraft flight paths
                if showFlightPaths {
                    ForEach(cotViewModel.aircraftTracks, id: \.hex) { aircraft in
                        let coordinates = getAircraftFlightPath(for: aircraft)
                        
                        if coordinates.count > 1 {
                            MapPolyline(coordinates: coordinates)
                                .stroke(aircraft.isStale ? Color.gray : Color.cyan, 
                                       style: StrokeStyle(lineWidth: aircraft.isStale ? 1.5 : 2, 
                                                         lineCap: .round, 
                                                         lineJoin: .round))
                        }
                    }
                }
                
                // Aircraft markers
                ForEach(cotViewModel.aircraftTracks, id: \.hex) { aircraft in
                    if let coordinate = aircraft.coordinate {
                        Annotation(aircraft.displayName, coordinate: coordinate) {
                            VStack(spacing: 2) {
                                ZStack {
                                    Image(systemName: aircraftIcon(for: aircraft))
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(aircraft.isEmergency ? .red : (aircraft.isStale ? .gray : .cyan))
                                        .rotationEffect(.degrees((aircraft.track ?? 0) - 90))
                                        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                                        .opacity(aircraft.isStale ? 0.5 : 1.0)
                                }
                                
                                Text(aircraft.displayName)
                                    .font(.caption2)
                                    .bold()
                                    .foregroundColor(.primary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(aircraft.isStale ? .gray.opacity(0.2) : .cyan.opacity(0.2))
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(4)
                                    .opacity(aircraft.isStale ? 0.7 : 1.0)
                                
                                if let alt = aircraft.altitudeFeet {
                                    Text("\(alt)ft")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(4)
                                        .opacity(aircraft.isStale ? 0.7 : 1.0)
                                }
                                
                                if aircraft.isStale {
                                    Text("Stale")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(.ultraThinMaterial)
                                        .cornerRadius(4)
                                }
                            }
                        }
                    }
                }
            }
            .mapStyle(selectedMapStyle.mapStyle)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { _ in
                        userHasMovedMap = true
                    }
            )
            .gesture(
                MagnificationGesture(minimumScaleDelta: 0.01)
                    .onChanged { _ in
                        userHasMovedMap = true
                    }
            )
            
            // Overlay controls
            VStack {
                HStack {
                    Spacer()
                    
                    // Flight Path Toggle
                    Button {
                        showFlightPaths.toggle()
                    } label: {
                        Label(showFlightPaths ? "Paths" : "Paths", systemImage: showFlightPaths ? "arrow.triangle.turn.up.right.diamond.fill" : "arrow.triangle.turn.up.right.diamond")
                            .foregroundStyle(.white)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                    .padding(.top)
                    
                    // Map Style Picker
                    Menu {
                        Button {
                            selectedMapStyle = .standard
                        } label: {
                            Label("Standard", systemImage: selectedMapStyle == .standard ? "checkmark" : "map")
                        }
                        
                        Button {
                            selectedMapStyle = .hybrid
                        } label: {
                            Label("Hybrid", systemImage: selectedMapStyle == .hybrid ? "checkmark" : "map.fill")
                        }
                        
                        Button {
                            selectedMapStyle = .satellite
                        } label: {
                            Label("Satellite", systemImage: selectedMapStyle == .satellite ? "checkmark" : "globe.americas.fill")
                        }
                    } label: {
                        Label("Map", systemImage: "map")
                            .foregroundStyle(.white)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                    .padding(.top)
                    
                    // Fit to View button
                    Button(action: resetMapView) {
                        Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
                            .foregroundStyle(.white)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                    .padding(.top)
                    .padding(.trailing)
                }
                
                Spacer()
                
                // Aircraft count badge - tapping dismisses and returns to list
                Button(action: {
                    dismiss()
                }) {
                    VStack(spacing: 4) {
                        Text("\(cotViewModel.aircraftTracks.count) Aircraft")
                            .font(.footnote)
                            .foregroundColor(.cyan)
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }
                .padding(.bottom)
            }
        }
        .navigationTitle("Aircraft Map")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func aircraftIcon(for aircraft: Aircraft) -> String {
        if aircraft.isOnGround {
            return "airplane.arrival"
        } else if let vr = aircraft.verticalRate {
            if vr > 500 {
                return "airplane.departure"
            } else if vr < -500 {
                return "airplane.arrival"
            }
        }
        return "airplane"
    }
    
    private func getAircraftFlightPath(for aircraft: Aircraft) -> [CLLocationCoordinate2D] {
        var coordinates = aircraft.positionHistory.map { $0.coordinate }
        
        // Ensure path ends at current position for seamless alignment
        if let currentCoord = aircraft.coordinate {
            if coordinates.isEmpty {
                coordinates = [currentCoord]
            } else {
                // Replace last coordinate with current to ensure perfect alignment
                coordinates[coordinates.count - 1] = currentCoord
            }
        }
        
        return coordinates
    }
    
    private func resetMapView() {
        userHasMovedMap = false
        
        let allCoords = cotViewModel.aircraftTracks.compactMap { $0.coordinate }
        
        guard !allCoords.isEmpty else { return }
        
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
            latitudeDelta: max((maxLat - minLat) * 1.2, 0.05),
            longitudeDelta: max((maxLon - minLon) * 1.2, 0.05)
        )
        
        let region = MKCoordinateRegion(center: center, span: span)
        
        withAnimation {
            mapCameraPosition = .region(region)
        }
    }
}


