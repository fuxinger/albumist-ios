// Only Darwin, and with @preconcurrency: `mach_task_self_` is a C global variable, and Swift 6
// rejects a reference to one as shared mutable state unless its module comes in through a
// @preconcurrency import. Foundation or UIKit here would bring Darwin in a second time without
// it, so this file imports nothing else.
@preconcurrency import Darwin

/// The app's memory footprint as iOS counts it against the app's limit (`phys_footprint`, the
/// number of Xcode's memory gauge and of the system ending an app for its memory), for the map
/// prototype's HUD and its 60-second tests.
enum PrototypeMemory {
    /// Megabytes (2^20 bytes); nil when the kernel does not answer.
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }
}
