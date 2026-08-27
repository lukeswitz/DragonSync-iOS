//
//  BackgroundManager.swift
//  WarDragon
//
//  Created by Luke on 4/16/25.
//

import Foundation
import Network
import UIKit
import AVFAudio

final class BackgroundManager: @unchecked Sendable {

    static let shared = BackgroundManager()

    private let queue = DispatchQueue(label: "BackgroundWork")
    private var group: NWConnectionGroup?
    private let runningQueue = DispatchQueue(label: "BackgroundManager.running")
    private var _running = false
    private var running: Bool {
        get { runningQueue.sync { _running } }
        set { runningQueue.sync { _running = newValue } }
    }
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    private var bgRefreshTimer: Timer?
    private let monitor = NWPathMonitor()
    private var hasConnection = true
    private var taskStartTime: Date?
    private let maxTaskDuration: TimeInterval = 150
    private var memoryCheckCounter = 0
    private let memoryCheckInterval = 50  // Check memory every 50 iterations (~5 seconds)
    private var supervisionCounter = 0
    private let supervisionInterval = 50
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.hasConnection = (path.status == .satisfied)
        }
        monitor.start(queue: .global(qos: .background))
    }

    private weak var cotViewModel: CoTViewModel?
    func configure(with viewModel: CoTViewModel) { cotViewModel = viewModel }

    var isBackgroundModeActive: Bool { running }
    func isNetworkAvailable() -> Bool { hasConnection }

    func startBackgroundProcessing(useBackgroundTask: Bool = true) {
        if running {
            return
        }

        Task { @MainActor in
            let isListening = Settings.shared.isListening
            let enableBg = Settings.shared.enableBackgroundDetection
            let appState = UIApplication.shared.applicationState
            print("BackgroundManager: isListening=\(isListening), enableBackgroundDetection=\(enableBg), appState=\(appState.rawValue)")

            guard isListening && enableBg else {
                print("BackgroundManager: NOT starting - user not listening or background detection disabled")
                BackgroundDiagnostics.shared.log(.bgtask, "bg processing refused",
                                                 "isListening=\(isListening) enableBg=\(enableBg)")
                return
            }

            if useBackgroundTask && appState == .active {
                print("BackgroundManager: NOT starting - app is foreground (would create spurious bgTask + 2s refresh timer)")
                BackgroundDiagnostics.shared.log(.bgtask, "bg processing refused", "app is foreground")
                return
            }

            await self._internalStartBackgroundProcessing(useBackgroundTask: useBackgroundTask)
        }
    }
    
    private func claimRunning() -> Bool {
        runningQueue.sync {
            if _running { return false }
            _running = true
            return true
        }
    }

    private func _internalStartBackgroundProcessing(useBackgroundTask: Bool) async {
        guard claimRunning() else {
            BackgroundDiagnostics.shared.log(.bgtask, "bg processing already running", "duplicate start suppressed")
            return
        }

        BackgroundDiagnostics.shared.log(.bgtask, "bg processing started",
                                         "useBackgroundTask=\(useBackgroundTask)")
        SilentAudioKeepAlive.shared.start()

        if useBackgroundTask {
            await MainActor.run {
                beginDrainTask()
                bgRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.checkAndRefreshBackgroundTask()
                    }
                }
                if let timer = bgRefreshTimer {
                    RunLoop.main.add(timer, forMode: .default)
                }
            }
        }

        let connectionMode = await MainActor.run {
            Settings.shared.connectionMode
        }
        
        Task.detached { [weak self] in
            guard let self else { return }

            switch connectionMode {
            case .multicast:
                await MainActor.run { self.cotViewModel?.ensureMulticastHealthy() }
            case .zmq:
                ZMQHandler.shared.connectIfNeeded()
            }

            while await self.isRunningAndBackgroundOK(useBackgroundTask: useBackgroundTask) {
                let currentMode = await MainActor.run {
                    Settings.shared.connectionMode
                }
                
                switch currentMode {
                case .multicast:
                    self.supervisionCounter += 1
                    if self.supervisionCounter >= self.supervisionInterval {
                        self.supervisionCounter = 0
                        await MainActor.run { self.cotViewModel?.ensureMulticastHealthy() }
                    }
                case .zmq:
                    autoreleasepool {
                        if ZMQHandler.shared.isConnected {
                            ZMQHandler.shared.drainOnce()
                        } else {
                            ZMQHandler.shared.connectIfNeeded()
                        }
                    }
                    self.supervisionCounter += 1
                    if self.supervisionCounter >= self.supervisionInterval {
                        self.supervisionCounter = 0
                        await MainActor.run { self.cotViewModel?.verifyZMQSubscription() }
                    }
                }

                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }

            await self.logDrainLoopExit(useBackgroundTask: useBackgroundTask)

            self._internalStopBackgroundProcessing(stopKeepAlive: false)
        }
    }

    private func logDrainLoopExit(useBackgroundTask: Bool) async {
        let run = running
        let remaining = await MainActor.run { UIApplication.shared.backgroundTimeRemaining }
        let reason: String
        if !run {
            reason = "running flag cleared"
        } else if useBackgroundTask {
            reason = "backgroundTimeRemaining exhausted"
        } else {
            reason = "unknown"
        }
        BackgroundDiagnostics.shared.log(.bgtask, "drain loop exited",
                                         "reason=\(reason) running=\(run) remaining=\(BackgroundDiagnostics.format(remaining))")
    }
    
    // Multicast group construction removed. CoTViewModel owns the
    // NWConnectionGroup; BackgroundManager previously built a duplicate group
    // whose receive-handler posted notifications no observer subscribed to.
    
    private func cleanup() async {
        self._internalStopBackgroundProcessing()
    }

    func stopBackgroundProcessing(stopKeepAlive: Bool = true) {
        _internalStopBackgroundProcessing(stopKeepAlive: stopKeepAlive)
    }

    private func _internalStopBackgroundProcessing(stopKeepAlive: Bool = true) {
        let wasRunning = running
        running = false
        guard wasRunning else { return }

        BackgroundDiagnostics.shared.log(.bgtask, "bg processing stopped",
                                         "stopKeepAlive=\(stopKeepAlive)")

        // Do NOT disconnect the shared ZMQHandler here — it is owned by
        // CoTViewModel. We only stop OUR drain loop. ZMQHandler stays
        // connected so foreground resumes instantly without a full reconnect.
        // Multicast: BackgroundManager no longer maintains its own group; the
        // CoTViewModel's NWConnectionGroup is kept alive by SilentAudioKeepAlive.
        disconnectMulticast()

        DispatchQueue.main.async { [weak self] in
            self?.bgRefreshTimer?.invalidate()
            self?.bgRefreshTimer = nil
            self?.endDrainTask()
        }
        if stopKeepAlive {
            SilentAudioKeepAlive.shared.stop()
        }
        BackgroundDiagnostics.shared.flush()
    }

    private func isRunningAndBackgroundOK(useBackgroundTask: Bool) async -> Bool {
        let run = running
        
        let backgroundTimeOK: Bool
        if useBackgroundTask {
            backgroundTimeOK = await MainActor.run {
                UIApplication.shared.backgroundTimeRemaining > 5
            }
        } else {
            backgroundTimeOK = true
        }
            
        return run && backgroundTimeOK
    }

    @MainActor
    private func checkAndRefreshBackgroundTask() {
        guard bgTaskID != .invalid else { return }
        
        let currentTime = Date()
        let timeRemaining = UIApplication.shared.backgroundTimeRemaining
        
        let unlimited = timeRemaining == .greatestFiniteMagnitude || timeRemaining > Double(Int.max)
        guard !unlimited else { return }

        if let startTime = taskStartTime,
           currentTime.timeIntervalSince(startTime) >= 20 || timeRemaining < 30 {
            let age = Int(currentTime.timeIntervalSince(startTime))
            let remainingString: String
            if timeRemaining == .greatestFiniteMagnitude || timeRemaining > Double(Int.max) {
                remainingString = "unlimited"
            } else {
                remainingString = "\(Int(timeRemaining))s"
            }
            print("Refreshing background task (age: \(age)s, remaining: \(remainingString))")
            BackgroundDiagnostics.shared.log(.bgtask, "bg task rotated",
                                             "age=\(age)s remaining=\(remainingString)")
            rotateDrainTask()
        }
    }

    @MainActor
    private func rotateDrainTask() {
        let previous = bgTaskID
        bgTaskID = .invalid
        beginDrainTask()
        if previous != .invalid {
            UIApplication.shared.endBackgroundTask(previous)
        }
    }

    @MainActor
    private func beginDrainTask() {
        endDrainTask()

        taskStartTime = Date()
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "Drain") {
            print("⚠️ Background task about to expire - refreshing...")
            BackgroundDiagnostics.shared.log(.bgtask, "bg task expiring", "iOS reclaimed the assertion")
            BackgroundDiagnostics.shared.flush()
            NotificationCenter.default.post(name: NSNotification.Name("BackgroundTaskExpiring"), object: nil)
        }

        guard bgTaskID != .invalid else {
            print("❌ Failed to begin background task - iOS may have denied it")
            BackgroundDiagnostics.shared.log(.bgtask, "bg task denied", "beginBackgroundTask returned .invalid")
            return
        }
        
        let timeRemaining = UIApplication.shared.backgroundTimeRemaining
        let timeString: String
        if timeRemaining == .greatestFiniteMagnitude {
            timeString = "unlimited"
        } else if timeRemaining > Double(Int.max) {
            timeString = "unlimited"
        } else {
            timeString = "\(Int(timeRemaining))s"
        }
        print("Background task started - ID: \(bgTaskID.rawValue), time remaining: \(timeString)")
    }

    @MainActor
    private func endDrainTask() {
        if bgTaskID != .invalid {
            print("Ending background task - ID: \(bgTaskID.rawValue)")
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
            taskStartTime = nil
        }
    }
    
    /// Force end all background tasks (for app termination)
    func endAllBackgroundTasks(stopKeepAlive: Bool = true) {
        print("BackgroundManager: Ending all background tasks")
        _internalStopBackgroundProcessing(stopKeepAlive: stopKeepAlive)
        print(" BackgroundManager: All tasks ended")
    }
    
    private func disconnectMulticast() {
        group?.cancel()
        group = nil
    }
    
    func checkMemoryUsage() {
        let headroomMB = Double(os_proc_available_memory()) / 1024.0 / 1024.0
        BackgroundDiagnostics.shared.log(.memory, "releasing caches",
                                         String(format: "headroom=%.1fMB", headroomMB))

        ZMQHandler.shared.clearCaches()
        URLCache.shared.removeAllCachedResponses()

        Task { @MainActor in
            SwiftDataStorageManager.shared.releaseBackgroundMemory()
            DroneStorageManager.shared.forceSave()
            self.cotViewModel?.trimDetectionBuffersForBackground()
        }
    }
}
