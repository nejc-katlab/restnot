import Foundation
import IOKit.pwr_mgt

class SleepManager {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var isHolding = false

    func assertIfNeeded(reason: String) {
        guard !isHolding else { return }

        let reasonStr = "RestNot: \(reason) is running" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonStr,
            &assertionID
        )

        if result == kIOReturnSuccess {
            isHolding = true
            NSLog("RestNot: sleep assertion created — %@", reason)
        } else {
            NSLog("RestNot: failed to create sleep assertion (error %d)", result)
        }
    }

    func releaseAssertion() {
        guard isHolding else { return }

        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            NSLog("RestNot: sleep assertion released")
        }
        assertionID = IOPMAssertionID(0)
        isHolding = false
    }

    deinit {
        releaseAssertion()
    }
}
