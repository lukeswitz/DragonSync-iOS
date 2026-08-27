//
//  StatusListView.swift
//  WarDragon
//
//  Created by Luke on 11/18/24.
//

import SwiftUI

struct StatusListView: View {
    @ObservedObject var statusViewModel: StatusViewModel
    @ObservedObject var cotViewModel: CoTViewModel
    @State private var showingDeleteConfirmation = false
    @State private var messageToDelete: StatusViewModel.StatusMessage?
    
    private func deleteMessage(_ message: StatusViewModel.StatusMessage) {
        messageToDelete = message
        showingDeleteConfirmation = true
    }
    
    var body: some View {
        #if DEBUG
        let _ = PerfHeartbeat.shared.count("StatusListView")
        #endif
        systemStatusView
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.large)
            .alert("Delete Message", isPresented: $showingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let message = messageToDelete,
                       let index = statusViewModel.statusMessages.firstIndex(where: { $0.id == message.id }) {
                        statusViewModel.statusMessages.remove(at: index)
                    }
                    messageToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    messageToDelete = nil
                }
            } message: {
                Text("Are you sure you want to delete this status message?")
            }
    }
    
    private var systemStatusView: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                List {
                    // Real-time status header
                    Section {
                        StatusConnectionHeaderView(statusViewModel: statusViewModel)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    
                    // System status messages
                    Section {
                        ForEach(statusViewModel.statusMessages) { message in
                            StatusMessageView(message: message, statusViewModel: statusViewModel)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteMessage(message)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive, action: {
                                        deleteMessage(message)
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onDelete { indexSet in
                            statusViewModel.statusMessages.remove(atOffsets: indexSet)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .center)
                .onChange(of: statusViewModel.statusMessages.count) { _, _ in
                    if let latest = statusViewModel.statusMessages.last {
                        withAnimation {
                            proxy.scrollTo(latest.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Connection Status Header
struct StatusConnectionHeaderView: View {
    @ObservedObject var statusViewModel: StatusViewModel
    @State private var clockTick = Date()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusViewModel.statusColor)
                        .frame(width: 12, height: 12)
                    
                    Text("SYSTEM CONNECTION")
                        .font(.system(.headline, design: .monospaced))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(statusViewModel.statusText)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(statusViewModel.statusColor)
                        .fontWeight(.semibold)
                }
            }
            
            if let lastReceived = statusViewModel.lastStatusMessageReceived {
                HStack {
                    Text("Last Message Received:")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(statusViewModel.lastReceivedText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(statusViewModel.isSystemOnline ? .green : .red)
                            .fontWeight(.medium)
                        
                        Text(lastReceived, style: .time)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack {
                    Text("No status messages received")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            
            // Connection quality indicator
            HStack {
                Text("Connection Reliablity:")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                connectionQualityView
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick in
            clockTick = tick
        }
        .padding()
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    statusViewModel.statusColor.opacity(0.1),
                    statusViewModel.statusColor.opacity(0.05)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private var connectionQualityView: some View {
        let quality = connectionQuality
        
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                Rectangle()
                    .fill(index < quality.bars ? quality.color : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(6 + index * 2))
                    .cornerRadius(1)
            }
        }
    }
    
    private var connectionQuality: (bars: Int, color: Color) {
        guard let lastReceived = statusViewModel.lastStatusMessageReceived else {
            return (0, .red)
        }
        
        let timeSinceLastMessage = clockTick.timeIntervalSince(lastReceived)
        
        switch timeSinceLastMessage {
        case 0..<90:        // Less than 1.5 minutes - excellent
            return (4, .green)
        case 90..<180:      // 1.5-3 minutes - good
            return (3, .green)
        case 180..<300:     // 3-5 minutes - fair
            return (2, .yellow)
        case 300..<600:     // 5-10 minutes - weak
            return (1, .orange)
        default:            // 10+ minutes - poor/offline
            return (0, .red)
        }
    }
}

