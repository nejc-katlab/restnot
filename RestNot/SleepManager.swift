import Foundation
import IOKit.pwr_mgt

class SleepManager {
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var currentReason: String?
    private(set) var isHolding = false

    func assertIfNeeded(reason: String) {
        let reasonStr = "RestNot: \(reason) is running" as CFString

        if isHolding {
            guard reason != currentReason else { return }
            IOPMAssertionSetProperty(assertionID, kIOPMAssertionNameKey as CFString, reasonStr)
            currentReason = reason
            return
        }

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonStr,
            &assertionID
        )

        if result == kIOReturnSuccess {
            isHolding = true
            currentReason = reason
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
        currentReason = nil
        isHolding = false
    }

    deinit {
        releaseAssertion()
    }
}
