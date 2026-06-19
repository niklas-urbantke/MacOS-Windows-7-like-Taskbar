import Foundation
import Darwin

/// CPU and RAM usage sampling via the Mach kernel APIs.
final class SystemStats {
    private var prevUsed: [Double] = []
    private var prevTotal: [Double] = []

    /// Overall CPU usage 0…100 (delta since the previous call).
    func cpuUsagePercent() -> Int {
        var numCPUs = natural_t(0)
        var infoArray: processor_info_array_t? = nil
        var infoCount = mach_msg_type_number_t(0)
        let r = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &infoArray, &infoCount)
        guard r == KERN_SUCCESS, let info = infoArray else { return 0 }
        defer {
            let size = vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.stride))
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let n = Int(numCPUs)
        if prevUsed.count != n { prevUsed = Array(repeating: 0, count: n); prevTotal = Array(repeating: 0, count: n) }

        var usedDelta = 0.0, totalDelta = 0.0
        for i in 0..<n {
            let base = i * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let system = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            let used = user + system + nice
            let total = used + idle
            usedDelta += used - prevUsed[i]
            totalDelta += total - prevTotal[i]
            prevUsed[i] = used
            prevTotal[i] = total
        }
        guard totalDelta > 0 else { return 0 }
        return max(0, min(100, Int((usedDelta / totalDelta) * 100)))
    }

    /// Used physical memory 0…100.
    func ramUsagePercent() -> Int {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return max(0, min(100, Int(used / total * 100)))
    }
}
