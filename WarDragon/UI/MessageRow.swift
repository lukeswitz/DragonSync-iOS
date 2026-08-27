//
//  MessageRow.swift
//  WarDragon
//
//  Created by Luke on 11/18/24.
//

import SwiftUI
import MapKit

// MARK: - Drone Editor Manager

@MainActor
class DroneEditorManager: ObservableObject {
    static let shared = DroneEditorManager()
    
    @Published var isPresented: Bool = false
    @Published var editingDroneId: String? = nil
    @Published var customName: String = ""
    @Published var trustStatus: DroneSignature.UserDefinedInfo.TrustStatus = .unknown
    
    private init() {}
    
    func present(droneId: String) {
        let encounter = SwiftDataStorageManager.shared.fetchEncounter(id: droneId)
        
        self.editingDroneId = droneId
        self.customName = encounter?.customName ?? ""
        self.trustStatus = encounter?.trustStatus ?? .unknown
        self.isPresented = true

        NotificationCenter.default.post(name: Notification.Name("DroneEditorPresented"), object: nil)
    }
    
    func dismiss() {
        isPresented = false
        
        NotificationCenter.default.post(name: Notification.Name("DroneEditorDismissed"), object: nil)
        
        // Clear state after a short delay to allow sheet animation to complete
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run {
                self.editingDroneId = nil
                self.customName = ""
                self.trustStatus = .unknown
            }
        }
    }
    
    func saveChanges() {
        guard let droneId = editingDroneId else { return }
        
        SwiftDataStorageManager.shared.updateDroneInfo(
            id: droneId,
            name: customName,
            trustStatus: trustStatus
        )
        
        dismiss()
    }
}

// MARK: - Drone Info Editor Sheet

struct DroneInfoEditorSheet: View {
    @ObservedObject var manager: DroneEditorManager = .shared
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Drone Name", text: $manager.customName)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.appDefault)
                    .padding(.bottom, 8)
                    .autocorrectionDisabled()
                
                Text("Trust Status")
                    .font(.appSubheadline)
                    .padding(.bottom, 4)
                
                HStack(spacing: 16) {
                    TrustButton(
                        title: "Trusted",
                        icon: "checkmark.shield.fill",
                        color: .green,
                        isSelected: manager.trustStatus == .trusted,
                        action: { manager.trustStatus = .trusted }
                    )
                    
                    TrustButton(
                        title: "Unknown",
                        icon: "shield.fill",
                        color: .gray,
                        isSelected: manager.trustStatus == .unknown,
                        action: { manager.trustStatus = .unknown }
                    )
                    
                    TrustButton(
                        title: "Untrusted",
                        icon: "xmark.shield.fill",
                        color: .red,
                        isSelected: manager.trustStatus == .untrusted,
                        action: { manager.trustStatus = .untrusted }
                    )
                }
                .padding(.bottom, 16)
                
                Button(action: manager.saveChanges) {
                    Text("Save")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Edit Drone Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        manager.dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }
}

struct MessageRow: View, Equatable {
    let message: CoTViewModel.CoTMessage
    let cotViewModel: CoTViewModel
    let isCompact: Bool
    @State private var droneEncounter: StoredDroneEncounter? = nil
    @State private var droneSignature: DroneSignature? = nil
    @State private var activeSheet: SheetType?
    @State private var showingSaveConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingFAAInfo = false
    @State private var showingFAAError = false
    @State private var faaData: [String: Any]?
    @State private var faaError: String?
    @State private var isLoadingFAA = false
    @State private var isEditingThisDrone = false
    @StateObject private var faaService = FAAService.shared

    @State private var cachedDisplayName: String = ""
    @State private var cachedDisplayDetails: String = ""
    @State private var cachedDisplayRSSI: String = ""
    @State private var cachedTrustStatus: DroneSignature.UserDefinedInfo.TrustStatus = .unknown
    
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message.uid == rhs.message.uid && 
        lhs.isCompact == rhs.isCompact &&
        lhs.message.lastUpdated == rhs.message.lastUpdated &&
        lhs.message.rssi == rhs.message.rssi &&
        lhs.message.alt == rhs.message.alt &&
        lhs.message.speed == rhs.message.speed
    }
    
    init(message: CoTViewModel.CoTMessage, cotViewModel: CoTViewModel, isCompact: Bool = false) {
        self.message = message
        self.cotViewModel = cotViewModel
        self.isCompact = isCompact
    }
    
    enum SheetType: Identifiable {
        case liveMap
        case detailView
        
        var id: Int { hashValue }
    }
    
    //MARK - FPV
    private var displayRSSI: String {
        if message.isFPVDetection {
            return message.fpvSignalStrengthFormatted
        } else if let rssi = getRSSI() {
            if rssi > 1000 {
                // MDN-style values
                return String(format: "%.0f", rssi)
            } else {
                // Standard dBm values
                return String(format: "%.0f dBm", rssi)
            }
        }
        return "Unknown"
    }

    private var displayName: String {
        if message.isFPVDetection {
            return message.fpvDisplayName
        }
        return message.description.isEmpty ? "Unnamed Drone" : message.description
    }
    
    private var spoofDetectionInfo: (isSpoofed: Bool, confidence: Double, reasons: [String])? {
        guard let encounter = currentEncounter,
              let latest = encounter.signatures.last,
              latest.isSpoofed else {
            return nil
        }
        return (latest.isSpoofed, latest.spoofConfidence, latest.spoofReasons)
    }
    
    private var shouldShowSpoofWarning: Bool {
        guard let info = spoofDetectionInfo else { return false }
        return info.confidence > 0.6
    }
    
    private var spoofIndicatorColor: Color {
        guard let info = spoofDetectionInfo else { return .gray }
        if info.confidence >= 0.85 { return .red }
        if info.confidence >= 0.7 { return .orange }
        return .yellow
    }

    private var displayDetails: String {
        if message.isFPVDetection {
            // Check for channel detection
            if let freq = message.fpvFrequency,
               let channel = FPVChannel.detectChannel(fromFrequency: String(freq)) {
                return "\(channel.name) • \(freq) MHz • \(channel.band) Band"
            }
            return message.fpvFrequencyFormatted
        }
        
        // Regular drone details
        var details: [String] = []
        
        if let mac = getMAC() {
            details.append(mac)
        }
        
        if message.speed != "0.0" && !message.speed.isEmpty {
            details.append("\(message.speed) m/s")
        }
        
        return details.joined(separator: " • ")
    }
    
    private var currentEncounter: StoredDroneEncounter? {
        droneEncounter ?? DetectionViewCache.shared.encounter(for: message.uid)
    }
    
    private var signature: DroneSignature? {
        droneSignature
    }
    
    private func removeDroneFromTracking() {
        var baseId = message.uid.replacingOccurrences(of: "drone-", with: "")
        baseId = baseId.replacingOccurrences(of: "fpv-", with: "")
        
        let droneId = message.uid.hasPrefix("drone-") ? message.uid : "drone-\(message.uid)"
        let fpvId = message.uid.hasPrefix("fpv-") ? message.uid : "fpv-\(baseId)"
        
        var idsToRemove = [
            message.uid,
            droneId,
            baseId,
            "drone-\(baseId)",
            fpvId
        ]
        
        if message.isFPVDetection {
            idsToRemove.append(message.id)
            idsToRemove.append("fpv-\(message.id)")
        }
        
        for id in idsToRemove {
            SwiftDataStorageManager.shared.markAsDoNotTrack(id: id)
        }
        
        cotViewModel.parsedMessages.removeAll { msg in
            return idsToRemove.contains(msg.uid) || idsToRemove.contains(msg.id) || msg.uid.contains(baseId) || msg.id.contains(baseId)
        }
        
        cotViewModel.droneSignatures.removeAll { signature in
            return idsToRemove.contains(signature.primaryId.id)
        }
        
        for id in idsToRemove {
            cotViewModel.macIdHistory.removeValue(forKey: id)
            cotViewModel.macProcessing.removeValue(forKey: id)
        }
        
        cotViewModel.alertRings.removeAll { ring in
            return idsToRemove.contains(ring.droneId) || ring.droneId.contains(baseId)
        }
        
        for id in idsToRemove {
            WebhookManager.shared.clearNotificationHistory(for: id)
        }
        
        cotViewModel.objectWillChange.send()
        
        print("Stopped tracking drone/FPV with IDs: \(idsToRemove)")
    }
    
    private func deleteDroneFromStorage() {
        var baseId = message.uid.replacingOccurrences(of: "drone-", with: "")
        baseId = baseId.replacingOccurrences(of: "fpv-", with: "")
        
        var possibleIds = [
            message.uid,
            "drone-\(message.uid)",
            baseId,
            "drone-\(baseId)",
            "fpv-\(baseId)"
        ]
        
        // For FPV detections, also include message.id variants
        if message.isFPVDetection {
            possibleIds.append(message.id)
            possibleIds.append("fpv-\(message.id)")
        }
        
        for id in possibleIds {
            SwiftDataStorageManager.shared.deleteEncounter(id: id)
        }
    }

    // MARK: - Helper Methods
    
    private func triggerFAALookup() {
        guard let mac = message.mac else { return }
        let remoteId = message.uid.replacingOccurrences(of: "drone-", with: "")
        
        isLoadingFAA = true
        Task {
            if let data = await faaService.queryFAAData(mac: mac, remoteId: remoteId) {
                faaData = data
                showingFAAInfo = true
            } else if let error = faaService.error {
                faaError = error
                showingFAAError = true
            }
            isLoadingFAA = false
        }
    }
    
    private func rssiColor(_ rssi: Double) -> Color {
        switch rssi {
        case -50...0: return .green
        case -70..<(-50): return .yellow
        case -80..<(-70): return .orange
        default: return .red
        }
    }
    
    private func getRSSI() -> Double? {
        if let signature = signature, let rssi = signature.transmissionInfo.signalStrength {
            return rssi
        }
        
        if let rssi = message.rssi {
            return Double(rssi)
        }
        
        if let basicId = message.rawMessage["Basic ID"] as? [String: Any] {
            if let rssi = basicId["RSSI"] as? Double {
                return rssi
            }
            if let rssi = basicId["rssi"] as? Double {
                return rssi
            }
        }
        
        return nil
    }
    
    private func getMAC() -> String? {
        if let signature = signature,
           let mac = signature.transmissionInfo.macAddress,
           !mac.isEmpty {
            return mac.uppercased()
        }
        
        if let mac = message.mac, !mac.isEmpty {
            return mac.uppercased()
        }
        
        if let basicId = message.rawMessage["Basic ID"] as? [String: Any] {
            if let mac = basicId["MAC"] as? String, !mac.isEmpty {
                return mac.uppercased()
            }
        }
        
        return nil
    }
    
    // MARK: - Subview Builders
    
    @ViewBuilder
    private func headerView() -> some View {
        HStack {
            let customName = currentEncounter?.customName ?? ""
            let trustStatus = currentEncounter?.trustStatus ?? .unknown
            
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    if shouldShowSpoofWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(spoofIndicatorColor)
                            .font(.caption)
                    }
                    
                    if !customName.isEmpty {
                        Text(customName)
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }
                
                if message.isFPVDetection {
                    if let freq = message.fpvFrequency,
                       let channel = FPVChannel.detectChannel(fromFrequency: String(freq)) {
                        HStack(spacing: 8) {
                            Image(systemName: channel.icon)
                                .foregroundStyle(channel.color)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                // Only show channel name if no custom name
                                if customName.isEmpty {
                                    Text("FPV Channel \(channel.name)")
                                        .font(.system(.title3, design: .monospaced))
                                        .foregroundColor(.primary)
                                } else {
                                    Text("Channel \(channel.name)")
                                        .font(.appCaption)
                                        .foregroundColor(.secondary)
                                }
                                Text("\(freq) MHz • \(channel.band) Band")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        // No channel detected - show FPV display name only if no custom name
                        if customName.isEmpty {
                            HStack {
                                Text(message.fpvDisplayName)
                                    .font(.system(.title3, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .onAppear {
                                        print("Displaying FPV: ID=\(message.id), UID=\(message.uid)")
                                    }
                            }
                        } else {
                            // Show frequency as subtitle
                            if let freq = message.fpvFrequency {
                                Text("\(freq) MHz")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } else {
                    // Regular drone - only show ID if no custom name
                    if customName.isEmpty {
                        HStack {
                            Text(message.id)
                                .font(.system(.title3, design: .monospaced))
                                .foregroundColor(.primary)
                                .onAppear {
                                    print("Displaying drone: ID=\(message.id), UID=\(message.uid)")
                                }
                        }
                    } else {
                        // Show ID as subtitle
                        Text(message.id)
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let caaReg = message.caaRegistration, !caaReg.isEmpty {
                    Text("CAA ID: \(caaReg)")
                        .font(.appSubheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                // Status indicator
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(message.statusColor)
                            .frame(width: 8, height: 8)
                        Text(message.statusDescription)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(message.statusColor)
                    }
                    
                    Image(systemName: trustStatus.icon)
                        .foregroundColor(trustStatus.color)
                        .font(.system(size: 18))
                }
                
                // Add FAA lookup button if we have the necessary IDs
                if message.idType.contains("Serial Number") ||
                    message.idType.contains("ANSI") ||
                    message.idType.contains("CTA-2063-A") {
                    FAALookupButton(mac: message.mac, remoteId: message.uid.replacingOccurrences(of: "drone-", with: ""))
                        .buttonStyle(.plain)
                }
                
                Menu {
                    Button(action: { 
                        DroneEditorManager.shared.present(droneId: message.uid)
                    }) {
                        Label("Edit Info", systemImage: "pencil")
                    }
                    
                    Button(action: { activeSheet = .liveMap }) {
                        Label("Live Map", systemImage: "map")
                    }
                    
                    // Add FAA lookup to menu when there are multiple items
                    if message.idType.contains("Serial Number") ||
                        message.idType.contains("ANSI") ||
                        message.idType.contains("CTA-2063-A") {
                        Button(action: { 
                            // Trigger the FAA lookup through a state variable
                            triggerFAALookup()
                        }) {
                            Label("FAA Lookup", systemImage: "airplane.departure")
                        }
                    }
                    
                    Divider()
                    
                    Button(action: {
                        removeDroneFromTracking()
                    }) {
                        Label("Stop Tracking", systemImage: "eye.slash")
                    }
                    
                    Button(role: .destructive, action: {
                        showingDeleteConfirmation = true
                    }) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    @ViewBuilder
    private func typeInfoView() -> some View {
        Text("Type: \(message.type)")
            .font(.appSubheadline)
    }
    
    @ViewBuilder
    private func signalSourcesView() -> some View {
        if !message.signalSources.isEmpty {
            VStack(alignment: .leading) {
                // Sort by timestamp (most recent first)
                let sortedSources = message.signalSources.sorted(by: { $0.timestamp > $1.timestamp })
                
                ForEach(sortedSources, id: \.self) { source in
                    signalSourceRow(source)
                }
            }
        } else if let rssi = getRSSI() {
            // Fallback for messages without signal sources
            HStack(spacing: 8) {
                Label("\(Int(rssi))dBm", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.appCaption)
                    .fontWeight(.bold)
                    .foregroundColor(rssiColor(rssi))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .background(rssiColor(rssi).opacity(0.1))
            }
        }
    }
    
    private func signalSourceRow(_ source: CoTViewModel.SignalSource) -> some View {
        let iconName: String
        let iconColor: Color
        
        // Determine icon and color based on source type
        switch source.type {
        case .bluetooth:
            iconName = "antenna.radiowaves.left.and.right.circle"
            iconColor = .blue
        case .wifi:
            iconName = "wifi.circle"
            iconColor = .green
        case .sdr:
            iconName = "dot.radiowaves.left.and.right"
            iconColor = .purple
        case .fpv:
            iconName = "antenna.radiowaves.left.and.right"
            iconColor = .orange
        default:
            iconName = "questionmark.circle"
            iconColor = .gray
        }
        
        return HStack {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
            
            VStack(alignment: .leading) {
                HStack {
                    Text(source.mac)
                        .font(.appCaption)
                    Text(source.type.rawValue)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("\(source.rssi) dBm")
                        .font(.appCaption)
                        .fontWeight(.bold)
                        .foregroundColor(rssiColor(Double(source.rssi)))
                    Spacer()
                    Text(source.timestamp.formatted(.relative(presentation: .numeric)))
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .background(rssiColor(Double(source.rssi)).opacity(0.1))
        .cornerRadius(6)
        .id("\(source.mac)-\(source.timestamp.timeIntervalSince1970)")
    }
    
    @ViewBuilder
    private func macRandomizationView() -> some View {
        if let macs = cotViewModel.macIdHistory[message.uid], macs.count > 2 {
            let macCount = macs.count
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("MAC randomizing")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                Text("(\(macCount > 10 ? "10+" : String(macCount)) MACs)")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                
                if cotViewModel.macProcessing[message.uid] == true {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.yellow)
                        .help("Random MAC addresses detected")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(Color.yellow.opacity(0.1))
        }
    }
    
    @ViewBuilder
    private func mapSectionView() -> some View {
        if message.isFPVDetection {
            // Try to get alert ring first, otherwise use message coordinate
            if let ring = cotViewModel.alertRings.first(where: { $0.droneId == message.uid }),
               !(ring.centerCoordinate.latitude == 0 && ring.centerCoordinate.longitude == 0) {
                // FPV with valid alert ring - use fixed position to prevent auto-zoom
                VStack(alignment: .leading, spacing: 0) {
                    // Quick preview label
                    HStack {
                        Text("Signal Range Map")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            activeSheet = .detailView
                        }) {
                            HStack(spacing: 4) {
                                Text("Quick View")
                                    .font(.caption2)
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2)
                            }
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.05))
                    
                    Map(position: .constant(.camera(MapCamera(
                        centerCoordinate: ring.centerCoordinate,
                        distance: ring.radius * 3 // 3x the radius for good viewing
                    ))), interactionModes: [.pan, .zoom]) {
                        MapCircle(center: ring.centerCoordinate, radius: ring.radius)
                            .foregroundStyle(.orange.opacity(0.1))
                            .stroke(.orange, lineWidth: 2)
                        
                        Annotation("Monitor", coordinate: ring.centerCoordinate) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundColor(.blue)
                                .font(.title2)
                                .background(Circle().fill(.white))
                        }
                        
                        Annotation("FPV \(message.fpvFrequency ?? 0)MHz", coordinate: ring.centerCoordinate) {
                            VStack {
                                Text("FPV Signal")
                                    .font(.caption)
                                Text("\(Int(ring.radius))m radius")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                        }
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .frame(height: 150)
                }
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange, lineWidth: 1)
                )
                .allowsHitTesting(true)
            } else if let coord = message.coordinate, !(coord.latitude == 0 && coord.longitude == 0) {
                // FPV detection with coordinate (from user's location) but no alert ring
                VStack(alignment: .leading, spacing: 0) {
                    // Quick preview label
                    HStack {
                        Text("Signal Location Map")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            activeSheet = .detailView
                        }) {
                            HStack(spacing: 4) {
                                Text("Quick View")
                                    .font(.caption2)
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption2)
                            }
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.05))
                    
                    Map(position: .constant(.camera(MapCamera(
                        centerCoordinate: coord,
                        distance: 500
                    ))), interactionModes: [.pan, .zoom]) {
                        Annotation("FPV \(message.fpvFrequency ?? 0)MHz", coordinate: coord) {
                            VStack {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundColor(.orange)
                                    .font(.title2)
                                    .background(Circle().fill(.white).frame(width: 30, height: 30))
                                Text("FPV Signal")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(4)
                            }
                        }
                    }
                    .mapStyle(.standard)
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .frame(height: 150)
                }
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.orange, lineWidth: 1)
                )
                .allowsHitTesting(true)
            } else {
                // No location data available for FPV
//                VStack(spacing: 8) {
//                    HStack {
//                        Image(systemName: "antenna.radiowaves.left.and.right")
//                            .foregroundColor(.orange)
//                            .font(.title2)
//                        
//                        VStack(alignment: .leading) {
//                            Text(message.fpvDisplayName)
//                                .font(.caption)
//                                .fontWeight(.medium)
//                            Text("No location data")
//                                .font(.caption2)
//                                .foregroundColor(.secondary)
//                        }
//                        
//                        Spacer()
//                    }
//                    .padding()
//                    .background(
//                        RoundedRectangle(cornerRadius: 10)
//                            .fill(Color.orange.opacity(0.1))
//                            .overlay(
//                                RoundedRectangle(cornerRadius: 10)
//                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
//                            )
//                    )
//                }
//                .frame(height: 80)
            }
        } else {
            let encounter = currentEncounter

            let validCoordinate: CLLocationCoordinate2D? = {
                guard let coord = message.coordinate else { return nil }
                let lat = coord.latitude
                let lon = coord.longitude
                guard lat != 0 || lon != 0,
                      lat >= -90, lat <= 90,
                      lon >= -180, lon <= 180 else { return nil }
                return coord
            }()
            
            let flightCoords: [CLLocationCoordinate2D] = {
                var coords = encounter?.flightPoints.compactMap { point -> CLLocationCoordinate2D? in
                    let coord = point.coordinate
                    let lat = coord.latitude
                    let lon = coord.longitude
                    guard lat != 0 || lon != 0,
                          lat >= -90, lat <= 90,
                          lon >= -180, lon <= 180 else { return nil }
                    return coord
                } ?? []
                
                if let currentCoord = validCoordinate {
                    let isDuplicate = coords.contains { existing in
                        let latDiff = abs(existing.latitude - currentCoord.latitude)
                        let lonDiff = abs(existing.longitude - currentCoord.longitude)
                        return latDiff < 0.0001 && lonDiff < 0.0001
                    }
                    if !isDuplicate {
                        coords.append(currentCoord)
                    }
                }
                
                return coords
            }()
            
            let pilotCoordinate: CLLocationCoordinate2D? = {
                guard let pilotLatStr = encounter?.metadata["pilotLat"],
                      let pilotLonStr = encounter?.metadata["pilotLon"],
                      let lat = Double(pilotLatStr),
                      let lon = Double(pilotLonStr),
                      lat != 0 || lon != 0 else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }()
            
            let takeoffCoordinate: CLLocationCoordinate2D? = {
                guard let homeLatStr = encounter?.metadata["homeLat"],
                      let homeLonStr = encounter?.metadata["homeLon"],
                      let lat = Double(homeLatStr),
                      let lon = Double(homeLonStr),
                      lat != 0 || lon != 0 else { return nil }
                return CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }()
            
            let centerCoordinate = validCoordinate ?? pilotCoordinate ?? takeoffCoordinate
            
            if let center = centerCoordinate {
                Map(position: .constant(.camera(MapCamera(
                    centerCoordinate: center,
                    distance: 500
                ))), interactionModes: [.pan, .zoom]) {
                    // Flight path - only use valid coordinates
                    if flightCoords.count > 1 {
                        MapPolyline(coordinates: flightCoords)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    
                    if let coordinate = validCoordinate {
                        Annotation(message.uid, coordinate: coordinate) {
                            Image(systemName: "airplane")
                                .resizable()
                                .frame(width: 20, height: 20)
                                .rotationEffect(.degrees(message.headingDeg - 90))
                                .foregroundStyle(.blue)
                        }
                    }
                    
                    if let pilotCoordinate = pilotCoordinate {
                        Annotation("Pilot", coordinate: pilotCoordinate) {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.orange)
                                .background(Circle().fill(.white))
                        }
                    }
                    
                    if let takeoffCoordinate = takeoffCoordinate {
                        Annotation("Takeoff", coordinate: takeoffCoordinate) {
                            Image(systemName: "house.fill")
                                .foregroundStyle(.green)
                                .background(Circle().fill(.white))
                        }
                    }
                }
                .mapStyle(.standard)
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .frame(height: 150)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray, lineWidth: 1)
                )
                .allowsHitTesting(true)
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "airplane.circle")
                            .foregroundColor(.blue)
                            .font(.title2)
                        
                        VStack(alignment: .leading) {
                            Text(message.id)
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("No location data")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.blue.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .frame(height: 80)
            }
        }
    }
    
    @ViewBuilder
    private func detailsView() -> some View {
        Group {
            if message.isFPVDetection {
                // FPV specific details with channel detection
                if let frequency = message.fpvFrequency {
                    if let channel = FPVChannel.detectChannel(fromFrequency: String(frequency)) {
                        HStack(spacing: 8) {
                            Image(systemName: channel.icon)
                                .foregroundStyle(channel.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Channel: \(channel.name) (\(channel.band) Band)")
                                    .font(.appDefault)
                                Text("Frequency: \(frequency) MHz")
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("Frequency: \(frequency) MHz")
                    }
                }
                if let bandwidth = message.fpvBandwidth, !bandwidth.isEmpty {
                    Text("Bandwidth: \(bandwidth)")
                }
                if let source = message.fpvSource {
                    Text("Source: \(source)")
                }
                if let fpvRSSI = message.fpvRSSI {
                    Text("Signal Strength: \(String(format: "%.1f", fpvRSSI))")
                }
            } else {
                // Regular drone details (existing code)
                if message.lat != "0.0" {
                    Text("Position: \(message.lat), \(message.lon)")
                }
                if message.alt != "0.0" {
                    if let formattedAlt = message.formattedAltitude {
                        if let formattedHeight = message.formattedHeight {
                            Text("Altitude: \(formattedAlt) • AGL: \(formattedHeight)")
                        } else {
                            Text("Altitude: \(formattedAlt)")
                        }
                    } else if let altValue = Double(message.alt) {
                        if let formattedHeight = message.formattedHeight {
                            Text("Altitude: \(String(format: "%.1f", altValue))m • AGL: \(formattedHeight)")
                        } else {
                            Text("Altitude: \(String(format: "%.1f", altValue))m")
                        }
                    } else {
                        if let formattedHeight = message.formattedHeight {
                            Text("Altitude: \(message.alt)m • AGL: \(formattedHeight)")
                        } else {
                            Text("Altitude: \(message.alt)m")
                        }
                    }
                }
                if message.speed != "0.0" {
                    Text("Speed: \(message.speed)m/s")
                }
                if message.pilotLat != "0.0" {
                    Text("Pilot Location: \(message.pilotLat), \(message.pilotLon)")
                }
                if message.homeLat != "0.0" {
                    Text("Takeoff Location: \(message.homeLat), \(message.homeLon)")
                }
                if let mac = message.mac, !mac.isEmpty {
                    Text("MAC: \(mac)")
                }
                if message.operator_id != "" {
                    Text("Operator ID: \(message.operator_id ?? "")")
                }
                if let manufacturer = message.manufacturer, manufacturer != "Unknown" {
                    Text("Manufacturer: \(manufacturer)")
                }
            }
        }
        .font(.appCaption)
        .foregroundColor(.primary)
    }
    
    @ViewBuilder
    private func spoofDetectionView() -> some View {
        if let info = spoofDetectionInfo, info.isSpoofed {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(spoofIndicatorColor)
                    Text("Possible Spoofed Signal")
                        .font(.appDefault)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "%.0f%%", info.confidence * 100))
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
                
                if !info.reasons.isEmpty {
                    ForEach(info.reasons, id: \.self) { reason in
                        Text("• \(reason)")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(spoofIndicatorColor.opacity(0.1))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Main View
    
    var body: some View {
        #if DEBUG
        let _ = PerfHeartbeat.shared.count("MessageRow")
        #endif
        if isCompact {
            compactView
        } else {
            expandedView
        }
    }
    
    private var compactView: some View {
        Button(action: {
            activeSheet = .detailView
        }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(message.statusColor)
                    .frame(width: 10, height: 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // Show FPV channel if detected
                        if message.isFPVDetection,
                           let freq = message.fpvFrequency,
                           let channel = FPVChannel.detectChannel(fromFrequency: String(freq)) {
                            HStack(spacing: 4) {
                                Image(systemName: channel.icon)
                                    .foregroundStyle(channel.color)
                                    .font(.caption)
                                Text("FPV \(channel.name)")
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                Text("(\(freq) MHz)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(message.id)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                            
                            if let customName = currentEncounter?.customName, !customName.isEmpty {
                                Text("(\(customName))")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    HStack(spacing: 8) {
                        if let rssi = getRSSI() {
                            HStack(spacing: 4) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.caption2)
                                    .foregroundColor(rssiColor(rssi))
                                Text("\(Int(rssi)) dBm")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(rssiColor(rssi))
                            }
                        }
                        
                        if message.alt != "0.0", let alt = Double(message.alt) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.circle")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                Text("\(Int(alt))m")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if message.speed != "0.0", let speed = Double(message.speed) {
                            HStack(spacing: 4) {
                                Image(systemName: "speedometer")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                                Text(String(format: "%.1f m/s", speed))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Image(systemName: (currentEncounter?.trustStatus ?? .unknown).icon)
                        .foregroundColor((currentEncounter?.trustStatus ?? .unknown).color)
                        .font(.system(size: 16))
                    
                    Text(message.lastUpdated.formatted(.relative(presentation: .numeric)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(message.uid)
        .contextMenu {
            contextMenuItems
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            swipeActionItems
        }
        .onAppear {
            updateEncounterData()
        }
        .onReceive(SwiftDataStorageManager.shared.objectWillChange) { _ in
            guard !isEditingThisDrone else { return }
            updateEncounterData()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DroneInfoUpdated"))) { notification in
            guard !isEditingThisDrone else { return }
            if let droneId = notification.userInfo?["droneId"] as? String,
               droneId == message.uid {
                updateEncounterData()
            }
        }
        .sheet(item: $activeSheet) { sheetType in
            sheetContent(for: sheetType)
        }
        .sheet(isPresented: $showingFAAInfo) {
            if let data = faaData {
                NavigationStack {
                    FAAInfoView(faaData: data)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") {
                                    showingFAAInfo = false
                                }
                            }
                        }
                        .navigationTitle("FAA Lookup")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.height(350)])
                .presentationDragIndicator(.visible)
            }
        }
        .alert("FAA Lookup Error", isPresented: $showingFAAError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(faaError ?? "Unknown error occurred")
        }
        .alert("Delete Drone", isPresented: $showingDeleteConfirmation) {
            deleteConfirmationButtons
        } message: {
            deleteConfirmationMessage
        }
    }
    
    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                // Header with menu button - needs special handling to allow menu taps
                ZStack(alignment: .topLeading) {
                    // Background button for the entire header area
                    Button(action: {
                        activeSheet = .detailView
                    }) {
                        Color.clear
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    // Actual header content on top
                    headerView()
                        .allowsHitTesting(true) // Allow menu button to be tapped
                }
                
                // Rest of the tappable sections
                Button(action: {
                    activeSheet = .detailView
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        typeInfoView()
                        signalSourcesView()
                        macRandomizationView()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                // Non-tappable map section (allows map interactions)
                mapSectionView()
                
                // Tappable details section
                Button(action: {
                    activeSheet = .detailView
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        detailsView()
                        spoofDetectionView()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .cornerRadius(8)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary, lineWidth: 3)
                    .padding(-8)
            )
        }
        .id(message.uid)
        .onAppear {
            updateEncounterData()
        }
        .onReceive(SwiftDataStorageManager.shared.objectWillChange) { _ in
            guard !isEditingThisDrone else { return }
            updateEncounterData()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DroneInfoUpdated"))) { notification in
            guard !isEditingThisDrone else { return }
            if let droneId = notification.userInfo?["droneId"] as? String,
               droneId == message.uid {
                updateEncounterData()
            }
        }
        .contextMenu {
            contextMenuItems
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            swipeActionItems
        }
        .sheet(item: $activeSheet) { sheetType in
            sheetContent(for: sheetType)
        }
        .sheet(isPresented: $showingFAAInfo) {
            if let data = faaData {
                NavigationStack {
                    FAAInfoView(faaData: data)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") {
                                    showingFAAInfo = false
                                }
                            }
                        }
                        .navigationTitle("FAA Lookup")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.height(350)])
                .presentationDragIndicator(.visible)
            }
        }
        .alert("FAA Lookup Error", isPresented: $showingFAAError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(faaError ?? "Unknown error occurred")
        }
        .alert("Delete Drone", isPresented: $showingDeleteConfirmation) {
            deleteConfirmationButtons
        } message: {
            deleteConfirmationMessage
        }
    }
    
    // MARK: - Helper Functions
    
    private func updateEncounterData() {
        isEditingThisDrone = (DroneEditorManager.shared.isPresented && 
                              DroneEditorManager.shared.editingDroneId == message.uid)
        
        guard !isEditingThisDrone else { return }
        
        // Update encounter and signature data
        let newEncounter = DetectionViewCache.shared.encounter(for: message.uid)
        if droneEncounter?.id != newEncounter?.id || 
           droneEncounter?.customName != newEncounter?.customName ||
           droneEncounter?.trustStatus != newEncounter?.trustStatus {
            droneEncounter = newEncounter
        }
        
        let newSignature = cotViewModel.droneSignatures.first(where: { $0.primaryId.id == message.uid })
        if droneSignature?.primaryId.id != newSignature?.primaryId.id {
            droneSignature = newSignature
        }

        updateCachedValues()
    }
    
    private func updateCachedValues() {
        cachedDisplayName = displayName
        cachedDisplayDetails = displayDetails
        cachedDisplayRSSI = displayRSSI
        cachedTrustStatus = currentEncounter?.trustStatus ?? .unknown
    }
    
    @ViewBuilder
    private var contextMenuItems: some View {
        Button(action: {
            removeDroneFromTracking()
        }) {
            Label("Stop Tracking", systemImage: "eye.slash")
        }
        
        Button(role: .destructive, action: {
            showingDeleteConfirmation = true
        }) {
            Label("Delete from History", systemImage: "trash")
        }
    }
    
    @ViewBuilder
    private var swipeActionItems: some View {
        Button(role: .destructive) {
            removeDroneFromTracking()
            deleteDroneFromStorage()
        } label: {
            Label("Delete", systemImage: "trash")
        }
        
        Button {
            removeDroneFromTracking()
        } label: {
            Label("Stop", systemImage: "eye.slash")
        }
        .tint(.orange)
    }
    
    @ViewBuilder
    private func sheetContent(for sheetType: SheetType) -> some View {
        switch sheetType {
        case .liveMap:
            NavigationStack {
                LiveMapView(cotViewModel: cotViewModel, initialMessage: message)
                    .navigationTitle("Live Drone Map")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                activeSheet = nil
                            }
                        }
                    }
            }
        case .detailView:
            NavigationStack {
                DroneDetailView(
                    message: message,
                    flightPath: SwiftDataStorageManager.shared
                        .fetchEncounter(id: message.uid)?.flightPoints
                        .map { $0.coordinate } ?? [],
                    cotViewModel: cotViewModel
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            activeSheet = nil
                        }
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var deleteConfirmationButtons: some View {
        Button("Delete", role: .destructive) {
            removeDroneFromTracking()
            deleteDroneFromStorage()
        }
        Button("Cancel", role: .cancel) {}
    }
    
    private var deleteConfirmationMessage: some View {
        Text("Are you sure you want to delete this drone from tracking and history? This action cannot be undone.")
    }
}
