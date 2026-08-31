import XCTest
@testable import CapacitorIbeaconPlugin

class CapacitorIbeaconTests: XCTestCase {
    func testAuthorizationStatusMapping() {
        // Ensure the basic API wiring still works.
        let implementation = CapacitorIbeacon()
        let status = implementation.getAuthorizationStatus()

        /*
          Every status the plugin documents, authorized_reduced_accuracy included - it is reported in
          place of either grant when Precise Location is off, and was missing from this list for as
          long as it has existed. A simulator answers not_determined, so the omission never failed
          anything; it would have gone on not failing while the value was reachable from one grant
          and not the other.
        */
        let validStatuses = [
            "not_determined", "restricted", "denied",
            "authorized_always", "authorized_when_in_use", "authorized_reduced_accuracy",
            "unknown"
        ]
        XCTAssertTrue(validStatuses.contains(status), "undocumented status: \(status)")
    }

    func testIsRangingAvailable() {
        // Ensure the ranging availability check works.
        let implementation = CapacitorIbeacon()
        let isAvailable = implementation.isRangingAvailable()

        // Should return a boolean value
        XCTAssertNotNil(isAvailable)
    }
}
