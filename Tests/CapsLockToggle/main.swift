import Foundation
import IOKit.hidsystem

enum CheckError: Error { case io(kern_return_t), state }

func checkToggle() throws {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { throw CheckError.state }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    let opened = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
    guard opened == KERN_SUCCESS else { throw CheckError.io(opened) }
    defer { IOServiceClose(connection) }
    var initial = false
    let read = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &initial)
    guard read == KERN_SUCCESS else { throw CheckError.io(read) }
    defer { IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), initial) }

    let controller = CapsLockController()
    for expected in [!initial, initial] {
        let result = controller.toggle()
        guard result == KERN_SUCCESS else { throw CheckError.io(result) }
        var matched = false
        for _ in 0..<20 {
            var actual = false
            let status = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &actual)
            guard status == KERN_SUCCESS else { throw CheckError.io(status) }
            if actual == expected { matched = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard matched else { throw CheckError.state }
    }
}

do {
    try checkToggle()
    print("Caps Lock changed in both directions; initial state restored.")
} catch {
    print("Caps Lock check failed: \(error)")
    exit(1)
}
