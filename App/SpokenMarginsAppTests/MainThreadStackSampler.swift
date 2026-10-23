import Darwin
import Foundation

/// Test-only: the main thread's call stack, read from another thread while the main thread is stuck (#2195).
/// A tear-down drain that runs long prints it, so the lane log names the code behind a backlog instead of
/// leaving the cause to inference, as the first fix for #2195 did.
enum MainThreadStackSampler {
    /// Pauses `mainThread` just long enough to walk its frame pointers, then names each return address.
    /// Nothing that allocates or takes a lock runs while it is paused: the main thread may hold that lock.
    /// iOS has no `pthread_main_thread_np`, so the caller takes `pthread_self()` on the main thread.
    static func sample(_ mainThread: pthread_t, maxFrames: Int = 40) -> [String] {
        #if arch(arm64)
        let machThread = pthread_mach_thread_np(mainThread)
        let stackTop = UInt(bitPattern: pthread_get_stackaddr_np(mainThread))
        let stackBottom = stackTop - UInt(pthread_get_stacksize_np(mainThread))
        let addresses = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        defer { addresses.deallocate() }
        var found = 0
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        guard thread_suspend(machThread) == KERN_SUCCESS else { return [] }
        let read = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(machThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        if read == KERN_SUCCESS {
            addresses[0] = UInt(state.__pc)
            addresses[1] = UInt(state.__lr)
            found = 2
            var frame = UInt(state.__fp)
            while found < maxFrames, frame % 8 == 0, frame >= stackBottom, frame + 16 <= stackTop {
                let words = UnsafePointer<UInt>(bitPattern: frame)!
                let (next, returnAddress) = (words[0], words[1])
                guard returnAddress != 0 else { break }
                addresses[found] = returnAddress
                found += 1
                guard next > frame else { break }
                frame = next
            }
        }
        thread_resume(machThread)
        return (0..<found).map { describe(addresses[$0], index: $0) }
        #else
        return []
        #endif
    }

    private static func describe(_ address: UInt, index: Int) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return "#\(index) 0x\(String(address, radix: 16))" }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
        let offset = address - UInt(bitPattern: info.dli_saddr)
        return "#\(index) \(image) \(symbol) + \(offset)"
    }
}

/// Prints the main thread's stack every half second until `finish()` is called, at most four times (#2195).
final class MainThreadStallWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let label: String
    private let start = Date()
    private let mainThread: pthread_t

    /// Call on the main thread.
    init(label: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.label = label
        mainThread = pthread_self()
        schedule(after: 0.5, remaining: 4)
    }

    func finish() { lock.withLock { finished = true } }

    private func schedule(after delay: TimeInterval, remaining: Int) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [self] in
            guard remaining > 0, !lock.withLock({ finished }) else { return }
            let frames = MainThreadStackSampler.sample(mainThread)
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(start))
            print("Main thread stack \(elapsed) s into the drain \(label) (#2195):\n" + frames.joined(separator: "\n"))
            schedule(after: 0.5, remaining: remaining - 1)
        }
    }
}
