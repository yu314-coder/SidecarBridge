import Foundation
import IOKit

enum CableDetector {
    static func isIPadConnected() -> Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let keys = ["USB Product Name", "kUSBProductString", "Product Name"]
            for key in keys {
                guard let unmanaged = IORegistryEntryCreateCFProperty(
                    service,
                    key as CFString,
                    kCFAllocatorDefault,
                    0
                ) else { continue }
                if let value = unmanaged.takeRetainedValue() as? String,
                   value.localizedCaseInsensitiveContains("iPad") {
                    return true
                }
            }
        }
        return false
    }
}
