import Foundation
import os

/// This app's memory footprint, the number iOS uses when it decides to close an app for using too much memory.
/// A meter samples it every 10 ms while a tool runs, so the timing log can show each tool's peak.
final class MemoryMeter: @unchecked Sendable {
    /// Current footprint in MB (0 if the system call fails).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// How much more this app can use before iOS closes it, in MB (nil off iOS).
    static func availableMB() -> Double? {
        #if os(iOS)
        return Double(os_proc_available_memory()) / 1_048_576
        #else
        return nil
        #endif
    }

    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    private let lock = NSLock()
    private var peak: Double

    init() {
        peak = MemoryMeter.footprintMB()
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    deinit { timer.cancel() }

    private func sample() {
        let now = MemoryMeter.footprintMB()
        lock.lock()
        peak = max(peak, now)
        lock.unlock()
    }

    /// Stops sampling and returns the highest footprint seen, in MB.
    func stop() -> Double {
        timer.cancel()
        sample()
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}
