import XCTest
@testable import CapacitorIbeaconPlugin

class CapacitorIbeaconDiagnosticLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearLog()
    }

    override func tearDown() {
        clearLog()
        super.tearDown()
    }

    // Both the flag and the file are process-wide, and reset() also clears the once-per-process
    // marker - so each test starts from the same state regardless of the order they run in.
    private func clearLog() {
        CapacitorIbeaconDiagnosticLog.isEnabled = false
        CapacitorIbeaconDiagnosticLog.reset()
        CapacitorIbeaconDiagnosticLog.flush()
    }

    private func readLog() -> String {
        CapacitorIbeaconDiagnosticLog.flush()
        guard let url = CapacitorIbeaconDiagnosticLog.fileURL,
              let data = try? Data(contentsOf: url) else {
            return ""
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func testWritesNothingWhileDisabled() {
        CapacitorIbeaconDiagnosticLog.write("this must not be written")

        XCTAssertEqual(readLog(), "", "the log is opt-in and must stay absent until the host app asks for it")
    }

    func testWritesOneTimestampedLinePerMessage() {
        CapacitorIbeaconDiagnosticLog.isEnabled = true

        CapacitorIbeaconDiagnosticLog.write("first")
        CapacitorIbeaconDiagnosticLog.write("second")

        let lines = readLog().split(separator: "\n").map(String.init)
        // The process marker is written ahead of the first message, so three lines rather than two.
        // Asserted before the lines are indexed, and guarded after, so that a wrong count fails this
        // test rather than trapping and taking the rest of the run down with it.
        XCTAssertEqual(lines.count, 3, "unexpected log contents: \(lines)")
        guard lines.count == 3 else { return }
        XCTAssertTrue(lines[1].hasSuffix(" first"))
        XCTAssertTrue(lines[2].hasSuffix(" second"))
        // Every line carries its own timestamp, which is the only ordering a reader gets once the
        // file spans several processes.
        for line in lines {
            XCTAssertNotNil(line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "#, options: .regularExpression),
                            "unstamped line: \(line)")
        }
    }

    /*
      The marker that separates one process from the next.

      Core Location relaunches the app in the background to deliver a crossing, so a single file spans
      many processes - and the state a relaunched process starts with is what decides whether the
      event arriving moments later is announced. Without this the boundary cannot be found.
    */
    func testMarksWhereEachProcessBegins() {
        CapacitorIbeaconDiagnosticLog.isEnabled = true

        CapacitorIbeaconDiagnosticLog.write("an event")

        let first = readLog().split(separator: "\n").map(String.init).first ?? ""
        XCTAssertTrue(first.contains("--- process "))
        XCTAssertTrue(first.contains("\(ProcessInfo.processInfo.processIdentifier)"))
    }

    /*
      The funnel every log site in the plugin now goes through.

      All nineteen of them pass a printf format with %@ and %d and rely on it being rendered for the
      file the same way NSLog renders it for the console. This is the one part of the change that
      could fail silently: a format that does not render leaves the console correct and the file
      full of unsubstituted placeholders.
    */
    func testBeaconLogRendersTheSameFormatNSLogIsGiven() {
        CapacitorIbeaconDiagnosticLog.isEnabled = true

        beaconLog("CapacitorIbeacon: ranged %@ - %d heard: %@", "ZHR-K3-Home", 3, "rssi -71")

        XCTAssertTrue(readLog().contains("CapacitorIbeacon: ranged ZHR-K3-Home - 3 heard: rssi -71"))
    }

    // The same funnel, reached the way the host app reaches it.
    func testPublicLogRendersTheSameFormat() {
        CapacitorIbeaconDiagnosticLog.isEnabled = true

        CapacitorIbeaconDiagnosticLog.log("BeaconLoopback: %@ exit: holding %.0fs before posting", "ZHR-K3-Home", 180.0)

        XCTAssertTrue(readLog().contains("BeaconLoopback: ZHR-K3-Home exit: holding 180s before posting"))
    }

    func testBeaconLogWritesNothingToTheFileWhileDisabled() {
        beaconLog("CapacitorIbeacon: %@ must not reach the file", "this")

        XCTAssertEqual(readLog(), "")
    }

    /*
      Documents is backed up by default, and this file records where its owner has been.

      Worth a test because nothing would notice it missing: no behaviour changes and no error is
      raised, the trace simply starts syncing to iCloud and restoring onto the next device. The
      attribute is the only evidence either way.
    */
    func testKeepsTheLogOutOfBackups() throws {
        CapacitorIbeaconDiagnosticLog.isEnabled = true

        CapacitorIbeaconDiagnosticLog.write("a walk that stays on this phone")
        CapacitorIbeaconDiagnosticLog.flush()

        let url = try XCTUnwrap(CapacitorIbeaconDiagnosticLog.fileURL)
        let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true)
    }

    func testResetEmptiesTheLog() {
        CapacitorIbeaconDiagnosticLog.isEnabled = true
        CapacitorIbeaconDiagnosticLog.write("before the reset")
        XCTAssertTrue(readLog().contains("before the reset"))

        CapacitorIbeaconDiagnosticLog.reset()

        XCTAssertEqual(readLog(), "")
    }
}
