import Foundation
import Darwin
import SwiftUI

extension View {
    @MainActor
    func perfCount(_ name: String) -> some View {
        PerfHeartbeat.shared.count(name)
        return self
    }
}

@MainActor
final class PerfHeartbeat {
    static let shared = PerfHeartbeat()

    weak var cotViewModel: CoTViewModel?

    private var probeTimer: Timer?
    private var reportTimer: Timer?
    private var lastProbe = Date()
    private var worstStall: TimeInterval = 0
    private var lastCPUTime: TimeInterval = 0
    private var lastCPUStamp = Date()
    private var lastResidentMB: Double = 0

    private var renderCounts: [String: Int] = [:]

    private let probeInterval: TimeInterval = 0.25
    private let reportInterval: TimeInterval = 5.0

    private init() {}

    func count(_ name: String) {
        guard probeTimer != nil else { return }
        renderCounts[name, default: 0] += 1
    }

    func mark(_ label: String) {
        let startMem = Self.residentMB()
        let start = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let mem = Self.residentMB()
            print(String(format: "[HB] %@ took %.0fms  mem %.1f -> %.1fMB (%+.1f)",
                         label, elapsed, startMem, mem, mem - startMem))
        }
    }

    func start() {
        guard BackgroundDiagnostics.isEnabled, probeTimer == nil else { return }

        Self.mainThreadPort = pthread_mach_thread_np(pthread_self())
        lastProbe = Date()
        lastCPUTime = Self.processCPUSeconds()
        lastCPUStamp = Date()

        let probe = Timer(timeInterval: probeInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
        RunLoop.main.add(probe, forMode: .common)
        probeTimer = probe

        let report = Timer(timeInterval: reportInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.report() }
        }
        RunLoop.main.add(report, forMode: .common)
        reportTimer = report
    }

    private func probe() {
        let now = Date()
        let lateness = now.timeIntervalSince(lastProbe) - probeInterval
        if lateness > worstStall { worstStall = lateness }
        lastProbe = now
    }

    private func report() {
        let now = Date()
        let cpuNow = Self.processCPUSeconds()
        let wall = now.timeIntervalSince(lastCPUStamp)
        let cpuPercent = wall > 0 ? (cpuNow - lastCPUTime) / wall * 100 : 0
        lastCPUTime = cpuNow
        lastCPUStamp = now

        let residentMB = Self.residentMB()
        let growthMB = residentMB - lastResidentMB
        lastResidentMB = residentMB

        print(String(format: "[HB] mem=%.1fMB (%+.1fMB/%.0fs) headroom=%.0fMB cpu=%.0f%% mainStall=%.2fs",
                     residentMB, growthMB, reportInterval, Self.headroomMB(), cpuPercent, worstStall))
        worstStall = 0

        print("[HB] threads: \(Self.busyThreads())")
        print("[HB] collections: \(collectionSizes())")
        print("[HB] renders/\(Int(reportInterval))s: \(topRenders())")
        renderCounts.removeAll(keepingCapacity: true)
    }

    private func topRenders() -> String {
        guard !renderCounts.isEmpty else { return "none" }
        return renderCounts.sorted { $0.value > $1.value }
            .prefix(8)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    private func collectionSizes() -> String {
        var parts: [String] = []

        if let vm = cotViewModel {
            parts.append("msgs=\(vm.parsedMessages.count)")
            parts.append("sigs=\(vm.droneSignatures.count)")
            parts.append("rings=\(vm.alertRings.count)")
            parts.append("aircraft=\(vm.aircraftTracks.count)")
            parts.append("macHist=\(vm.macIdHistory.count)")
            parts.append("macProc=\(vm.macProcessing.count)")
            parts.append("randMac=\(vm.randomMacIdHistory.count)")
            parts.append("status=\(vm.statusViewModel.statusMessages.count)")
            parts.append("adsbHist=\(vm.statusViewModel.adsbEncounterHistory.count)")
        } else {
            parts.append("viewModel=nil")
        }

        parts.append("bgdiag=\(BackgroundDiagnostics.shared.entries.count)")
        parts.append(DetectionViewCache.shared.sizes())

        return parts.joined(separator: " ")
    }

    private static func processCPUSeconds() -> TimeInterval {
        var total: TimeInterval = 0

        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let basicErr = withUnsafeMutablePointer(to: &basic) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        if basicErr == KERN_SUCCESS {
            total += TimeInterval(basic.user_time.seconds) + TimeInterval(basic.user_time.microseconds) / 1_000_000
            total += TimeInterval(basic.system_time.seconds) + TimeInterval(basic.system_time.microseconds) / 1_000_000
        }

        var live = task_thread_times_info()
        var liveCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size) / 4
        let liveErr = withUnsafeMutablePointer(to: &live) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(liveCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveCount)
            }
        }
        if liveErr == KERN_SUCCESS {
            total += TimeInterval(live.user_time.seconds) + TimeInterval(live.user_time.microseconds) / 1_000_000
            total += TimeInterval(live.system_time.seconds) + TimeInterval(live.system_time.microseconds) / 1_000_000
        }

        return total
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }

    private static func headroomMB() -> Double {
        Double(os_proc_available_memory()) / 1024 / 1024
    }

    nonisolated(unsafe) private static var mainThreadPort: mach_port_t = 0

    private static func busyThreads() -> String {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else {
            return "unavailable"
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }

        var rows: [(String, Int32)] = []
        for i in 0..<Int(count) {
            var info = thread_extended_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &infoCount)
                }
            }
            guard kerr == KERN_SUCCESS, info.pth_cpu_usage > 0 else { continue }

            let nameBuffer = info.pth_name
            let nameSize = MemoryLayout.size(ofValue: nameBuffer)
            let name = withUnsafePointer(to: nameBuffer) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: nameSize) {
                    String(cString: $0)
                }
            }
            let port = list[i]
            let isMain = port == mainThreadPort
            let label: String
            if isMain {
                label = "MAIN"
            } else if !name.isEmpty {
                label = name
            } else {
                label = "tid:\(port)"
            }
            let runState: String
            switch info.pth_run_state {
            case TH_STATE_RUNNING:         runState = "run"
            case TH_STATE_STOPPED:         runState = "stop"
            case TH_STATE_WAITING:         runState = "wait"
            case TH_STATE_UNINTERRUPTIBLE: runState = "uninterruptible"
            case TH_STATE_HALTED:          runState = "halt"
            default:                       runState = "?"
            }
            rows.append(("\(label)/\(runState)", info.pth_cpu_usage))
        }

        guard !rows.isEmpty else { return "idle" }
        return rows.sorted { $0.1 > $1.1 }
            .prefix(6)
            .map { "\($0.0)=\(Double($0.1) / 10)%" }
            .joined(separator: " ")
    }
}
