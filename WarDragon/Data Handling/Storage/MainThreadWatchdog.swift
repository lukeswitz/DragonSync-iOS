import Foundation
import Darwin

final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    nonisolated(unsafe) private static var lastTick: Double = 0
    nonisolated(unsafe) private static var mainPort: mach_port_t = 0
    nonisolated(unsafe) private static var running = false

    private var heartbeat: Timer?
    private var watcher: Thread?

    private let tickInterval: TimeInterval = 0.1
    private let stallThreshold: TimeInterval = 0.4
    private let maxDepth = 40

    private init() {}

    func start() {
        guard BackgroundDiagnostics.isEnabled, watcher == nil else { return }

        Self.mainPort = pthread_mach_thread_np(pthread_self())
        Self.lastTick = CFAbsoluteTimeGetCurrent()
        Self.running = true

        let timer = Timer(timeInterval: tickInterval, repeats: true) { _ in
            Self.lastTick = CFAbsoluteTimeGetCurrent()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer

        let thread = Thread { [weak self] in
            self?.watchLoop()
        }
        thread.name = "wardragon.watchdog"
        thread.qualityOfService = .utility
        thread.start()
        watcher = thread
    }

    func stop() {
        Self.running = false
        heartbeat?.invalidate()
        heartbeat = nil
        watcher = nil
    }

    private func watchLoop() {
        var reportedFor: Double = 0

        while Self.running {
            Thread.sleep(forTimeInterval: 0.05)

            let tick = Self.lastTick
            let stalled = CFAbsoluteTimeGetCurrent() - tick

            guard stalled > stallThreshold, tick != reportedFor else { continue }
            reportedFor = tick

            let frames = Self.captureMainStack(maxDepth: maxDepth)
            guard !frames.isEmpty else { continue }

            print(String(format: "[STALL] main blocked %.2fs:", stalled))
            for (i, frame) in frames.enumerated() {
                print("[STALL]   \(i): \(frame)")
            }
        }
    }

    /// Symbolication runs only after thread_resume; dladdr and malloc must never
    /// be called while the main thread is suspended.
    private static func captureMainStack(maxDepth: Int) -> [String] {
        let addresses = captureMainFrames(maxDepth: maxDepth)
        return addresses.map { describe($0) ?? String(format: "0x%llx", $0) }
    }

    /// Collects raw return addresses only. No allocation, no dyld calls and no
    /// locks are taken while the main thread is suspended.
    private static func captureMainFrames(maxDepth: Int) -> [UInt64] {
        let port = mainPort
        guard port != 0 else { return [] }

        var scratch = [UInt64](repeating: 0, count: maxDepth + 2)
        var found = 0

        guard thread_suspend(port) == KERN_SUCCESS else { return [] }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }

        if kerr == KERN_SUCCESS {
            scratch[found] = state.__pc; found += 1
            scratch[found] = state.__lr; found += 1

            var fp = state.__fp
            while fp != 0, found < maxDepth {
                guard let words = readWords(at: fp) else { break }
                let nextFP = words.0
                let returnAddr = words.1
                guard returnAddr != 0 else { break }
                scratch[found] = returnAddr; found += 1
                guard nextFP > fp else { break }
                fp = nextFP
            }
        }

        thread_resume(port)

        return Array(scratch[0..<found])
    }

    /// Fault-tolerant read of two 64-bit words; unmapped memory returns nil
    /// instead of raising SIGSEGV.
    private static func readWords(at address: UInt64) -> (UInt64, UInt64)? {
        var buffer: (UInt64, UInt64) = (0, 0)
        var outSize: vm_size_t = 0

        let kr = withUnsafeMutablePointer(to: &buffer) { ptr -> kern_return_t in
            vm_read_overwrite(mach_task_self_,
                              vm_address_t(address),
                              vm_size_t(16),
                              vm_address_t(UInt(bitPattern: ptr)),
                              &outSize)
        }

        guard kr == KERN_SUCCESS, outSize == 16 else { return nil }
        return buffer
    }

    private static func describe(_ rawAddress: UInt64) -> String? {
        for candidate in [rawAddress, rawAddress & 0x0000000FFFFFFFFF] {
            guard let ptr = UnsafeRawPointer(bitPattern: UInt(candidate)) else { continue }
            var info = Dl_info()
            guard dladdr(ptr, &info) != 0 else { continue }

            let image = info.dli_fname.flatMap {
                (String(cString: $0) as NSString).lastPathComponent
            } ?? "?"

            guard let namePtr = info.dli_sname else {
                return String(format: "%@ 0x%llx", image, candidate)
            }
            let raw = String(cString: namePtr)
            return "\(image) \(demangle(raw) ?? raw)"
        }
        return nil
    }

    private static func demangle(_ symbol: String) -> String? {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return nil }
        return symbol
    }
}
