import Foundation
import Darwin

/// Mesures système légères (mémoire, CPU, état thermique) via les API publiques
/// Mach + Foundation. Aucun droit particulier.
enum SystemMetrics {

    /// Mémoire « utilisée » (approximation Moniteur d'activité) et totale.
    static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        return (min(used, total), total)
    }

    /// Compteurs de ticks CPU cumulés (tous cœurs). Faire la différence entre
    /// deux appels pour obtenir un pourcentage d'occupation.
    static func cpuTicks() -> (total: Double, idle: Double)? {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }

        var total = 0.0, idle = 0.0
        let states = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let b = i * states
            total += Double(info[b + Int(CPU_STATE_USER)]) + Double(info[b + Int(CPU_STATE_SYSTEM)])
                   + Double(info[b + Int(CPU_STATE_NICE)]) + Double(info[b + Int(CPU_STATE_IDLE)])
            idle  += Double(info[b + Int(CPU_STATE_IDLE)])
        }
        let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: UnsafeRawPointer(info))), size)
        return (total, idle)
    }

    static var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return "normale"
        case .fair:     return "modérée"
        case .serious:  return "élevée"
        case .critical: return "critique"
        @unknown default: return "n/c"
        }
    }
}
