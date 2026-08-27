import CoreGraphics
import Foundation
import IOKit

enum SystemWakeVisibilityPolicy {
    static func isUserVisible(
        displayActive: Bool,
        displayAsleep: Bool,
        clamshellClosed: Bool?
    ) -> Bool {
        displayActive && !displayAsleep && clamshellClosed == false
    }
}

struct SystemWakeEnvironment {
    static var isUserVisibleWake: Bool {
        let displayID = CGMainDisplayID()
        return SystemWakeVisibilityPolicy.isUserVisible(
            displayActive: CGDisplayIsActive(displayID) != 0,
            displayAsleep: CGDisplayIsAsleep(displayID) != 0,
            clamshellClosed: clamshellClosed
        )
    }

    private static var clamshellClosed: Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        else { return nil }
        return value as? Bool
    }
}
