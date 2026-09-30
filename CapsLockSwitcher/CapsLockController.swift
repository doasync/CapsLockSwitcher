import IOKit.hidsystem

final class CapsLockController {
    private var connection: io_connect_t = 0

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) != KERN_SUCCESS {
            connection = 0
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func toggle() -> kern_return_t {
        guard connection != 0 else { return kIOReturnNotOpen }
        var enabled = false
        let result = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &enabled)
        guard result == KERN_SUCCESS else { return result }
        return IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !enabled)
    }
}
