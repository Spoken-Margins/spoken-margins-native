// `@preconcurrency import Darwin` comes first, and Foundation isn't imported, for the same reason as in
// MemoryFootprintReader.swift: Swift 6 accepts the C global `mach_task_self_` only that way.
@preconcurrency import Darwin

/// Test-side memory helpers for MemoryFootprintRecorderTests (#1129): the resident size, which the
/// footprint must not be mistaken for, and mappings the test can touch and release page by page.
enum TaskMemoryProbe {
    static func residentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : nil
    }

    /// Maps `bytes` of private memory and writes every page, so the app really owns it.
    static func touchAnonymous(bytes: Int) -> UnsafeMutableRawPointer? {
        guard let region = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              region != MAP_FAILED else { return nil }
        for offset in stride(from: 0, to: bytes, by: Int(getpagesize())) {
            region.storeBytes(of: 1, toByteOffset: offset, as: UInt8.self)
        }
        return region
    }

    /// Maps the file at `path` read-only and reads every page: resident, but clean file pages that
    /// iOS can drop at will, so they don't count toward the app's footprint.
    static func readMapped(path: String, bytes: Int) -> UnsafeMutableRawPointer? {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard let region = mmap(nil, bytes, PROT_READ, MAP_PRIVATE, descriptor, 0),
              region != MAP_FAILED else { return nil }
        var sum = 0
        for offset in stride(from: 0, to: bytes, by: Int(getpagesize())) {
            sum &+= Int(region.load(fromByteOffset: offset, as: UInt8.self))
        }
        return sum >= 0 ? region : nil
    }

    static func unmap(_ region: UnsafeMutableRawPointer, bytes: Int) {
        munmap(region, bytes)
    }
}
