import Foundation
import Combine
import Network
import UIKit
import AVFAudio
import os.log

final class BackgroundDiagnostics: ObservableObject {

    static let shared = BackgroundDiagnostics()

    enum Kind: String, Codable, CaseIterable {
        case lifecycle
        case audio
        case bgtask
        case socket
        case memory
        case drop
        case heartbeat
        case gap

        var symbol: String {
            switch self {
            case .lifecycle: return "iphone"
            case .audio:     return "waveform"
            case .bgtask:    return "timer"
            case .socket:    return "antenna.radiowaves.left.and.right"
            case .memory:    return "memorychip"
            case .drop:      return "exclamationmark.triangle"
            case .heartbeat: return "waveform.path.ecg"
            case .gap:       return "bolt.horizontal.circle"
            }
        }
    }

    enum Source: String {
        case multicast
        case zmqTelemetry
        case zmqStatus
    }

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let t: Date
        let kind: Kind
        let event: String
        let detail: String
        let appState: String
        let bgTimeRemaining: Double
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var lastGapSeconds: Double = 0

    private let q = DispatchQueue(label: "com.wardragon.bgdiag")
    private let oslog = OSLog(subsystem: "com.wardragon", category: "BGDiag")
    private let maxEntries = 1000
    private var ring: [Entry] = []
    private var writeScheduled = false
    private var lastDropLog: Date = .distantPast
    private var suppressedDrops = 0

    private let counterLock = NSLock()
    private var packetCounts: [String: Int] = [:]
    private var lastPacketAt: [String: Date] = [:]

    private let pathMonitor = NWPathMonitor()
    private var pathDescription = "unknown"

    private var heartbeat: Timer?
    private let heartbeatInterval: TimeInterval = 5
    private let forcedHeartbeatInterval: TimeInterval = 30
    private var lastHeartbeatEmitted: Date = .distantPast
    private var lastHeartbeatFingerprint = ""

    private lazy var fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bg-diagnostics.json")
    }()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "backgroundDiagnosticsEnabled")
    }

    private init() {
        loadPersisted()
        detectProcessGap()
        startPathMonitor()
        log(.lifecycle, "app launch", "pid \(ProcessInfo.processInfo.processIdentifier)")
    }

    // MARK: - Heartbeat

    func startHeartbeat() {
        guard Self.isEnabled, heartbeat == nil else { return }
        let timer = Timer(timeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        tick()
    }

    private func tick() {
        let state = Self.currentAppState()
        let remaining = Self.currentBackgroundTimeRemaining()
        let engineUp = SilentAudioKeepAlive.shared.isRunning
        let otherAudio = AVAudioSession.sharedInstance().isOtherAudioPlaying

        counterLock.lock()
        let counts = packetCounts
        let seen = lastPacketAt
        counterLock.unlock()

        let now = Date()
        let flow = Source.allNames.map { name -> String in
            let count = counts[name] ?? 0
            guard let last = seen[name] else { return "\(name)=0" }
            return "\(name)=\(count)@\(Int(now.timeIntervalSince(last)))s"
        }.joined(separator: " ")

        let fingerprint = "\(state)|\(engineUp)|\(pathDescription)|\(Self.format(remaining))|\(counts.values.reduce(0,+) > 0)"
        let forced = now.timeIntervalSince(lastHeartbeatEmitted) >= forcedHeartbeatInterval

        guard forced || fingerprint != lastHeartbeatFingerprint else { return }
        lastHeartbeatFingerprint = fingerprint
        lastHeartbeatEmitted = now

        log(.heartbeat, "alive",
            "audioEngine=\(engineUp ? "up" : "DOWN") otherAudio=\(otherAudio) path=\(pathDescription) mem=\(Self.memorySummary()) rx[\(flow)]")
    }

    // MARK: - Packet flow

    func recordPacket(_ source: Source) {
        guard Self.isEnabled else { return }
        counterLock.lock()
        packetCounts[source.rawValue, default: 0] += 1
        lastPacketAt[source.rawValue] = Date()
        counterLock.unlock()
    }

    func secondsSinceLastPacket() -> Double? {
        counterLock.lock()
        let newest = lastPacketAt.values.max()
        counterLock.unlock()
        guard let newest else { return nil }
        return Date().timeIntervalSince(newest)
    }

    // MARK: - Network path

    private func startPathMonitor() {
        guard Self.isEnabled else { return }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let described = Self.describe(path)
            guard described != self.pathDescription else { return }
            let previous = self.pathDescription
            self.pathDescription = described
            self.log(.socket, "network path changed", "\(previous) -> \(described)")
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.wardragon.bgdiag.path"))
    }

    private static func describe(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied:         status = "satisfied"
        case .unsatisfied:       status = "UNSATISFIED"
        case .requiresConnection: status = "requiresConnection"
        @unknown default:        status = "unknown"
        }
        let via = path.availableInterfaces.isEmpty
            ? "none"
            : path.availableInterfaces.map { "\(name(for: $0.type)):\($0.name)" }.joined(separator: "+")
        return "\(status)/\(via)\(path.isExpensive ? "/expensive" : "")\(path.isConstrained ? "/constrained" : "")"
    }

    private static func name(for type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:          return "wifi"
        case .cellular:      return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback:      return "loopback"
        case .other:         return "other"
        @unknown default:    return "unknown"
        }
    }

    // MARK: - Gap detection

    private func detectProcessGap() {
        guard let newest = ring.last else { return }
        let gap = Date().timeIntervalSince(newest.t)
        guard gap > forcedHeartbeatInterval * 2 else { return }
        lastGapSeconds = gap
        let clean = newest.kind == .lifecycle && newest.event == "app terminating"
        let verdict = clean ? "clean termination" : "SUSPENDED OR KILLED - no clean shutdown recorded"
        log(.gap, "process gap \(Int(gap))s",
            "\(verdict); last event before gap: [\(newest.kind.rawValue)] \(newest.event) \(newest.detail) at \(ISO8601DateFormatter().string(from: newest.t))")
    }

    func reportForegroundGap() {
        guard let newest = entries.first(where: { $0.kind == .heartbeat }) else { return }
        let gap = Date().timeIntervalSince(newest.t)
        guard gap > forcedHeartbeatInterval * 2 else { return }
        lastGapSeconds = gap
        log(.gap, "heartbeat gap \(Int(gap))s",
            "process was not executing; last heartbeat: \(newest.detail) at \(ISO8601DateFormatter().string(from: newest.t))")
    }

    // MARK: - Recording

    func log(_ kind: Kind, _ event: String, _ detail: String = "") {
        guard Self.isEnabled else { return }
        let state = Self.currentAppState()
        let remaining = Self.currentBackgroundTimeRemaining()

        os_log("[%{public}@] %{public}@ %{public}@ | state=%{public}@ bgTime=%{public}@",
               log: oslog, type: (kind == .drop || kind == .gap) ? .error : .info,
               kind.rawValue, event, detail, state, Self.format(remaining))

        print("BGDiag [\(kind.rawValue)] \(event) \(detail) | state=\(state) bgTime=\(Self.format(remaining))")

        let entry = Entry(id: UUID(), t: Date(), kind: kind, event: event,
                          detail: detail, appState: state, bgTimeRemaining: remaining)

        q.async { [weak self] in
            guard let self else { return }
            self.ring.append(entry)
            if self.ring.count > self.maxEntries {
                self.ring.removeFirst(self.ring.count - self.maxEntries)
            }
            let snapshot = self.ring
            DispatchQueue.main.async { self.entries = snapshot.reversed() }
            self.schedulePersist()
        }
    }

    // MARK: - Rate-limited hot-path drops

    func logDrop(_ event: String, _ detail: String) {
        q.async { [weak self] in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastDropLog) >= 5 else {
                self.suppressedDrops += 1
                return
            }
            let suppressed = self.suppressedDrops
            self.suppressedDrops = 0
            self.lastDropLog = now
            let suffix = suppressed > 0 ? " (+\(suppressed) more in last 5s)" : ""
            DispatchQueue.main.async { self.log(.drop, event, detail + suffix) }
        }
    }

    func flush() {
        guard Self.isEnabled else { return }
        q.sync { self.persistNow() }
    }

    func clear() {
        q.async { [weak self] in
            guard let self else { return }
            self.ring.removeAll()
            DispatchQueue.main.async { self.entries = [] }
            self.persistNow()
        }
    }

    // MARK: - Queries

    var lastOffAirEvent: Entry? {
        entries.first {
            $0.kind == .gap
            || ($0.kind == .socket && ($0.event.contains("lost") || $0.event.contains("failed")
                                       || $0.event.contains("disconnect") || $0.event.contains("cancelled")
                                       || $0.detail.contains("UNSATISFIED")))
            || ($0.kind == .audio && ($0.event.contains("stopped") || $0.event.contains("failed")
                                      || $0.event.contains("interrupt")))
            || ($0.kind == .bgtask && $0.event.contains("expir"))
            || $0.kind == .drop
        }
    }

    func exportText() -> String {
        let df = ISO8601DateFormatter()
        return entries.reversed().map {
            "\(df.string(from: $0.t))\t\($0.kind.rawValue)\t\($0.event)\t\($0.detail)\tstate=\($0.appState)\tbgTime=\(Self.format($0.bgTimeRemaining))"
        }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func schedulePersist() {
        guard !writeScheduled else { return }
        writeScheduled = true
        q.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.writeScheduled = false
            self.persistNow()
        }
    }

    private func persistNow() {
        guard let data = try? JSONEncoder().encode(ring) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        ring = decoded
        entries = decoded.reversed()
    }

    // MARK: - Runtime state

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var cachedState = "active"
    nonisolated(unsafe) private static var cachedBgTime: Double = .greatestFiniteMagnitude

    static func currentAppState() -> String {
        guard Thread.isMainThread else {
            stateLock.lock(); defer { stateLock.unlock() }
            return cachedState + "~"
        }
        let state: String
        switch UIApplication.shared.applicationState {
        case .active:     state = "active"
        case .inactive:   state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        stateLock.lock(); cachedState = state; stateLock.unlock()
        return state
    }

    static func currentBackgroundTimeRemaining() -> Double {
        guard Thread.isMainThread else {
            stateLock.lock(); defer { stateLock.unlock() }
            return cachedBgTime
        }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        stateLock.lock(); cachedBgTime = remaining; stateLock.unlock()
        return remaining
    }

    static func memorySummary() -> String {
        var taskInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let headroomMB = Double(os_proc_available_memory()) / 1024.0 / 1024.0
        guard kerr == KERN_SUCCESS else {
            return String(format: "headroom=%.0fMB", headroomMB)
        }
        let residentMB = Double(taskInfo.resident_size) / 1024.0 / 1024.0
        return String(format: "%.0fMB/headroom=%.0fMB", residentMB, headroomMB)
    }

    static func format(_ remaining: Double) -> String {
        if remaining < 0 { return "n/a" }
        if remaining > 1_000_000 { return "unlimited" }
        return "\(Int(remaining))s"
    }
}

private extension BackgroundDiagnostics.Source {
    static var allNames: [String] {
        [BackgroundDiagnostics.Source.multicast.rawValue,
         BackgroundDiagnostics.Source.zmqTelemetry.rawValue,
         BackgroundDiagnostics.Source.zmqStatus.rawValue]
    }
}
