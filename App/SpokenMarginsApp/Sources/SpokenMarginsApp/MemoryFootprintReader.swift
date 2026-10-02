// `@preconcurrency import Darwin` comes first, and Foundation isn't imported: `mach_task_self_` is a C
// global, which Swift 6 rejects as shared mutable state unless the first import that provides it is
// `@preconcurrency`. Foundation re-exports Darwin, so importing it first would undo that.
@preconcurrency import Darwin
import os

/// Reads the app's memory use the way iOS counts it against the app's limit (#122).
enum MemoryFootprintReader {
    /// The physical footprint (`task_vm_info.phys_footprint`), the number jetsam compares with the limit.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// How much more the app may allocate before iOS ends it; nil where iOS doesn't say (0 on the simulator).
    static func availableBytes() -> UInt64? {
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
    }
}
