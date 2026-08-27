//
//  WarDragonApp.swift
//  WarDragon
//
//  Created by Luke on 11/18/24.
//

import SwiftUI
import SwiftData
import BackgroundTasks
import UserNotifications

extension Font {
    static let appDefault    = Font.system(.body,       design: .monospaced)
    static let appHeadline   = Font.system(.headline,   design: .monospaced)
    static let appSubheadline = Font.system(.subheadline, design: .monospaced)
    static let appCaption    = Font.system(.caption,    design: .monospaced)
}

@main
struct WarDragonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    
    @StateObject private var statusViewModel = StatusViewModel()
    @StateObject private var spectrumViewModel = SpectrumData.SpectrumViewModel()
    @StateObject private var cotViewModel: CoTViewModel
    
    init() {
        let statusVM = StatusViewModel()
        let spectrumVM = SpectrumData.SpectrumViewModel()
        let cotVM = CoTViewModel(statusViewModel: statusVM, spectrumViewModel: spectrumVM)
        
        _statusViewModel = StateObject(wrappedValue: statusVM)
        _spectrumViewModel = StateObject(wrappedValue: spectrumVM)
        _cotViewModel = StateObject(wrappedValue: cotVM)
        
        #if DEBUG
        SeriesSmoother.selfCheck()
        #endif

        Task { @MainActor in
            OpenSkyService.shared.cotViewModel = cotVM
            PerfHeartbeat.shared.cotViewModel = cotVM
            PerfHeartbeat.shared.start()
            MainThreadWatchdog.shared.start()
        }
    }
    
    // SwiftData model container with recovery
    let modelContainer: ModelContainer = {
        let schema = Schema([
            StoredDroneEncounter.self,
            StoredFlightPoint.self,
            StoredSignature.self,
            StoredADSBEncounter.self,
            OpenSkySettings.self,
            CachedAircraft.self
        ])
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("SwiftData initialization failed: \(error.localizedDescription)")
            print("   Attempting recovery by resetting SwiftData store...")
            
            // Try to delete corrupted store and recreate
            do {
                let fileManager = FileManager.default
                let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let storeURL = appSupportURL.appendingPathComponent("default.store")
                
                // Remove corrupted store files
                if fileManager.fileExists(atPath: storeURL.path) {
                    try fileManager.removeItem(at: storeURL)
                    print("   Removed corrupted store file")
                }
                
                // Also remove WAL and SHM files if they exist
                let walURL = appSupportURL.appendingPathComponent("default.store-wal")
                let shmURL = appSupportURL.appendingPathComponent("default.store-shm")
                try? fileManager.removeItem(at: walURL)
                try? fileManager.removeItem(at: shmURL)
                
                // Try creating container again
                let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
                print("Successfully recovered SwiftData store")

                // Intentionally NOT resetting the migration flag. Resetting it
                // caused ghost-drone re-imports from the legacy UserDefaults
                // blob on every store-recovery. A salvage copy is preserved
                // under DataMigration_LegacyEncounters_v1 — the UI must offer
                // an explicit "Restore old encounters?" action via
                // DataMigrationManager.restoreFromLegacySalvage.
                print("   Store reset — encounters lost; user can opt-in to legacy salvage if present")

                return container
            } catch {
                print("Recovery failed: \(error.localizedDescription)")
                fatalError("Could not create or recover ModelContainer. This should never happen. Error: \(error)")
            }
        }
    }()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .environmentObject(statusViewModel)
                .environmentObject(spectrumViewModel)
                .environmentObject(cotViewModel)
                .task {
                    // Wire the SwiftData context BEFORE migration / any save path
                    // runs. ContentView.onAppear used to do this, but BG-launched
                    // sessions never appear, so saves silently dropped.
                    await wireSwiftDataContext()
                    await configureOpenSkyService()
                    await performMigrationIfNeeded()
                }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .background:
                print("Scene Phase: Background")
            case .inactive:
                print("Scene Phase: Inactive (from \(oldPhase))")
            case .active:
                print("Scene Phase: Active")
            @unknown default:
                break
            }
        }
    }
    
    @MainActor
    private func wireSwiftDataContext() async {
        let context = modelContainer.mainContext
        SwiftDataStorageManager.shared.modelContext = context
        SwiftDataStorageManager.shared.statusViewModel = statusViewModel
        statusViewModel.modelContext = context
    }

    @MainActor
    private func configureOpenSkyService() async {
        let context = modelContainer.mainContext
        OpenSkyService.shared.configure(with: context)
    }
    
    @MainActor
    private func performMigrationIfNeeded() async {
        let context = modelContainer.mainContext
        let migrationManager = DataMigrationManager.shared
        print("Migration Status: \(migrationManager.migrationStatus)")
        
        guard migrationManager.needsMigration else {
            print("No migration needed - data already in SwiftData")
            DroneStorageManager.shared.loadFromStorage()
            return
        }
        
        print("DEBUG:  Starting data migration (first run)...")
        print("   This is a one-time process to migrate your data to the new storage system")
        
        do {
            // Only create backup if one doesn't already exist
            let existingBackups = (try? migrationManager.listBackupFiles()) ?? []
            let hasLegacyBackup = existingBackups.contains { $0.lastPathComponent.hasPrefix("wardragon_backup_") }
            
            if !hasLegacyBackup {
                do {
                    let backupURL = try migrationManager.createBackup()
                    print("Backup created at: \(backupURL.path)")
                } catch {
                    print("Warning: Backup creation failed (non-fatal): \(error.localizedDescription)")
                    print("   Migration will continue, but you may want to manually backup your data")
                }
            } else {
                print("Backup already exists, skipping duplicate backup creation")
            }
            
            // Perform migration with retry logic
            var migrationSucceeded = false
            var lastError: Error?
            
            for attempt in 1...3 {
                do {
                    if attempt > 1 {
                        print("Migration attempt \(attempt)/3...")
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    
                    try await migrationManager.migrate(modelContext: context)
                    migrationSucceeded = true
                    break
                } catch {
                    lastError = error
                    print("Migration attempt \(attempt) failed: \(error.localizedDescription)")
                    
                    if attempt < 3 {
                        print("   Will retry...")
                    }
                }
            }
            
            if migrationSucceeded {
                print("Migration completed successfully!")
                print("   Your data has been migrated to the new storage system")
                print("   New Migration Status: \(migrationManager.migrationStatus)")
                
                // Verify migration by checking data count
                let verifyDescriptor = FetchDescriptor<StoredDroneEncounter>()
                let count = try context.fetchCount(verifyDescriptor)
                print("Verification: \(count) encounters now stored in SwiftData")
                
                // Force DroneStorageManager to reload from SwiftData
                DroneStorageManager.shared.loadFromStorage()
                
                // Update cached stats in batches to avoid loading everything at once
                print("DEBUG:  Checking for encounters needing stat updates...")
                var updateDescriptor = FetchDescriptor<StoredDroneEncounter>(
                    predicate: #Predicate<StoredDroneEncounter> { encounter in
                        encounter.cachedFlightPointCount == 0 || encounter.cachedMaxAltitude == 0
                    }
                )
                updateDescriptor.fetchLimit = 50  // Process 50 at a time max
                
                let encountersNeedingUpdate = try context.fetch(updateDescriptor)
                
                if !encountersNeedingUpdate.isEmpty {
                    print("   Updating cached stats for \(encountersNeedingUpdate.count) encounters...")
                    for encounter in encountersNeedingUpdate {
                        encounter.updateCachedStats()
                    }
                    try context.save()
                    print(" Updated cached stats for \(encountersNeedingUpdate.count) encounters")
                } else {
                    print("   All encounters already have cached stats - skipping")
                }
                
                print("Migration complete - app is now using the new storage system")
            } else {
                throw lastError ?? NSError(domain: "Migration", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown migration error"])
            }
            
        } catch {
            print("Migration failed after all attempts: \(error.localizedDescription)")
            print("   Don't worry - your data is safe!")
            print("   • App will continue using UserDefaults as fallback")
            print("   • Migration will be retried automatically on next launch")
            print("   • Your original data has been preserved")
            
            // Load from UserDefaults fallback
            DroneStorageManager.shared.loadFromStorage()
            
            // Log additional debugging info
            if let nsError = error as NSError? {
                print("   Debug info: domain=\(nsError.domain), code=\(nsError.code)")
                if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("   Underlying: \(underlyingError.localizedDescription)")
                }
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let bgIDs = [
        "com.wardragon.processMessages",
        "com.wardragon.updateStatus",
        "com.wardragon.refreshConnections"
    ]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Always reset listening state on app launch
        // User must explicitly tap "Start" to begin monitoring
        Task { @MainActor in
            Settings.shared.isListening = false
            print("App launch - reset listening state (user must explicitly start)")
        }
        
        // Clear background monitoring flag on startup
        UserDefaults.standard.set(false, forKey: "BackgroundMonitoringActive")
        UserDefaults.standard.synchronize()

        UNUserNotificationCenter.current().delegate = self
        BackgroundDiagnostics.shared.startHeartbeat()
        setupAppLifecycleObservers()
        registerBGTasks()
        scheduleAllBGTasks()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.windows.first?.frame = scene.windows.first?.frame ?? .zero
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {

        if let trigger = (userInfo["dragon"] as? [String : String])?["trigger"],
           trigger == "processMessages" {
            scheduleBGTask(id: "com.wardragon.processMessages", delay: 0)
        }
        completion(.newData)
    }

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appMovingToBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appMovingToForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleMemoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
    }
    
    @objc private func handleMemoryWarning() {
        print("⚠️ Memory warning received - performing aggressive cleanup")
        BackgroundDiagnostics.shared.log(.memory, "system memory warning",
                                         String(format: "resident=%.1fMB", getMemoryUsage()))

        Task { @MainActor in
            // Get memory info before cleanup
            let memoryBefore = getMemoryUsage()
            print("   Memory before cleanup: \(memoryBefore)MB")
            
            DroneStorageManager.shared.forceSave()
            SwiftDataStorageManager.shared.forceSave()
            BackgroundManager.shared.checkMemoryUsage()
            
            // If in background and memory is critical, temporarily pause processing
            if UIApplication.shared.applicationState == .background {
                let memoryAfter = getMemoryUsage()
                print("   Memory after cleanup: \(memoryAfter)MB")
                
                if memoryAfter > 80 {  // If still using >80MB in background, that's a lot
                    print("⚠️ High memory usage in background - consider pausing if issues persist")
                }
            }
            
            print("✅ Memory warning cleanup completed")
        }
    }
    
    private func getMemoryUsage() -> Double {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return Double(taskInfo.resident_size) / 1024.0 / 1024.0
        }
        return 0
    }

    @objc private func appMovingToBackground() {
        print("App moving to background")
        BackgroundDiagnostics.shared.log(.lifecycle, "entered background", "")

        Task { @MainActor in
            let memoryBefore = getMemoryUsage()
            print("   Memory before background prep: \(memoryBefore)MB")
            
            // AGGRESSIVE memory cleanup for background
            SwiftDataStorageManager.shared.releaseBackgroundMemory()
            DroneStorageManager.shared.forceSave()
            
            // Clear ALL caches
            URLCache.shared.removeAllCachedResponses()
            URLCache.shared.memoryCapacity = 0  // Disable memory cache
            URLCache.shared.diskCapacity = 0     // Disable disk cache
            
            ZMQHandler.shared.clearCaches()
            
            // Force garbage collection
            autoreleasepool {
                // Intentionally empty - just forces cleanup
            }
            
            let memoryAfter = getMemoryUsage()
            print("   Memory after cleanup: \(memoryAfter)MB (freed \(String(format: "%.1f", memoryBefore - memoryAfter))MB)")
            
            // iOS kills apps >50MB in background. If we're still high, warn
            if memoryAfter > 50 {
                print("⚠️ WARNING: Still using \(memoryAfter)MB - iOS may kill us!")
                print("   Normal background limit is 50-80MB")
            }
            
            print("Forced data save and memory cleanup completed")
            
            let isListening = Settings.shared.isListening
            let enableBg = Settings.shared.enableBackgroundDetection
            
            print("AppDelegate: isListening=\(isListening), enableBackgroundDetection=\(enableBg)")
            
            if isListening && enableBg {
                print("App entering background - ALWAYS continue monitoring")
                UserDefaults.standard.set(true, forKey: "BackgroundMonitoringActive")
                UserDefaults.standard.synchronize()
                
                ZMQHandler.shared.setBackgroundMode(true)
                BackgroundManager.shared.startBackgroundProcessing()
                print("Background monitoring enabled with task rotation")
            } else {
                print("App entering background - NOT monitoring (user not listening or bg disabled)")
                BackgroundDiagnostics.shared.log(.lifecycle, "background monitoring off",
                                                 "isListening=\(isListening) enableBg=\(enableBg)")
                UserDefaults.standard.set(false, forKey: "BackgroundMonitoringActive")
                UserDefaults.standard.synchronize()
            }
            BackgroundDiagnostics.shared.flush()
        }
    }

    @objc private func appMovingToForeground() {
        print("App moving to foreground")
        BackgroundDiagnostics.shared.reportForegroundGap()
        BackgroundDiagnostics.shared.log(.lifecycle, "returned to foreground", "")

        Task { @MainActor in
            ZMQHandler.shared.setBackgroundMode(false)
            
            UserDefaults.standard.set(false, forKey: "BackgroundMonitoringActive")
            UserDefaults.standard.synchronize()
            
            BackgroundManager.shared.stopBackgroundProcessing(stopKeepAlive: !Settings.shared.isListening)

            print("Returned to foreground mode")
        }
    }

    private func registerBGTasks() {
        bgIDs.forEach { id in
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                self.handleBGTask(task as! BGProcessingTask)
            }
        }
    }

    private func scheduleAllBGTasks() {
        Task { @MainActor in
            guard Settings.shared.enableBackgroundDetection else {
                print("Background detection disabled - skipping BGTask scheduling")
                return
            }
            
            bgIDs.forEach { id in scheduleBGTask(id: id, delay: 15*60) }
        }
    }

    private func scheduleBGTask(id: String, delay: TimeInterval) {
        let req = BGProcessingTaskRequest(identifier: id)
        req.requiresNetworkConnectivity = true
        req.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleBGTask(_ task: BGProcessingTask) {
        BackgroundDiagnostics.shared.log(.bgtask, "BGProcessingTask fired", task.identifier)
        scheduleBGTask(id: task.identifier, delay: 15*60)

        task.expirationHandler = {
            BackgroundDiagnostics.shared.log(.bgtask, "BGProcessingTask expired", task.identifier)
            BackgroundDiagnostics.shared.flush()
            BackgroundManager.shared.stopBackgroundProcessing(stopKeepAlive: false)
            task.setTaskCompleted(success: false)
        }
        BackgroundManager.shared.startBackgroundProcessing(useBackgroundTask: false)
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        BackgroundDiagnostics.shared.log(.lifecycle, "app terminating", "")
        BackgroundDiagnostics.shared.flush()
        Task { @MainActor in
            Settings.shared.isListening = false
        }
        ZMQHandler.shared.disconnect()
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
